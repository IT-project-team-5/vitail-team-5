import SwiftUI

struct DogFormView: View {
    @ObservedObject var viewModel: DogViewModel
    @State private var dog: Dog?
    private let onSave: (() -> Void)?
    @State private var photoData: Data?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var breedID: Int?
    @State private var years: String
    @State private var months: Int
    @State private var size: DogSize
    @State private var isBrachycephalic: Bool
    @State private var validationMessage: String?
    @State private var isConfirmingDelete = false

    init(viewModel: DogViewModel, dog: Dog? = nil, onSave: (() -> Void)? = nil) {
        self.viewModel = viewModel
        _dog = State(initialValue: dog)
        self.onSave = onSave
        let age = DogAgeInput.formValues(forAgeMonths: dog?.ageMonths ?? 1)
        _name = State(initialValue: dog?.name ?? "")
        _breedID = State(initialValue: dog?.breed.id)
        _years = State(initialValue: dog == nil ? "" : String(age.years))
        _months = State(initialValue: age.months)
        _size = State(initialValue: dog?.size ?? .medium)
        _isBrachycephalic = State(initialValue: dog?.isBrachycephalic ?? false)
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
                }
                .listRowBackground(AppColors.surface)

                Section("Age") {
                    TextField("Years", text: $years, prompt: Text("Years").foregroundStyle(AppColors.secondaryText))
                        .keyboardType(.numberPad)
                    Picker("Months", selection: $months) {
                        ForEach(DogAgeInput.monthOptions, id: \.self) { month in
                            Text("\(month)").tag(month)
                        }
                    }
                    .pickerStyle(.menu)
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
        guard
            let yearValue = Int(years),
            let ageMonths = DogAgeInput.totalMonths(years: yearValue, months: months)
        else {
            validationMessage = "Enter a valid non-negative number of years."
            return
        }

        validationMessage = nil
        let request = DogWriteRequest(
            name: trimmedName,
            breedID: breedID,
            ageMonths: ageMonths,
            size: size,
            isBrachycephalic: isBrachycephalic
        )
        if await viewModel.save(dog: dog, request: request, photoData: photoData) {
            onSave?()
            dismiss()
        } else if let savedDog = viewModel.lastSavedDog {
            // A saved profile remains editable if its photo failed; retry must not create another dog.
            dog = savedDog
        }
    }

    private func deleteDog() async {
        guard let dog else { return }
        if await viewModel.delete(dog) { dismiss() }
    }
}
