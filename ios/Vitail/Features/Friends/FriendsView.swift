import SwiftUI

struct FriendsView: View {
    @ObservedObject var store: FriendsStore
    @State private var pendingRemoval: SocialProfile?
    @State private var pendingBlock: SocialProfile?

    var body: some View {
        List {
            if let overview = store.overview {
                requestsSection(overview)
                friendsSection(overview)
                settingsSection
            } else if store.isRefreshing {
                Section { ProgressView("Loading friends…") }
            } else {
                Section {
                    ContentUnavailableView(
                        "Friends unavailable",
                        systemImage: "person.2.slash",
                        description: Text(store.errorMessage ?? "Check your connection and try again.")
                    )
                    Button("Try Again") { Task { await store.refresh() } }
                        .frame(maxWidth: .infinity)
                }
            }

            if store.overview != nil, let error = store.errorMessage {
                Section {
                    Text(error).foregroundStyle(AppColors.error)
                    Button("Try Again") { Task { await store.refresh() } }
                }
            }
            if let notice = store.notice {
                Section { Text(notice).foregroundStyle(AppColors.secondaryText) }
            }
        }
        .buttonStyle(.borderless)
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .navigationTitle("Friends")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    AddFriendsView(store: store)
                } label: {
                    Label("Add friends", systemImage: "person.badge.plus")
                }
                .tint(AppColors.brand)
                .accessibilityIdentifier("friends-add-button")
            }
        }
        .refreshable { await store.refresh() }
        .task { if store.overview == nil { await store.refresh() } }
        .confirmationDialog("Remove friend?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible) {
            if let user = pendingRemoval {
                Button("Remove \(name(user))", role: .destructive) { Task { await store.removeFriend(user) } }
            }
        } message: {
            Text("This also stops location sharing and ends an active Net-Walk with this person.")
        }
        .confirmationDialog("Block this user?", isPresented: Binding(
            get: { pendingBlock != nil }, set: { if !$0 { pendingBlock = nil } }
        ), titleVisibility: .visible) {
            if let user = pendingBlock {
                Button("Block \(name(user))", role: .destructive) { Task { await store.block(user) } }
            }
        } message: {
            Text("Blocking removes the friendship and hides both profiles from each other.")
        }
    }

    @ViewBuilder
    private func requestsSection(_ overview: SocialOverview) -> some View {
        if !overview.incomingRequests.isEmpty {
            Section("Friend requests") {
                ForEach(overview.incomingRequests) { request in
                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        SocialProfileRow(user: request.user)
                        HStack {
                            Button("Accept") { Task { await store.respondToRequest(request, accept: true) } }
                                .buttonStyle(.borderedProminent).tint(AppColors.brand)
                            Button("Decline", role: .destructive) {
                                Task { await store.respondToRequest(request, accept: false) }
                            }
                            .buttonStyle(.bordered)
                        }
                        .disabled(store.isWorking)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        if !overview.outgoingRequests.isEmpty {
            Section("Sent requests") {
                ForEach(overview.outgoingRequests) { request in
                    HStack {
                        SocialProfileRow(user: request.user)
                        Spacer()
                        Button("Cancel") { Task { await store.removeFriend(request.user) } }
                            .disabled(store.isWorking)
                    }
                }
            }
        }
    }

    private func friendsSection(_ overview: SocialOverview) -> some View {
        Section("Friends") {
            if overview.friends.isEmpty {
                ContentUnavailableView(
                    "No friends yet",
                    systemImage: "person.2",
                    description: Text("Use the add button to find someone by name or public ID.")
                )
            }
            ForEach(overview.friends) { friendship in
                HStack(spacing: AppSpacing.small) {
                    SocialProfileRow(user: friendship.user)
                    Spacer()
                    Menu {
                        Button("Remove friend", role: .destructive) { pendingRemoval = friendship.user }
                        Button("Block user", role: .destructive) { pendingBlock = friendship.user }
                    } label: {
                        Label("Options", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(store.isWorking)
                }
            }
        }
    }

    private var settingsSection: some View {
        Section {
            NavigationLink {
                FriendsSettingsView(store: store)
            } label: {
                Label("Privacy & map avatar", systemImage: "slider.horizontal.3")
            }
        } footer: {
            Text("Live people and Net-Walking controls appear on the Walk map.")
        }
    }

    private func name(_ user: SocialProfile) -> String {
        user.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Vitail walker" : user.displayName
    }
}

private struct FriendsSettingsView: View {
    @ObservedObject var store: FriendsStore

    var body: some View {
        Form {
            Section("Map avatar") {
                if let me = store.overview?.me {
                    HStack(spacing: AppSpacing.medium) {
                        SocialAvatarView(user: SocialProfile(
                            publicID: me.publicID,
                            displayName: me.displayName,
                            photoURL: me.photoURL,
                            avatarKey: store.avatarKey
                        ), size: 52)
                        Picker("Appearance", selection: avatarBinding) {
                            ForEach(SocialAvatarOption.allCases) { option in
                                Label(option.title, systemImage: option.systemImage).tag(option.rawValue)
                            }
                        }
                    }
                }
            }
            Section {
                Toggle("Share with friends", isOn: Binding(
                    get: { store.sharesWithFriends },
                    set: { value in
                        Task { await store.updatePreferences(shareWithFriends: value, netMatching: store.netMatchingEnabled) }
                    }
                ))
                Toggle("Find Net-Walking partners", isOn: Binding(
                    get: { store.netMatchingEnabled },
                    set: { value in
                        Task { await store.updatePreferences(shareWithFriends: store.sharesWithFriends, netMatching: value) }
                    }
                ))
            } header: {
                Text("Walk location")
            } footer: {
                Text("Sharing is off by default and runs only while a walk is recording. Nearby discovery uses an approximate position until both walkers accept.")
            }
            if let message = store.preferenceSaveError {
                Section("Save required") {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.error)
                    if let summary = store.preferenceRetrySummary {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Button {
                        Task { await store.retryPreferences() }
                    } label: {
                        if store.isWorking {
                            Label("Saving settings…", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("Retry saving settings", systemImage: "arrow.clockwise")
                        }
                    }
                    .accessibilityIdentifier("friends-settings-retry")
                }
            }
            if let blocked = store.overview?.blockedUsers, !blocked.isEmpty {
                Section("Blocked people") {
                    ForEach(blocked) { user in
                        HStack {
                            SocialProfileRow(user: user)
                            Spacer()
                            Button("Unblock") { Task { await store.unblock(user) } }
                                .disabled(store.isWorking)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .navigationTitle("Friend Settings")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(store.overview == nil || store.isWorking)
    }

    private var avatarBinding: Binding<String> {
        Binding(
            get: { store.avatarKey },
            set: { key in
                Task {
                    await store.updatePreferences(
                        shareWithFriends: store.sharesWithFriends,
                        netMatching: store.netMatchingEnabled,
                        avatarKey: key
                    )
                }
            }
        )
    }
}

private struct AddFriendsView: View {
    @ObservedObject var store: FriendsStore
    @State private var query = ""
    @State private var pendingBlock: SocialProfile?
    @State private var copied = false
    @State private var isDebouncing = false

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if normalizedQuery.count >= 2 {
                Section("Results") {
                    if isDebouncing || store.isSearching {
                        ProgressView("Searching…")
                    } else if store.searchResults.isEmpty && store.errorMessage == nil {
                        ContentUnavailableView.search(text: normalizedQuery)
                    }
                    ForEach(store.searchResults) { user in
                        VStack(alignment: .leading, spacing: AppSpacing.small) {
                            SocialProfileRow(user: user, showsPublicID: true)
                            HStack {
                                if isFriend(user) {
                                    Label("Friend", systemImage: "checkmark")
                                } else if hasPendingRequest(user) {
                                    Text("Request pending").foregroundStyle(AppColors.secondaryText)
                                } else {
                                    Button("Add friend") { Task { await store.sendRequest(user) } }
                                }
                                Spacer()
                                Button("Block", role: .destructive) { pendingBlock = user }
                            }
                            .font(.subheadline)
                            .disabled(store.isWorking)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            identitySection
            if let error = store.errorMessage {
                Section {
                    Text(error).foregroundStyle(AppColors.error)
                    Button("Try Again") { Task { await store.search(query) } }
                }
            }
        }
        .buttonStyle(.borderless)
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .navigationTitle("Add Friends")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Name or public ID")
        .task { if store.overview == nil { await store.refresh() } }
        .task(id: normalizedQuery) {
            await store.search("")
            isDebouncing = normalizedQuery.count >= 2
            if normalizedQuery.count >= 2 {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            }
            isDebouncing = false
            await store.search(normalizedQuery)
        }
        .confirmationDialog("Block this user?", isPresented: Binding(
            get: { pendingBlock != nil }, set: { if !$0 { pendingBlock = nil } }
        ), titleVisibility: .visible) {
            if let user = pendingBlock {
                Button("Block \(name(user))", role: .destructive) { Task { await store.block(user) } }
            }
        } message: { Text("Blocking hides both profiles from each other.") }
    }

    private var identitySection: some View {
        Section("Your public ID") {
            if let me = store.overview?.me {
                Text(me.publicID).font(.footnote.monospaced()).textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = me.publicID
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy public ID", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: "Add me on Vitail using my public ID: \(me.publicID)") {
                    Label("Share my Vitail ID", systemImage: "square.and.arrow.up")
                }
            } else {
                ProgressView("Loading your ID…")
            }
        }
    }

    private func name(_ user: SocialProfile) -> String {
        user.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Vitail walker" : user.displayName
    }
    private func isFriend(_ user: SocialProfile) -> Bool {
        store.overview?.friends.contains { $0.user.id == user.id } == true
    }
    private func hasPendingRequest(_ user: SocialProfile) -> Bool {
        let requests = (store.overview?.incomingRequests ?? []) + (store.overview?.outgoingRequests ?? [])
        return requests.contains { $0.user.id == user.id }
    }
}

struct SocialProfileRow: View {
    let user: SocialProfile
    var showsPublicID = false

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            SocialAvatarView(user: user, size: 42)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName).fontWeight(.medium)
                if showsPublicID {
                    Text(user.publicID).font(.caption.monospaced()).foregroundStyle(AppColors.secondaryText)
                        .lineLimit(1).textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var displayName: String {
        user.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Vitail walker" : user.displayName
    }
}

struct SocialAvatarView: View {
    let user: SocialProfile
    var size: CGFloat = 44

    var body: some View {
        if let option = SocialAvatarOption(rawValue: user.avatarKey ?? ""), option != .photo {
            ZStack {
                AppColors.brand.opacity(0.12)
                Image(systemName: option.systemImage)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(AppColors.brand)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityLabel("\(displayName) avatar")
        } else {
            AvatarView(url: user.photoURL, name: displayName, size: size)
        }
    }

    private var displayName: String {
        user.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Vitail walker" : user.displayName
    }
}
