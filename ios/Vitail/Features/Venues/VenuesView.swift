import MapKit
import SwiftUI

struct VenuesView: View {
    @ObservedObject var viewModel: VenuesViewModel
    @State private var selectedVenueID: Int?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    private var selectedVenue: Venue? {
        viewModel.venues.first { $0.id == selectedVenueID }
    }

    var body: some View {
        VStack(spacing: 0) {
            Map(position: $position, selection: $selectedVenueID) {
                UserAnnotation()
                ForEach(viewModel.venues) { venue in
                    Marker(venue.name, systemImage: venue.venueType.icon, coordinate: venue.coordinate)
                        .tint(venue.checkedInToday ? AppColors.success : AppColors.brand)
                        .tag(venue.id)
                    if venue.id == selectedVenueID || venue.id == viewModel.activeCheckIn?.venueID {
                        MapCircle(center: venue.coordinate, radius: CLLocationDistance(venue.checkinRadiusM))
                            .foregroundStyle(AppColors.brand.opacity(0.18))
                            .stroke(AppColors.brand, lineWidth: 1)
                    }
                }
            }
            .frame(minHeight: 220)
            .frame(maxHeight: .infinity)

            ScrollView {
                VStack(spacing: AppSpacing.small) {
                    banner
                    if let message = viewModel.errorMessage, viewModel.activeCheckIn == nil {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(AppColors.error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if viewModel.hasLoaded && viewModel.venues.isEmpty {
                        Text("No partner venues yet. Check back soon.")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                            .padding(.vertical, AppSpacing.medium)
                    }
                    ForEach(viewModel.venues) { venue in
                        Button { selectedVenueID = venue.id } label: { VenueRow(venue: venue) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(AppSpacing.medium)
            }
            .frame(maxHeight: .infinity)
            .background(AppColors.background)
        }
        .task { await viewModel.load() }
        .sheet(item: Binding(
            get: { selectedVenue },
            set: { selectedVenueID = $0?.id }
        )) { venue in
            VenueDetailSheet(viewModel: viewModel, venue: venue)
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var banner: some View {
        switch viewModel.phase {
        case let .active(checkIn):
            ActiveCheckInCard(viewModel: viewModel, checkIn: checkIn)
        case let .finished(checkIn):
            FinishedCheckInCard(checkIn: checkIn) { viewModel.dismissResult() }
        case .idle, .starting:
            EmptyView()
        }
    }
}

private struct VenueRow: View {
    let venue: Venue

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
            Image(systemName: venue.venueType.icon)
                .frame(width: 36, height: 36)
                .foregroundStyle(AppColors.brand)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(venue.name).font(.headline)
                Text("\(venue.venueType.title) · stay \(venue.dwellText)")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            }
            Spacer()
            if venue.checkedInToday {
                Label("Done today", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AppColors.success)
            } else {
                Text("12 pts").font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.brand)
            }
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay { RoundedRectangle(cornerRadius: AppRadius.card).stroke(AppColors.border, lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}

private struct ActiveCheckInCard: View {
    @ObservedObject var viewModel: VenuesViewModel
    let checkIn: CheckIn

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Checking in at \(checkIn.venueName)").font(.headline)
            ProgressView(value: Double(viewModel.elapsedSeconds), total: Double(max(1, checkIn.requiredDwellS)))
                .tint(AppColors.brand)
            Text("\(DwellFormat.clock(seconds: viewModel.remainingSeconds(for: checkIn))) to go — stay at the venue. Locking your phone is fine.")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
            if let notice = viewModel.connectionNotice {
                Text(notice).font(.footnote).foregroundStyle(AppColors.warning)
            }
            Button("Cancel check-in", role: .cancel) { Task { await viewModel.cancel() } }
                .font(.subheadline)
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
    let checkIn: CheckIn
    let dismiss: () -> Void

    private var earned: Bool { checkIn.status == .completed }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Label(
                earned ? "Checked in at \(checkIn.venueName)" : "Check-in ended",
                systemImage: earned ? "checkmark.seal.fill" : "info.circle"
            )
            .font(.headline)
            .foregroundStyle(earned ? AppColors.success : AppColors.information)
            Text(earned
                 ? (checkIn.awardedPoints > 0
                    ? "You earned \(checkIn.awardedPoints) points."
                    : "You've reached today's 72-point limit, so no more points today — thanks for visiting!")
                 : checkIn.abandonMessage)
                .font(.subheadline)
            Button("Done", action: dismiss).font(.subheadline.weight(.semibold))
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay { RoundedRectangle(cornerRadius: AppRadius.card).stroke(AppColors.border, lineWidth: 1) }
    }
}

private struct VenueDetailSheet: View {
    @ObservedObject var viewModel: VenuesViewModel
    let venue: Venue
    @Environment(\.dismiss) private var dismiss

    private var isCheckingInHere: Bool { viewModel.activeCheckIn?.venueID == venue.id }
    private var isStartingHere: Bool { viewModel.phase == .starting(venueID: venue.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.medium) {
                Label(venue.venueType.title, systemImage: venue.venueType.icon)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                Text(venue.name).font(.title2.weight(.bold))
                if !venue.address.isEmpty { Text(venue.address).foregroundStyle(AppColors.secondaryText) }
                if !venue.description.isEmpty { Text(venue.description) }
                if !venue.openingHours.isEmpty {
                    Text("Hours: \(venue.openingHours)").font(.subheadline).foregroundStyle(AppColors.secondaryText)
                }
                Text("Earn 12 points by staying within \(venue.checkinRadiusM) m for \(venue.dwellText). Once per venue per day. Vitail only checks your location after you tap Start check-in.")
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)

                if let message = viewModel.errorMessage, !isCheckingInHere {
                    Text(message).font(.footnote).foregroundStyle(AppColors.error)
                }
                if isCheckingInHere, let checkIn = viewModel.activeCheckIn {
                    ActiveCheckInCard(viewModel: viewModel, checkIn: checkIn)
                } else if venue.checkedInToday {
                    Label("Checked in today — come back tomorrow", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                } else {
                    PrimaryButton(
                        title: viewModel.isBusy && !isStartingHere ? "Finish your current check-in first" : "Start check-in",
                        isLoading: isStartingHere,
                        isDisabled: viewModel.isBusy && !isStartingHere
                    ) {
                        Task { await viewModel.start(venue) }
                    }
                }
            }
            .padding(AppSpacing.medium)
        }
        .background(AppColors.background)
        .onChange(of: viewModel.phase) { _, phase in
            if case .finished = phase { dismiss() }
        }
    }
}
