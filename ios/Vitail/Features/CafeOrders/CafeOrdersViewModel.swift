import Combine
import Foundation

@MainActor
final class CafeOrdersViewModel: ObservableObject {
    static let pollingIntervalSeconds: UInt64 = 5

    @Published private(set) var orders: [CafeOrder] = []
    @Published private(set) var isInitialLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdatedAt: Date?

    private let service: any CafeOrdersServing
    private var cursor: Int?
    private var isRefreshing = false

    init(service: any CafeOrdersServing = CafeOrdersService()) {
        self.service = service
    }

    func pollWhileVisible() async {
        await refresh()

        while !Task.isCancelled {
            do {
                try await Task.sleep(
                    nanoseconds: Self.pollingIntervalSeconds * 1_000_000_000
                )
            } catch {
                return
            }

            await refresh()
        }
    }

    func refresh() async {
        guard !isRefreshing, !Task.isCancelled else { return }

        isRefreshing = true
        if !hasLoaded {
            isInitialLoading = true
        }
        defer {
            isRefreshing = false
            isInitialLoading = false
        }

        var requestedCursor = cursor

        do {
            let result: CafeOrdersFetchResult
            do {
                result = try await service.fetchOrders(since: requestedCursor)
            } catch APIError.invalidCursor where requestedCursor != nil {
                cursor = nil
                requestedCursor = nil
                result = try await service.fetchOrders(since: nil)
            }
            guard !Task.isCancelled else { return }

            switch result {
            case let .updated(feed):
                apply(
                    feed,
                    replacingAll: requestedCursor == nil || feed.reset
                )
            case let .notModified(nextCursor):
                if let nextCursor {
                    cursor = nextCursor
                }
            }

            hasLoaded = true
            errorMessage = nil
            lastUpdatedAt = Date()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ feed: CafeOrdersFeed, replacingAll: Bool) {
        var ordersByID: [Int: CafeOrder]

        if replacingAll {
            ordersByID = [:]
        } else {
            ordersByID = Dictionary(
                orders.map { ($0.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
        }

        for order in feed.orders {
            ordersByID[order.id] = order
        }
        for removedOrderID in feed.removedOrderIDs {
            ordersByID.removeValue(forKey: removedOrderID)
        }

        orders = ordersByID.values.sorted {
            if $0.orderedAt == $1.orderedAt {
                return $0.id > $1.id
            }
            return $0.orderedAt > $1.orderedAt
        }
        cursor = feed.cursor
    }
}
