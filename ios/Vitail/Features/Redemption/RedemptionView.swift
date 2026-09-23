import SwiftUI

struct RedemptionView: View {
    @ObservedObject var viewModel: RedemptionViewModel
    @State private var selectedCafe: CafeRewardGroup?
    @State private var selectedOrder: Redemption?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your points").font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    Text(viewModel.balance.map { "\($0.formatted())" } ?? "—")
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    if let balance = viewModel.balance {
                        Text(CoffeeEstimate.text(for: balance))
                            .font(.caption).foregroundStyle(AppColors.secondaryText)
                            .accessibilityHint("Estimate based on 60 points per cup. Menu prices vary.")
                    }
                }
                .padding(.vertical, 12)
                PendingPurchaseNotice(viewModel: viewModel)
                if let message = viewModel.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message).font(.subheadline).foregroundStyle(AppColors.error)
                        Button("Try again") { Task { await viewModel.refresh() } }
                            .disabled(viewModel.isLoading || viewModel.isMutating)
                    }
                }
                if !viewModel.pendingRedemptions.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Ready to collect").font(.headline)
                        ForEach(viewModel.pendingRedemptions) { order in orderCard(order) }
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Rewards").font(.headline)
                    if viewModel.cafes.isEmpty && !viewModel.isLoading {
                        ContentUnavailableView("No cafés yet", systemImage: "cup.and.saucer",
                                               description: Text("Check back soon for local rewards."))
                    }
                    ForEach(viewModel.cafes) { cafe in
                        Button { selectedCafe = cafe } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                CafeCoverPhoto(url: cafe.photo, name: cafe.name)
                                    .frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 16))
                                Text(cafe.name).font(.headline).foregroundStyle(AppColors.primaryText)
                                Text(cafe.openingHours.isEmpty ? "Opening hours not provided" : cafe.openingHours)
                                    .font(.caption).foregroundStyle(AppColors.secondaryText)
                                    .multilineTextAlignment(.leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityHint("View café and menu").padding(.bottom, 8)
                    }
                }
                if !viewModel.history.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("History").font(.headline)
                        ForEach(viewModel.history) { order in orderCard(order) }
                    }
                }
            }
            .padding(AppSpacing.large)
        }
        .background(AppColors.background)
        .refreshable { await viewModel.refresh() }
        .overlay {
            if viewModel.isLoading && viewModel.balance == nil { LoadingView(message: "Loading cafés…") }
        }
        .sheet(item: $selectedCafe) { cafe in CafeMenuView(cafe: cafe, viewModel: viewModel) }
        .sheet(item: $selectedOrder) { order in RedemptionDetailView(order: order, viewModel: viewModel) }
    }

    private func orderCard(_ order: Redemption) -> some View {
        Button { selectedOrder = order } label: {
            HStack(spacing: 14) {
                AvatarView(url: order.cafePhoto, name: order.cafeNameSnapshot ?? "Café", systemImage: "storefront.fill", size: 54)
                VStack(alignment: .leading, spacing: 5) {
                    Text(order.cafeNameSnapshot ?? "Café").font(.subheadline.weight(.semibold))
                    Text(order.rewardNameSnapshot).font(.subheadline)
                    Text(order.status == .pending ? "\(order.pointCostSnapshot) pts · Ready to collect" : order.status.rawValue.capitalized)
                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppColors.secondaryText)
            }
            .foregroundStyle(AppColors.primaryText).padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityHint("View order details")
    }
}

struct CafeCoverPhoto: View {
    let url: String?
    let name: String
    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        AppColors.surface
                        Image(systemName: "storefront").font(.system(size: 44, weight: .ultraLight))
                            .foregroundStyle(AppColors.brand)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .accessibilityLabel("\(name) photo")
    }
}

