import SwiftUI

struct DogFormView: View {
    @ObservedObject var viewModel: DogViewModel
    @State private var dog: Dog?
    private let onSave: (() -> Void)?
    private let onSavedDog: ((Dog) -> Void)?
    private let isNew: Bool
    private let draftKey: String
    @State private var photoData: Data?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var breedID: Int?
    @State private var birthday: String?
    @State private var birthdayDraft: Date
    @State private var isChoosingBirthday = false
    @State private var size: DogSize
    @State private var isBrachycephalic: Bool
    @State private var weightKg: String
    @State private var validationMessage: String?
    @State private var isConfirmingDelete = false
    @State private var requestID = UUID()
    @State private var isShowingGoal = false
    @State private var pendingRequest: DogWriteRequest?
    @FocusState private var focusedField: Field?
    private enum Field { case name, weight }

    init(viewModel: DogViewModel, dog: Dog? = nil, onSave: (() -> Void)? = nil, onSavedDog: ((Dog) -> Void)? = nil) {
        self.viewModel = viewModel
        self.onSavedDog = onSavedDog
        isNew = dog == nil
        draftKey = viewModel.draftKey + ":\(dog?.id ?? 0)"
        let draft = UserDefaults.standard.data(forKey: draftKey).flatMap { try? JSONDecoder().decode(DogFormDraft.self, from: $0) }
        _dog = State(initialValue: dog)
        self.onSave = onSave
        _name = State(initialValue: draft?.name ?? dog?.name ?? "")
        _breedID = State(initialValue: draft?.breedID ?? dog?.breed.id)
        _birthday = State(initialValue: draft?.birthday ?? dog?.dateOfBirth)
        _birthdayDraft = State(initialValue: dog?.dateOfBirth.flatMap(DogBirthday.date(from:)) ?? Date())
        _size = State(initialValue: draft?.size ?? dog?.size ?? .medium)
        _isBrachycephalic = State(initialValue: draft?.brachycephalic ?? dog?.isBrachycephalic ?? false)
        _weightKg = State(initialValue: draft?.weight ?? dog?.weightKg ?? "")
        _requestID = State(initialValue: draft?.requestID ?? UUID())
        _photoData = State(initialValue: draft?.photo)
        _pendingRequest = State(initialValue: UserDefaults.standard.data(forKey: draftKey + ":pending")
            .flatMap { try? JSONDecoder().decode(DogWriteRequest.self, from: $0) })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AvatarPhotoPicker(url: dog?.photo, name: name.isEmpty ? "your dog" : name,
                                      systemImage: "dog.fill", photoData: $photoData)
                        .padding(.vertical, AppSpacing.small)
                    if pendingRequest != nil && dog == nil {
                        Text("Your previous save needs confirmation. Retry to recover that profile, then edit its details if needed.")
                            .font(AppFont.body(13, relativeTo: .footnote))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .vitailInset()
                    }
                    Group {
                        fieldGroup("Dog's name") {
                            TextField("Name", text: $name, prompt: Text("e.g. Mochi").foregroundStyle(AppColors.secondaryText))
                                .focused($focusedField, equals: .name)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .weight }
                                .vitailFieldStyle()
                        }
                        fieldGroup("Breed") {
                            Menu {
                                Picker("Breed", selection: $breedID) {
                                    Text("Select a breed").tag(Int?.none)
                                    ForEach(viewModel.breeds) { breed in
                                        Text(breed.name).tag(Optional(breed.id))
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(selectedBreedName)
                                        .foregroundStyle(breedID == nil ? AppColors.secondaryText : AppColors.primaryText)
                                    Spacer(minLength: AppSpacing.small)
                                    Image(systemName: "chevron.down")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(AppColors.secondaryText)
                                        .accessibilityHidden(true)
                                }
                                .vitailFieldStyle()
                                // Include the label, spacer and arrow in the native control.
                                .contentShape(Rectangle())
                            }
                            .menuIndicator(.hidden)
                            .buttonStyle(.plain)
                            .accessibilityLabel("Breed")
                            .accessibilityValue(selectedBreedName)
                            .accessibilityIdentifier("dog.breed")
                        }
                        fieldGroup("Birthday", footer: dog != nil && birthday == nil
                                    ? "Birthday is not recorded. Add it when you know it."
                                    : "Used for birthday quests. Age updates automatically.") {
                            Button {
                                birthdayDraft = birthday.flatMap(DogBirthday.date(from:)) ?? Date()
                                isChoosingBirthday = true
                            } label: {
                                HStack {
                                    Text(birthday.map(DogBirthday.display) ?? "DD / MM / YYYY")
                                        .foregroundStyle(birthday == nil ? AppColors.secondaryText : AppColors.primaryText)
                                    Spacer()
                                    if let birthday, let age = DogBirthday.ageMonths(birthday: birthday) {
                                        Text(ageDescription(months: age))
                                            .font(AppFont.body(13, relativeTo: .subheadline))
                                            .foregroundStyle(AppColors.secondaryText)
                                    } else if let dog {
                                        Text(dog.ageDescription)
                                            .font(AppFont.body(13, relativeTo: .subheadline))
                                            .foregroundStyle(AppColors.secondaryText)
                                    }
                                    Image(systemName: "calendar").foregroundStyle(AppColors.secondaryText)
                                }
                                .vitailFieldStyle()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Birthday")
                            .accessibilityValue(birthday.map(DogBirthday.display) ?? "Not selected")
                        }
                        fieldGroup("Size") {
                            VitailSegmentedControl(selection: $size,
                                                   options: DogSize.allCases.map { (value: $0, title: $0.label) },
                                                   label: "Size")
                        }
                        fieldGroup("Weight (kg)") {
                            TextField("Weight (kg)", text: $weightKg, prompt: Text("e.g. 9.5").foregroundStyle(AppColors.secondaryText))
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .weight)
                                .vitailFieldStyle()
                        }
                        Toggle(isOn: $isBrachycephalic) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Brachycephalic").font(AppFont.heading(15, .semibold))
                                Text("Short-nosed breeds get gentler goals")
                                    .font(AppFont.body(12, relativeTo: .caption))
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                        }
                        .tint(AppColors.sage)
                        .padding(14)
                        .vitailCardBackground(shadow: false)
                    }
                    .disabled(pendingRequest != nil && dog == nil)

