import CoreLocation
import SwiftUI

/// Compact controls for the map's bottom panel. Participants are chosen at Finish.
struct WalkDogSelectionCard: View {
    @ObservedObject var selection: WalkDogSelectionViewModel
    @ObservedObject var session: WalkSessionTracker
    let location: CLLocation?
    let canStartNewWalk: Bool
    var onReviewFinish: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var controlDiameter: CGFloat = 72

    init(
        selection: WalkDogSelectionViewModel,
        session: WalkSessionTracker,
        location: CLLocation? = nil,
        canStartNewWalk: Bool = true,
        onReviewFinish: @escaping () -> Void = {}
    ) {
        self.selection = selection
        self.session = session
        self.location = location
        self.canStartNewWalk = canStartNewWalk
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
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Circle().fill(session.status == .paused ? AppColors.honey : AppColors.success)
                                .frame(width: 8, height: 8)
                            Text(session.status == .paused ? "Paused" : "Walking")
                                .font(AppFont.heading(13, .semibold, relativeTo: .caption))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(AppColors.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(AppColors.outline, lineWidth: AppStroke.width))
                        HStack {
                            VitailStat(value: Self.durationText(session.elapsedActiveDuration(at: timeline.date)),
                                       label: "Time", size: 26)
                                .accessibilityLabel("Active walking time, \(Self.durationText(session.elapsedActiveDuration(at: timeline.date)))")
                            VitailStat(value: String(format: "%.2f", session.distanceKilometres), unit: "km",
                                       label: "Distance", size: 26)
                        }
                        .monospacedDigit()
                        .padding(.vertical, 12)
                        .vitailCardBackground()
                        .padding(.trailing, AppStroke.shadow)
                        .padding(.bottom, AppStroke.shadow)
                    }
                }
            }

            VStack(spacing: 6) {
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
                        Button { session.finish() } label: {
                            Label("\(titles[1]) walk", systemImage: "stop.fill")
                                .font(AppFont.heading(17, .semibold))
                                .padding(.horizontal, AppSpacing.large)
                                .frame(minWidth: 150, minHeight: 56)
                        }
                        .buttonStyle(VitailPressStyle(fill: AppColors.brand, foreground: AppColors.brandForeground))
                        .padding(.trailing, AppStroke.shadow)
                        .padding(.bottom, AppStroke.shadow)
                        .accessibilityLabel("Finish walk")
                            .accessibilityHint("Review your walk and choose the dogs who came along.")
                    }
                }
                .frame(maxWidth: .infinity)

                if !session.isInProgress && canStartNewWalk {
                    Text("Start walk")
                        .font(AppFont.heading(17, .semibold))
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
                Text("Every walk, a little closer.")
                    .font(AppFont.body(12, relativeTo: .footnote))
                    .foregroundStyle(AppColors.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, AppSpacing.medium)
            if canStartNewWalk && (session.canStart || session.status == .paused)
                && !WalkSessionTracker.isFresh(location) {
                Text("Finding an accurate location…")
                    .font(AppFont.body(12, relativeTo: .caption)).foregroundStyle(AppColors.secondaryText)
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
        let isPause = systemImage.hasPrefix("pause")
        let diameter = min(controlDiameter, 104)
        return Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.bold))
                .foregroundStyle(isDisabled ? AppColors.secondaryText
                                 : isPause ? AppColors.primaryText : AppColors.brandForeground)
                .frame(width: diameter, height: diameter)
                .background(isDisabled ? AppColors.border.opacity(0.45)
                            : isPause ? AppColors.surface : AppColors.brand, in: Circle())
                .overlay(Circle().strokeBorder(isDisabled ? AppColors.border : AppColors.outline,
                                               lineWidth: AppStroke.width))
                .background {
                    if !isDisabled {
                        Circle().fill(AppColors.outline).offset(x: AppStroke.shadow, y: AppStroke.shadow)
                    }
                }
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
