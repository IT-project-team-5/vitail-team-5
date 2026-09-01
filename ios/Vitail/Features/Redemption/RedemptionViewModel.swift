import Combine
import Foundation

@MainActor
final class RedemptionViewModel: ObservableObject {
    @Published private(set) var balance: Int?
    @Published private(set) var venues: [Venue] = []
    @Published private(set) var orders: [RedemptionOrder] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingVenueDetail = false
    @Published private(set) var isPlacingOrder = false
    @Published private(set) var selectedVenueDetail: VenueDetail?
    @Published private(set) var lastPlacedOrder: RedemptionOrder?
    @Published var errorMessage: String?

    var pendingOrders: [RedemptionOrder] {
        orders.filter { $0.status == .pending }
    }

    var recentlyCollectedOrders: [RedemptionOrder] {
        Array(orders.filter { $0.status == .collected }.prefix(5))
    }

    private let service: RedemptionService

    init(service: RedemptionService = RedemptionService()) {
        self.service = service
    }

    func loadInitialData() async {
        guard venues.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let balanceTask = service.fetchBalance()
            async let venuesTask = service.fetchVenues()
            async let ordersTask = service.fetchOrders()
            let (fetchedBalance, fetchedVenues, fetchedOrders) = try await (
                balanceTask, venuesTask, ordersTask
            )
            balance = fetchedBalance.balance
            venues = fetchedVenues
            orders = fetchedOrders
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        errorMessage = nil
        do {
            async let balanceTask = service.fetchBalance()
            async let ordersTask = service.fetchOrders()
            let (fetchedBalance, fetchedOrders) = try await (balanceTask, ordersTask)
            balance = fetchedBalance.balance
            orders = fetchedOrders
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadVenueDetail(id: Int) async {
        isLoadingVenueDetail = true
        errorMessage = nil
        defer { isLoadingVenueDetail = false }

        do {
            selectedVenueDetail = try await service.fetchVenueDetail(id: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearSelectedVenue() {
        selectedVenueDetail = nil
        lastPlacedOrder = nil
    }

    func placeOrder(venueId: Int, cart: [Int: Int]) async {
        let items = cart.compactMap { offerId, quantity -> CreateOrderItemRequest? in
            quantity > 0 ? CreateOrderItemRequest(offerId: offerId, quantity: quantity) : nil
        }
        guard !items.isEmpty else {
            errorMessage = "Choose at least one item."
            return
        }

        isPlacingOrder = true
        errorMessage = nil
        defer { isPlacingOrder = false }

        do {
            let order = try await service.createOrder(venueId: venueId, items: items)
            lastPlacedOrder = order
            orders.insert(order, at: 0)
            if let currentBalance = balance {
                balance = currentBalance - order.totalPoints
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func collect(orderID: Int) async {
        errorMessage = nil
        do {
            let updated = try await service.collectOrder(id: orderID)
            if let index = orders.firstIndex(where: { $0.id == updated.id }) {
                orders[index] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
