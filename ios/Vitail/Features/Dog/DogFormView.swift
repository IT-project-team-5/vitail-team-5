import SwiftUI

struct DogFormView: View {
    @ObservedObject var viewModel: DogViewModel
    let dog: Dog?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var breedID: Int?
    @State private var years: String
    @State private var months: String
    @State private var size: DogSize
    @State private var isBrachycephalic: Bool
    @State private var validationMessage: String?

    init(viewModel: DogViewModel, dog: Dog? = nil) {
        self.viewModel = viewModel
        self.dog = dog
        _name = State(initialValue: dog?.name ?? "")
        _breedID = State(initialValue: dog?.breed.id)
        _years = State(initialValue: dog.map { String($0.ageMonths / 12) } ?? "0")
        _months = State(initialValue: dog.map { String($0.ageMonths % 12) } ?? "0")
        _size = State(initialValue: dog?.size ?? .medium)
        _isBrachycephalic = State(initialValue: dog?.isBrachycephalic ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Dog details") {
                    TextField("Name", text: $name)
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

                Section("Age") {
                    TextField("Years", text: $years)
                        .keyboardType(.numberPad)
                    TextField("Months (0–11)", text: $months)
                        .keyboardType(.numberPad)
                }

                if let message = validationMessage ?? viewModel.errorMessage {
                    Section { Text(message).foregroundStyle(AppColors.error) }
                }
            }
            .navigationTitle(dog == nil ? "Add Dog" : "Edit Dog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(viewModel.isSaving)
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
            let yearValue = Int(years), yearValue >= 0,
            let monthValue = Int(months), (0...11).contains(monthValue)
        else {
            validationMessage = "Enter a valid age using non-negative years and 0–11 months."
            return
        }
        let (yearMonths, yearOverflow) = yearValue.multipliedReportingOverflow(by: 12)
        let (ageMonths, ageOverflow) = yearMonths.addingReportingOverflow(monthValue)
        guard !yearOverflow, !ageOverflow else {
            validationMessage = "Enter a valid age."
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
        if await viewModel.save(dog: dog, request: request) { dismiss() }
    }
}
