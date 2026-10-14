import Foundation

@MainActor
final class CafeOrdersViewModel: ObservableObject {
    @Published private(set) var orders: [RedemptionOrder] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let service: RedemptionService

    init(service: RedemptionService = RedemptionService()) {
        self.service = service
    }

    var pendingOrders: [RedemptionOrder] {
        orders.filter { $0.status == .pending }
    }

    func loadOrders() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            orders = try await service.fetchCafeOrders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}