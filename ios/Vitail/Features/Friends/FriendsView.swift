import SwiftUI

struct FriendsView: View {
    @ObservedObject var store: FriendsStore
    @ObservedObject var session: SessionStore
    @State private var pendingRemoval: SocialProfile?
    @State private var pendingBlock: SocialProfile?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let profile = store.overview?.me.profile { myProfileSection(profile) }
                if store.overview != nil { visibilityCard }
                NavigationLink {
                    StatisticsView(ownerID: store.ownerID, session: session)
                } label: {
                    linkRow(title: "Statistics & leaderboard", subtitle: "Your walks and how friends compare",
                            systemImage: "chart.bar.xaxis", fill: AppColors.honey)
                        .vitailCard(padding: 14)
                }
                .buttonStyle(.plain)
                .padding(.trailing, AppStroke.shadow)
                .accessibilityIdentifier("friends-statistics-link")
                if let overview = store.overview {
                    friendsSection(overview)
                    settingsSection
                } else if store.isRefreshing {
                    ProgressView("Loading friends…")
                        .font(AppFont.body(15))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.large)
                } else {
                    VStack(spacing: AppSpacing.medium) {
                        ContentUnavailableView {
                            Label("Friends unavailable", systemImage: "person.2.slash")
                                .font(AppFont.heading(20, .semibold, relativeTo: .title3))
                        } description: {
                            Text(store.errorMessage ?? "Check your connection and try again.")
                                .font(AppFont.body(15))
                        }
                        SecondaryButton(title: "Try Again") { Task { await store.refresh() } }
                    }
                    .vitailInset()
                }

                if store.overview != nil, let error = store.errorMessage {
                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        Text(error).font(AppFont.body(14)).foregroundStyle(AppColors.error)
                        SecondaryButton(title: "Try Again") { Task { await store.refresh() } }
                    }
                    .vitailInset()
                }
                if let notice = store.notice {
                    Text(notice).font(AppFont.body(14)).foregroundStyle(AppColors.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .vitailInset()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, AppSpacing.medium)
        }
        .scrollContentBackground(.hidden)
        .background { VitailScreenBackground() }
        .navigationTitle("Friends")
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

    private func myProfileSection(_ me: SocialProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                MapAppearanceEditor(store: store)
            } label: {
                HStack(spacing: AppSpacing.medium) {
                    SocialAvatarView(user: me, size: 60)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name(me)).font(AppFont.heading(18, .bold)).foregroundStyle(AppColors.primaryText)
                        Text("Edit your map appearance")
                            .font(AppFont.body(13, .semibold, relativeTo: .subheadline)).foregroundStyle(AppColors.brand)
                        if me.avatarKey == SocialAvatarOption.dog.rawValue {
                            Text(me.dogAvatarBreed.title)
                                .font(AppFont.body(12, relativeTo: .caption)).foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("friends-my-map-profile")
            DogBandanaGuidanceView(user: me)
            Text("This is the appearance other walkers see. Changing it does not turn on location sharing.")
                .font(AppFont.body(12, relativeTo: .caption)).foregroundStyle(AppColors.secondaryText)
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vitailCardBackground()
        .padding(.trailing, AppStroke.shadow)
    }

    /// Prototype "Visible to friends" card, wired to the existing sharing preference.
    private var visibilityCard: some View {
        VStack(spacing: 12) {
            toggleRow(title: "Visible to friends", subtitle: "Friends see your dog on their map while you walk",
                      systemImage: "eye", fill: AppColors.sky,
                      isOn: Binding(get: { store.sharesWithFriends }, set: { value in
                          Task { await store.updatePreferences(shareWithFriends: value, netMatching: store.netMatchingEnabled) }
                      }))
            Rectangle().fill(AppColors.border).frame(height: 1.5)
            toggleRow(title: "Find Net-Walking partners", subtitle: "Match with walkers nearby",
                      systemImage: "person.2", fill: AppColors.sage,
                      isOn: Binding(get: { store.netMatchingEnabled }, set: { value in
                          Task { await store.updatePreferences(shareWithFriends: store.sharesWithFriends, netMatching: value) }
                      }))
        }
        .disabled(store.isWorking)
        .vitailCard(padding: 14)
        .padding(.trailing, AppStroke.shadow)
    }

    private func toggleRow(title: String, subtitle: String, systemImage: String, fill: Color,
                           isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                VitailIconTile(systemImage: systemImage, fill: fill, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AppFont.heading(15, .semibold)).foregroundStyle(AppColors.primaryText)
                    Text(subtitle).font(AppFont.body(12, relativeTo: .caption)).foregroundStyle(AppColors.secondaryText)
                }
            }
        }
        .tint(AppColors.sage)
    }

    private func linkRow(title: String, subtitle: String?, systemImage: String, fill: Color) -> some View {
        HStack(spacing: 12) {
            VitailIconTile(systemImage: systemImage, fill: fill, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AppFont.heading(15, .semibold)).foregroundStyle(AppColors.primaryText)
                if let subtitle {
                    Text(subtitle).font(AppFont.body(12, relativeTo: .caption)).foregroundStyle(AppColors.secondaryText)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(overview.friends.isEmpty ? "Friends" : "Friends · \(overview.friends.count)")
                    .font(AppFont.heading(22, .bold, relativeTo: .title3))
                Spacer()
                NavigationLink {
                    AddFriendsView(store: store)
                } label: {
                    let hasRequests = !overview.incomingRequests.isEmpty
                    Label("Add", systemImage: "plus")
                        .font(AppFont.heading(15, .semibold))
                        .foregroundStyle(AppColors.brand)
                        .frame(minHeight: 44)
                        .overlay(alignment: .topTrailing) {
                            if hasRequests {
                                Circle().fill(AppColors.error).frame(width: 8, height: 8).offset(x: 6, y: 8)
                            }
                        }
                        .accessibilityLabel(hasRequests ? "Add friends, new friend requests" : "Add friends")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("friends-add-button")
            }
            .padding(.bottom, 8)
            if overview.friends.isEmpty {
                ContentUnavailableView {
                    Label("No friends yet", systemImage: "person.2")
                        .font(AppFont.heading(20, .semibold, relativeTo: .title3))
                } description: {
                    Text("Use the add button to find someone by name or public ID.").font(AppFont.body(15))
                }
                .vitailInset()
            }
            ForEach(overview.friends) { friendship in
                HStack(spacing: AppSpacing.small) {
                    NavigationLink {
                        FriendProfileView(initialUser: friendship.user, store: store)
                    } label: {
                        HStack(spacing: 12) {
                            SocialAvatarView(user: friendship.user, size: 44)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name(friendship.user)).font(AppFont.heading(16, .semibold))
                                    .foregroundStyle(AppColors.primaryText)
                                if let status = walkingStatus(friendship.user) {
                                    Label(status, systemImage: "circle.fill")
                                        .labelStyle(WalkingStatusLabelStyle())
                                        .font(AppFont.body(12, relativeTo: .caption))
                                        .foregroundStyle(AppColors.secondaryText)
                                } else if let dog = friendship.user.dog {
                                    Text(dog.breedName).font(AppFont.body(12, relativeTo: .caption))
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                    }
                    .buttonStyle(.plain)
                    Menu {
                        Button("Remove friend", role: .destructive) { pendingRemoval = friendship.user }
                        Button("Block user", role: .destructive) { pendingBlock = friendship.user }
                    } label: {
                        Label("Options", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .disabled(store.isWorking)
                }
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(AppColors.border).frame(height: 1.5)
                }
            }
        }
    }

    private func walkingStatus(_ user: SocialProfile) -> String? {
        guard let peer = store.mapSnapshot.friends.first(where: { $0.user.publicID == user.publicID }) else { return nil }
        guard let meters = peer.distanceM else { return "Walking now" }
        let distance = meters < 1000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1000)
        return "Walking now · \(distance) away"
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                FriendsSettingsView(store: store)
            } label: {
                linkRow(title: "Privacy & blocked people", subtitle: nil,
                        systemImage: "slider.horizontal.3", fill: AppColors.inset)
                    .vitailCard(padding: 14)
            }
            .buttonStyle(.plain)
            .padding(.trailing, AppStroke.shadow)
            Text("Live people and Net-Walking controls appear on the Walk map.")
                .font(AppFont.body(12, relativeTo: .caption)).foregroundStyle(AppColors.secondaryText)
                .padding(.horizontal, 4)
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
            FriendRequestSections(store: store)
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
        .refreshable { await store.refresh() }
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

/// Small sage dot in front of "Walking now".
private struct WalkingStatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(AppColors.success)
            configuration.title
        }
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
                Text(displayName).font(AppFont.heading(16, .semibold))
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
        if user.avatarKey == SocialAvatarOption.dog.rawValue {
            DogMapAvatarView(breed: user.dogAvatarBreed, bandanaColor: user.bandanaColor, outfit: user.avatarOutfit)
                .padding(2)
                .frame(width: size, height: size)
                .background(AvatarView.accent(for: displayName).opacity(0.35), in: Circle())
                .overlay(Circle().strokeBorder(AppColors.outline, lineWidth: AppStroke.width))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(displayName), \(user.dogAvatarBreed.title), \(user.bandanaColor.guidance ?? "no bandana, no designation")")
        } else if let option = SocialAvatarOption(rawValue: user.avatarKey ?? ""), option != .photo {
            ZStack {
                AvatarView.accent(for: displayName)
                Image(systemName: option.systemImage)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(AppColors.onAccent)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(AppColors.outline, lineWidth: AppStroke.width))
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

struct DogBandanaGuidanceView: View {
    let user: SocialProfile

    var body: some View {
        if user.avatarKey == SocialAvatarOption.dog.rawValue,
           let guidance = user.bandanaColor.guidance {
            Label {
                Text(guidance)
            } icon: {
                Image(systemName: "triangle.fill")
                    .foregroundStyle(user.bandanaColor.avatarColor)
            }
            .font(.subheadline)
            .accessibilityIdentifier("friend-bandana-guidance")
        }
    }
}

struct PublicDogDetailsView: View {
    let user: SocialProfile
    var body: some View {
        Section {
            if let dog = user.dog {
                LabeledContent("Name", value: dog.name)
                LabeledContent("Breed", value: dog.breedName)
                LabeledContent("Age", value: dog.ageDescription)
                LabeledContent("Size", value: dog.size.capitalized)
            } else {
                Text("This walker hasn't shared a dog profile.")
                    .font(.subheadline).foregroundStyle(AppColors.secondaryText)
            }
            DogBandanaGuidanceView(user: user)
            if user.bandanaColor == .none {
                Text("No bandana · no designation")
                    .font(.subheadline).foregroundStyle(AppColors.secondaryText)
            }
        } header: {
            Text("Dog profile")
        } footer: {
            Text("Shared by the owner, not a confirmed list of dogs on this walk. Icon faces are decorative; bandanas are owner-selected handling guidance. Ask before approaching.")
        }
        .accessibilityIdentifier("friend-public-dog-details")
    }
}

private struct FriendRequestSections: View {
    @ObservedObject var store: FriendsStore
    var body: some View {
        if let overview = store.overview {
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
                                }.buttonStyle(.bordered)
                            }.disabled(store.isWorking)
                        }.padding(.vertical, 4)
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
    }
}

