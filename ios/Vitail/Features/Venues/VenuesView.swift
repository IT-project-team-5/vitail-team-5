import MapKit
import SwiftUI

struct VenuesView: View {
    @ObservedObject var viewModel: VenuesViewModel
    @ObservedObject var progressStore: CheckInProgressStore
    @State private var selectedVenueID: Int?
    @State private var position: MapCameraPosition = .automatic

    private var selectedVenue: CheckInVenue? {
        viewModel.venues.first { $0.id == selectedVenueID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.venues.isEmpty {
                Map(position: $position) {
                    UserAnnotation()
                    ForEach(viewModel.venues) { venue in
                        if venue.id == selectedVenueID || venue.id == viewModel.activeCheckIn?.venueID {
                            MapCircle(center: venue.coordinate, radius: CLLocationDistance(venue.checkinRadiusM))
                                .foregroundStyle(AppColors.brand.opacity(0.16))
                                .stroke(AppColors.brand, lineWidth: 1)
                        }
                        Annotation("", coordinate: venue.coordinate) {
                            VenueHotspotAnnotation(
                                venue: venue,
                                isSelected: venue.id == selectedVenueID || venue.id == viewModel.activeCheckIn?.venueID,
                                availability: displayedAvailability(for: venue)
                            ) {
                                selectedVenueID = venue.id
                            }
                        }
                    }
                }
                .frame(minHeight: 260)
                .frame(maxHeight: .infinity)
                .mapStyle(.standard)
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
            }

            ScrollView {
                VStack(spacing: AppSpacing.small) {
                    VenueCheckInStatusCard(viewModel: viewModel, progressStore: progressStore)
                    loadState
                    ForEach(viewModel.venues) { venue in
                        Button { selectedVenueID = venue.id } label: {
                            VenueRow(venue: venue, availability: displayedAvailability(for: venue))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows venue check-in details")
                    }
                }
                .padding(AppSpacing.medium)
            }
            .frame(maxHeight: .infinity)
            .background(AppColors.background)
            .refreshable { await viewModel.load() }
        }
        .task { await viewModel.load() }
        .sheet(item: Binding(
            get: { selectedVenue },
            set: { selectedVenueID = $0?.id }
        )) { venue in
            VenueDetailSheet(viewModel: viewModel, progressStore: progressStore, venue: venue)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: viewModel.venues.map(\.id)) { _, venueIDs in
            if let selectedVenueID, !venueIDs.contains(selectedVenueID) {
                self.selectedVenueID = nil
            }
        }
        .onChange(of: progressStore.visibleItems) { _, items in
            viewModel.reconcileSharedProgress(items)
        }
        .onAppear { viewModel.reconcileSharedProgress(progressStore.visibleItems) }
    }

    @ViewBuilder
    private var loadState: some View {
        if viewModel.isLoading && !viewModel.hasLoaded {
            HStack(spacing: AppSpacing.small) {
                ProgressView().tint(AppColors.brand)
                Text("Loading check-in venues…")
                    .font(.subheadline).foregroundStyle(AppColors.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.medium)
        }
        if let message = viewModel.errorMessage {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Label("Venues could not be refreshed", systemImage: "wifi.exclamationmark")
                    .font(.headline).foregroundStyle(AppColors.error)
                Text(message).font(.footnote).foregroundStyle(AppColors.secondaryText)
                Button("Try again") { Task { await viewModel.load() } }
                    .font(.subheadline.weight(.semibold))
                    .disabled(viewModel.isLoading)
            }
            .padding(AppSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
            .overlay { RoundedRectangle(cornerRadius: AppRadius.card).stroke(AppColors.border, lineWidth: 1) }
        } else if viewModel.hasLoaded && viewModel.venues.isEmpty {
            VStack(spacing: AppSpacing.small) {
                Image(systemName: "mappin.slash")
                    .font(.title2).foregroundStyle(AppColors.secondaryText)
                Text("No check-in venues available")
                    .font(.headline)
                Text("Check back later for nearby places where you can earn points.")
                    .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(AppSpacing.large)
            .frame(maxWidth: .infinity)
        }
    }

    private func displayedAvailability(for venue: CheckInVenue) -> CheckInVenueAvailability {
        switch viewModel.phase {
        case let .finished(checkIn) where checkIn.venueID == venue.id && checkIn.status == .collected:
            return .collected
        default:
            break
        }
        if let progress = progressStore.visibleItems.first(where: { $0.venueID == venue.id }) {
            switch progress.status {
            case .collected: return .collected
            case .ready: return .ready
            case .inProgress: return .inProgress
            case .cancelled: return .unavailable
            }
        }
        switch viewModel.phase {
        case let .starting(venueID) where venueID == venue.id:
            return .inProgress
        case let .active(checkIn) where checkIn.venueID == venue.id:
            return .inProgress
        case let .finished(checkIn) where checkIn.venueID == venue.id:
            return checkIn.status == .collected ? .collected : .ready
        default:
            return venue.availability
        }
    }
}

private struct VenueRow: View {
    let venue: CheckInVenue
    let availability: CheckInVenueAvailability

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
            Image(systemName: icon)
                .frame(width: 40, height: 40)
                .foregroundStyle(statusColor)
                .background(statusColor.opacity(0.1), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(venue.name).font(.headline).foregroundStyle(AppColors.primaryText)
                Text("\(venue.venueType.title) · stay \(venue.dwellText)")
                    .font(.subheadline).foregroundStyle(AppColors.secondaryText)
            }
            Spacer(minLength: AppSpacing.small)
            Text(availability == .available ? "12 pts" : availability.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay { RoundedRectangle(cornerRadius: AppRadius.card).stroke(AppColors.border, lineWidth: 1) }
        .opacity(availability == .unavailable ? 0.72 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(venue.name), \(venue.venueType.title), \(availability.title)")
    }

    private var icon: String {
        switch availability {
        case .ready: return "gift.fill"
        case .collected: return "checkmark.circle.fill"
        case .inProgress: return "clock.fill"
        case .unavailable: return "minus.circle"
        case .available: return venue.venueType.icon
        }
    }

    private var statusColor: Color {
        switch availability {
        case .available: return AppColors.brand
        case .inProgress: return AppColors.warning
        case .ready, .collected: return AppColors.success
        case .unavailable: return AppColors.secondaryText
        }
    }
}

/// A compact, tappable venue map marker. The status is conveyed
/// with an icon and spoken label as well as colour.
private struct VenueHotspotAnnotation: View {
    let venue: CheckInVenue
    let isSelected: Bool
    var availability: CheckInVenueAvailability? = nil
    let action: () -> Void

    private var displayedAvailability: CheckInVenueAvailability { availability ?? venue.availability }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack {
                    Circle().fill(.regularMaterial)
                    Circle().stroke(statusColor, lineWidth: isSelected ? 4 : 3)
                    Image(systemName: statusIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.16), radius: 3, y: 2)

                Text(venue.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .foregroundStyle(AppColors.primaryText)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .scaleEffect(isSelected ? 1.08 : 1)
            .opacity(displayedAvailability == .unavailable ? 0.62 : 1)
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel("\(venue.name), \(venue.venueType.title), \(displayedAvailability.title)")
        .accessibilityHint("Shows venue check-in details")
        .accessibilityIdentifier("venue-hotspot-\(venue.id)")
    }

    private var statusColor: Color {
        switch displayedAvailability {
        case .available: return AppColors.brand
        case .inProgress: return AppColors.warning
        case .ready, .collected: return AppColors.success
        case .unavailable: return AppColors.secondaryText
        }
    }

    private var statusIcon: String {
        switch displayedAvailability {
        case .available: return venue.venueType.icon
        case .inProgress: return "clock.fill"
        case .ready: return "gift.fill"
        case .collected: return "checkmark"
        case .unavailable: return "minus"
        }
    }
}

/// The active check-in remains visible below the venue map while the owner
/// browses other available places.
private struct VenueCheckInStatusCard: View {
    @ObservedObject var viewModel: VenuesViewModel
    @ObservedObject var progressStore: CheckInProgressStore

    var body: some View {
        switch viewModel.phase {
        case let .active(checkIn):
            ActiveCheckInCard(viewModel: viewModel, checkIn: checkIn)
        case let .finished(checkIn):
            if progressStore.visibleItems.contains(where: {
                $0.venueID == checkIn.venueID && $0.status == .collected
            }), checkIn.status != .collected {
                SharedCollectedCheckInCard(venueName: checkIn.venueName) { viewModel.dismissResult() }
            } else {
                FinishedCheckInCard(viewModel: viewModel, checkIn: checkIn) { viewModel.dismissResult() }
            }
        case .starting:
            HStack(spacing: AppSpacing.small) {
                ProgressView().tint(AppColors.brand)
                Text("Confirming your location…")
                    .font(.subheadline).foregroundStyle(AppColors.secondaryText)
            }
            .padding(AppSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
            .overlay { RoundedRectangle(cornerRadius: AppRadius.card).stroke(AppColors.border, lineWidth: 1) }
        case .idle:
            EmptyView()
        }
    }
}

private struct SharedCollectedCheckInCard: View {
    let venueName: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Label("Collected from \(venueName)", systemImage: "checkmark.seal.fill")
                .font(.headline).foregroundStyle(AppColors.success)
            Text("This check-in was collected from Quest.")
                .font(.subheadline).foregroundStyle(AppColors.secondaryText)
            Button("Done", action: onDismiss).font(.subheadline.weight(.semibold))
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay { RoundedRectangle(cornerRadius: AppRadius.card).stroke(AppColors.border, lineWidth: 1) }
    }
}

private struct ActiveCheckInCard: View {
    @ObservedObject var viewModel: VenuesViewModel
    let checkIn: VenueCheckInSession

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Label("Checking in at \(checkIn.venueName)", systemImage: "location.fill")
                .font(.headline)
                .foregroundStyle(AppColors.primaryText)
            ProgressView(value: Double(viewModel.elapsedSeconds), total: Double(max(1, checkIn.requiredSeconds)))
                .tint(AppColors.brand)
                .accessibilityLabel("Venue check-in progress")
                .accessibilityValue("\(DwellFormat.clock(seconds: viewModel.elapsedSeconds)) of \(DwellFormat.clock(seconds: checkIn.requiredSeconds))")
            Text("\(DwellFormat.clock(seconds: viewModel.remainingSeconds(for: checkIn))) left — stay near the venue. Progress updates after the server verifies your location.")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
            if let notice = viewModel.connectionNotice {
                Text(notice).font(.footnote).foregroundStyle(AppColors.warning)
            }
            Button("Cancel check-in", role: .destructive) { Task { await viewModel.cancel() } }
                .font(.subheadline.weight(.semibold))
                .disabled(viewModel.isCancelling)
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay { RoundedRectangle(cornerRadius: AppRadius.card).stroke(AppColors.brand, lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }
}

private struct FinishedCheckInCard: View {
    @ObservedObject var viewModel: VenuesViewModel
    let checkIn: VenueCheckInSession
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Label(checkIn.status == .collected ? "Collected from \(checkIn.venueName)" : "Check-in ready",
                  systemImage: checkIn.status == .collected ? "checkmark.seal.fill" : "gift.fill")
                .font(.headline)
                .foregroundStyle(checkIn.status == .collected ? AppColors.success : AppColors.brand)
            Text(checkIn.status == .collected
                 ? "You earned \(checkIn.rewardPoints) points."
                 : "Your visit is verified. Collect \(checkIn.rewardPoints) points now or from Quest.")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
            if checkIn.status == .ready {
                PrimaryButton(title: "Collect · \(checkIn.rewardPoints) pts", isLoading: viewModel.isCollecting,
                              isDisabled: viewModel.isCollecting) { Task { await viewModel.collect() } }
            }
            if let message = viewModel.errorMessage {
                Text(message).font(.footnote).foregroundStyle(AppColors.error)
            }
            Button("Done", action: onDismiss).font(.subheadline.weight(.semibold))
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay { RoundedRectangle(cornerRadius: AppRadius.card).stroke(AppColors.border, lineWidth: 1) }
    }
}

struct VenueDetailSheet: View {
    @ObservedObject var viewModel: VenuesViewModel
    @ObservedObject var progressStore: CheckInProgressStore
    let venue: CheckInVenue
    @Environment(\.dismiss) private var dismiss

    private var isCheckingInHere: Bool { viewModel.activeCheckIn?.venueID == venue.id }
    private var isStartingHere: Bool { viewModel.phase == .starting(venueID: venue.id) }
    private var finishedHere: VenueCheckInSession? {
        guard case let .finished(checkIn) = viewModel.phase, checkIn.venueID == venue.id else { return nil }
        if checkIn.status != .collected,
           progressStore.visibleItems.contains(where: { $0.venueID == venue.id && $0.status == .collected }) {
            return nil
        }
        return checkIn
    }
    private var effectiveAvailability: CheckInVenueAvailability {
        if case let .finished(checkIn) = viewModel.phase,
           checkIn.venueID == venue.id, checkIn.status == .collected { return .collected }
        if let progress = progressStore.visibleItems.first(where: { $0.venueID == venue.id }) {
            switch progress.status {
            case .collected: return .collected
            case .ready: return .ready
            case .inProgress: return .inProgress
            case .cancelled: return .unavailable
            }
        }
        return venue.availability
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.medium) {
                    Label(venue.venueType.title, systemImage: venue.venueType.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.brand)
                    Text(venue.name).font(.title2.weight(.bold))
                    if !venue.address.isEmpty { Text(venue.address).foregroundStyle(AppColors.secondaryText) }
                    if !venue.description.isEmpty { Text(venue.description) }
                    if !venue.openingHours.isEmpty {
                        Label(venue.openingHours, systemImage: "clock")
                            .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    }
                    Text("Stay within \(venue.checkinRadiusM) m for \(venue.dwellText) to earn 12 points. Location verification begins only after you choose Start check-in.")
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)

                    if let message = viewModel.errorMessage, !isCheckingInHere {
                        Text(message).font(.footnote).foregroundStyle(AppColors.error)
                    }

                    actionContent
                }
                .padding(AppSpacing.medium)
            }
            .background(AppColors.background)
            .navigationTitle("Venue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task(id: "\(venue.id)-\(venue.checkInStatus)") {
            if venue.availability == .ready || venue.availability == .inProgress {
                await progressStore.refresh()
                viewModel.reconcileSharedProgress(progressStore.visibleItems)
            }
        }
    }

    @ViewBuilder
    private var actionContent: some View {
        if isCheckingInHere, let checkIn = viewModel.activeCheckIn {
            ActiveCheckInCard(viewModel: viewModel, checkIn: checkIn)
        } else if let finishedHere {
            FinishedCheckInCard(viewModel: viewModel, checkIn: finishedHere, onDismiss: { dismiss() })
        } else {
            switch effectiveAvailability {
            case .collected:
                Label("Checked in today — come back tomorrow", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
            case .ready:
                if let progress = progressStore.visibleItems.first(where: {
                    $0.venueID == venue.id && $0.status == .ready
                }) {
                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        Label("Visit verified", systemImage: "gift.fill")
                            .font(.headline).foregroundStyle(AppColors.success)
                        PrimaryButton(
                            title: "Collect · \(progress.rewardPoints) pts",
                            isLoading: progressStore.collectingIDs.contains(progress.id),
                            isDisabled: progressStore.collectingIDs.contains(progress.id)
                        ) { Task { await progressStore.collect(id: progress.id) } }
                    }
                } else if let message = progressStore.errorMessage {
                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        Text(message).font(.footnote).foregroundStyle(AppColors.error)
                        Button("Try again") { Task { await progressStore.refresh() } }
                            .font(.subheadline.weight(.semibold))
                            .disabled(progressStore.isRefreshing)
                    }
                } else if progressStore.isRefreshing {
                    HStack(spacing: AppSpacing.small) {
                        ProgressView().tint(AppColors.brand)
                        Text("Loading your verified visit…")
                            .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    }
                } else {
                    Button("Load verified visit") { Task { await progressStore.refresh() } }
                        .font(.subheadline.weight(.semibold))
                }
            case .unavailable:
                Label("This check-in is unavailable today.", systemImage: "minus.circle")
                    .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                PrimaryButton(title: "Unavailable today", isDisabled: true) {}
            case .available, .inProgress:
                PrimaryButton(
                    title: viewModel.isBusy && !isStartingHere ? "Finish your current check-in first"
                        : effectiveAvailability == .inProgress ? "Resume check-in" : "Start check-in",
                    isLoading: isStartingHere,
                    isDisabled: viewModel.isBusy && !isStartingHere
                ) {
                    Task { await viewModel.start(venue) }
                }
            }
        }
    }
}
