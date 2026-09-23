import XCTest
@testable import Vitail

@MainActor
final class CafeProductsTests: XCTestCase {
    func testLoadIncludesUnavailableProductsAndRefreshFailureKeepsMenu() async {
        let service = CafeProductsStub()
        let model = CafeProductsViewModel(service: service)
        await model.load()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.products.count, 2)
        XCTAssertFalse(model.products[1].isAvailable)

        await service.setFetchFailure(true)
        await model.load()
        XCTAssertEqual(model.products.count, 2)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)

        await service.setFetchFailure(false)
        await model.load()
        XCTAssertNil(model.errorMessage)
    }

    func testInitialLoadFailureCanBeRetried() async {
        let service = CafeProductsStub()
        await service.setFetchFailure(true)
        let model = CafeProductsViewModel(service: service)
        await model.load()
        XCTAssertFalse(model.hasLoaded)
        XCTAssertNotNil(model.errorMessage)
        await service.setFetchFailure(false)
        await model.load()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.errorMessage)
    }

    func testFormValidatesRequiredNameLengthsAndWholePointRange() {
        let model = CafeProductsViewModel(service: CafeProductsStub())
        model.startAdding()
        XCTAssertFalse(model.canSave)
        model.name = " \n "
        model.pointCost = "10"
        XCTAssertFalse(model.canSave)
        model.name = String(repeating: "a", count: 101)
        XCTAssertFalse(model.canSave)
        model.name = " " + String(repeating: "a", count: 100) + " "
        XCTAssertTrue(model.canSave)
        model.description = String(repeating: "d", count: 2001)
        XCTAssertFalse(model.canSave)
        model.description = String(repeating: "d", count: 2000)
        XCTAssertTrue(model.canSave)
        for invalid in ["", "0", "-1", "1.5", "+2", "1e3", "2,000", "2147483648", "9999999999999999999999999"] {
            model.pointCost = invalid
            XCTAssertFalse(model.canSave, "Unexpected valid price: \(invalid)")
        }
        for valid in ["1", " 25 ", "2147483647"] {
            model.pointCost = valid
            XCTAssertTrue(model.canSave, "Unexpected invalid price: \(valid)")
        }
    }

    func testInvalidFormNeverSendsCreateRequest() async {
        let service = CafeProductsStub()
        let model = CafeProductsViewModel(service: service)
        model.startAdding()
        model.name = "Coffee"
        model.pointCost = "0"
        await model.save()
        let requests = await service.creates
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(model.isPresentingEditor)
    }

    func testCreateTrimsInputAndAddsServerProductWithoutReload() async {
        let service = CafeProductsStub()
        let model = CafeProductsViewModel(service: service)
        await model.load()
        model.startAdding()
        model.name = "  Iced coffee \n"
        model.description = "  Cold brew  "
        model.pointCost = " 50 "
        model.isAvailable = false
        await model.save()

        let requests = await service.creates
        XCTAssertEqual(requests, [CafeProductRequest(name: "Iced coffee", description: "Cold brew", pointCost: 50, isAvailable: false)])
        XCTAssertEqual(model.products.first?.id, 3)
        XCTAssertEqual(model.products.first?.name, "Iced coffee")
        XCTAssertEqual(model.products.first?.isAvailable, false)
        XCTAssertEqual(model.products.count, 3)
        XCTAssertFalse(model.isPresentingEditor)
        XCTAssertFalse(model.isSaving)
        XCTAssertNil(model.saveErrorMessage)
    }

    func testEditingChangesPriceAndAvailabilityWithoutDuplicatingProduct() async throws {
        let service = CafeProductsStub()
        let model = CafeProductsViewModel(service: service)
        await model.load()
        model.startEditing(try XCTUnwrap(model.products.first))
        XCTAssertEqual(model.name, "Coffee")
        XCTAssertEqual(model.pointCost, "20")
        model.pointCost = "30"
        model.isAvailable = false
        await model.save()

        let updates = await service.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.id, 1)
        XCTAssertEqual(model.products.first?.pointCost, 30)
        XCTAssertEqual(model.products.first?.isAvailable, false)
        XCTAssertEqual(model.products.count, 2)
        let creates = await service.creates
        XCTAssertTrue(creates.isEmpty)
    }

    func testSaveFailurePreservesDraftAndRetryClearsError() async {
        let service = CafeProductsStub()
        await service.setSaveFailure(true)
        let model = CafeProductsViewModel(service: service)
        model.startAdding()
        model.name = "Tea"
        model.description = "English breakfast"
        model.pointCost = "15"
        await model.save()
        XCTAssertTrue(model.isPresentingEditor)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.name, "Tea")
        XCTAssertEqual(model.description, "English breakfast")
        XCTAssertEqual(model.pointCost, "15")
        XCTAssertNotNil(model.saveErrorMessage)
        XCTAssertTrue(model.products.isEmpty)

        await service.setSaveFailure(false)
        await model.save()
        XCTAssertFalse(model.isPresentingEditor)
        XCTAssertNil(model.saveErrorMessage)
        XCTAssertEqual(model.products.count, 1)
    }

    func testAddAfterEditResetsDraftAndCreatesInsteadOfPatching() async throws {
        let service = CafeProductsStub()
        let model = CafeProductsViewModel(service: service)
        await model.load()
        model.startEditing(try XCTUnwrap(model.products.last))
        XCTAssertFalse(model.isAvailable)
        model.isPresentingEditor = false
        model.startAdding()
        XCTAssertNil(model.editingProductID)
        XCTAssertTrue(model.name.isEmpty)
        XCTAssertTrue(model.description.isEmpty)
        XCTAssertTrue(model.pointCost.isEmpty)
        XCTAssertTrue(model.isAvailable)
        model.name = "New product"
        model.pointCost = "10"
        await model.save()
        let creates = await service.creates
        let updates = await service.updates
        XCTAssertEqual(creates.count, 1)
        XCTAssertTrue(updates.isEmpty)
    }
}

private actor CafeProductsStub: CafeProductsServing {
    private var failFetch = false
    private var failSave = false
    var creates: [CafeProductRequest] = []
    var updates: [(id: Int, request: CafeProductRequest)] = []

    func setFetchFailure(_ value: Bool) { failFetch = value }
    func setSaveFailure(_ value: Bool) { failSave = value }

    func fetchProducts() async throws -> [CafeProduct] {
        if failFetch { throw APIError.network("Offline") }
        return [
            CafeProduct(id: 1, name: "Coffee", description: "Hot coffee", pointCost: 20, isAvailable: true),
            CafeProduct(id: 2, name: "Cake", description: "", pointCost: 40, isAvailable: false),
        ]
    }

    func createProduct(_ request: CafeProductRequest) async throws -> CafeProduct {
        creates.append(request)
        if failSave { throw APIError.network("Offline") }
        return product(id: 3, request: request)
    }

    func updateProduct(id: Int, request: CafeProductRequest) async throws -> CafeProduct {
        updates.append((id: id, request: request))
        if failSave { throw APIError.network("Offline") }
        return product(id: id, request: request)
    }

    private func product(id: Int, request: CafeProductRequest) -> CafeProduct {
        CafeProduct(id: id, name: request.name, description: request.description,
                    pointCost: request.pointCost, isAvailable: request.isAvailable)
    }
}
