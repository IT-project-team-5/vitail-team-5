import SwiftUI

/// The owner's Redeem tab: current point balance, pending redemptions
/// waiting to be collected in-store, and the rewards an owner can redeem
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

                if !viewModel.pendingRedemptions.isEmpty {
                    pendingRedemptionsSection
                }

                rewardsSection

                if !viewModel.recentlyCollectedRedemptions.isEmpty {
                    recentRedemptionsSection
                }
            }
            .padding(AppSpacing.large)
        }
        .background(AppColors.background)
        .refreshable {
            await viewModel.refresh()
        }
        .overlay {
            if viewModel.isLoading && viewModel.rewards.isEmpty {
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

    private var pendingRedemptionsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Ready to collect")
                .font(.headline)

            ForEach(viewModel.pendingRedemptions) { redemption in
                PendingRedemptionRow(redemption: redemption) {
                    Task { await viewModel.collect(redemptionID: redemption.id) }
                }
            }
        }
    }

    private var rewardsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Rewards")
                .font(.headline)

            if viewModel.rewards.isEmpty && !viewModel.isLoading {
                Text("No rewards available yet.")
                    .foregroundStyle(AppColors.secondaryText)
            }

            ForEach(viewModel.rewards) { reward in
                RewardRow(
                    reward: reward,
                    isRedeeming: viewModel.redeemingRewardID == reward.id,
                    canAfford: (viewModel.balance ?? 0) >= reward.pointCost
                ) {
                    Task { await viewModel.redeem(rewardID: reward.id) }
                }
            }
        }
    }

    private var recentRedemptionsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Recently redeemed")
                .font(.headline)

            ForEach(viewModel.recentlyCollectedRedemptions) { redemption in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(redemption.rewardNameSnapshot)
                            .fontWeight(.medium)
                        Text("Ref \(redemption.referenceNumber) · \(redemption.pointCostSnapshot) pts")
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

private struct RewardRow: View {
    let reward: Reward
    let isRedeeming: Bool
    let canAfford: Bool
    let onRedeem: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(reward.name)
                    .fontWeight(.semibold)
                Text("\(reward.cafeName) · \(reward.pointCost) pts")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }

            if !reward.description.isEmpty {
                Text(reward.description)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }

            PrimaryButton(
                title: canAfford ? "Redeem" : "Not enough points",
                isLoading: isRedeeming,
                isDisabled: !canAfford,
                action: onRedeem
            )
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }
}

private struct PendingRedemptionRow: View {
    let redemption: Redemption
    let onCollect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(redemption.rewardNameSnapshot)
                    .fontWeight(.semibold)
                Text("Ref \(redemption.referenceNumber) · \(redemption.pointCostSnapshot) pts")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            PrimaryButton(title: "Collect", action: onCollect)
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }
}
