import SwiftUI

struct CheckInProgressCard: View {
    @ObservedObject var store: CheckInProgressStore
    let checkInID: String

    var body: some View {
        if let item = store.items.first(where: { $0.id == checkInID }) {
            VStack(alignment: .leading, spacing: AppSpacing.medium) {
                HStack(spacing: AppSpacing.small) {
                    AvatarView(url: item.photo, name: item.venueName, systemImage: "storefront", size: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.venueName).font(.headline)
                        Text(statusText(item)).font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                ProgressView(value: item.progressRatio)
                    .tint(AppColors.brand)
                    .accessibilityLabel("Check-in progress")
                    .accessibilityValue("\(Int(item.progressRatio * 100)) percent")
                if item.status == .ready {
                    PrimaryButton(title: "Collect · \(item.rewardPoints) pts",
                                  isLoading: store.collectingIDs.contains(item.id)) {
                        Task { await store.collect(id: item.id) }
                    }
                    .disabled(store.collectingIDs.contains(item.id))
                } else if item.status == .collected {
                    Label("Collected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success).font(.subheadline)
                }
                if let message = store.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(AppColors.error)
                }
            }
            .padding(AppSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        }
    }

    private func statusText(_ item: VenueCheckInProgress) -> String {
        switch item.status {
        case .ready: return "Your reward is ready"
        case .collected: return "Check-in complete"
        case .cancelled: return "Check-in ended"
        case .inProgress:
            return "\(item.verifiedSeconds / 60)m \(item.verifiedSeconds % 60)s of \(item.requiredSeconds / 60)m"
        }
    }
}
