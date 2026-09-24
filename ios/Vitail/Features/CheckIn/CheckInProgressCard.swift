import SwiftUI

struct CheckInProgressCard: View {
    @ObservedObject var store: CheckInProgressStore
    let checkInID: String
    @State private var showingDetails = false

    private var item: VenueCheckInProgress? { store.visibleItems.first { $0.id == checkInID } }

    var body: some View {
        if let item {
            Button { showingDetails = true } label: {
                HStack(spacing: AppSpacing.medium) {
                    AvatarView(url: item.photo, name: item.venueName, systemImage: "mappin.and.ellipse", size: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.venueName).font(.headline).foregroundStyle(AppColors.primaryText)
                        Label(statusText(item), systemImage: statusIcon(item))
                            .font(.caption).foregroundStyle(item.status == .ready ? AppColors.brand : AppColors.secondaryText)
                        if item.status == .inProgress {
                            ProgressView(value: item.progressRatio).tint(AppColors.brand)
                                .accessibilityLabel("Check-in progress")
                                .accessibilityValue("\(Int(item.progressRatio * 100)) percent")
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.secondaryText).accessibilityHidden(true)
                }
                .padding(AppSpacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(item.status == .ready ? AppColors.brand.opacity(0.12) : AppColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
                .overlay {
                    RoundedRectangle(cornerRadius: AppRadius.card)
                        .stroke(item.status == .ready ? AppColors.brand.opacity(0.45) : .clear, lineWidth: 1)
                }
                .opacity(item.status == .collected ? 0.6 : 1)
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.card))
            }
            .buttonStyle(.plain)
            .accessibilityHint("View check-in details")
            .sheet(isPresented: $showingDetails) {
                NavigationStack {
                    detail
                        .navigationTitle("Check-in")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDetails = false } } }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.large) {
                    HStack(spacing: AppSpacing.medium) {
                        AvatarView(url: item.photo, name: item.venueName, systemImage: "mappin.and.ellipse", size: 64)
                        Text(item.venueName).font(.title2.bold())
                    }
                    Label(statusText(item), systemImage: statusIcon(item))
                        .foregroundStyle(item.status == .ready ? AppColors.brand : AppColors.secondaryText)
                    Text("Stay at this venue for \(item.requiredSeconds / 60)m \(item.requiredSeconds % 60)s.")
                    ProgressView(value: item.progressRatio).tint(AppColors.brand)
                    Text("\(item.verifiedSeconds / 60)m \(item.verifiedSeconds % 60)s completed")
                        .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    let availablePoints = min(item.rewardPoints, max(0, CheckInProgressSnapshot.dailyLimit - store.earnedPointsToday))
                    if item.status != .collected {
                        Text("\(availablePoints) points").font(.headline)
                        Text("Walking and check-in rewards share a 72-point daily limit.")
                            .font(.footnote).foregroundStyle(AppColors.secondaryText)
                    }
                    if item.status == .ready {
                        PrimaryButton(title: "Collect · \(availablePoints) pts", isLoading: store.collectingIDs.contains(item.id),
                                      isDisabled: store.collectingIDs.contains(item.id)) {
                            Task { await store.collect(id: item.id) }
                        }
                    }
                    if let message = store.errorMessage {
                        Text(message).font(.footnote).foregroundStyle(AppColors.error)
                    }
                }
                .padding(AppSpacing.large)
            }
            .background(AppColors.background)
            .foregroundStyle(AppColors.primaryText)
        } else {
            Text("This quest is no longer available today.")
                .foregroundStyle(AppColors.secondaryText).padding(AppSpacing.large)
        }
    }

    private func statusText(_ item: VenueCheckInProgress) -> String {
        switch item.status {
        case .ready: return "Ready to collect"
        case .collected: return "Collected"
        case .cancelled: return "Unavailable"
        case .inProgress: return "In progress"
        }
    }

    private func statusIcon(_ item: VenueCheckInProgress) -> String {
        switch item.status {
        case .ready: return "gift.fill"
        case .collected: return "checkmark.circle.fill"
        case .cancelled: return "minus.circle"
        case .inProgress: return "clock"
        }
    }
}
