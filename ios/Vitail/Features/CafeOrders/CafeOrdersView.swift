import SwiftUI

struct CafeOrdersView: View {
    @Environment(\.scenePhase) private var scenePhase

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
    @StateObject private var ordersViewModel: CafeOrdersViewModel
    @State private var selection: Page = .orders

    init(
        user: User,
        session: SessionStore,
        service: any CafeOrdersServing = CafeOrdersService()
    ) {
        self.user = user
        self.session = session
        _ordersViewModel = StateObject(
            wrappedValue: CafeOrdersViewModel(service: service)
        )
    }

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
            .task(id: shouldPollOrders) {
                guard shouldPollOrders else { return }
                await ordersViewModel.pollWhileVisible()
            }
        }
    }

    private var shouldPollOrders: Bool {
        selection == .orders && scenePhase == .active
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
        Group {
            if ordersViewModel.isInitialLoading {
                LoadingView(message: "Loading orders…")
            } else if !ordersViewModel.hasLoaded {
                initialOrdersError
            } else {
                loadedOrdersPage
            }
        }
        .background(AppColors.background)
    }

    private var loadedOrdersPage: some View {
        VStack(spacing: 0) {
            ordersHeader

            if let errorMessage = ordersViewModel.errorMessage {
                refreshErrorBanner(errorMessage)
            }

            ScrollView {
                if ordersViewModel.orders.isEmpty {
                    ContentUnavailableView {
                        Label("No new orders", systemImage: "cup.and.saucer.fill")
                    } description: {
                        Text("Orders awaiting collection will appear here automatically.")
                    }
                    .padding(.top, AppSpacing.extraLarge * 2)
                } else {
                    LazyVStack(spacing: AppSpacing.medium) {
                        ForEach(ordersViewModel.orders) { order in
                            orderCard(order)
                        }
                    }
                    .padding(AppSpacing.medium)
                }
            }
            .refreshable {
                await ordersViewModel.refresh()
            }
        }
    }

    private var ordersHeader: some View {
        HStack(alignment: .center, spacing: AppSpacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.headline)
                Label("Updates every 5 seconds", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }

            Spacer()

            if let lastUpdatedAt = ordersViewModel.lastUpdatedAt {
                Text(lastUpdatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityLabel("Last updated")
                    .accessibilityValue(lastUpdatedAt.formatted(date: .omitted, time: .shortened))
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
        .background(AppColors.surface)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var initialOrdersError: some View {
        VStack(spacing: AppSpacing.medium) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(AppColors.error)
            Text("Could not load orders")
                .font(.title3.bold())
            Text(ordersViewModel.errorMessage ?? "Please try again.")
                .multilineTextAlignment(.center)
                .foregroundStyle(AppColors.secondaryText)
            PrimaryButton(title: "Try Again") {
                Task { await ordersViewModel.refresh() }
            }
            .frame(maxWidth: 280)
        }
        .padding(AppSpacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refreshErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColors.error)
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") {
                Task { await ordersViewModel.refresh() }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(AppColors.brand)
        }
        .padding(AppSpacing.small)
        .background(AppColors.error.opacity(0.1))
        .accessibilityElement(children: .contain)
    }

    private func orderCard(_ order: CafeOrder) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            HStack(alignment: .top, spacing: AppSpacing.small) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(order.referenceNumber)
                        .font(.headline.monospaced())
                        .textSelection(.enabled)
                    Label("Awaiting collection", systemImage: "clock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.brand)
                }

                Spacer()

                Text(order.orderedAt, format: .dateTime.hour().minute())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
            }

            Label(order.ownerName, systemImage: "person.fill")
                .font(.subheadline)

            Divider()

            VStack(alignment: .leading, spacing: AppSpacing.small) {
                if order.items.isEmpty {
                    Text("No items recorded")
                        .foregroundStyle(AppColors.secondaryText)
                } else {
                    ForEach(Array(order.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                            Text("\(item.quantity)×")
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .frame(minWidth: 28, alignment: .trailing)
                            Text(item.name)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(item.quantity) \(item.name)")
                    }
                }
            }
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.card)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
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
