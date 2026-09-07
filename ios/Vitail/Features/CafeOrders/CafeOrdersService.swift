import Foundation

protocol CafeOrdersServing: Sendable {
    func fetchOrders(since cursor: Int?) async throws -> CafeOrdersFetchResult
}

actor CafeOrdersService: CafeOrdersServing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func fetchOrders(since cursor: Int?) async throws -> CafeOrdersFetchResult {
        let queryItems = cursor.map {
            [URLQueryItem(name: "since", value: String($0))]
        } ?? []
        let response: ConditionalAPIResponse<CafeOrdersFeed> = try await apiClient.getConditional(
            "/api/cafe/orders",
            queryItems: queryItems
        )

        switch response {
        case let .value(feed):
            return .updated(feed)
        case let .notModified(headers):
            let nextCursor = headers.first { name, _ in
                name.caseInsensitiveCompare("X-Cafe-Orders-Cursor") == .orderedSame
            }.flatMap { Int($0.value) }
            return .notModified(cursor: nextCursor)
        }
    }
}