struct CafeMenuView: View {
    let cafe: CafeRewardGroup
    @ObservedObject var viewModel: RedemptionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedReward: Reward?
    private var currentCafe: CafeRewardGroup { viewModel.cafes.first { $0.id == cafe.id } ?? cafe }
    private var menu: [Reward] { viewModel.cafes.first { $0.id == cafe.id }?.rewards ?? [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    CafeCoverPhoto(url: currentCafe.photo, name: currentCafe.name)
                        .frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 20))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(currentCafe.name).font(.title2.weight(.semibold)).foregroundStyle(AppColors.primaryText)
                        if !currentCafe.description.isEmpty { Text(currentCafe.description).font(.subheadline) }
                        if !currentCafe.openingHours.isEmpty {
                            Label(currentCafe.openingHours, systemImage: "clock").font(.caption)
                        }
                        if !currentCafe.address.isEmpty { Text(currentCafe.address).font(.caption) }
                        if let url = mapsURL(currentCafe.googleMapsURL) {
                            Link(destination: url) { Label("Google Maps", systemImage: "arrow.up.right") }
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    .foregroundStyle(AppColors.secondaryText)
                    if let notice = viewModel.purchaseNotice {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .font(.subheadline).foregroundStyle(AppColors.success)
                    }
                    if let message = viewModel.errorMessage {
                        Text(message).font(.subheadline).foregroundStyle(AppColors.error)
                    }
                    PendingPurchaseNotice(viewModel: viewModel)
                    Text("Menu").font(.headline)
                    if menu.isEmpty { Text("No items available right now.").foregroundStyle(AppColors.secondaryText) }
                    ForEach(menu) { reward in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(reward.name).font(.headline)
                            if !reward.description.isEmpty {
                                Text(reward.description).font(.subheadline).foregroundStyle(AppColors.secondaryText)
                            }
                            let isRetry = viewModel.retryRewardID == reward.id
                            let canAfford = (viewModel.balance ?? 0) >= reward.pointCost
                            PrimaryButton(
                                title: "\(isRetry ? "Retry purchase" : "Purchase") · \(reward.pointCost) pts",
                                isLoading: viewModel.redeemingRewardID == reward.id,
                                isDisabled: viewModel.isLoading || viewModel.isMutating ||
                                    (!canAfford && !isRetry) || (viewModel.retryRewardID != nil && !isRetry)
                            ) { selectedReward = reward }
                            if !canAfford && !isRetry {
                                Text("You need \(max(0, reward.pointCost - (viewModel.balance ?? 0))) more points.")
                                    .font(.caption).foregroundStyle(AppColors.secondaryText)
                            }
                        }
                        .padding(18).background(AppColors.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(AppSpacing.large)
            }
            .background(AppColors.background)
            .navigationTitle("Vitail").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Confirm purchase", isPresented: Binding(
                get: { selectedReward != nil }, set: { if !$0 { selectedReward = nil } }
            ), titleVisibility: .visible, presenting: selectedReward) { reward in
                Button("Purchase · \(reward.pointCost) pts") {
                    Task { await viewModel.redeem(rewardID: reward.id) }
                }
            } message: { reward in
                Text("\(reward.name) at \(reward.cafeName). Points are deducted now; collect before the end of today.")
            }
        }
        .vitailAppearance()
    }
}

struct RedemptionDetailView: View {
    let order: Redemption
    @ObservedObject var viewModel: RedemptionViewModel
    @Environment(\.dismiss) private var dismiss
    private var current: Redemption { viewModel.redemptions.first { $0.id == order.id } ?? order }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    AvatarView(url: current.cafePhoto, name: current.cafeNameSnapshot ?? "Café", systemImage: "storefront.fill", size: 80)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(current.cafeNameSnapshot ?? "Café").font(.title2.weight(.semibold))
                        Text(current.rewardNameSnapshot).font(.title3)
                        Text("\(current.pointCostSnapshot) points").foregroundStyle(AppColors.secondaryText)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Order \(current.referenceNumber)").font(.subheadline.monospaced())
                        if let address = current.cafeAddress, !address.isEmpty { Text(address).font(.subheadline) }
                        if let hours = current.cafeOpeningHours, !hours.isEmpty {
                            Label(hours, systemImage: "clock").font(.caption)
                        }
                        if let url = mapsURL(current.cafeGoogleMapsURL) {
                            Link(destination: url) { Label("Google Maps", systemImage: "arrow.up.right") }
                        }
                    }
                    .foregroundStyle(AppColors.secondaryText)
                    if let message = viewModel.errorMessage {
                        Text(message).font(.subheadline).foregroundStyle(AppColors.error)
                    }
                    if current.status == .pending {
                        Text("Show this order to the café. Slide only after you receive your item.")
                            .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                        if let expiry = current.expiresAt.flatMap(Self.date) {
                            Text("Collect by \(expiry.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(AppColors.secondaryText)
                        }
                        SlideToCollect(isLoading: viewModel.collectingRedemptionID == current.id,
                                       isDisabled: viewModel.isLoading || viewModel.isMutating) {
                            await viewModel.collect(redemptionID: current.id)
                        }
                    } else {
                        Label(current.status == .collected ? "Collected. Enjoy!" : "\(current.status.rawValue.capitalized) · points refunded",
                              systemImage: current.status == .collected ? "checkmark.circle.fill" : "arrow.uturn.backward.circle")
                            .font(.headline).foregroundStyle(AppColors.success)
                    }
                }
                .padding(AppSpacing.large).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppColors.background)
            .navigationTitle("Your order").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await viewModel.refresh() }
        }
        .vitailAppearance()
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private func mapsURL(_ text: String?) -> URL? {
    guard let text, let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    return url
}

private struct PendingPurchaseNotice: View {
    @ObservedObject var viewModel: RedemptionViewModel

    var body: some View {
        if let rewardID = viewModel.retryRewardID {
            VStack(alignment: .leading, spacing: 10) {
                Text("Check your previous purchase before placing another order.")
                    .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                if let reward = viewModel.retryReward {
                    Text("\(reward.name) · \(reward.cafeName)").font(.subheadline.weight(.medium))
                }
                PrimaryButton(
                    title: viewModel.retryReward.map { "Retry purchase · \($0.pointCost) pts" } ?? "Check purchase",
                    isLoading: viewModel.isMutating, isDisabled: viewModel.isLoading || viewModel.isMutating
                ) { Task { await viewModel.redeem(rewardID: rewardID) } }
            }
        }
    }
}
