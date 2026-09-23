import Combine
import Foundation

@MainActor
final class CafeProductsViewModel: ObservableObject {
    @Published private(set) var products: [CafeProduct] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var saveErrorMessage: String?
    @Published private(set) var editingProductID: Int?
    @Published var isPresentingEditor = false
    @Published var name = ""
    @Published var description = ""
    @Published var pointCost = ""
    @Published var isAvailable = true

    private let service: any CafeProductsServing

    init(service: any CafeProductsServing = CafeProductsService()) {
        self.service = service
    }

    var validationMessage: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return "Enter a product name." }
        if trimmedName.count > 100 { return "Product name must be 100 characters or fewer." }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).count > 2000 {
            return "Description must be 2,000 characters or fewer."
        }
        if validatedPointCost == nil {
            return "Enter a whole-number point price between 1 and 2,147,483,647."
        }
        return nil
    }

    var canSave: Bool {
        isPresentingEditor && validationMessage == nil && !isSaving && !isLoading
    }

    private var validatedPointCost: Int? {
        let value = pointCost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let points = Int(value), (1...2_147_483_647).contains(points) else { return nil }
        return points
    }

    func load() async {
        guard !isLoading, !isSaving, !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await service.fetchProducts()
            try Task.checkCancellation()
            products = response
            hasLoaded = true
            errorMessage = nil
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    func startAdding() {
        guard !isSaving else { return }
        editingProductID = nil
        name = ""
        description = ""
        pointCost = ""
        isAvailable = true
        saveErrorMessage = nil
        isPresentingEditor = true
    }

    func startEditing(_ product: CafeProduct) {
        guard !isSaving else { return }
        editingProductID = product.id
        name = product.name
        description = product.description
        pointCost = String(product.pointCost)
        isAvailable = product.isAvailable
        saveErrorMessage = nil
        isPresentingEditor = true
    }

    func save() async {
        guard canSave, let points = validatedPointCost, !Task.isCancelled else { return }
        isSaving = true
        saveErrorMessage = nil
        defer { isSaving = false }
        let request = CafeProductRequest(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            pointCost: points,
            isAvailable: isAvailable
        )
        do {
            let saved: CafeProduct
            if let editingProductID {
                saved = try await service.updateProduct(id: editingProductID, request: request)
            } else {
                saved = try await service.createProduct(request)
            }
            try Task.checkCancellation()
            if let index = products.firstIndex(where: { $0.id == saved.id }) {
                products[index] = saved
            } else {
                products.insert(saved, at: 0)
            }
            isPresentingEditor = false
        } catch {
            if !Task.isCancelled { saveErrorMessage = error.localizedDescription }
        }
    }
}
