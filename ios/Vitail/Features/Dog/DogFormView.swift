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
        _size = State(initialValue: dog?.size ?? .medium)
        _isBrachycephalic = State(initialValue: draft?.brachycephalic ?? dog?.isBrachycephalic ?? false)
        _weightKg = State(initialValue: draft?.weight ?? dog?.weightKg ?? "")
        _requestID = State(initialValue: draft?.requestID ?? UUID())
        _photoData = State(initialValue: draft?.photo)
        _pendingRequest = State(initialValue: UserDefaults.standard.data(forKey: draftKey + ":pending")
            .flatMap { try? JSONDecoder().decode(DogWriteRequest.self, from: $0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AvatarPhotoPicker(url: dog?.photo, name: name.isEmpty ? "your dog" : name,
                                      systemImage: "dog.fill", photoData: $photoData)
                        .padding(.vertical, AppSpacing.medium)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                if pendingRequest != nil && dog == nil {
                    Section {
                        Text("Your previous save needs confirmation. Retry to recover that profile, then edit its details if needed.")
                            .font(.footnote)
                    }
                }
                Section("Dog details") {
                    TextField("Name", text: $name, prompt: Text("Name").foregroundStyle(AppColors.secondaryText))
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .weight }
                    Picker("Breed", selection: $breedID) {
                        Text("Select a breed").tag(Int?.none)
                        ForEach(viewModel.breeds) { breed in
                            Text(breed.name).tag(Optional(breed.id))
                        }
                    }
                    Toggle("Brachycephalic", isOn: $isBrachycephalic)
                    TextField("Weight (kg)", text: $weightKg)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .weight)
                }
                .disabled(pendingRequest != nil && dog == nil)
                .listRowBackground(AppColors.surface)

                Section {
                    Button {
                        birthdayDraft = birthday.flatMap(DogBirthday.date(from:)) ?? Date()
                        isChoosingBirthday = true
                    } label: {
                        LabeledContent("Birthday", value: birthday.map(DogBirthday.display) ?? "Select birthday")
                    }
                    .foregroundStyle(AppColors.primaryText)
                    if let birthday, let age = DogBirthday.ageMonths(birthday: birthday) {
                        LabeledContent("Age", value: ageDescription(months: age))
                    } else if let dog {
                        LabeledContent("Recorded age", value: dog.ageDescription)
                    }
                } header: {
                    Text("Birthday")
                } footer: {
                    Text(dog != nil && birthday == nil
                         ? "Birthday is not recorded. Add it when you know it."
                         : "Your dog's age updates automatically from their birthday.")
                }
                .disabled(pendingRequest != nil && dog == nil)
                .listRowBackground(AppColors.surface)

                if let message = validationMessage ?? viewModel.errorMessage {
                    Section { Text(message).foregroundStyle(AppColors.error) }
                        .listRowBackground(AppColors.surface)
                }

                if dog != nil {
                    Section {
                        Button("Delete Dog", role: .destructive) {
                            isConfirmingDelete = true
                        }
                        .foregroundStyle(AppColors.error)
                        .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(AppColors.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { focusedField = nil }
            .background(AppColors.background)
            .navigationTitle(dog == nil ? "Add Dog" : "Edit Dog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pendingRequest != nil && dog == nil ? "Retry save" : "Save") { Task { await save() } }
                        .disabled(viewModel.isSaving)
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
                     weight: weightKg, requestID: requestID, photo: photoData)
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
            VStack(spacing: AppSpacing.medium) {
                Text("Set up Vitail").font(.title2.bold())
                Text("Account created · \(selectedDog == nil ? "Step 2 of 3: Dog profile" : "Step 3 of 3: Walking goal")")
                    .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    .multilineTextAlignment(.center)
                ProgressView(value: selectedDog == nil ? 0.5 : 1).tint(AppColors.brand)
                if let selectedDog {
                    DogGoalView(dog: dogs.dogs.first { $0.id == selectedDog.id } ?? selectedDog, service: dogs.goalService,
                                onSavingChanged: { savingGoal = $0 }, setupActions: AnyView(setupActions))
                        .id(selectedDog.id)
                } else {
                    ScrollView {
                        DogListView(viewModel: dogs, addDog: { addingDog = true }, editDog: { selectedDog = $0 })
                        setupActions
                    }
                }
            }
            .padding(AppSpacing.large)
            .background(AppColors.background)
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
            if let selectedDog {
                Button("Back to \(selectedDog.name)'s profile") { editingDog = selectedDog }
                    .disabled(savingGoal || finishing)
                if dogs.dogs.count > 1 {
                    Button("Review both dogs") { self.selectedDog = nil }
                        .disabled(savingGoal || finishing)
                }
            }
            if let message = errorMessage ?? dogs.errorMessage {
                Text(message).foregroundStyle(AppColors.error)
                if dogs.dogs.isEmpty { Button("Retry loading dogs") { Task { await dogs.load() } } }
            }
            if !dogs.dogs.isEmpty {
                if selectedDog != nil {
                    Text("Save your goal above, or finish without an active goal and set one later in Dog Profile.")
                        .font(.footnote).foregroundStyle(AppColors.secondaryText)
                }
                if dogs.canAddDog { Button("Add a second dog (optional)") { addingDog = true }.disabled(savingGoal || finishing) }
                PrimaryButton(title: "Finish setup", isLoading: finishing, isDisabled: savingGoal) { Task { await finish() } }
            }
        }
        .buttonStyle(.borderless)
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
