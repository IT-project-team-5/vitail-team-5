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
                    AvatarView(url: currentDog.photo, name: currentDog.name, systemImage: "dog.fill", size: 104)
                        .background(Circle().fill(AppColors.outline).offset(x: AppStroke.shadow, y: AppStroke.shadow))
                    VStack(spacing: 4) {
                        Text(currentDog.name).vitailTitle(30)
                        Text(currentDog.breed.name).font(AppFont.body(14)).foregroundStyle(AppColors.secondaryText)
                    }
                    VStack(spacing: 12) {
                        LabeledContent("Breed", value: currentDog.breed.name)
                        LabeledContent("Birthday", value: currentDog.dateOfBirth.map(DogBirthday.display) ?? "Not recorded")
                        LabeledContent(currentDog.dateOfBirth == nil ? "Recorded age" : "Age", value: currentDog.ageDescription)
                        LabeledContent("Weight", value: currentDog.weightKg.map { "\($0) kg" } ?? "Not recorded")
                        if currentDog.isBrachycephalic {
                            LabeledContent("Brachycephalic", value: "Yes")
                        }
                    }
                    .font(AppFont.body(15))
                    .padding(18)
                    .vitailCardBackground()
                    .padding(.trailing, AppStroke.shadow)
                    NavigationLink {
                        DogGoalView(dog: currentDog, service: goalService, onChanged: onGoalsChanged)
                    } label: {
                        HStack(spacing: 12) {
                            VitailIconTile(systemImage: "figure.walk", fill: AppColors.honey, size: 40)
                            Text("Daily walking goal")
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppColors.secondaryText)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(AppFont.heading(16, .semibold)).padding(14)
                        .foregroundStyle(AppColors.primaryText)
                        .vitailCardBackground()
                        .contentShape(RoundedRectangle(cornerRadius: AppRadius.card))
                    }.buttonStyle(.plain).padding(.trailing, AppStroke.shadow)
                    NavigationLink {
                        DogDocumentsView(dogID: currentDog.id, service: documentService, session: session,
                                         onChanged: onDocumentsChanged)
                    } label: {
                        HStack(spacing: 12) {
                            VitailIconTile(systemImage: "doc.text", fill: AppColors.sky, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Documents")
                                Text("Vaccination & registration records")
                                    .font(AppFont.body(12, relativeTo: .caption)).foregroundStyle(AppColors.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        .font(AppFont.heading(16, .semibold)).padding(14)
                        .foregroundStyle(AppColors.primaryText)
                        .vitailCardBackground()
                    }.buttonStyle(.plain).padding(.trailing, AppStroke.shadow)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, AppSpacing.large)
                .frame(maxWidth: .infinity)
            }
            .background { VitailScreenBackground(layout: .leadingDog) }
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
    var onSavingChanged: (Bool) -> Void = { _ in }
    var setupActions: AnyView?
    @StateObject private var model: DogGoalViewModel
    @State private var percentage = 100
    private var percentageKey: String { "goal-adjustment:\(AppConfiguration.apiBaseURL?.absoluteString ?? ""):\(dog.id)" }

    init(dog: Dog, service: any DogServicing = DogService(), onChanged: @escaping () async -> Void = {},
         onSavingChanged: @escaping (Bool) -> Void = { _ in }, setupActions: AnyView? = nil) {
        self.dog = dog
        self.onChanged = onChanged
        self.onSavingChanged = onSavingChanged
        self.setupActions = setupActions
        _model = StateObject(wrappedValue: DogGoalViewModel(service: service))
    }

    private static let presets = [75, 100, 125, 150]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                targetCard
                HStack(spacing: 8) {
                    ForEach(Self.presets, id: \.self) { value in
                        let isSelected = percentage == value
                        Button { percentage = value } label: {
                            Text("\(value)%")
                                .font(AppFont.heading(15, .semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(VitailPressStyle(fill: isSelected ? AppColors.honey : AppColors.surface,
                                                      foreground: AppColors.onAccent, shadow: isSelected ? 3 : 0))
                        .padding(.trailing, isSelected ? 3 : 0)
                        .padding(.bottom, 3)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .disabled(model.isSaving || model.pendingSave != nil)
                VStack(alignment: .leading, spacing: 4) {
                    VitailSectionLabel(text: "Fine-tune · \(percentage)%")
                    Slider(value: Binding(get: { Double(percentage) }, set: { percentage = Int($0) }), in: 50...200, step: 1) {
                        Text("Walking goal adjustment")
                    } minimumValueLabel: { Text("50%").font(AppFont.body(12)) } maximumValueLabel: { Text("200%").font(AppFont.body(12)) }
                        .tint(AppColors.honey)
                        .accessibilityValue("\(percentage) percent of the recommendation")
                        .disabled(model.isSaving || model.pendingSave != nil)
                }
                infoBox
                if let preview = model.preview {
                    if preview.eligible {
                        PrimaryButton(title: model.saved ? "Goal saved" : model.pendingSave != nil ? "Retry saving goal" : "Save walking goal",
                                      isLoading: model.isSaving, isDisabled: !model.canSave(percentage: percentage)) {
                            Task {
                                if await model.save(dogID: dog.id, percentage: percentage) { await onChanged() }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(preview.reason ?? "Personalised goal unavailable.").font(AppFont.body(14, .medium))
                            if !preview.missingInputs.isEmpty {
                                Text("Edit the dog profile to add: \(preview.missingInputs.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")).")
                                    .font(AppFont.body(12, relativeTo: .footnote)).foregroundStyle(AppColors.secondaryText)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .vitailInset()
                    }
                }
                if let error = model.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(AppFont.body(14)).foregroundStyle(AppColors.error)
                        SecondaryButton(title: "Reload recommendation") { Task { await model.load(dogID: dog.id, percentage: percentage) } }
                            .disabled(model.isSaving)
                    }
                }
                if let pending = model.pendingSave {
                    VStack(alignment: .leading, spacing: 8) {
                        VitailSectionLabel(text: "Pending save")
                        Text("Retry will confirm your original \(pending.ownerAdjustment)× adjustment starting \(DogBirthday.display(pending.effectiveFrom)). It will not create another revision.")
                            .font(AppFont.body(12, relativeTo: .footnote))
                        if model.preview?.eligible != true {
                            SecondaryButton(title: "Retry saving goal") {
                                Task { if await model.save(dogID: dog.id, percentage: percentage) { await onChanged() } }
                            }
                            .disabled(!model.canSave(percentage: percentage))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vitailInset()
                }
                if let preview = model.preview { savedGoals(preview) }
                if let setupActions { setupActions.padding(.top, 4) }
            }
            .padding(.horizontal, setupActions == nil ? 20 : 0)
            .padding(.vertical, AppSpacing.medium)
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .tint(AppColors.brand)
        .navigationTitle("Daily walking goal")
        .onAppear {
            if let saved = UserDefaults.standard.object(forKey: percentageKey) as? Int, (50...200).contains(saved) { percentage = saved }
        }
        .task(id: percentage) {
            UserDefaults.standard.set(percentage, forKey: percentageKey)
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            await model.load(dogID: dog.id, percentage: percentage)
        }
        .interactiveDismissDisabled(model.isSaving)
        .onChange(of: model.isSaving) { _, saving in onSavingChanged(saving) }
    }

    /// Big target number, as on the prototype's daily goal card.
    private var targetCard: some View {
        VStack(spacing: 6) {
            if let preview = model.preview, preview.eligible, let target = preview.targetSeconds {
                let parts = DogGoalPreview.duration(target).split(separator: " ", maxSplits: 1).map(String.init)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(parts.first ?? "")
                        .font(AppFont.heading(64, .bold, relativeTo: .largeTitle))
                        .contentTransition(.numericText())
                    Text(parts.count > 1 ? parts[1] : "")
                        .font(AppFont.heading(22, .semibold, relativeTo: .title3))
                }
                Text("\(preview.recommendation) · \(percentage)%")
                    .font(AppFont.body(13, relativeTo: .subheadline)).foregroundStyle(AppColors.secondaryText)
                    .multilineTextAlignment(.center)
                Text("Starts \(DogBirthday.display(preview.effectiveFrom))")
                    .font(AppFont.body(12, relativeTo: .caption)).foregroundStyle(AppColors.secondaryText)
            } else if model.isLoading {
                ProgressView("Calculating…").font(AppFont.body(14))
            } else {
                Text("\(percentage)%").font(AppFont.heading(64, .bold, relativeTo: .largeTitle))
                Text("of the recommended daily walking time")
                    .font(AppFont.body(13, relativeTo: .subheadline)).foregroundStyle(AppColors.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .padding(.vertical, 12)
        .vitailCardBackground()
        .padding(.trailing, AppStroke.shadow)
        .padding(.bottom, AppStroke.shadow)
        .accessibilityElement(children: .combine)
    }

    private var infoBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            infoRow("sparkle", AppColors.honey, "+20 pts each day \(dog.name) reaches the goal")
            infoRow("flame.fill", AppColors.terracotta, "Walking, goal and check-in points share a 72-point daily cap")
            infoRow("pawprint.fill", AppColors.sage, "Changes keep today's goal. Start at 100% and adjust for your dog's needs")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vitailInset(padding: 14)
    }

    private func infoRow(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.footnote.weight(.bold)).foregroundStyle(color)
                .frame(width: 18).accessibilityHidden(true)
            Text(text).font(AppFont.body(13, relativeTo: .footnote)).foregroundStyle(AppColors.primaryText)
        }
    }

    private func savedGoals(_ preview: DogGoalPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VitailSectionLabel(text: "Saved goals")
            HStack {
                Text("Current target").font(AppFont.body(14)).foregroundStyle(AppColors.secondaryText)
                Spacer()
                Text(preview.currentTarget?.duration ?? "Not configured").font(AppFont.heading(15, .semibold))
            }
            if let detail = preview.currentTarget?.calculationInputs?.description {
                Text(detail).font(AppFont.body(12, relativeTo: .footnote)).foregroundStyle(AppColors.secondaryText)
            }
            ForEach(preview.scheduledTargets) { target in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(DogBirthday.display(target.effectiveFrom)).font(AppFont.body(14)).foregroundStyle(AppColors.secondaryText)
                        Spacer()
                        Text(target.duration).font(AppFont.heading(15, .semibold))
                    }
                    if let detail = target.calculationInputs?.description {
                        Text(detail).font(AppFont.body(12, relativeTo: .footnote)).foregroundStyle(AppColors.secondaryText)
                    }
                }
            }
            Text("Admin and owner changes share this schedule. A paused goal stays paused until a later target starts.")
                .font(AppFont.body(11, relativeTo: .caption2)).foregroundStyle(AppColors.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .vitailCardBackground(shadow: false)
    }
}