private struct FriendProfileView: View {
    let initialUser: SocialProfile
    @ObservedObject var store: FriendsStore
    private var user: SocialProfile? {
        store.overview?.friends.first { $0.user.id == initialUser.id }?.user
    }

    var body: some View {
        List {
            if let user {
            Section {
                HStack(spacing: AppSpacing.medium) {
                    SocialAvatarView(user: user, size: 72)
                    Text(user.displayName.isEmpty ? "Vitail walker" : user.displayName)
                        .font(.title3.bold())
                }
                if user.avatarKey == SocialAvatarOption.dog.rawValue {
                    LabeledContent("Map icon", value: user.dogAvatarBreed.title)
                    DogBandanaGuidanceView(user: user)
                    if user.bandanaColor == .none {
                        Text("No bandana · no designation")
                            .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                    }
                }
            } footer: {
                Text("Bandana meanings are chosen by the walker. Always ask before approaching their dog.")
            }
            Section("Public ID") {
                Text(user.publicID).font(.footnote.monospaced()).textSelection(.enabled)
            }
            PublicDogDetailsView(user: user)
            } else {
                ContentUnavailableView("Friend unavailable", systemImage: "person.2.slash",
                                       description: Text("This profile is no longer in your friends list."))
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .navigationTitle("Friend Profile")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MapAppearanceEditor: View {
    @ObservedObject var store: FriendsStore
    @Environment(\.dismiss) private var dismiss
    @State private var avatarKey: String
    @State private var breed: DogMapBreed
    @State private var bandanaColor: DogBandanaColor
    @State private var publicDogID: Int?
    @StateObject private var shop: AvatarShopStore
    private let initialPublicDogID: Int?
    @State private var isSaving = false
    @State private var lastAttempt: AppearanceDraft?

    private struct AppearanceDraft: Equatable {
        let avatarKey: String
        let breed: DogMapBreed
        let bandanaColor: DogBandanaColor
        let publicDogID: Int?
    }

    init(store: FriendsStore) {
        self.store = store
        initialPublicDogID = store.publicDogSelection.dogID
        _avatarKey = State(initialValue: store.avatarKey)
        _breed = State(initialValue: store.dogAvatarBreed)
        _bandanaColor = State(initialValue: store.bandanaColor)
        _publicDogID = State(initialValue: store.publicDogSelection.dogID)
        _shop = StateObject(wrappedValue: store.makeAvatarShopStore())
    }

    private var draft: AppearanceDraft {
        AppearanceDraft(avatarKey: avatarKey, breed: breed, bandanaColor: bandanaColor, publicDogID: publicDogID)
    }

    private var preview: SocialProfile? {
        guard let me = store.overview?.me else { return nil }
        return SocialProfile(
            publicID: me.publicID, displayName: me.displayName,
            photoURL: me.photoURL, avatarKey: avatarKey,
            dogAvatarBreed: breed, bandanaColor: bandanaColor,
            dog: store.publicDogOptions.first { $0.id == publicDogID }.map(PublicDogProfile.init)
                ?? (publicDogID == me.publicDogID ? me.dog : nil),
            avatarOutfit: shop.snapshot?.outfit ?? me.avatarOutfit
        )
    }

    var body: some View {
        Form {
            if let preview {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: AppSpacing.small) {
                            SocialAvatarView(user: preview, size: 104)
                            Text(preview.displayName.isEmpty ? "Vitail walker" : preview.displayName)
                                .font(.headline)
                            DogBandanaGuidanceView(user: preview)
                        }
                        Spacer()
                    }
                    .padding(.vertical, AppSpacing.small)
                } footer: {
                    Text("Preview only. Tap Save to share this appearance across your devices and with other walkers.")
                }
            }
            Section("Appearance") {
                Picker("Map avatar", selection: $avatarKey) {
                    ForEach(SocialAvatarOption.allCases) { option in
                        Label(option.title, systemImage: option.systemImage).tag(option.rawValue)
                    }
                }
                .accessibilityIdentifier("friends-avatar-kind")
            }
            Section {
                if store.isLoadingPublicDogs { ProgressView("Loading your dogs…") }
                Picker("Public dog", selection: $publicDogID) {
                    Text("Do not share a dog profile").tag(Int?.none)
                    ForEach(store.publicDogOptions) { dog in
                        Text("\(dog.name) · \(dog.breed.name)").tag(Optional(dog.id))
                    }
                    if let id = publicDogID, !store.publicDogOptions.contains(where: { $0.id == id }) {
                        Text(store.overview?.me.dog?.name ?? "Previously selected dog").tag(Optional(id))
                    }
                }
                .disabled(store.isLoadingPublicDogs || store.publicDogLoadError != nil)
                .accessibilityIdentifier("friends-public-dog-picker")
                if let error = store.publicDogLoadError {
                    Text(error).foregroundStyle(AppColors.error)
                    Button("Reload dogs") { Task { await store.loadPublicDogs() } }
                }
                if let dog = preview?.dog {
                    LabeledContent("Name", value: dog.name)
                    LabeledContent("Breed", value: dog.breedName)
                    LabeledContent("Age", value: dog.ageDescription)
                    LabeledContent("Size", value: dog.size.capitalized)
                }
            } header: {
                Text("Choose a public dog profile")
            } footer: {
                Text("Optional. Saving shares only this dog's name, breed, age and size in your social profile, including search and map details. It does not publish your other dogs, exact birthday, chip or documents, or confirm this dog is on the current walk. Choose no dog to hide these details.")
            }
            if let preview {
                Section {
                    NavigationLink {
                        MapClothingShopView(store: shop, profile: preview)
                    } label: {
                        Label("Clothing shop", systemImage: "cart")
                    }
                    .accessibilityIdentifier("friends-clothing-shop-link")
                } footer: {
                    Text("Buy outfits with real account pt. Purchases and worn clothing sync across your devices and other walkers; outfit changes save separately from the profile above.")
                }
            }
            if avatarKey == SocialAvatarOption.dog.rawValue {
                Section("Choose a face") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88))], spacing: AppSpacing.small) {
                        ForEach(DogMapBreed.allCases, id: \.self) { option in
                            Button {
                                breed = option
                            } label: {
                                VStack(spacing: 4) {
                                    DogMapAvatarView(breed: option, bandanaColor: bandanaColor)
                                        .frame(width: 58, height: 58)
                                    Text(option.title).font(.caption).multilineTextAlignment(.center)
                                        .foregroundStyle(AppColors.primaryText)
                                    if option.isEasterEgg {
                                        Text("Easter egg").font(.caption2).foregroundStyle(AppColors.secondaryText)
                                    }
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, minHeight: 104)
                                .background(breed == option ? AppColors.brand.opacity(0.14) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: AppRadius.card))
                                .overlay {
                                    RoundedRectangle(cornerRadius: AppRadius.card)
                                        .stroke(breed == option ? AppColors.brand : Color.clear, lineWidth: 2)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.title)
                            .accessibilityAddTraits(breed == option ? .isSelected : [])
                        }
                    }
                }
                Section {
                    ForEach(DogBandanaColor.allCases, id: \.self) { color in
                        Button {
                            bandanaColor = color
                        } label: {
                            HStack(spacing: AppSpacing.small) {
                                Image(systemName: color == .none ? "triangle" : "triangle.fill")
                                    .foregroundStyle(color == .none ? AppColors.secondaryText : color.avatarColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(color.title).foregroundStyle(AppColors.primaryText)
                                    Text(color.guidance ?? "No designation")
                                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                                }
                                Spacer()
                                if bandanaColor == color {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AppColors.brand)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(bandanaColor == color ? .isSelected : [])
                    }
                } header: {
                    Text("Bandana meaning")
                } footer: {
                    Text("Choose the message you want other walkers to see. No bandana does not imply that your dog is friendly.")
                }
            }
            if lastAttempt != nil, let message = store.preferenceSaveError {
                Section("Not saved") {
                    Text(message).foregroundStyle(AppColors.error)
                    Text("Your selection stays here until it is saved successfully.")
                        .font(.footnote).foregroundStyle(AppColors.secondaryText)
                    if lastAttempt == draft {
                        Button("Retry saving appearance") {
                            Task { await save(retrying: true) }
                        }
                        .accessibilityIdentifier("friends-profile-retry")
                    }
                }
            }
        }
        .disabled(isSaving || store.isWorking || store.overview == nil)
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .navigationTitle("My Map Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isSaving)
        .interactiveDismissDisabled(isSaving)
        .task { await store.loadPublicDogs() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save(retrying: false) }
                } label: {
                    if isSaving { ProgressView() } else { Text("Save") }
                }
                .disabled(isSaving || store.isWorking || store.overview == nil)
                .accessibilityIdentifier("friends-profile-save")
            }
        }
    }

    @MainActor
    private func save(retrying: Bool) async {
        guard !isSaving, !store.isWorking else { return }
        isSaving = true
        if retrying {
            await store.retryPreferences()
        } else {
            lastAttempt = draft
            await store.updateAppearance(
                avatarKey: avatarKey,
                dogAvatarBreed: breed,
                bandanaColor: bandanaColor,
                publicDogSelection: publicDogID == initialPublicDogID ? nil
                    : publicDogID.map { .selected($0) } ?? .hidden
            )
        }
        isSaving = false
        if store.preferenceSaveError == nil { dismiss() }
    }
}
