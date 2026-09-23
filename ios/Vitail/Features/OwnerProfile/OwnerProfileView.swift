import SwiftUI

struct OwnerProfileView: View {
    let user: User
    @ObservedObject var session: SessionStore
    @StateObject private var dogViewModel: DogViewModel
    @State private var isEditingProfile = false
    @State private var isAddingDog = false
    @State private var selectedDog: Dog?

    init(user: User, session: SessionStore, dogService: any DogServicing = DogService()) {
        self.user = user
        self.session = session
        _dogViewModel = StateObject(wrappedValue: DogViewModel(service: dogService))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                profileCard
                DogListView(
                    viewModel: dogViewModel,
                    addDog: { isAddingDog = true },
                    editDog: { selectedDog = $0 }
                )
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
            DogDetailView(viewModel: dogViewModel, dog: dog)
        }
    }

    private var profileCard: some View {
        Button { isEditingProfile = true } label: {
            HStack(spacing: AppSpacing.large) {
                AvatarView(url: user.photo, name: user.displayName, size: 76)
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.displayName).font(.title2.bold())
                        .foregroundStyle(AppColors.primaryText)
                    Text(user.email).font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").foregroundStyle(AppColors.secondaryText)
            }
            .padding(.vertical, AppSpacing.large)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Your profile, \(user.displayName)")
        .accessibilityHint("Edit your photo and account details")
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

    private var currentPhoto: String? {
        if case let .signedIn(currentUser) = session.state { return currentUser.photo }
        return user.photo
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AvatarPhotoPicker(url: currentPhoto, name: user.displayName, photoData: $viewModel.photoData)
                        .padding(.vertical, AppSpacing.medium)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                Section("Profile") {
                    TextField("Display name", text: $viewModel.displayName)
                        .textContentType(.name)
                    LabeledContent("Email", value: user.email)
                        .foregroundStyle(AppColors.secondaryText)
                }
                .listRowBackground(AppColors.surface)
                AppearanceSettingsSection()
                Section {
                    Button("Log Out", role: .destructive) {
                        Task { await session.logout(); dismiss() }
                    }
                    .foregroundStyle(AppColors.error)
                }
                .listRowBackground(AppColors.surface)
                if let message = viewModel.errorMessage {
                    Section { Text(message).foregroundStyle(AppColors.error) }
                        .listRowBackground(AppColors.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.background)
            .navigationTitle("Your Profile")
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
            .interactiveDismissDisabled(viewModel.isSaving)
        }
    }
}
