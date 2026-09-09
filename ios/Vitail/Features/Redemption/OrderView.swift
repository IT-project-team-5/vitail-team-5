import SwiftUI

struct OrderView: View {
    @ObservedObject var viewModel: RedemptionViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.large) {

                // Ready to pick up header
                HStack {
                    Text("Ready to pick up")
                        .font(.title3)
                        .fontWeight(.bold)

                    Spacer()

                    Text("\(viewModel.pendingOrders.count)")
                        .font(.headline)
                        .foregroundStyle(AppColors.secondaryText)
                }

                if viewModel.pendingOrders.isEmpty {
                    emptyState
                } else {
                    ForEach(viewModel.pendingOrders) { order in
                        NavigationLink {
                            OrderDetailView(
                                order: order,
                                viewModel: viewModel
                            )
                        } label: {
                            orderCard(order)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(AppSpacing.large)
        }
        .background(AppColors.background)
        .refreshable {
            await viewModel.loadInitialData()
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.medium) {
            Image(systemName: "bag")
                .font(.system(size: 42))
                .foregroundStyle(AppColors.secondaryText)

            Text("No orders ready to pick up")
                .font(.headline)

            Text("Orders you place from Redeem will appear here.")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func orderCard(_ order: RedemptionOrder) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {

            // Status
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "bag.fill")
                    .foregroundStyle(AppColors.brand)

                Text("ORDER READY TO PICK UP")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(AppColors.brand)
            }

            Divider()

            // Venue
            HStack {
                Text(order.venueName)
                    .font(.headline)

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(AppColors.secondaryText)
            }

            // Items
            VStack(alignment: .leading, spacing: 4) {
                ForEach(order.items) { item in
                    Text("\(item.quantity) × \(item.itemNameSnapshot)")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reference")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)

                    Text(order.referenceNumber)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Points")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)

                    Text("\(order.totalPoints) pts")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            }
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surface)
        .clipShape(
            RoundedRectangle(cornerRadius: AppRadius.card)
        )
    }
}
