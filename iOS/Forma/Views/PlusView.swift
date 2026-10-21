import SwiftUI
import StoreKit

struct PlusView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var subscription: SubscriptionService
    var body: some View {
        NavigationStack {
            ScrollView {
                AdaptiveContent(maxWidth: 640) {
                VStack(alignment: .leading, spacing: 24) {
                    Brand().padding(.top, 20)
                    Text(L.text("plus_title")).font(AppFont.text(42, weight: .semibold)).accessibilityLabel("pushx Plus")
                    Text(L.text("plus_body")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    InfoCard(icon: "chart.bar.xaxis", title: L.text("advanced_stats"), detail: L.text("advanced_stats_body"))
                    InfoCard(icon: "square.and.arrow.up", title: L.text("export_csv"), detail: L.text("export_body"))
                    if subscription.isPremium {
                        Label(L.text("plus_active"), systemImage: "checkmark.seal").font(AppFont.text(17, weight: .semibold))
                    } else {
                        ForEach(subscription.products) { product in
                            Button { Task { await subscription.purchase(product) } } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(planTitle(product)).font(AppFont.text(17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                                        Text(L.text("auto_renewable")).font(AppFont.text(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    Text(product.displayPrice).font(AppFont.text(20, weight: .medium)).fixedSize()
                                }.padding(22).background(Color.panel, in: RoundedRectangle(cornerRadius: 24))
                            }.buttonStyle(.plain).disabled(subscription.isLoading || AppConfiguration.privacyURL == nil || AppConfiguration.termsURL == nil)
                        }
                        if subscription.products.isEmpty && !subscription.isLoading { StatusNote(text: L.text("products_unavailable")) }
                        if AppConfiguration.privacyURL == nil || AppConfiguration.termsURL == nil { StatusNote(text: L.text("purchase_not_configured")) }
                    }
                    if subscription.isLoading { ProgressView().frame(maxWidth: .infinity) }
                    if subscription.purchasePending { StatusNote(text: L.text("purchase_pending")) }
                    if let error = subscription.errorMessage { StatusNote(text: error) }
                    Text(L.text("subscription_disclosure")).font(AppFont.text(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(L.text("restore_purchases")) { Task { await subscription.restore() } }.font(AppFont.text(15)).disabled(subscription.isLoading)
                    ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) {
                        if let url = AppConfiguration.privacyURL { Link(L.text("privacy"), destination: url) }
                        if let url = AppConfiguration.termsURL { Link(L.text("terms"), destination: url) }
                    }.font(AppFont.text(12))
                    VStack(alignment: .leading, spacing: 12) {
                        if let url = AppConfiguration.privacyURL { Link(L.text("privacy"), destination: url) }
                        if let url = AppConfiguration.termsURL { Link(L.text("terms"), destination: url) }
                    }.font(AppFont.text(12))
                    }
                    Button(L.text("continue_free")) { dismiss() }.font(AppFont.text(14, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                }
            }.background(Color.canvas).toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel(L.text("close")) } }
                .task { await subscription.refresh() }
        }
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
