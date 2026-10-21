import SwiftUI

struct DogListView: View {
    @ObservedObject var viewModel: DogViewModel
    let addDog: () -> Void
    let editDog: (Dog) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text("My Dogs")
                .font(AppFont.heading(20, .bold, relativeTo: .title3))

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
                        .font(AppFont.heading(16, .semibold))
                    Text("Add your first dog to start building their profile.")
                        .font(AppFont.body(14))
                        .foregroundStyle(AppColors.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .vitailInset()
            } else {
                ForEach(viewModel.dogs) { dog in
                    Button { editDog(dog) } label: {
                        HStack(spacing: AppSpacing.medium) {
                            AvatarView(url: dog.photo, name: dog.name, systemImage: "dog.fill", size: 52)
                            Text(dog.name)
                                .font(AppFont.heading(17, .semibold))
                                .foregroundStyle(AppColors.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        .padding(14)
                        .vitailCardBackground()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, AppStroke.shadow)
                }
            }

            if viewModel.canAddDog {
                Button(action: addDog) {
                    Label(viewModel.dogs.isEmpty ? "Add your first dog" : "Add Dog", systemImage: "plus")
                        .font(AppFont.heading(16, .semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.brand)
            } else {
                Text("Your account supports up to two dogs.")
                    .font(AppFont.body(12, relativeTo: .footnote))
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }
}
