import SwiftUI

struct OwnerHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    private enum Page: String, CaseIterable, Identifiable {
        case account = "Account"
        case walk = "Walk"
        case redeem = "Redeem"

        var id: Self { self }

        var icon: String {
            switch self {
            case .account:
                return "person.crop.circle"
            case .walk:
                return "figure.walk"
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
            case .redeem:
                return "gift.fill"
            }
        }
    }

    let user: User
    @ObservedObject var session: SessionStore
    let dogService: any DogServicing
    let walkService: any WalkServing
    @StateObject private var redemptionViewModel: RedemptionViewModel
    @StateObject private var walkCoordinator: WalkSessionCoordinator
    @StateObject private var onboardingDogs: DogViewModel
    @State private var selection: Page = .walk
    @State private var hasCheckedOnboarding = false
    @State private var isAddingFirstDog = false
    @State private var accountRefreshID = 0

    init(
        user: User, session: SessionStore,
        dogService: any DogServicing = DogService(),
        redemptionService: any RedemptionServing = RedemptionService(),
        walkService: any WalkServing = WalkService()
    ) {
        self.user = user
        self.session = session
        self.dogService = dogService
        self.walkService = walkService
        _onboardingDogs = StateObject(wrappedValue: DogViewModel(service: dogService))
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
                    OwnerProfileView(user: user, session: session, dogService: dogService)
                        .id(accountRefreshID)
                        .tag(Page.account)
                    WalkMapView(coordinator: walkCoordinator, isActive: selection == .walk && hasCheckedOnboarding && !isAddingFirstDog) {
                        selection = .account
                    }
                    .tag(Page.walk)
                    RedemptionView(viewModel: redemptionViewModel)
                    .tag(Page.redeem)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomNavigation
            }
            .background(AppColors.background)
            .navigationTitle("Vitail")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $isAddingFirstDog, onDismiss: {
                accountRefreshID += 1
                Task { await walkCoordinator.dogSelection.load() }
            }) {
                DogFormView(viewModel: onboardingDogs)
            }
            .task {
                guard !hasCheckedOnboarding else { return }
                await onboardingDogs.load()
                guard !Task.isCancelled else { return }
                hasCheckedOnboarding = true
                isAddingFirstDog = onboardingDogs.errorMessage == nil && onboardingDogs.dogs.isEmpty
            }
            .task(id: "\(selection.rawValue)-\(scenePhase == .active)") {
                guard scenePhase == .active else { return }
                walkCoordinator.sync.onWalletChanged = { [weak redemptionViewModel] in await redemptionViewModel?.refresh() }
                session.beforeLogout = { [weak walkCoordinator] in await walkCoordinator?.prepareForLogout() }
                await walkCoordinator.sync.refreshAndUpload()
                await redemptionViewModel.refresh()
            }
        }
    }

    private var bottomNavigation: some View {
        HStack {
            ForEach(Page.allCases) { page in
                Button {
                    selection = page
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: selection == page ? page.selectedIcon : page.icon)
                        Text(page.rawValue)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selection == page ? AppColors.brand : AppColors.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == page ? .isSelected : [])
            }
        }
        .padding(.top, AppSpacing.small)
        .padding(.bottom, AppSpacing.small)
        .padding(.horizontal, AppSpacing.small)
        .background(AppColors.surface)
    }
}
