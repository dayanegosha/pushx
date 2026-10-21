import Combine
import Foundation
import StoreKit

@MainActor
final class SubscriptionService: ObservableObject {
    static let shared = SubscriptionService()
    @Published private(set) var products: [Product] = []
    @Published private(set) var isPremium = false
    @Published private(set) var isLoading = false
    @Published private(set) var purchasePending = false
    @Published private(set) var activeProductID: String?
    @Published private(set) var expirationDate: Date?
    @Published var errorMessage: String?

    private var updatesTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var refreshGeneration = 0

    private init() {}

    func start() async {
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                for await result in Transaction.updates {
                    guard !Task.isCancelled, let self else { return }
                    switch result {
                    case .verified(let transaction):
                        guard AppConfiguration.subscriptionIDs.contains(transaction.productID) else { continue }
                        await self.refreshEntitlements()
                        await transaction.finish()
                    case .unverified:
                        self.errorMessage = ServiceError.verificationFailed.localizedDescription
                    }
                }
            }
        }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        await refreshEntitlements()
        do {
            let loaded = try await Product.products(for: AppConfiguration.subscriptionIDs)
            products = loaded.filter { $0.type == .autoRenewable }.sorted { $0.price < $1.price }
            if products.isEmpty { errorMessage = ServiceError.productsUnavailable.localizedDescription }
            else { errorMessage = nil }
            await refreshEntitlements()
        } catch { errorMessage = ServiceCopy.message(for: error) }
    }

    func purchase(_ product: Product) async {
        guard !isLoading, AppConfiguration.subscriptionIDs.contains(product.id), product.type == .autoRenewable else { return }
        isLoading = true
        purchasePending = false
        errorMessage = nil
        defer { isLoading = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result,
                      AppConfiguration.subscriptionIDs.contains(transaction.productID) else {
                    throw ServiceError.verificationFailed
                }
                await refreshEntitlements()
                await transaction.finish()
            case .pending:
                purchasePending = true
            case .userCancelled:
                break
            @unknown default:
                throw ServiceError.invalidResponse
            }
        } catch { errorMessage = ServiceCopy.message(for: error) }
    }

    func restore() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !isPremium {
                errorMessage = ServiceCopy.text("No active pushx Plus subscription was found for this Apple account.", "Для этого аккаунта Apple не найдена активная подписка pushx Plus.", "未找到此 Apple 账户的有效 pushx Plus 订阅。")
            }
        } catch { errorMessage = ServiceCopy.message(for: error) }
    }

    private func refreshEntitlements() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let now = Date()
        var candidates: [(id: String, expiration: Date)] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  AppConfiguration.subscriptionIDs.contains(transaction.productID),
                  transaction.productType == .autoRenewable,
                  transaction.revocationDate == nil, !transaction.isUpgraded,
                  let expiration = transaction.expirationDate, expiration > now else { continue }
            candidates.append((transaction.productID, expiration))
        }
        for product in products {
            guard let subscription = product.subscription,
                  let statuses = try? await subscription.status else { continue }
            for status in statuses where status.state == .inGracePeriod {
                guard case .verified(let transaction) = status.transaction,
                      case .verified(let renewal) = status.renewalInfo,
                      AppConfiguration.subscriptionIDs.contains(transaction.productID),
                      transaction.revocationDate == nil, !transaction.isUpgraded,
                      let expiration = renewal.gracePeriodExpirationDate, expiration > now else { continue }
                candidates.append((transaction.productID, expiration))
            }
        }
        guard generation == refreshGeneration else { return }
        let best = candidates.max { $0.expiration < $1.expiration }
        isPremium = best != nil
        activeProductID = best?.id
        expirationDate = best?.expiration
        if best != nil { purchasePending = false }
        expiryTask?.cancel()
        if let expiration = best?.expiration {
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(1, expiration.timeIntervalSinceNow + 0.5))) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self?.refreshEntitlements()
            }
        }
    }
}
