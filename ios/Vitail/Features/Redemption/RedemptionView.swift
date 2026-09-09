import SwiftUI

/// The owner's Redeem tab: current point balance, pending redemptions
/// waiting to be collected in-store, and the rewards an owner can redeem
/// (README.md, "Redeeming Points").
struct RedemptionView: View {
    @ObservedObject var viewModel: RedemptionViewModel
    @State private var selectedReward: Reward?
    @State private var selectedRedemption: Redemption?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                balanceCard

                if let errorMessage = viewModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.error)
                        .accessibilityIdentifier("redemptionError")
                    Button("Refresh") { Task { await viewModel.refresh() } }
                        .disabled(viewModel.isLoading || viewModel.isMutating)
                }

                if !viewModel.pendingRedemptions.isEmpty {
                    pendingRedemptionsSection
                }

                rewardsSection

                if !viewModel.history.isEmpty {
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
        .confirmationDialog(
            "Redeem this reward?",
            isPresented: Binding(
                get: { selectedReward != nil },
                set: { if !$0 { selectedReward = nil } }
            ),
            titleVisibility: .visible,
            presenting: selectedReward
        ) { reward in
            Button("Redeem for \(reward.pointCost) points") {
                Task { await viewModel.redeem(rewardID: reward.id) }
            }
        } message: { reward in
            Text("\(reward.name) at \(reward.cafeName). Points are deducted when you confirm.")
        }
        .confirmationDialog(
            "Have you received this reward?",
            isPresented: Binding(
                get: { selectedRedemption != nil },
                set: { if !$0 { selectedRedemption = nil } }
            ),
            titleVisibility: .visible,
            presenting: selectedRedemption
        ) { redemption in
            Button("Confirm collected") {
                Task { await viewModel.collect(redemptionID: redemption.id) }
            }
        } message: { _ in
            Text("Only confirm after the café staff hands over your reward.")
        }
    }

    private var balanceCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your points")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                Text(viewModel.balance.map { "\($0) pts" } ?? "— pts")
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
                PendingRedemptionRow(
                    redemption: redemption,
                    isCollecting: viewModel.collectingRedemptionID == redemption.id,
                    isDisabled: viewModel.isLoading || viewModel.isMutating
                ) {
                    selectedRedemption = redemption
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
                    canAfford: (viewModel.balance ?? 0) >= reward.pointCost,
                    isRetry: viewModel.retryRewardID == reward.id,
                    isDisabled: viewModel.isLoading || viewModel.isMutating ||
                        (viewModel.retryRewardID != nil && viewModel.retryRewardID != reward.id)
                ) {
                    selectedReward = reward
                }
            }
        }
    }

    private var recentRedemptionsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("History")
                .font(.headline)

            ForEach(viewModel.history) { redemption in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(redemption.rewardNameSnapshot)
                            .fontWeight(.medium)
                        Text("Ref \(redemption.referenceNumber) · \(redemption.pointCostSnapshot) pts")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        Text(redemption.status.rawValue.capitalized)
                            .font(.caption)
                        if redemption.status == .expired || redemption.status == .cancelled {
                            Text("Points refunded")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    Spacer()
                    Image(systemName: redemption.status == .collected ? "checkmark.circle.fill" : "arrow.uturn.backward.circle")
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
    let isRetry: Bool
    let isDisabled: Bool
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
                title: isRetry ? "Retry redemption" : (canAfford ? "Redeem" : "Not enough points"),
                isLoading: isRedeeming,
                isDisabled: isDisabled || (!canAfford && !isRetry),
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
    let isCollecting: Bool
    let isDisabled: Bool
    let onCollect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(redemption.rewardNameSnapshot)
                    .fontWeight(.semibold)
                if let cafe = redemption.cafeNameSnapshot {
                    Text(cafe).font(.caption)
                }
                Text("Ref \(redemption.referenceNumber) · \(redemption.pointCostSnapshot) pts")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            PrimaryButton(
                title: "Collect", isLoading: isCollecting,
                isDisabled: isDisabled, action: onCollect
            )
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }
}