                    if let message = validationMessage ?? viewModel.errorMessage {
                        Label(message, systemImage: "exclamationmark.circle.fill")
                            .font(AppFont.body(14, .medium))
                            .foregroundStyle(AppColors.error)
                    }

                    PrimaryButton(title: pendingRequest != nil && dog == nil ? "Retry save" : (isNew ? "Continue" : "Save"),
                                  isLoading: viewModel.isSaving, isDisabled: viewModel.isSaving) {
                        Task { await save() }
                    }
                    .padding(.top, 4)

                    if dog != nil {
                        Button(role: .destructive) {
                            isConfirmingDelete = true
                        } label: {
                            Text("Delete Dog")
                                .font(AppFont.heading(16, .semibold))
                                .foregroundStyle(AppColors.error)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, AppSpacing.medium)
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(AppColors.background)
            .navigationTitle(dog == nil ? "Dog profile" : "Edit Dog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .disabled(viewModel.isSaving)
            .interactiveDismissDisabled(viewModel.isSaving)
            .onChange(of: draft) { _, value in
                guard !isNew || dog == nil else { return }
                if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: draftKey) }
            }
            .navigationDestination(isPresented: $isShowingGoal) {
                if let dog {
                    DogGoalView(dog: dog, service: viewModel.goalService)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                }
            }
            .sheet(isPresented: $isChoosingBirthday) {
                NavigationStack {
                    DatePicker("Birthday", selection: $birthdayDraft, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .environment(\.calendar, DogBirthday.calendar)
                        .environment(\.timeZone, DogBirthday.timeZone)
                        .padding(AppSpacing.large)
                        .background(AppColors.background)
                        .navigationTitle("Birthday")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { isChoosingBirthday = false }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Use Birthday") {
                                    birthday = DogBirthday.string(from: birthdayDraft)
                                    isChoosingBirthday = false
                                }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .onChange(of: breedID) { _, newValue in
                guard
                    let newValue,
                    let breed = viewModel.breeds.first(where: { $0.id == newValue })
                else { return }
                size = breed.defaultSize
                isBrachycephalic = breed.isBrachycephalic
            }
            .alert("Delete \(dog?.name ?? "this dog")?", isPresented: $isConfirmingDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task { await deleteDog() }
                }
            } message: {
                Text("This dog profile will be permanently deleted.")
            }
        }
    }

    private func fieldGroup<Content: View>(_ label: String, footer: String? = nil,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VitailSectionLabel(text: label).padding(.horizontal, 4).accessibilityHidden(true)
            content()
            if let footer {
                Text(footer).font(AppFont.body(12, relativeTo: .caption))
                    .foregroundStyle(AppColors.secondaryText)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var selectedBreedName: String {
        viewModel.breeds.first(where: { $0.id == breedID })?.name ?? "Select a breed"
    }

    private func save() async {
        if dog == nil, let pendingRequest {
            await performSave(pendingRequest)
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Enter your dog's name."
            return
        }
        guard let breedID else {
            validationMessage = "Select a breed."
            return
        }
        guard dog != nil || birthday != nil else {
            validationMessage = "Select your dog's birthday."
            return
        }
        let ageMonths: Int
        if let birthday {
            guard let computedAge = DogBirthday.ageMonths(birthday: birthday) else {
                validationMessage = "Select a valid birthday that is not in the future."
                return
            }
            ageMonths = computedAge
        } else {
            ageMonths = dog?.ageMonths ?? 0
        }

        let weight = weightKg.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.autoupdatingCurrent.decimalSeparator ?? ".", with: ".")
        let parsedWeight = Decimal(string: weight)
        if (isNew && weight.isEmpty) || (!weight.isEmpty && (weight.range(of: #"^[0-9]+(?:\.[0-9]{1,2})?$"#, options: .regularExpression) == nil
                              || parsedWeight == nil || parsedWeight! <= 0 || parsedWeight! > 9999.99)) {
            validationMessage = "Enter a positive weight in kilograms with up to two decimal places."
            return
        }
        validationMessage = nil
        var request = DogWriteRequest(
            name: trimmedName,
            breedID: breedID,
            ageMonths: ageMonths,
            size: size,
            isBrachycephalic: isBrachycephalic,
            dateOfBirth: birthday,
            weightKg: parsedWeight.map { NSDecimalNumber(decimal: $0).stringValue }
        )
        request.requestID = requestID
        if dog == nil {
            pendingRequest = request
            UserDefaults.standard.set(try? JSONEncoder().encode(request), forKey: draftKey + ":pending")
        }
        await performSave(request)
    }

    private func performSave(_ request: DogWriteRequest) async {
        let pendingKey = draftKey + ":pending"
        focusedField = nil
        if await viewModel.save(dog: dog, request: request, photoData: photoData) {
            pendingRequest = nil
            UserDefaults.standard.removeObject(forKey: pendingKey)
            UserDefaults.standard.removeObject(forKey: draftKey)
            onSave?()
            if let saved = viewModel.lastSavedDog, isNew {
                dog = saved
                if let onSavedDog { onSavedDog(saved); dismiss() }
                else { isShowingGoal = true }
            } else { dismiss() }
        } else if let savedDog = viewModel.lastSavedDog {
            // A saved profile remains editable if its photo failed; retry must not create another dog.
            dog = savedDog
        } else if !viewModel.saveMayHaveCommitted {
            pendingRequest = nil
            UserDefaults.standard.removeObject(forKey: pendingKey)
            requestID = UUID()
        }
    }

    private var draft: DogFormDraft {
        DogFormDraft(name: name, breedID: breedID, birthday: birthday, brachycephalic: isBrachycephalic,
                     weight: weightKg, requestID: requestID, photo: photoData, size: size)
    }

    private func ageDescription(months: Int) -> String {
        let years = months / 12
        let remainingMonths = months % 12
        if years == 0 { return "\(remainingMonths) mo" }
        let yearsText = "\(years) yr\(years == 1 ? "" : "s")"
        return remainingMonths == 0 ? yearsText : "\(yearsText) \(remainingMonths) mo"
    }

    private func deleteDog() async {
        guard let dog else { return }
        if await viewModel.delete(dog) { dismiss() }
    }
}

private struct DogFormDraft: Codable, Equatable {
    let name: String
    let breedID: Int?
    let birthday: String?
    let brachycephalic: Bool
    let weight: String
    let requestID: UUID
    let photo: Data?
    // Optional so drafts saved before the size control was added still decode.
    let size: DogSize?
}

struct DogOnboardingView: View {
    @ObservedObject var dogs: DogViewModel
    @ObservedObject var session: SessionStore
    @State private var selectedDog: Dog?
    @State private var addingDog = false
    @State private var editingDog: Dog?
    @State private var finishing = false
    @State private var errorMessage: String?
    @State private var savingGoal = false
    let onFinished: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                VitailStepBar(step: selectedDog == nil ? 1 : 2, total: 2)
                if let selectedDog {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Set \(selectedDog.name)'s daily goal").vitailTitle(26)
                        Text("Pick a level you can keep up most days. You can change it any time in Account.")
                            .font(AppFont.body(14)).foregroundStyle(AppColors.secondaryText)
                    }
                    DogGoalView(dog: dogs.dogs.first { $0.id == selectedDog.id } ?? selectedDog, service: dogs.goalService,
                                onSavingChanged: { savingGoal = $0 }, setupActions: AnyView(setupActions))
                        .id(selectedDog.id)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Tell us about your dog").vitailTitle(26)
                                Text("You can add more dogs later in Account.")
                                    .font(AppFont.body(14)).foregroundStyle(AppColors.secondaryText)
                            }
                            DogListView(viewModel: dogs, addDog: { addingDog = true }, editDog: { selectedDog = $0 })
                            setupActions
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, AppSpacing.medium)
            .background(AppColors.background)
            .navigationTitle(selectedDog == nil ? "Dog profile" : "Daily goal")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $addingDog) {
                DogFormView(viewModel: dogs, onSavedDog: { selectedDog = $0 })
            }
            .sheet(item: $editingDog, onDismiss: {
                if let selectedDog, !dogs.dogs.contains(where: { $0.id == selectedDog.id }) {
                    self.selectedDog = dogs.dogs.last
                }
            }) { dog in DogFormView(viewModel: dogs, dog: dog) }
            .task {
                await dogs.load()
                selectedDog = dogs.dogs.last
                if dogs.errorMessage == nil && dogs.dogs.isEmpty { addingDog = true }
            }
        }
        .interactiveDismissDisabled()
    }

    private var setupActions: some View {
        VStack(spacing: AppSpacing.medium) {
            if let message = errorMessage ?? dogs.errorMessage {
                Text(message).font(AppFont.body(14)).foregroundStyle(AppColors.error)
                if dogs.dogs.isEmpty {
                    SecondaryButton(title: "Retry loading dogs") { Task { await dogs.load() } }
                }
            }
            if !dogs.dogs.isEmpty {
                if selectedDog != nil {
                    Text("Save your goal above, or finish without an active goal and set one later in Dog Profile.")
                        .font(AppFont.body(12, relativeTo: .footnote)).foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.center)
                }
                PrimaryButton(title: "Finish setup", isLoading: finishing, isDisabled: savingGoal) { Task { await finish() } }
                if dogs.canAddDog {
                    VitailTextButton(title: "Add a second dog (optional)", systemImage: "plus") { addingDog = true }
                        .disabled(savingGoal || finishing)
                }
            }
            if let selectedDog {
                VitailTextButton(title: "Back to \(selectedDog.name)'s profile") { editingDog = selectedDog }
                    .disabled(savingGoal || finishing)
                if dogs.dogs.count > 1 {
                    VitailTextButton(title: "Review both dogs") { self.selectedDog = nil }
                        .disabled(savingGoal || finishing)
                }
            }
        }
    }

    private func finish() async {
        guard !finishing else { return }
        finishing = true
        defer { finishing = false }
        do {
            _ = try await dogs.goalService.completeOnboarding()
            try await session.reloadCurrentUser()
            onFinished()
        } catch { errorMessage = error.localizedDescription }
    }
}
