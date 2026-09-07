import CoreLocation
import SwiftUI

struct WalkDogSelectionCard: View {
    @ObservedObject var selection: WalkDogSelectionViewModel
    @ObservedObject var session: WalkSessionTracker
    let location: CLLocation?
    let onManageDogs: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        selection: WalkDogSelectionViewModel,
        session: WalkSessionTracker,
        location: CLLocation? = nil,
        onManageDogs: @escaping () -> Void
    ) {
        self.selection = selection
        self.session = session
        self.location = location
        self.onManageDogs = onManageDogs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    selectionTitle.fixedSize()
                    Spacer()
                    selectionActions.fixedSize()
                }
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    selectionTitle.fixedSize(horizontal: false, vertical: true)
                    selectionActions
                }
            }

            Text(dogSelectionHint)
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)

            if selection.isLoading || (!selection.hasLoaded && selection.errorMessage == nil) {
                HStack(spacing: AppSpacing.small) {
                    ProgressView()
                    Text("Loading your dogs...")
                        .foregroundStyle(AppColors.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, AppSpacing.small)
            } else if let message = selection.errorMessage {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    Label("Could not load your dogs", systemImage: "exclamationmark.circle")
                        .font(.headline)
                        .foregroundStyle(AppColors.error)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                    Button("Try Again", action: reloadDogs)
                        .fontWeight(.semibold)
                }
            } else if selection.dogs.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    Text("No dogs yet")
                        .font(.headline)
                    Text("Add a dog in Account before starting a walk.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                    Button(action: onManageDogs) {
                        Label("Add a dog", systemImage: "plus")
                            .fontWeight(.semibold)
                    }
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: AppSpacing.small) {
                        ForEach(displayedDogs) { dog in
                            dogSelectionButton(dog)
                        }
                    }
                    .padding(2)
                }
                .scrollIndicators(.hidden)
            }

            Divider()
            walkControls
        }
        .tint(AppColors.brand)
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }

    private var selectionTitle: some View {
        Label("Who's walking?", systemImage: "dog.fill")
            .font(.headline)
    }

    private var selectionCount: some View {
        Text("\(displayedSelectionCount) selected")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppColors.brand)
    }

    private var selectionActions: some View {
        HStack(spacing: 4) {
            selectionCount
            if !session.isInProgress {
                Menu {
                    Button("Select all") { selection.selectAll() }
                        .disabled(!selection.canEditSelection || selection.selectedDogIDs.count == selection.dogs.count)
                    Button("Clear selection") { selection.clearSelection() }
                        .disabled(!selection.canEditSelection || selection.selectedDogIDs.isEmpty)
                    Button("Refresh dogs", systemImage: "arrow.clockwise", action: reloadDogs)
                        .disabled(selection.isLoading)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Dog selection options")
            }
        }
    }

    private func dogSelectionButton(_ dog: Dog) -> some View {
        let isSelected = session.isInProgress
            ? session.participatingDogs.contains(where: { $0.id == dog.id })
            : selection.selectedDogIDs.contains(dog.id)

        return Button {
            selection.toggleDog(id: dog.id)
        } label: {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AppColors.brand : AppColors.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(dog.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.primaryText)
                        .lineLimit(2)
                    Text(dog.breed.name)
                        .font(.caption2)
                        .foregroundStyle(AppColors.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: dynamicTypeSize.isAccessibilitySize ? 200 : 128, alignment: .leading)
            .frame(minHeight: 40)
            .padding(10)
            .background(isSelected ? AppColors.brand.opacity(0.1) : AppColors.background)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.field))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.field)
                    .stroke(isSelected ? AppColors.brand : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!selection.canEditSelection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(dog.name), \(dog.breed.name)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var displayedDogs: [Dog] {
        session.isInProgress ? session.participatingDogs : selection.dogs
    }

    private var displayedSelectionCount: Int {
        session.isInProgress ? session.participatingDogs.count : selection.selectedDogIDs.count
    }

    private var dogSelectionHint: String {
        if session.isInProgress {
            return "Dogs are fixed until you finish. Swipe to see more."
        }
        if session.status == .finished {
            return "Choose dogs for your next walk. Swipe to see more."
        }
        return "Choose one or more dogs. Swipe to see more."
    }

    private var walkControls: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.status == .finished ? "Last walk distance" : "Distance")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(session.distanceKilometres, format: .number.precision(.fractionLength(2)))
                            .font(.title2.bold())
                            .monospacedDigit()
                        Text("km")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
                Spacer()
                Text(walkStatusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(walkStatusColour)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(walkStatusColour.opacity(0.12))
                    .clipShape(Capsule())
            }

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: AppSpacing.small))
                : AnyLayout(HStackLayout(spacing: AppSpacing.small))
            layout {
                WalkControlButton(
                    title: "Start Walk", icon: "play.fill", colour: AppColors.brand,
                    isDisabled: !selection.canStartWalk || !WalkSessionTracker.canUse(location)
                ) {
                    guard selection.canStartWalk else { return }
                    session.start(from: location, dogs: selection.selectedDogs)
                }
                WalkControlButton(
                    title: session.status == .paused ? "Resume" : "Pause",
                    icon: session.status == .paused ? "playpause.fill" : "pause.fill",
                    colour: .orange, isDisabled: !session.canPauseOrResume
                ) {
                    if session.status == .walking {
                        session.pause()
                    } else if session.status == .paused {
                        session.resume(from: location)
                    }
                }
                WalkControlButton(
                    title: "Finish Walk", icon: "stop.fill", colour: AppColors.error,
                    isDisabled: !session.canFinish
                ) {
                    session.finish()
                }
            }

            if session.canStart && selection.canEditSelection && !selection.dogs.isEmpty
                && selection.selectedDogIDs.isEmpty {
                Text("Select at least one dog to start.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            } else if session.canStart && !WalkSessionTracker.canUse(location) {
                Label("Waiting for an accurate location...", systemImage: "location.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    private var walkStatusTitle: String {
        switch session.status {
        case .idle: return "Ready"
        case .walking: return "Walking"
        case .paused: return "Paused"
        case .finished: return "Finished"
        }
    }

    private var walkStatusColour: Color {
        switch session.status {
        case .idle: return AppColors.secondaryText
        case .walking: return AppColors.brand
        case .paused: return .orange
        case .finished: return .blue
        }
    }

    private func reloadDogs() {
        Task { await selection.load() }
    }
}

private struct WalkControlButton: View {
    let title: String
    let icon: String
    let colour: Color
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.subheadline)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .foregroundStyle(isDisabled ? AppColors.secondaryText : colour)
            .background(isDisabled ? Color.secondary.opacity(0.08) : colour.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.field, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.field, style: .continuous)
                    .stroke(isDisabled ? Color.secondary.opacity(0.12) : colour.opacity(0.35))
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}
