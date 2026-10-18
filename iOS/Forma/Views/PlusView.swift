import SwiftUI
import StoreKit

struct PlusView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var subscription: SubscriptionService
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Brand().padding(.top, 20)
                    Text(L.text("plus_title")).font(.system(size: 44, weight: .bold, design: .rounded)).tracking(-2).accessibilityLabel("FORMA Plus")
                    Text(L.text("plus_body")).foregroundStyle(.secondary)
                    InfoCard(icon: "chart.bar.xaxis", title: L.text("advanced_stats"), detail: L.text("advanced_stats_body"))
                    InfoCard(icon: "square.and.arrow.up", title: L.text("export_csv"), detail: L.text("export_body"))
                    if subscription.isPremium {
                        Label(L.text("plus_active"), systemImage: "checkmark.seal").font(.headline)
                    } else {
                        ForEach(subscription.products) { product in
                            Button { Task { await subscription.purchase(product) } } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(planTitle(product)).font(.headline)
                                        Text(L.text("auto_renewable")).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(product.displayPrice).font(.title3.weight(.medium))
                                }.padding(22).background(Color.panel, in: RoundedRectangle(cornerRadius: 24))
                            }.buttonStyle(.plain).disabled(subscription.isLoading || AppConfiguration.privacyURL == nil || AppConfiguration.termsURL == nil)
                        }
                        if subscription.products.isEmpty && !subscription.isLoading { StatusNote(text: L.text("products_unavailable")) }
                        if AppConfiguration.privacyURL == nil || AppConfiguration.termsURL == nil { StatusNote(text: L.text("purchase_not_configured")) }
                    }
                    if subscription.isLoading { ProgressView().frame(maxWidth: .infinity) }
                    if subscription.purchasePending { StatusNote(text: L.text("purchase_pending")) }
                    if let error = subscription.errorMessage { StatusNote(text: error) }
                    Text(L.text("subscription_disclosure")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button(L.text("restore_purchases")) { Task { await subscription.restore() } }.font(.subheadline).disabled(subscription.isLoading)
                    HStack(spacing: 24) {
                        if let url = AppConfiguration.privacyURL { Link(L.text("privacy"), destination: url) }
                        if let url = AppConfiguration.termsURL { Link(L.text("terms"), destination: url) }
                    }.font(.caption)
                    Button(L.text("continue_free")) { dismiss() }.font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.padding(26)
            }.toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel(L.text("close")) } }
                .task { await subscription.refresh() }
        }.tint(.primary)
    }
    private func planTitle(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return product.displayName }
        switch period.unit {
        case .month: return period.value == 1 ? L.text("monthly") : product.displayName
        case .year: return period.value == 1 ? L.text("yearly") : product.displayName
        default: return product.displayName
        }
    }
}
