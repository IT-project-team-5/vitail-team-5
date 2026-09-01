import SwiftUI

struct OwnerProfileView: View {
    let user: User
    @ObservedObject var session: SessionStore
    @StateObject private var dogViewModel = DogViewModel()
    @State private var isEditingProfile = false
    @State private var isAddingDog = false
    @State private var selectedDog: Dog?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                profileCard
                Divider()
                DogListView(
                    viewModel: dogViewModel,
                    addDog: { isAddingDog = true },
                    editDog: { selectedDog = $0 }
                )
                Divider()
                Button("Log Out", role: .destructive) {
                    Task { await session.logout() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(AppSpacing.large)
        }
        .task { await dogViewModel.load() }
        .refreshable { await dogViewModel.load() }
        .sheet(isPresented: $isEditingProfile) {
            EditOwnerProfileView(user: user, session: session)
        }
        .sheet(isPresented: $isAddingDog) {
            DogFormView(viewModel: dogViewModel)
        }
        .sheet(item: $selectedDog) { dog in
            DogFormView(viewModel: dogViewModel, dog: dog)
        }
    }

    private var profileCard: some View {
        VStack(spacing: AppSpacing.medium) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(AppColors.brand)
                .accessibilityLabel("Default profile avatar")
            VStack(spacing: 4) {
                Text(user.displayName)
                    .font(.title2.bold())
                Text(user.email)
                    .foregroundStyle(AppColors.secondaryText)
            }
            Button("Edit Profile") { isEditingProfile = true }
                .fontWeight(.semibold)
                .foregroundStyle(AppColors.brand)
        }
        .padding(AppSpacing.large)
        .frame(maxWidth: .infinity)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }
}

private struct EditOwnerProfileView: View {
    let user: User
    @ObservedObject var session: SessionStore
    @StateObject private var viewModel: OwnerProfileViewModel
    @Environment(\.dismiss) private var dismiss

    init(user: User, session: SessionStore) {
        self.user = user
        self.session = session
        _viewModel = StateObject(wrappedValue: OwnerProfileViewModel(user: user))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Display name", text: $viewModel.displayName)
                        .textContentType(.name)
                    LabeledContent("Email", value: user.email)
                        .foregroundStyle(AppColors.secondaryText)
                }
                if let message = viewModel.errorMessage {
                    Section { Text(message).foregroundStyle(AppColors.error) }
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await viewModel.save(using: session) { dismiss() }
                        }
                    }
                    .disabled(!viewModel.canSave || viewModel.isSaving)
                }
            }
            .disabled(viewModel.isSaving)
        }
    }
}
