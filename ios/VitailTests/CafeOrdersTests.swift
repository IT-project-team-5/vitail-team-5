import XCTest
@testable import Vitail

final class CafeOrdersTests: XCTestCase {
    func testFeedDecodesCafeOrderContractAndFractionalTimestamp() throws {
        let data = #"""
        {
          "cursor": 17,
          "reset": true,
          "upserts": [
            {
              "id": 42,
              "reference_number": "RDM-ABC123",
              "owner_name": "Taylor",
              "items": [
                {"name": "Flat white", "quantity": 2},
                {"name": "Puppuccino", "quantity": 1}
              ],
              "ordered_at": "2026-09-07T03:15:12.123456Z"
            }
          ],
          "removed_ids": [9]
        }
        """#.data(using: .utf8)!

        let feed = try JSONDecoder().decode(CafeOrdersFeed.self, from: data)

        XCTAssertEqual(feed.cursor, 17)
        XCTAssertTrue(feed.reset)
        XCTAssertEqual(feed.removedOrderIDs, [9])
        XCTAssertEqual(feed.orders.first?.referenceNumber, "RDM-ABC123")
        XCTAssertEqual(feed.orders.first?.ownerName, "Taylor")
        XCTAssertEqual(feed.orders.first?.items.count, 2)
        XCTAssertEqual(feed.orders.first?.items.first?.quantity, 2)
    }

    func testFeedDefaultsResetToFalseForOlderResponses() throws {
        let data = #"{"cursor":1,"upserts":[],"removed_ids":[]}"#.data(using: .utf8)!

        let feed = try JSONDecoder().decode(CafeOrdersFeed.self, from: data)

        XCTAssertFalse(feed.reset)
    }

    @MainActor
    func testInitialLoadAndDeltaMergeOrdersByNewestFirst() async {
        let olderOrder = makeOrder(id: 1, minute: 0)
        let existingOrder = makeOrder(id: 2, minute: 1)
        let newOrder = makeOrder(id: 3, minute: 2)
        let service = CafeOrdersServiceStub(responses: [
            .result(
                .updated(
                    CafeOrdersFeed(
                        cursor: 10,
                        orders: [olderOrder, existingOrder],
                        removedOrderIDs: []
                    )
                )
            ),
            .result(
                .updated(
                    CafeOrdersFeed(
                        cursor: 12,
                        orders: [newOrder],
                        removedOrderIDs: [olderOrder.id]
                    )
                )
            )
        ])
        let viewModel = CafeOrdersViewModel(service: service)

        await viewModel.refresh()
        XCTAssertEqual(viewModel.orders.map(\.id), [2, 1])

        await viewModel.refresh()

        XCTAssertEqual(viewModel.orders.map(\.id), [3, 2])
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.hasLoaded)
        let cursors = await service.receivedCursors()
        XCTAssertEqual(cursors.count, 2)
        XCTAssertNil(cursors[0])
        XCTAssertEqual(cursors[1], 10)
    }

    @MainActor
    func testRefreshFailureKeepsLastSuccessfulOrdersVisible() async {
        let order = makeOrder(id: 1, minute: 0)
        let service = CafeOrdersServiceStub(responses: [
            .result(
                .updated(
                    CafeOrdersFeed(cursor: 3, orders: [order], removedOrderIDs: [])
                )
            ),
            .failure(.network("The Internet connection appears to be offline."))
        ])
        let viewModel = CafeOrdersViewModel(service: service)

        await viewModel.refresh()
        await viewModel.refresh()

        XCTAssertEqual(viewModel.orders, [order])
        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertEqual(
            viewModel.errorMessage,
            "The Internet connection appears to be offline."
        )
    }

    @MainActor
    func testNotModifiedResponseAdvancesCursorFromHeaderValue() async {
        let service = CafeOrdersServiceStub(responses: [
            .result(
                .updated(
                    CafeOrdersFeed(cursor: 2, orders: [], removedOrderIDs: [])
                )
            ),
            .result(.notModified(cursor: 8)),
            .result(.notModified(cursor: 8))
        ])
        let viewModel = CafeOrdersViewModel(service: service)

        await viewModel.refresh()
        await viewModel.refresh()
        await viewModel.refresh()

        let cursors = await service.receivedCursors()
        XCTAssertEqual(cursors.count, 3)
        XCTAssertNil(cursors[0])
        XCTAssertEqual(cursors[1], 2)
        XCTAssertEqual(cursors[2], 8)
    }

    @MainActor
    func testResetFeedReplacesPreviouslyCachedOrders() async {
        let staleOrder = makeOrder(id: 1, minute: 0)
        let currentOrder = makeOrder(id: 2, minute: 1)
        let service = CafeOrdersServiceStub(responses: [
            .result(
                .updated(
                    CafeOrdersFeed(
                        cursor: 5,
                        orders: [staleOrder],
                        removedOrderIDs: []
                    )
                )
            ),
            .result(
                .updated(
                    CafeOrdersFeed(
                        cursor: 2,
                        orders: [currentOrder],
                        removedOrderIDs: [],
                        reset: true
                    )
                )
            )
        ])
        let viewModel = CafeOrdersViewModel(service: service)

        await viewModel.refresh()
        await viewModel.refresh()

        XCTAssertEqual(viewModel.orders, [currentOrder])
        let cursors = await service.receivedCursors()
        XCTAssertEqual(cursors.count, 2)
        XCTAssertNil(cursors[0])
        XCTAssertEqual(cursors[1], 5)
    }

    @MainActor
    func testInvalidCursorRetriesOnceWithAFullReload() async {
        let staleOrder = makeOrder(id: 1, minute: 0)
        let currentOrder = makeOrder(id: 2, minute: 1)
        let service = CafeOrdersServiceStub(responses: [
            .result(
                .updated(
                    CafeOrdersFeed(
                        cursor: 9,
                        orders: [staleOrder],
                        removedOrderIDs: []
                    )
                )
            ),
            .failure(.invalidCursor),
            .result(
                .updated(
                    CafeOrdersFeed(
                        cursor: 3,
                        orders: [currentOrder],
                        removedOrderIDs: [],
                        reset: true
                    )
                )
            )
        ])
        let viewModel = CafeOrdersViewModel(service: service)

        await viewModel.refresh()
        await viewModel.refresh()

        XCTAssertEqual(viewModel.orders, [currentOrder])
        XCTAssertNil(viewModel.errorMessage)
        let cursors = await service.receivedCursors()
        XCTAssertEqual(cursors.count, 3)
        XCTAssertNil(cursors[0])
        XCTAssertEqual(cursors[1], 9)
        XCTAssertNil(cursors[2])
    }

    @MainActor
    func testInitialFailureShowsErrorWithoutClaimingLoadCompleted() async {
        let service = CafeOrdersServiceStub(responses: [
            .failure(.http(status: 403, message: "Café access is required."))
        ])
        let viewModel = CafeOrdersViewModel(service: service)

        await viewModel.refresh()

        XCTAssertFalse(viewModel.hasLoaded)
        XCTAssertTrue(viewModel.orders.isEmpty)
        XCTAssertEqual(viewModel.errorMessage, "Café access is required.")
        XCTAssertFalse(viewModel.isInitialLoading)
    }

    @MainActor
    func testPollingIntervalIsFiveSeconds() {
        XCTAssertEqual(CafeOrdersViewModel.pollingIntervalSeconds, 5)
    }

    private func makeOrder(id: Int, minute: TimeInterval) -> CafeOrder {
        CafeOrder(
            id: id,
            referenceNumber: "RDM-\(id)",
            ownerName: "Owner \(id)",
            items: [CafeOrderItem(name: "Coffee", quantity: 1)],
            orderedAt: Date(timeIntervalSince1970: minute * 60)
        )
    }
}

private actor CafeOrdersServiceStub: CafeOrdersServing {
    enum Response: Sendable {
        case result(CafeOrdersFetchResult)
        case failure(APIError)
    }

    private var responses: [Response]
    private var cursors: [Int?] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func fetchOrders(since cursor: Int?) async throws -> CafeOrdersFetchResult {
        cursors.append(cursor)
        guard !responses.isEmpty else {
            throw APIError.invalidResponse
        }

        switch responses.removeFirst() {
        case let .result(result):
            return result
        case let .failure(error):
            throw error
        }
    }

    func receivedCursors() -> [Int?] {
        cursors
    }
}
