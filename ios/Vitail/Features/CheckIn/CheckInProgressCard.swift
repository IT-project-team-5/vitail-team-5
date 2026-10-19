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
                        Text(item.venueName).font(AppFont.heading(16, .semibold)).foregroundStyle(AppColors.primaryText)
                        Label(statusText(item), systemImage: statusIcon(item))
                            .font(AppFont.body(12, .medium, relativeTo: .caption)).foregroundStyle(item.status == .ready ? AppColors.brand : AppColors.secondaryText)
                        if item.status == .inProgress {
                            VitailProgressBar(value: item.progressRatio)
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
                .vitailCardBackground(shadow: item.status != .collected)
                .overlay {
                    if item.status == .ready {
                        RoundedRectangle(cornerRadius: AppRadius.card)
                            .strokeBorder(AppColors.honey, lineWidth: AppStroke.width + 1)
                    }
                }
                .padding(.trailing, AppStroke.shadow)
                .padding(.bottom, item.status == .collected ? 0 : AppStroke.shadow)
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
                        Text(item.venueName).vitailTitle(24)
                    }
                    Label(statusText(item), systemImage: statusIcon(item))
                        .foregroundStyle(item.status == .ready ? AppColors.brand : AppColors.secondaryText)
                    Text("Stay at this venue for \(item.requiredSeconds / 60)m \(item.requiredSeconds % 60)s.")
                    VitailProgressBar(value: item.progressRatio)
                    Text("\(item.verifiedSeconds / 60)m \(item.verifiedSeconds % 60)s completed")
                        .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    let availablePoints = item.availablePoints(earnedToday: store.earnedPointsToday)
                    if item.status != .collected {
                        VitailChip(text: "+\(availablePoints) pts", systemImage: "sparkle", fill: AppColors.honey)
                        Text("Walking and check-in rewards share a 72-point daily limit.")
                            .font(.footnote).foregroundStyle(AppColors.secondaryText)
                    }
                    if item.status == .ready, item.walkRequestID == nil {
                        PrimaryButton(title: "Collect · \(availablePoints) pts", isLoading: store.collectingIDs.contains(item.id),
                                      isDisabled: store.collectingIDs.contains(item.id)) {
                            Task { await store.collect(id: item.id) }
                        }
                    }
                    if item.status == .ready, item.walkRequestID != nil {
                        Text("Check-in complete. Finish your walk.")
                            .font(.headline).foregroundStyle(AppColors.brand)
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
        case .ready: return item.walkRequestID == nil ? "Ready to collect" : "Completed · finish your walk"
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
