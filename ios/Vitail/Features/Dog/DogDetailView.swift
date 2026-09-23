import SwiftUI

struct DogDetailView: View {
    @ObservedObject var viewModel: DogViewModel
    let dog: Dog
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
                        LabeledContent("Age", value: currentDog.ageDescription)
                        LabeledContent("Size", value: currentDog.size.label)
                        if currentDog.isBrachycephalic {
                            LabeledContent("Brachycephalic", value: "Yes")
                        }
                    }
                    .padding(AppSpacing.large)
                    .background(AppColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
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
