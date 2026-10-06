import MapKit
import SwiftUI

struct FriendsView: View {
    @ObservedObject var store: FriendsStore
    @State private var query = ""
    @State private var pendingRemoval: SocialProfile?
    @State private var pendingBlock: SocialProfile?

    var body: some View {
        List {
            if let error = store.errorMessage {
                Section {
                    Text(error).foregroundStyle(AppColors.error)
                    Button("Try Again") { Task { await store.refresh() } }
                }
            }
            if let notice = store.notice { Text(notice).foregroundStyle(AppColors.secondaryText) }
            identitySection
            privacySection
            searchSection
            requestsSection
            friendsSection
            netWalkingSection
            mapSection
            blockedSection
        }
        .buttonStyle(.borderless)
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .navigationTitle("Friends")
        .refreshable { await store.refresh() }
        .task { await store.refresh() }
        .task(id: query) {
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            await store.search(query)
        }
        .overlay {
            if store.overview == nil && store.isRefreshing { ProgressView("Loading friends…") }
        }
        .confirmationDialog("Remove friend?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible) {
            if let user = pendingRemoval {
                Button("Remove \(name(user))", role: .destructive) { Task { await store.removeFriend(user) } }
            }
        } message: { Text("Removing this friend stops friend location sharing and ends any Net-Walking pairing with them.") }
        .confirmationDialog("Block this user?", isPresented: Binding(
            get: { pendingBlock != nil }, set: { if !$0 { pendingBlock = nil } }
        ), titleVisibility: .visible) {
            if let user = pendingBlock {
                Button("Block \(name(user))", role: .destructive) { Task { await store.block(user) } }
            }
        } message: { Text("Blocking removes the friendship, ends Net-Walking and hides your profiles from each other.") }
    }

    private var identitySection: some View {
        Section("Your public ID") {
            if let me = store.overview?.me {
                Text(me.publicID).font(.footnote.monospaced()).textSelection(.enabled)
                Button("Copy public ID") { UIPasteboard.general.string = me.publicID }
                ShareLink(item: "Add me on Vitail using my public ID: \(me.publicID)") {
                    Label("Share my Vitail ID", systemImage: "square.and.arrow.up")
                }
            } else { Text("Your ID will appear when connected.").foregroundStyle(AppColors.secondaryText) }
        }
    }

    private var privacySection: some View {
        Section {
            Toggle("Share walk location with friends", isOn: Binding(
                get: { store.sharesWithFriends },
                set: { value in Task { await store.updatePreferences(shareWithFriends: value, netMatching: store.netMatchingEnabled) } }
            ))
            Toggle("Find Net-Walking partners", isOn: Binding(
                get: { store.netMatchingEnabled },
                set: { value in Task { await store.updatePreferences(shareWithFriends: store.sharesWithFriends, netMatching: value) } }
            ))
        } header: { Text("Location privacy") } footer: {
            Text("Both options are off by default. Location is shared only while recording a walk. Friends see your current walk location; other consenting walkers see an approximate nearby position. An accepted Net-Walking partner sees your walk location until either of you pauses, finishes or ends the pairing.")
        }
        .disabled(store.overview == nil || store.isWorking)
    }

