import SwiftUI

struct CafeOrdersView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case account = "Account"
        case orders = "Orders"

        var id: Self { self }

        var icon: String {
            switch self {
            case .account:
                return "person.crop.circle"
            case .orders:
                return "list.bullet.rectangle"
            }
        }

        var selectedIcon: String {
            switch self {
            case .account:
                return "person.crop.circle.fill"
            case .orders:
                return "list.bullet.rectangle.fill"
            }
        }
    }

    let user: User
    @ObservedObject var session: SessionStore
    @State private var selection: Page = .orders

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selection) {
                    accountPage
                        .tag(Page.account)
                    ordersPage
                        .tag(Page.orders)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomNavigation
            }
            .background(AppColors.background)
            .navigationTitle(selection.rawValue)
            .navigationBarTitleDisplayMode(.inline)
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

    private var ordersPage: some View {
        VStack(spacing: AppSpacing.medium) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 44))
                .foregroundStyle(AppColors.brand)
            Text("No new orders")
                .font(.title2.bold())
            Text("Reward orders will appear here.")
                .foregroundStyle(AppColors.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
