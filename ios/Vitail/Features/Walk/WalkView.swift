import MapKit
import SwiftUI

struct WalkView: View {
    @ObservedObject var session: SessionStore
    @StateObject private var model: WalkViewModel
    private let onWalletChanged: @MainActor () async -> Void

    init(
        session: SessionStore,
        service: any WalkServing = WalkService(),
        dogService: any DogServicing = DogService(),
        onWalletChanged: @escaping @MainActor () async -> Void = {}
    ) {
        self.session = session
        self.onWalletChanged = onWalletChanged
        _model = StateObject(wrappedValue: WalkViewModel(service: service, dogService: dogService))
    }

    var body: some View {
        WalkContent(model: model, recorder: model.recorder)
            .task {
                model.onWalletChanged = onWalletChanged
                session.beforeLogout = { [weak model] in await model?.finishForLogout() }
                await model.load()
            }
            .onChange(of: session.state) { _, state in
                if case .signedOut = state { model.discard() }
            }
            .onDisappear {
                // Swiping tabs keeps recording; removing the signed-in flow does not.
                if case .signedIn = session.state { return }
                model.discard()
            }
    }
}

private struct WalkContent: View {
    @ObservedObject var model: WalkViewModel
    @ObservedObject var recorder: WalkRecorder
    @State private var confirmDiscard = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                Text("8 points per km · up to 40 walking points per day")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)

                if !recorder.isActive && model.pendingRequest == nil {
                    dogSelection
                }

                if !recorder.coordinates.isEmpty {
                    Map {
                        MapPolyline(coordinates: recorder.coordinates)
                            .stroke(AppColors.brand, lineWidth: 5)
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
                }

                if recorder.isActive {
                    Text(recorder.phase == .locating ? "Waiting for GPS…" : "Recording your walk")
                        .font(.headline)
                    Text(String(format: "%.2f km estimated", recorder.estimatedDistanceM / 1000))
                        .font(.title2.bold())
                    if let started = recorder.startedAt {
                        Text(started, style: .timer).monospacedDigit()
                    }
                    Text("GPS continues while the phone is locked. Ends after 5 minutes without movement.")
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)
                    PrimaryButton(title: "End Walk", isLoading: model.isSaving) {
                        Task { await model.finish() }
                    }
                } else if model.pendingRequest != nil {
                    Text("This walk has not been saved yet. Retry before starting another walk.")
                        .font(.subheadline)
                    PrimaryButton(title: "Retry Upload", isLoading: model.isSaving) {
                        Task { await model.retryUpload() }
                    }
                    Button("Discard Unsaved Walk", role: .destructive) { confirmDiscard = true }
                        .disabled(model.isSaving)
                } else {
                    PrimaryButton(title: "Start Walk", isDisabled: model.selectedDogIDs.isEmpty || model.isLoading) {
                        model.start()
                    }
                }

                if let message = recorder.message {
                    Text(message).font(.footnote).foregroundStyle(AppColors.secondaryText)
                }
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(AppColors.error)
                    if model.dogs.isEmpty {
                        Button("Retry") { Task { await model.load() } }
                    }
                }
                if let walk = model.lastSavedWalk {
                    Text("Walk saved: \(walk.pointsAwarded) points added to your wallet.")
                        .font(.headline)
                    Text("The backend validates GPS and calculates points. Distance beyond the daily cap earns no extra points.")
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)
                }

                Text("Recent walks").font(.headline)
                if model.walks.isEmpty {
                    Text("Your saved walks will appear here.").foregroundStyle(AppColors.secondaryText)
                }
                ForEach(model.walks.prefix(10)) { walk in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(walk.pointDate)
                            Text(String(format: "%.2f km", walk.distanceM / 1000))
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        Spacer()
                        Text("+\(walk.pointsAwarded) pts").fontWeight(.semibold)
                    }
                }
                Text("Raw GPS is used to validate this walk, then discarded by the backend. Force-quitting loses an unsaved walk.")
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
            }
            .padding(AppSpacing.large)
        }
        .refreshable { await model.load() }
        .alert("Discard this unsaved walk?", isPresented: $confirmDiscard) {
            Button("Keep", role: .cancel) {}
            Button("Discard", role: .destructive) { model.discard() }
        } message: {
            Text("If an upload timed out, check your walk history first: the backend may already have saved it.")
        }
    }

    private var dogSelection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Who's coming?").font(.headline)
            if model.dogs.isEmpty {
                Text("Add a dog in Account before starting a walk.")
                    .foregroundStyle(AppColors.secondaryText)
            }
            ForEach(model.dogs) { dog in
                Toggle(dog.name, isOn: Binding(
                    get: { model.selectedDogIDs.contains(dog.id) },
                    set: { selected in
                        if selected { model.selectedDogIDs.insert(dog.id) }
                        else { model.selectedDogIDs.remove(dog.id) }
                    }
                ))
                .tint(AppColors.brand)
            }
        }
    }
}