    private var searchSection: some View {
        Section("Find people") {
            TextField("Name or public ID (at least 2 characters)", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityLabel("Search people by name or public ID")
            if store.isSearching { ProgressView("Searching…") }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
               !store.isSearching, store.searchResults.isEmpty {
                Text("No matching people.").foregroundStyle(AppColors.secondaryText)
            }
            ForEach(store.searchResults) { user in
                VStack(alignment: .leading, spacing: 8) {
                    profile(user)
                    HStack {
                        if isFriend(user) { Label("Friend", systemImage: "checkmark") }
                        else if hasPendingRequest(user) { Text("Request pending").foregroundStyle(AppColors.secondaryText) }
                        else { Button("Add friend") { Task { await store.sendRequest(user) } } }
                        Spacer()
                        Button("Block", role: .destructive) { pendingBlock = user }
                    }.font(.subheadline).disabled(store.isWorking)
                }.padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder private var requestsSection: some View {
        if let overview = store.overview, !overview.incomingRequests.isEmpty {
            Section("Friend requests") {
                ForEach(overview.incomingRequests) { request in
                    VStack(alignment: .leading, spacing: 8) {
                        profile(request.user)
                        HStack {
                            Button("Accept") { Task { await store.respondToRequest(request, accept: true) } }
                            Spacer()
                            Button("Decline", role: .destructive) { Task { await store.respondToRequest(request, accept: false) } }
                        }.disabled(store.isWorking)
                    }
                }
            }
        }
        if let overview = store.overview, !overview.outgoingRequests.isEmpty {
            Section("Sent requests") {
                ForEach(overview.outgoingRequests) { request in
                    HStack {
                        profile(request.user)
                        Spacer()
                        Button("Cancel") { Task { await store.removeFriend(request.user) } }.disabled(store.isWorking)
                    }
                }
            }
        }
    }

    private var friendsSection: some View {
        Section("Friends") {
            if store.overview?.friends.isEmpty != false {
                Text("Find someone by name or share your public ID to add your first friend.")
                    .foregroundStyle(AppColors.secondaryText)
            }
            ForEach(store.overview?.friends ?? []) { friendship in
                VStack(alignment: .leading, spacing: 8) {
                    profile(friendship.user)
                    HStack {
                        if store.canInvite, visibleForNet(friendship.user) {
                            Button("Invite to Net-Walk") { Task { await store.invite(friendship.user) } }
                        }
                        Spacer()
                        Menu {
                            Button("Remove friend", role: .destructive) { pendingRemoval = friendship.user }
                            Button("Block user", role: .destructive) { pendingBlock = friendship.user }
                        } label: { Label("Options", systemImage: "ellipsis.circle") }
                    }.font(.subheadline).disabled(store.isWorking)
                }
            }
        }
    }

    private var netWalkingSection: some View {
        Section {
            if let active = store.invitations.active {
                Label("Walking with \(name(active.user))", systemImage: "figure.walk.motion")
                if let session = store.currentSession {
                    Text("Verified together: \(session.sharedDistanceM / 1000, specifier: "%.2f") km")
                    if session.bonusStatus == "awaiting_rules" {
                        Text("Estimated bonus: \(session.estimatedBonusPoints, specifier: "%.0f") points. Reward rules are awaiting confirmation; these points have not been added to your wallet.")
                            .font(.footnote).foregroundStyle(AppColors.secondaryText)
                    } else if session.bonusStatus == "settled" {
                        Text("Confirmed bonus: \(session.bonusPoints) points")
                    } else {
                        Text("Estimated bonus: \(session.estimatedBonusPoints, specifier: "%.0f") points, subject to verification when the walk finishes.")
                            .font(.footnote).foregroundStyle(AppColors.secondaryText)
                    }
                }
                Button("End Net-Walking", role: .destructive) { Task { await store.endInvitation(active) } }
                    .disabled(store.isWorking)
            } else if !store.isCurrentlyWalking {
                Text("Start recording a walk in the Walk tab to find a partner.").foregroundStyle(AppColors.secondaryText)
            } else if !store.netMatchingEnabled {
                Text("Enable Find Net-Walking partners to meet consenting walkers nearby.").foregroundStyle(AppColors.secondaryText)
            } else { Text("No active pairing. Invite a nearby walker below.").foregroundStyle(AppColors.secondaryText) }
            ForEach(store.invitations.incoming) { invitation in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(name(invitation.user)) invited you to walk together.")
                    HStack {
                        Button("Accept") { Task { await store.respondToInvitation(invitation, accept: true) } }
                            .disabled(!store.canInvite || store.isWorking)
                        Spacer()
                        Button("Decline", role: .destructive) { Task { await store.respondToInvitation(invitation, accept: false) } }
                            .disabled(store.isWorking)
                    }
                }
            }
            ForEach(store.invitations.outgoing) { invitation in
                HStack {
                    Text("Waiting for \(name(invitation.user))")
                    Spacer()
                    Button("Cancel") { Task { await store.endInvitation(invitation) } }.disabled(store.isWorking)
                }
            }
            ForEach(store.mapSnapshot.nearby.filter { $0.isFresh(at: Date()) }) { peer in
                VStack(alignment: .leading, spacing: 8) {
                    profile(peer.user)
                    if peer.isApproximate { Text("Approximate nearby position").font(.caption).foregroundStyle(AppColors.secondaryText) }
                    if let distance = peer.distanceM { Text("About \(distance, specifier: "%.0f") m away").font(.footnote) }
                    Button("Invite to Net-Walk") { Task { await store.invite(peer.user) } }
                        .disabled(!store.canInvite || store.isWorking || store.invitations.active != nil)
                }
            }
        } header: { Text("Net-Walking") } footer: {
            Text("You do not have to be friends first. Both walkers must opt in and accept the pairing. Pausing a walk ends the pairing; send a new invitation after resuming.")
        }
    }

    @ViewBuilder private var mapSection: some View {
        Section("Walking nearby") {
            if store.peers.isEmpty {
                Text("No recent shared locations. People appear only during active walks and with their permission.")
                    .foregroundStyle(AppColors.secondaryText)
            } else {
                Map {
                    ForEach(store.peers) { peer in
                        Annotation(name(peer.user), coordinate: peer.coordinate) {
                            Image(systemName: peer.isNetPartner ? "figure.walk.motion" : "person.circle.fill")
                                .font(.title2).padding(8)
                                .foregroundStyle(.white).background(AppColors.brand)
                                .clipShape(Circle())
                                .accessibilityLabel("\(name(peer.user)), \(peer.isNetPartner ? "Net-Walking partner" : "shared walk location")")
                        }
                    }
                }.frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Nearby discovery positions are approximate. Markers disappear when sharing stops or a fresh location is unavailable.")
                    .font(.footnote).foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    @ViewBuilder private var blockedSection: some View {
        if let blocked = store.overview?.blockedUsers, !blocked.isEmpty {
            Section("Blocked people") {
                ForEach(blocked) { user in
                    HStack {
                        profile(user)
                        Spacer()
                        Button("Unblock") { Task { await store.unblock(user) } }.disabled(store.isWorking)
                    }
                }
            }
        }
    }

    private func profile(_ user: SocialProfile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(AppColors.brand)
            VStack(alignment: .leading, spacing: 3) {
                Text(name(user)).fontWeight(.medium)
                Text(user.publicID).font(.caption.monospaced()).foregroundStyle(AppColors.secondaryText)
                    .lineLimit(1).textSelection(.enabled)
            }
        }
    }
    private func name(_ user: SocialProfile) -> String { user.displayName.isEmpty ? "Vitail walker" : user.displayName }
    private func isFriend(_ user: SocialProfile) -> Bool { store.overview?.friends.contains { $0.user.id == user.id } == true }
    private func hasPendingRequest(_ user: SocialProfile) -> Bool {
        let requests = (store.overview?.incomingRequests ?? []) + (store.overview?.outgoingRequests ?? [])
        return requests.contains { $0.user.id == user.id }
    }
    private func visibleForNet(_ user: SocialProfile) -> Bool {
        store.mapSnapshot.nearby.contains { $0.user.id == user.id }
    }
}
