import CoreLocation
import SwiftUI

/// Compact controls for the map's bottom panel. Participants are chosen at Finish.
struct WalkDogSelectionCard: View {
    @ObservedObject var selection: WalkDogSelectionViewModel
    @ObservedObject var session: WalkSessionTracker
    let location: CLLocation?
    let canStartNewWalk: Bool
    let onManageDogs: () -> Void
    var onReviewFinish: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var controlDiameter: CGFloat = 72

    init(
        selection: WalkDogSelectionViewModel,
        session: WalkSessionTracker,
        location: CLLocation? = nil,
        canStartNewWalk: Bool = true,
        onManageDogs: @escaping () -> Void,
        onReviewFinish: @escaping () -> Void = {}
    ) {
        self.selection = selection
        self.session = session
        self.location = location
        self.canStartNewWalk = canStartNewWalk
        self.onManageDogs = onManageDogs
        self.onReviewFinish = onReviewFinish
    }

    static func controlTitles(status: WalkSessionTracker.Status, canStartNewWalk: Bool = true) -> [String] {
        switch status {
        case .walking: return ["Pause"]
        case .paused: return ["Resume", "Finish"]
        case .idle, .finished: return canStartNewWalk ? ["Start"] : ["Review walk"]
        }
    }

    var body: some View {
        let titles = Self.controlTitles(status: session.status, canStartNewWalk: canStartNewWalk)
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            if session.isInProgress {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.status == .paused ? "Paused" : "Walking")
                                .font(.caption).foregroundStyle(AppColors.secondaryText)
                            Text("\(session.distanceKilometres, specifier: "%.2f") km")
                                .font(.title2.weight(.semibold)).monospacedDigit()
                        }
                        Spacer()
                        Text(Self.durationText(session.elapsedActiveDuration(at: timeline.date)))
                            .font(.title3).monospacedDigit()
                            .accessibilityLabel("Active walking time, \(Self.durationText(session.elapsedActiveDuration(at: timeline.date)))")
                    }
                }
            }

            VStack(spacing: AppSpacing.medium) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: AppSpacing.medium))
                    : AnyLayout(HStackLayout(spacing: AppSpacing.large))
                layout {
                    switch session.status {
                    case .idle, .finished:
                        if canStartNewWalk {
                            symbolControl(
                                title: titles[0], systemImage: "play.fill",
                                isDisabled: !WalkSessionTracker.isFresh(location)
                            ) {
                                guard canStartNewWalk, WalkSessionTracker.isFresh(location) else { return }
                                selection.resetForNewWalk()
                                session.start(from: location, dogs: [])
                            }
                        } else {
                            PrimaryButton(title: titles[0], action: onReviewFinish)
                        }
                    case .walking:
                        symbolControl(title: titles[0], systemImage: "pause.fill") { session.pause() }
                    case .paused:
                        symbolControl(
                            title: titles[0], systemImage: "play.fill",
                            isDisabled: !WalkSessionTracker.isFresh(location)
                        ) {
                            guard WalkSessionTracker.isFresh(location) else { return }
                            session.resume(from: location)
                        }
                        Button(titles[1]) { session.finish() }
                            .font(.headline)
                            .foregroundStyle(AppColors.brand)
                            .padding(.horizontal, AppSpacing.large)
                            .padding(.vertical, AppSpacing.medium)
                            .frame(minWidth: 112, minHeight: 64)
                            .background(AppColors.brand.opacity(0.10), in: Capsule())
                            .buttonStyle(.plain)
                            .accessibilityLabel("Finish walk")
                            .accessibilityHint("Review your walk and choose the dogs who came along.")
                    }
                }
                .frame(maxWidth: .infinity)

                Text("Every walk, a little closer.")
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, AppSpacing.medium)
            if canStartNewWalk && (session.canStart || session.status == .paused)
                && !WalkSessionTracker.isFresh(location) {
                Text("Finding an accurate location…")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(AppColors.primaryText)
        .tint(AppColors.brand)
        .padding(.horizontal, AppSpacing.medium)
        .padding(.top, AppSpacing.small)
        .padding(.bottom, AppSpacing.large)
    }

    private func symbolControl(
        title: String, systemImage: String, isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(isDisabled ? AppColors.secondaryText : AppColors.brandForeground)
                .frame(width: min(controlDiameter, 104), height: min(controlDiameter, 104))
                .background(isDisabled ? AppColors.border.opacity(0.45) : AppColors.brand, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel("\(title) walk")
    }

    static func durationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.isFinite ? duration : 0))
        if seconds >= 3_600 { return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
