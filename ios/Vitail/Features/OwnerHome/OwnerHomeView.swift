import SwiftUI

struct OwnerHomeView: View {
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
    @State private var selection: Page = .walk

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selection) {
                    accountPage
                        .tag(Page.account)
                    placeholderPage(
                        icon: "figure.walk",
                        title: "Walk",
                        message: "Walk tracking will appear here."
                    )
                    .tag(Page.walk)
                    placeholderPage(
                        icon: "gift.fill",
                        title: "Redeem",
                        message: "Rewards will appear here."
                    )
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
                        Text("0 pts")
                    }
                        .fontWeight(.semibold)
                        .foregroundStyle(AppColors.brand)
                }
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

    private func placeholderPage(icon: String, title: String, message: String) -> some View {
        VStack(spacing: AppSpacing.medium) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(AppColors.brand)
            Text(title)
                .font(.title2.bold())
            Text(message)
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
