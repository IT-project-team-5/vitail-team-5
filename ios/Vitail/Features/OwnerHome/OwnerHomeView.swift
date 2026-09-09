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
    @State private var selection: Page = .walk

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
        _redemptionViewModel = StateObject(
            wrappedValue: RedemptionViewModel(service: redemptionService)
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selection) {
                    OwnerProfileView(user: user, session: session, dogService: dogService)
                        .tag(Page.account)
                    WalkView(
                        session: session, service: walkService, dogService: dogService,
                        onWalletChanged: { await redemptionViewModel.refresh() }
                    )
                    .tag(Page.walk)
                    RedemptionView(viewModel: redemptionViewModel)
                    .tag(Page.redeem)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomNavigation
            }
            .background(AppColors.background)
            .navigationTitle(selection.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        Image(systemName: "pawprint.fill")
                        Text(redemptionViewModel.balance.map { "\($0) pts" } ?? "— pts")
                    }
                        .fontWeight(.semibold)
                        .foregroundStyle(AppColors.brand)
                }
            }
            .task(id: "\(selection.rawValue)-\(scenePhase == .active)") {
                guard scenePhase == .active else { return }
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
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
