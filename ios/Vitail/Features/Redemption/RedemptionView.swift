import SwiftUI

/// The owner's Redeem tab: current point balance, pending orders waiting to
/// be collected in-store, and the partner venues an owner can order from
/// (README.md, "Redeeming Points").
struct RedemptionView: View {
    @ObservedObject var viewModel: RedemptionViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                balanceCard

                if let errorMessage = viewModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.error)
                        .accessibilityIdentifier("redemptionError")
                }

                if !viewModel.pendingOrders.isEmpty {
                    pendingOrdersSection
                }

                venuesSection

                if !viewModel.recentlyCollectedOrders.isEmpty {
                    recentOrdersSection
                }
            }
            .padding(AppSpacing.large)
        }
        .background(AppColors.background)
        .refreshable {
            await viewModel.refresh()
        }
        .overlay {
            if viewModel.isLoading && viewModel.venues.isEmpty {
                LoadingView(message: "Loading rewards…")
            }
        }
        .task {
            await viewModel.loadInitialData()
        }
    }

    private var balanceCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your points")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                Text("\(viewModel.balance ?? 0) pts")
                    .font(.title.bold())
            }
            Spacer()
            Image(systemName: "pawprint.fill")
                .font(.system(size: 28))
                .foregroundStyle(AppColors.brand)
        }
        .padding(AppSpacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }

    private var pendingOrdersSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Ready to collect")
                .font(.headline)

            ForEach(viewModel.pendingOrders) { order in
                PendingOrderRow(order: order) {
                    Task { await viewModel.collect(orderID: order.id) }
                }
            }
        }
    }

    private var venuesSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Partner venues")
                .font(.headline)

            if viewModel.venues.isEmpty && !viewModel.isLoading {
                Text("No partner venues yet.")
                    .foregroundStyle(AppColors.secondaryText)
            }

            ForEach(viewModel.venues) { venue in
                NavigationLink {
                    VenueOfferView(venue: venue, viewModel: viewModel)
                } label: {
                    VenueRow(venue: venue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentOrdersSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Recently redeemed")
                .font(.headline)

            ForEach(viewModel.recentlyCollectedOrders) { order in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(order.venueName)
                            .fontWeight(.medium)
                        Text("Ref \(order.referenceNumber) · \(order.totalPoints) pts")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.brand)
                }
                .padding(AppSpacing.medium)
                .background(AppColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
            }
        }
    }
}

private struct VenueRow: View {
    let venue: Venue

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(venue.name)
                    .fontWeight(.semibold)
                Text(venue.venueType.capitalized)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }
}

private struct PendingOrderRow: View {
    let order: RedemptionOrder
    let onRedeem: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(order.venueName)
                    .fontWeight(.semibold)
                Text("Ref \(order.referenceNumber) · \(order.totalPoints) pts")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            PrimaryButton(title: "Redeem", action: onRedeem)
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }
}
