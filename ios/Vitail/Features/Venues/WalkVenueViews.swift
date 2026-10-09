import SwiftUI

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

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Circle().fill(.regularMaterial)
                    Circle().stroke(AppColors.brand.opacity(0.25), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: completed ? 1 : presentation.progress)
                        .stroke(AppColors.brand, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .linear(duration: 0.35), value: presentation.progress)
                    Image(systemName: venue.venueType.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppColors.brand)
                }
                .frame(width: 40, height: 40)
                .shadow(color: glowing ? AppColors.brand.opacity(0.55) : .clear, radius: completionFlash ? 14 : 9)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: glowing)
                if completed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14)).foregroundStyle(AppColors.success)
                        .background(AppColors.surface, in: Circle())
                }
            }
            .frame(width: 44, height: 44)
            .opacity(presentation.state == .collected || presentation.state == .unavailable ? 0.55 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(venue.name), \(venue.venueType.title), \(presentation.message)")
        .accessibilityValue("\(Int((completed ? 1 : presentation.progress) * 100)) percent complete")
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
                        Text("Required stay: \(current.dwellText) · within 20 metres")
                            .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                        HStack(spacing: AppSpacing.medium) {
                            WalkVenueMarker(venue: current, presentation: presentation, action: {})
                                .accessibilityHidden(true)
                            Text(presentation.message).font(.headline)
                        }
                        if presentation.state != .collected && presentation.state != .unavailable {
                            ProgressView(value: presentation.progress).tint(AppColors.brand)
                            Text("\(DwellFormat.text(seconds: presentation.verifiedSeconds)) verified")
                                .font(.caption).foregroundStyle(AppColors.secondaryText)
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
