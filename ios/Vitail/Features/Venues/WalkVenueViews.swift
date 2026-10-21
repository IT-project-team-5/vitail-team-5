import SwiftUI

private extension WalkVenuePresentation {
    var isAwaitingConfirmation: Bool { state == .accumulating && displayedSeconds >= requiredSeconds }
    var liveStatusMessage: String {
        if state == .accumulating && isPendingVerification {
            return "Waiting for verification. The timer may adjust when the connection returns."
        }
        return isAwaitingConfirmation ? "Confirming check-in…" : message
    }
}

struct WalkVenueMarker: View {
    let venue: CheckInVenue
    let presentation: WalkVenuePresentation
    let action: () -> Void
    private let reduceMotionOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var completionFlash = false
    @State private var completionEvent: UUID?

    // SwiftUI's accessibility preference is read-only. An explicit override
    // lets render tests exercise reduced motion without changing device settings.
    init(venue: CheckInVenue, presentation: WalkVenuePresentation,
         reduceMotionOverride: Bool? = nil, action: @escaping () -> Void) {
        self.venue = venue
        self.presentation = presentation
        self.reduceMotionOverride = reduceMotionOverride
        self.action = action
    }

    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    private var completed: Bool { presentation.state == .ready || presentation.state == .collected }
    private var glowing: Bool { presentation.state == .accumulating || completionFlash }
    private var highlightedBadge: Bool { presentation.state == .accumulating && !presentation.isPendingVerification }
    private var statusTitle: String {
        switch presentation.state {
        case .outside: return "Visit"
        case .accumulating:
            if presentation.isPendingVerification { return "Verifying" }
            return presentation.isAwaitingConfirmation ? "Confirming" : "Recording"
        case .paused: return "Paused"
        case .ready: return "Ready"
        case .collected: return "Collected"
        case .unavailable: return "Unavailable"
        }
    }
    private var statusIcon: String {
        switch presentation.state {
        case .outside: return "location"
        case .accumulating: return presentation.isPendingVerification ? "wifi.exclamationmark" : "record.circle.fill"
        case .paused: return "pause.circle.fill"
        case .ready, .collected: return "checkmark.circle.fill"
        case .unavailable: return "minus.circle"
        }
    }
    private var statusColor: Color {
        switch presentation.state {
        case .accumulating: return presentation.isPendingVerification ? AppColors.warning : AppColors.brand
        case .paused: return AppColors.warning
        case .ready, .collected: return AppColors.success
        case .outside, .unavailable: return AppColors.secondaryText
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        Circle().fill(AppColors.brand.opacity(glowing ? 0.22 : 0))
                            .frame(width: 64, height: 64)
                        Circle().stroke(AppColors.brand.opacity(glowing ? 0.5 : 0), lineWidth: 2)
                            .frame(width: 60, height: 60)
                        Circle().fill(AppColors.surface)
                            .frame(width: 52, height: 52)
                        Circle().stroke(AppColors.brand.opacity(0.2), lineWidth: 5)
                            .frame(width: 47, height: 47)
                        Circle()
                            .trim(from: 0, to: completed ? 1 : presentation.progress)
                            .stroke(AppColors.brand, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 47, height: 47)
                            .animation(reduceMotion ? nil : .linear(duration: 0.35), value: presentation.progress)
                        Circle().fill(glowing ? AppColors.brand : AppColors.surface)
                            .frame(width: 37, height: 37)
                        Image(systemName: venue.venueType.icon)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(glowing ? AppColors.brandForeground : AppColors.brand)
                    }
                    .frame(width: 64, height: 64)
                    .shadow(color: glowing ? AppColors.brand.opacity(0.7) : .clear,
                            radius: completionFlash ? 16 : 10)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: glowing)
                    if completed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .bold)).foregroundStyle(AppColors.success)
                            .background(AppColors.surface, in: Circle())
                            .padding(4)
                    }
                }
                Label(statusTitle, systemImage: statusIcon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(highlightedBadge ? AppColors.brandForeground : statusColor)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(highlightedBadge ? AppColors.brand : AppColors.surface, in: Capsule())
                    .overlay { Capsule().stroke(statusColor.opacity(0.45), lineWidth: 1) }
                    .fixedSize()
            }
            .opacity(presentation.state == .collected || presentation.state == .unavailable ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(venue.name), \(venue.venueType.title), \(presentation.liveStatusMessage)")
        .accessibilityValue("\(statusTitle), \(presentation.displayedSeconds) of \(presentation.requiredSeconds) seconds, \(presentation.verifiedSeconds) seconds server verified")
        .accessibilityHint("Shows venue details")
        .accessibilityIdentifier("walk-venue-\(venue.id)")
        .onChange(of: presentation.state) { old, new in
            if old != .ready, new == .ready, !reduceMotion { completionEvent = UUID() }
            else if new != .ready { completionEvent = nil; completionFlash = false }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { completionEvent = nil; completionFlash = false }
        }
        .task(id: completionEvent) {
            guard completionEvent != nil, presentation.state == .ready, !reduceMotion else { completionFlash = false; return }
            completionFlash = true
            do { try await Task.sleep(for: .seconds(0.7)) } catch {}
            completionFlash = false
        }
    }
}

