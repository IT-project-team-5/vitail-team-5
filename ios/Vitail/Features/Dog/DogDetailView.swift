import SwiftUI

struct DogDetailView: View {
    @ObservedObject var viewModel: DogViewModel
    let dog: Dog
    var documentService: any DocumentServing = DocumentService()
    var session: SessionStore? = nil
    var onDocumentsChanged: () async -> Void = {}
    var onGoalsChanged: () async -> Void = {}
    var goalService: any DogServicing = DogService()
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false

    private var currentDog: Dog { viewModel.dogs.first { $0.id == dog.id } ?? dog }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.large) {
                    AvatarView(url: currentDog.photo, name: currentDog.name, systemImage: "dog.fill", size: 112)
                    Text(currentDog.name).font(.largeTitle.bold())
                    VStack(spacing: AppSpacing.medium) {
                        LabeledContent("Breed", value: currentDog.breed.name)
                        LabeledContent("Birthday", value: currentDog.dateOfBirth.map(DogBirthday.display) ?? "Not recorded")
                        LabeledContent(currentDog.dateOfBirth == nil ? "Recorded age" : "Age", value: currentDog.ageDescription)
                        LabeledContent("Size", value: currentDog.size.label)
                        LabeledContent("Weight", value: currentDog.weightKg.map { "\($0) kg" } ?? "Not recorded")
                        if currentDog.isBrachycephalic {
                            LabeledContent("Brachycephalic", value: "Yes")
                        }
                    }
                    .padding(AppSpacing.large)
                    .background(AppColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
                    NavigationLink("Daily walking goal") {
                        DogGoalView(dog: currentDog, service: goalService, onChanged: onGoalsChanged)
                    }
                    NavigationLink {
                        DogDocumentsView(dogID: currentDog.id, service: documentService, session: session,
                                         onChanged: onDocumentsChanged)
                    } label: {
                        HStack {
                            Label("Registration documents", systemImage: "doc.text")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .font(.headline).padding(AppSpacing.large)
                        .foregroundStyle(AppColors.primaryText)
                        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.card))
                    }.buttonStyle(.plain)
                }
                .padding(AppSpacing.large)
                .frame(maxWidth: .infinity)
            }
            .background(AppColors.background)
            .navigationTitle("Dog Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Edit") { isEditing = true } }
            }
            .sheet(isPresented: $isEditing, onDismiss: {
                if !viewModel.dogs.contains(where: { $0.id == dog.id }) { dismiss() }
            }) {
                DogFormView(viewModel: viewModel, dog: currentDog)
            }
        }
    }
}

struct DogGoalView: View {
    let dog: Dog
    var onChanged: () async -> Void = {}
    @StateObject private var model: DogGoalViewModel
    @State private var percentage = 100

    init(dog: Dog, service: any DogServicing = DogService(), onChanged: @escaping () async -> Void = {}) {
        self.dog = dog
        self.onChanged = onChanged
        _model = StateObject(wrappedValue: DogGoalViewModel(service: service))
    }

    var body: some View {
        Form {
            Section("\(dog.name)'s walking goal") {
                Stepper("Exercise level: \(percentage)%", value: $percentage, in: 50...200, step: 1)
                    .disabled(model.isSaving)
                Text("Choose 50–200% of the recommendation. Start at 100% and adjust for your dog's exercise needs.")
                    .font(.footnote)
                if model.isLoading { ProgressView("Calculating…") }
                if let preview = model.preview {
                    if preview.eligible {
                        LabeledContent("Recommendation", value: preview.recommendation)
                        LabeledContent("Your daily target", value: preview.targetSeconds.map(DogGoalPreview.duration) ?? "Unavailable")
                        LabeledContent("Starts", value: DogBirthday.display(preview.effectiveFrom))
                        Text("Changes preserve today's goal. Profile edits do not change a saved target; review and save a new goal when needed.")
                            .font(.footnote)
                        Button(model.saved ? "Goal saved" : "Save walking goal") {
                            Task {
                                if await model.save(dogID: dog.id, percentage: percentage) { await onChanged() }
                            }
                        }
                        .disabled(!model.canSave(percentage: percentage))
                    } else {
                        Text(preview.reason ?? "Personalised goal unavailable.")
                        if !preview.missingInputs.isEmpty {
                            Text("Edit the dog profile to add: \(preview.missingInputs.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")).")
                                .font(.footnote)
                        }
                    }
                }
            }
            if let preview = model.preview {
                Section("Saved goals") {
                    LabeledContent("Current target", value: preview.currentTarget?.duration ?? "Not configured")
                    if let detail = preview.currentTarget?.calculationInputs?.description {
                        Text(detail).font(.footnote)
                    }
                    ForEach(preview.scheduledTargets) { target in
                        VStack(alignment: .leading) {
                            LabeledContent(DogBirthday.display(target.effectiveFrom), value: target.duration)
                            if let detail = target.calculationInputs?.description { Text(detail).font(.footnote) }
                        }
                    }
                    Text("Admin and owner changes share this schedule. A paused goal stays paused until a later target starts.")
                        .font(.footnote)
                }
            }
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(AppColors.error)
                    Button("Reload recommendation") { Task { await model.load(dogID: dog.id, percentage: percentage) } }
                        .disabled(model.isSaving)
                }
            }
            Section { Text("Daily-goal rewards are not yet available.").font(.footnote) }
        }
        .navigationTitle("Daily walking goal")
        .task(id: percentage) { await model.load(dogID: dog.id, percentage: percentage) }
        .interactiveDismissDisabled(model.isSaving)
    }
}
