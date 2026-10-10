import SwiftUI

struct OwnerHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private enum Page: String, CaseIterable, Identifiable {
        case account = "Account"
        case walk = "Walk"
        case quest = "Quest"
        case venues = "Venues"
        case redeem = "Redeem"

        var id: Self { self }

        var icon: String {
            switch self {
            case .account:
                return "person.crop.circle"
            case .walk:
                return "figure.walk"
            case .quest:
                return "flag"
            case .venues:
                return "mappin.and.ellipse"
            case .redeem:
                return "gift"
            }
        }

        var selectedIcon: String {
            switch self {
            case .account:
                return "person.crop.circle.fill"
            case .walk:
                return "figure.walk"
            case .quest:
                return "flag.fill"
            case .venues:
                return "mappin.and.ellipse"
            case .redeem:
                return "gift.fill"
            }
        }
    }

    let user: User
    @ObservedObject var session: SessionStore
    let dogService: any DogServicing
    let documentService: (any DocumentServing)?
    @StateObject private var redemptionViewModel: RedemptionViewModel
    @StateObject private var walkCoordinator: WalkSessionCoordinator
    @StateObject private var onboardingDogs: DogViewModel
    @StateObject private var questStore: QuestStore
    @StateObject private var checkIns: CheckInProgressStore
    @StateObject private var venueCheckIns: VenuesViewModel
    @StateObject private var friends: FriendsStore
    @State private var selection: Page = .walk
    @State private var hasCheckedOnboarding = false
    @State private var isAddingFirstDog = false
    @State private var accountRefreshID = 0
    @State private var documentSelection: DocumentQuestRoute?
    @State private var isShowingFriends = false

    init(
        user: User, session: SessionStore,
        dogService: any DogServicing = DogService(),
        redemptionService: any RedemptionServing = RedemptionService(),
        walkService: any WalkServing = WalkService(),
        questService: any QuestServing = QuestService(),
        checkInService: (any CheckInProgressServing)? = nil,
        venueCheckInService: any VenueCheckInServing = VenueCheckInService(),
        documentService: (any DocumentServing)? = nil,
        friendsService: any FriendsServing = FriendsService()
    ) {
        self.user = user
        self.session = session
        self.dogService = dogService
        self.documentService = documentService
        _friends = StateObject(wrappedValue: FriendsStore(ownerID: user.id, session: session, service: friendsService))
        _questStore = StateObject(wrappedValue: QuestStore(ownerID: user.id, session: session, service: questService))
        _checkIns = StateObject(wrappedValue: CheckInProgressStore(ownerID: user.id, service: checkInService, session: session))
        _venueCheckIns = StateObject(wrappedValue: VenuesViewModel(service: venueCheckInService, session: session, ownerID: user.id))
        _onboardingDogs = StateObject(wrappedValue: DogViewModel(service: dogService, session: session))
        _walkCoordinator = StateObject(wrappedValue: WalkSessionCoordinator(
            ownerID: user.id, session: session, dogService: dogService, walkService: walkService
        ))
        _redemptionViewModel = StateObject(
            wrappedValue: RedemptionViewModel(service: redemptionService)
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selection) {
                    OwnerProfileView(user: user, session: session, dogService: dogService,
                                     documentService: documentService ?? DocumentService(), onDocumentsChanged: {
                                         async let quests: Void = questStore.documentsDidChange()
                                         async let wallet: Void = redemptionViewModel.refresh()
                                         _ = await (quests, wallet)
                                     }, onGoalsChanged: {
                                         await questStore.walksDidChange()
                                     }, onOpenFriends: { isShowingFriends = true })
                        .id(accountRefreshID)
                        .tag(Page.account)
                    WalkMapView(coordinator: walkCoordinator, isActive: selection == .walk && hasCheckedOnboarding && !isAddingFirstDog, checkIns: checkIns, friends: friends)
                    .tag(Page.walk)
                    QuestView(store: questStore, checkIns: checkIns, points: redemptionViewModel.balance,
                              onOpenDocuments: documentService != nil
                                ? { route in documentSelection = route } : nil,
                              onResetAll: {
                                  async let wallet: Void = redemptionViewModel.refresh()
                                  async let checkInProgress: Void = checkIns.refresh()
                                  async let venues: Void = venueCheckIns.load()
                                  _ = await (wallet, checkInProgress, venues)
                              })
                        .tag(Page.quest)
                    VenuesView(viewModel: venueCheckIns, progressStore: checkIns)
                        .tag(Page.venues)
                    RedemptionView(viewModel: redemptionViewModel, documentService: documentService ?? DocumentService(), session: session)
                    .tag(Page.redeem)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomNavigation
            }
            .background(AppColors.background)
            .navigationTitle("Vitail")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $isShowingFriends) {
                FriendsView(store: friends)
            }
            .sheet(isPresented: $isAddingFirstDog, onDismiss: {
                accountRefreshID += 1
                Task {
                    await walkCoordinator.dogSelection.load()
                    await questStore.refresh()
                }
            }) {
                DogOnboardingView(dogs: onboardingDogs, session: session, onFinished: { isAddingFirstDog = false })
            }
            .sheet(item: $documentSelection, onDismiss: {
                Task { await questStore.refresh() }
            }) { selectedDocument in
                if let documentService {
                    NavigationStack {
                        DocumentSubmissionView(service: documentService, session: session,
                                               initialDogID: selectedDocument.dogID, initialKind: selectedDocument.kind,
                                               expectedEntitlementID: selectedDocument.expectedEntitlementID, needsExpiry: selectedDocument.needsExpiry,
                                               onSubmitted: {
                                                   async let quests: Void = questStore.refresh()
                                                   async let wallet: Void = redemptionViewModel.refresh()
                                                   _ = await (quests, wallet)
                                               }, onChanged: { await questStore.documentsDidChange() })
                        .id(selectedDocument.id)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { documentSelection = nil }
                            }
                        }
                    }
                }
            }
            .task {
                guard !hasCheckedOnboarding else { return }
                await onboardingDogs.load()
                guard !Task.isCancelled else { return }
                hasCheckedOnboarding = true
                isAddingFirstDog = user.onboardingComplete == false
            }
            .onAppear { friends.setForeground(scenePhase == .active) }
            .task(id: "\(selection.rawValue)-\(scenePhase == .active)") {
                guard scenePhase == .active else { return }
                configureCallbacks()
                async let walks: Void = walkCoordinator.sync.refreshAndUpload()
                async let wallet: Void = redemptionViewModel.refresh()
                async let quests: Void = questStore.refresh()
                async let venues: Void = checkIns.refresh()
                async let venueMap: Void = venueCheckIns.load()
                _ = await (walks, wallet, quests, venues, venueMap)
                // Both progress surfaces observe the same server-backed store.
                // Tab changes/backgrounding cancel this task and its polling.
                while !Task.isCancelled && (selection == .walk || selection == .quest || selection == .venues) {
                    do { try await Task.sleep(for: .seconds(5)) }
                    catch { break }
                    guard !Task.isCancelled else { break }
                    await checkIns.refresh()
                    if selection == .venues { await venueCheckIns.load() }
                    if selection == .quest { await questStore.refresh() }
                }
            }
            .onChange(of: session.state) { _, state in
                guard case let .signedIn(currentUser) = state,
                      currentUser.id == user.id, currentUser.role == .owner else {
                    questStore.stop()
                    checkIns.stop()
                    friends.stop()
                    return
                }
            }
            .onChange(of: scenePhase) { _, phase in
                friends.setForeground(phase == .active)
            }
        }
    }

    private func configureCallbacks() {
        walkCoordinator.onSocialWalkChanged = { [weak friends] draft, status in
            friends?.updateWalk(isWalking: status == .walking, requestID: draft?.id, startedAt: draft?.startedAt)
        }
        walkCoordinator.onSocialLocations = { [weak friends] locations in
            for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
                friends?.receiveLocation(location)
            }
        }
        walkCoordinator.onSocialLocationInterrupted = { [weak friends] in
            friends?.locationUpdatesInterrupted()
        }
        let draft = walkCoordinator.tracker.makeDraft()
        friends.updateWalk(isWalking: walkCoordinator.tracker.status == .walking,
                           requestID: draft?.id, startedAt: draft?.startedAt)
        walkCoordinator.sync.onWalletChanged = { [weak redemptionViewModel, weak questStore] in
            guard let redemptionViewModel, let questStore else { return }
            async let wallet: Void = redemptionViewModel.refresh()
            async let quests: Void = questStore.walksDidChange()
            _ = await (wallet, quests)
        }
        questStore.onAward = { [weak redemptionViewModel] _ in
            await redemptionViewModel?.refresh()
        }
        checkIns.onCollection = { [weak redemptionViewModel, weak questStore] in
            guard let redemptionViewModel, let questStore else { return }
            async let wallet: Void = redemptionViewModel.refresh()
            async let quests: Void = questStore.refresh()
            _ = await (wallet, quests)
        }
        venueCheckIns.onProgressChanged = { [weak checkIns] in
            await checkIns?.refresh()
        }
        venueCheckIns.onPointsAwarded = { [weak redemptionViewModel, weak questStore] in
            guard let redemptionViewModel, let questStore else { return }
            async let wallet: Void = redemptionViewModel.refresh()
            async let quests: Void = questStore.refresh()
            _ = await (wallet, quests)
        }
        session.beforeLogout = { [weak walkCoordinator, weak questStore, weak checkIns, weak venueCheckIns, weak friends] in
            questStore?.stop()
            checkIns?.stop()
            await friends?.prepareForLogout()
            await venueCheckIns?.prepareForLogout()
            await walkCoordinator?.prepareForLogout()
        }
    }

    private var bottomNavigation: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal, showsIndicators: false) { navigationItems }
            } else {
                navigationItems
            }
        }
        .padding(.vertical, AppSpacing.small)
        .padding(.horizontal, AppSpacing.small)
        .background(AppColors.surface)
    }

    private var navigationItems: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Page.allCases) { page in
                Button {
                    selection = page
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: selection == page ? page.selectedIcon : page.icon)
                            .accessibilityHidden(true)
                        Text(page.rawValue)
                            .font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                    }
                    .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? 132 : 0, minHeight: 44)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selection == page ? AppColors.brand : AppColors.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.rawValue)
                .accessibilityIdentifier("owner-tab-\(page.rawValue.lowercased())")
                .accessibilityAddTraits(selection == page ? .isSelected : [])
            }
        }
    }
}