struct WalkVenueDetailSheet: View {
    @ObservedObject var store: WalkVenueCheckInStore
    let venue: CheckInVenue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { tick in
                let current = store.venues.first { $0.id == venue.id } ?? venue
                let presentation = store.presentation(for: current, at: tick.date)
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.medium) {
                        Label(current.venueType.title, systemImage: current.venueType.icon)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.brand)
                        Text(current.name).font(.title2.bold())
                        Text(current.address.isEmpty ? "Address not provided" : current.address)
                            .foregroundStyle(AppColors.secondaryText)
                        if !current.description.isEmpty { Text(current.description) }
                        if !current.openingHours.isEmpty { Label(current.openingHours, systemImage: "clock") }
                        Text("Required stay: \(current.dwellText) · within \(current.checkinRadiusM) metres")
                            .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                        HStack(spacing: AppSpacing.medium) {
                            WalkVenueMarker(venue: current, presentation: presentation, action: {})
                                .accessibilityHidden(true)
                            Text(presentation.liveStatusMessage).font(.headline)
                        }
                        if presentation.state != .collected && presentation.state != .unavailable {
                            ProgressView(value: presentation.progress).tint(AppColors.brand)
                            Text("\(presentation.displayedSeconds) / \(presentation.requiredSeconds) seconds")
                                .font(.title3.weight(.bold)).monospacedDigit()
                                .accessibilityIdentifier("venue-live-seconds")
                            Text("Server verified: \(presentation.verifiedSeconds) seconds")
                                .font(.caption).monospacedDigit().foregroundStyle(AppColors.secondaryText)
                            Text("The stay timer updates every second. Your check-in is complete once confirmed.")
                                .font(.footnote).foregroundStyle(AppColors.secondaryText)
                            if presentation.state == .paused {
                                Label("Verification paused. Stay within the circle with a clear GPS signal. Your confirmed seconds are saved for this walk.",
                                      systemImage: "pause.circle.fill")
                                    .font(.subheadline).foregroundStyle(AppColors.warning)
                            }
                            Text("Venue rewards are settled when you complete your walk. Each category earns points once a day, within the shared 72-point daily limit.")
                                .font(.footnote).foregroundStyle(AppColors.secondaryText)
                            if !store.isWalking && presentation.state != .ready {
                                Text("Start or resume your walk to record a visit.")
                                    .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                            }
                        }
                        if let message = store.errorMessage {
                            Text(message).font(.footnote).foregroundStyle(AppColors.warning)
                            Button("Retry verification") { Task { await store.load() } }
                        }
                    }
                    .padding(AppSpacing.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(AppColors.background)
            .navigationTitle("Venue check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct WalkVenueAwardsSection: View {
    let summary: WalkSummary
    private var successfulAwards: [WalkVenueAward] { summary.checkInAwards.filter { $0.awardedPoints > 0 } }
    var body: some View {
        if !successfulAwards.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.medium) {
                Text("Venue check-ins").font(.headline)
                ForEach(successfulAwards) { award in
                    HStack(alignment: .top, spacing: AppSpacing.small) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(AppColors.success)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(award.venueName)
                            Text(award.categoryTitle).font(.caption).foregroundStyle(AppColors.secondaryText)
                        }
                        Spacer()
                        Text("+\(award.awardedPoints) pts").font(.subheadline.weight(.semibold))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
