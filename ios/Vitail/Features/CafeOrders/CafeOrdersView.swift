import SwiftUI

struct CafeOrdersView: View {
    @Environment(\.scenePhase) private var scenePhase

    private enum Page: String, CaseIterable, Identifiable {
        case account = "Account"
        case products = "Products"
        case orders = "Orders"

        var id: Self { self }

        var icon: String {
            switch self {
            case .account:
                return "person.crop.circle"
            case .products:
                return "cup.and.saucer"
            case .orders:
                return "list.bullet.rectangle"
            }
        }

        var selectedIcon: String {
            switch self {
            case .account:
                return "person.crop.circle.fill"
            case .products:
                return "cup.and.saucer.fill"
            case .orders:
                return "list.bullet.rectangle.fill"
            }
        }
    }

    let user: User
    @ObservedObject var session: SessionStore
    @StateObject private var ordersViewModel: CafeOrdersViewModel
    @State private var selection: Page = .orders
    private let profileService: any CafeProfileServing
    private let productsService: any CafeProductsServing

    init(
        user: User,
        session: SessionStore,
        service: any CafeOrdersServing = CafeOrdersService(),
        profileService: any CafeProfileServing = CafeProfileService(),
        productsService: any CafeProductsServing = CafeProductsService()
    ) {
        self.user = user
        self.session = session
        self.profileService = profileService
        self.productsService = productsService
        _ordersViewModel = StateObject(
            wrappedValue: CafeOrdersViewModel(service: service)
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selection) {
                    CafeProfileView(session: session, service: profileService)
                        .tag(Page.account)
                    CafeProductsView(service: productsService)
                        .tag(Page.products)
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
                            NavigationLink {
                                CafeOrderDetailView(
                                    orderID: order.id,
                                    initialOrder: order,
                                    viewModel: ordersViewModel
                                )
                            } label: {
                                orderCard(order)
                            }
                            .buttonStyle(.plain)
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
        HStack(spacing: AppSpacing.medium) {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Text(order.itemTitle)
                    .font(.headline)
                    .foregroundStyle(AppColors.primaryText)
                Text(order.customerSummary)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(AppColors.secondaryText)
                .accessibilityHidden(true)
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.card)
                .stroke(AppColors.border, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.card))
        .accessibilityElement(children: .combine)
        .accessibilityHint("View order details")
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

private struct CafeOrderDetailView: View {
    let orderID: Int
    let initialOrder: CafeOrder
    @ObservedObject var viewModel: CafeOrdersViewModel

    private var currentOrder: CafeOrder? {
        viewModel.orders.first { $0.id == orderID }
    }

    private var order: CafeOrder { currentOrder ?? initialOrder }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                Text(order.itemTitle)
                    .font(.title2.bold())
                    .foregroundStyle(AppColors.primaryText)

                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    Text(order.ownerName)
                        .font(.headline)
                    if !order.ownerDogNames.isEmpty {
                        Text("Customer’s dogs")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        Text(order.ownerDogNames.joined(separator: ", "))
                            .font(.subheadline)
                    }
                }

                VStack(spacing: AppSpacing.medium) {
                    LabeledContent("Reference", value: order.referenceNumber)
                        .textSelection(.enabled)
                    LabeledContent("Ordered") {
                        Text(order.orderedAt, format: .dateTime.day().month().hour().minute())
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Status") {
                        Text(currentOrder == nil ? "No longer awaiting collection" : order.statusLabel)
                            .multilineTextAlignment(.trailing)
                    }
                    if currentOrder != nil, let expiresAt = order.expiresAt {
                        LabeledContent("Collect before") {
                            Text(expiresAt, format: .dateTime.day().month().hour().minute())
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .padding(AppSpacing.medium)
                .background(AppColors.surface)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.large)
        }
        .background(AppColors.background)
        .navigationTitle("Order")
        .navigationBarTitleDisplayMode(.inline)
    }
}
