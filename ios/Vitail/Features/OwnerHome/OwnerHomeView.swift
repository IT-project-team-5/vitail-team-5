import SwiftUI

struct OwnerHomeView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case account = "Account"
        case walk = "Walk"
        case rewards = "Rewards"
        case order = "Order"

        var id: Self { self }

        var icon: String {
            switch self {
            case .account:
                return "person.crop.circle"
            case .walk:
                return "figure.walk"
            case .rewards:
                return "gift"
            case .order:
                return "bag"
            }
        }

        var selectedIcon: String {
            switch self {
            case .account:
                return "person.crop.circle.fill"
            case .walk:
                return "figure.walk"
            case .rewards:
                return "gift.fill"
            case .order:
                return "bag.fill"
            }
        }
    }

    let user: User
    @ObservedObject var session: SessionStore
    @StateObject private var redemptionStore = RedemptionStore()
    @State private var selection: Page = .walk
    @State private var isShowingOrderHistory = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selection) {
                    accountPage
                        .tag(Page.account)
                    WalkMapView(isActive: selection == .walk)
                        .tag(Page.walk)
                    RewardsView(store: redemptionStore) {
                        selection = .order
                    }
                    .tag(Page.rewards)
                    OrderView(store: redemptionStore) {
                        selection = .rewards
                    }
                    .tag(Page.order)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomNavigation
            }
            .background(AppColors.background)
            .navigationTitle(selection.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selection == .order {
                        Button {
                            isShowingOrderHistory = true
                        } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        Image(systemName: "pawprint.fill")
                        Text("\(redemptionStore.pointsBalance) pts")
                    }
                        .fontWeight(.semibold)
                        .foregroundStyle(AppColors.brand)
                }
            }
            .sheet(isPresented: $isShowingOrderHistory) {
                OrderHistoryView(store: redemptionStore)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var accountPage: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Text(user.displayName)
                    .font(.title2.bold())
                Text(user.email)
                    .foregroundStyle(AppColors.secondaryText)
            }
            .padding(AppSpacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))

            Button("Log Out", role: .destructive) {
                Task { await session.logout() }
            }

            Spacer()
        }
        .padding(AppSpacing.large)
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
