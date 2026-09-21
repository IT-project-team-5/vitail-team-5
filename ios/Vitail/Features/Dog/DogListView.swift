import SwiftUI

struct DogListView: View {
    @ObservedObject var viewModel: DogViewModel
    let addDog: () -> Void
    let editDog: (Dog) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text("My Dogs")
                .font(.title2.bold())

            if viewModel.isLoading && viewModel.dogs.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding()
            } else if let message = viewModel.errorMessage, viewModel.dogs.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(AppColors.error)
                    Button("Try Again") { Task { await viewModel.load() } }
                }
            } else if viewModel.dogs.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    Text("No dogs yet")
                        .font(.headline)
                    Text("Add your first dog to start building their profile.")
                        .foregroundStyle(AppColors.secondaryText)
                }
                .padding(AppSpacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
            } else {
                ForEach(viewModel.dogs) { dog in
                    Button { editDog(dog) } label: {
                        HStack(spacing: AppSpacing.medium) {
                            Image(systemName: "dog.fill")
                                .font(.title2)
                                .foregroundStyle(AppColors.brand)
                                .frame(width: 48, height: 48)
                                .background(AppColors.brand.opacity(0.12))
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(dog.name).font(.headline)
                                Text(dog.breed.name)
                                Text("\(dog.ageDescription) · \(dog.size.label)")
                            }
                            .foregroundStyle(AppColors.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        .padding(AppSpacing.medium)
                        .background(AppColors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
                    }
                    .buttonStyle(.plain)
                }
            }

            if viewModel.canAddDog {
                Button(action: addDog) {
                    Label(viewModel.dogs.isEmpty ? "Add your first dog" : "Add Dog", systemImage: "plus")
                        .fontWeight(.semibold)
                }
                .foregroundStyle(AppColors.brand)
            } else {
                Text("You have reached the maximum of 10 dogs.")
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }
}
