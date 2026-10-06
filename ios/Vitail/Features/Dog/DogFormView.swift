import SwiftUI

struct DogFormView: View {
    @ObservedObject var viewModel: DogViewModel
    @State private var dog: Dog?
    private let onSave: (() -> Void)?
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

    init(viewModel: DogViewModel, dog: Dog? = nil, onSave: (() -> Void)? = nil) {
        self.viewModel = viewModel
        _dog = State(initialValue: dog)
        self.onSave = onSave
        _name = State(initialValue: dog?.name ?? "")
        _breedID = State(initialValue: dog?.breed.id)
        _birthday = State(initialValue: dog?.dateOfBirth)
        _birthdayDraft = State(initialValue: dog?.dateOfBirth.flatMap(DogBirthday.date(from:)) ?? Date())
        _size = State(initialValue: dog?.size ?? .medium)
        _isBrachycephalic = State(initialValue: dog?.isBrachycephalic ?? false)
        _weightKg = State(initialValue: dog?.weightKg ?? "")
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
                Section("Dog details") {
                    TextField("Name", text: $name, prompt: Text("Name").foregroundStyle(AppColors.secondaryText))
                    Picker("Breed", selection: $breedID) {
                        Text("Select a breed").tag(Int?.none)
                        ForEach(viewModel.breeds) { breed in
                            Text(breed.name).tag(Optional(breed.id))
                        }
                    }
                    Picker("Size", selection: $size) {
                        ForEach(DogSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    Toggle("Brachycephalic", isOn: $isBrachycephalic)
                    TextField("Weight (kg, for walking goals)", text: $weightKg)
                        .keyboardType(.decimalPad)
                }
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
            .background(AppColors.background)
            .navigationTitle(dog == nil ? "Add Dog" : "Edit Dog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(viewModel.isSaving)
            .interactiveDismissDisabled(viewModel.isSaving)
                }
            }
            .disabled(viewModel.isSaving)
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
        if !weight.isEmpty && (weight.range(of: #"^[0-9]+(?:\.[0-9]{1,2})?$"#, options: .regularExpression) == nil
                              || parsedWeight == nil || parsedWeight! <= 0) {
            validationMessage = "Enter a positive weight in kilograms with up to two decimal places."
            return
        }
        validationMessage = nil
        let request = DogWriteRequest(
            name: trimmedName,
            breedID: breedID,
            ageMonths: ageMonths,
            size: size,
            isBrachycephalic: isBrachycephalic,
            dateOfBirth: birthday,
            weightKg: parsedWeight.map { NSDecimalNumber(decimal: $0).stringValue }
        )
        if await viewModel.save(dog: dog, request: request, photoData: photoData) {
            onSave?()
            dismiss()
        } else if let savedDog = viewModel.lastSavedDog {
            // A saved profile remains editable if its photo failed; retry must not create another dog.
            dog = savedDog
        }
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
