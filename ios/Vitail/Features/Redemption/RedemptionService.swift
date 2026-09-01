import Foundation

/// Talks to /api/venues, /api/wallet and /api/redemptions. Every call goes
/// through AuthService.performAuthorized so a stale access token is
/// refreshed once and retried instead of failing the request.
actor RedemptionService {
    private let apiClient: APIClient
    private let authService: AuthService

    init(apiClient: APIClient = APIClient(), authService: AuthService = AuthService()) {
        self.apiClient = apiClient
        self.authService = authService
    }

    func fetchBalance() async throws -> WalletBalance {
        try await authService.performAuthorized { token in
            try await self.apiClient.get("/api/wallet/", bearerToken: token)
        }
    }

    func fetchVenues() async throws -> [Venue] {
        try await authService.performAuthorized { token in
            try await self.apiClient.get("/api/venues/", bearerToken: token)
        }
    }

    func fetchVenueDetail(id: Int) async throws -> VenueDetail {
        try await authService.performAuthorized { token in
            try await self.apiClient.get("/api/venues/\(id)", bearerToken: token)
        }
    }

    func fetchOrders() async throws -> [RedemptionOrder] {
        try await authService.performAuthorized { token in
            try await self.apiClient.get("/api/redemptions/orders", bearerToken: token)
        }
    }

    func createOrder(venueId: Int, items: [CreateOrderItemRequest]) async throws -> RedemptionOrder {
        try await authService.performAuthorized { token in
            try await self.apiClient.post(
                "/api/redemptions/orders",
                body: CreateOrderRequest(venueId: venueId, items: items),
                bearerToken: token
            )
        }
    }

    func collectOrder(id: Int) async throws -> RedemptionOrder {
        try await authService.performAuthorized { token in
            try await self.apiClient.post(
                "/api/redemptions/orders/\(id)/collect",
                body: EmptyRequestBody(),
                bearerToken: token
            )
        }
    }
}
