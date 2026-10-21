import SwiftUI

struct OwnerProfileView: View {
    let user: User
    @ObservedObject var session: SessionStore
    @StateObject private var dogViewModel: DogViewModel
    @State private var isEditingProfile = false
    @State private var isAddingDog = false
    @State private var selectedDog: Dog?
    let documentService: any DocumentServing
    let onDocumentsChanged: () async -> Void
    let onGoalsChanged: () async -> Void
    let dogService: any DogServicing

    init(user: User, session: SessionStore, dogService: any DogServicing = DogService(),
         documentService: any DocumentServing = DocumentService(), onDocumentsChanged: @escaping () async -> Void = {},
         onGoalsChanged: @escaping () async -> Void = {}) {
        self.documentService = documentService
        self.onDocumentsChanged = onDocumentsChanged
        self.onGoalsChanged = onGoalsChanged
        self.dogService = dogService
        self.user = user
        self.session = session
        _dogViewModel = StateObject(wrappedValue: DogViewModel(service: dogService, session: session))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                profileCard
                DogListView(
                    viewModel: dogViewModel,
                    addDog: { isAddingDog = true },
                    editDog: { selectedDog = $0 }
                )
                settingsCard
            }
            .padding(.horizontal, 20)
            .padding(.vertical, AppSpacing.medium)
        }
        .background { VitailScreenBackground(layout: .leadingDog) }
        .task { await dogViewModel.load() }
        .refreshable { await dogViewModel.load() }
        .sheet(isPresented: $isEditingProfile) {
            EditOwnerProfileView(user: user, session: session)
        }
        .sheet(isPresented: $isAddingDog) {
            DogFormView(viewModel: dogViewModel)
        }
        .sheet(item: $selectedDog) { dog in
            DogDetailView(viewModel: dogViewModel, dog: dog, documentService: documentService, session: session,
                          onDocumentsChanged: onDocumentsChanged, onGoalsChanged: onGoalsChanged, goalService: dogService)
        }
    }

    private var profileCard: some View {
        Button { isEditingProfile = true } label: {
            HStack(spacing: 14) {
                AvatarView(url: user.photo, name: user.displayName, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.displayName).font(AppFont.heading(20, .bold, relativeTo: .title3))
                        .foregroundStyle(AppColors.primaryText)
                    Text(user.email).font(AppFont.body(13, relativeTo: .subheadline))
                        .foregroundStyle(AppColors.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
            }
            .padding(AppSpacing.medium)
            .vitailCardBackground()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, AppStroke.shadow)
        .accessibilityLabel("Your profile, \(user.displayName)")
        .accessibilityHint("Edit your photo and account details")
    }

    /// Prototype "Settings" row. Opens the same profile sheet, which holds
    /// appearance and sign out.
    private var settingsCard: some View {
        Button { isEditingProfile = true } label: {
            HStack(spacing: 12) {
                VitailIconTile(systemImage: "gearshape", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings").font(AppFont.heading(15, .semibold)).foregroundStyle(AppColors.primaryText)
                    Text("Appearance, profile and sign out").font(AppFont.body(12, relativeTo: .caption))
                        .foregroundStyle(AppColors.secondaryText)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
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
