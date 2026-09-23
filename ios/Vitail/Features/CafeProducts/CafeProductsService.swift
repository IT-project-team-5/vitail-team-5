import Foundation

protocol CafeProductsServing: Sendable {
    func fetchProducts() async throws -> [CafeProduct]
    func createProduct(_ request: CafeProductRequest) async throws -> CafeProduct
    func updateProduct(id: Int, request: CafeProductRequest) async throws -> CafeProduct
}

actor CafeProductsService: CafeProductsServing {
    private let apiClient: AuthenticatedAPIClient

    init(apiClient: AuthenticatedAPIClient = AuthenticatedAPIClient()) {
        self.apiClient = apiClient
    }

    func fetchProducts() async throws -> [CafeProduct] {
        try await apiClient.get("/api/cafe/products")
    }

    func createProduct(_ request: CafeProductRequest) async throws -> CafeProduct {
        try await apiClient.post("/api/cafe/products", body: request)
    }

    func updateProduct(id: Int, request: CafeProductRequest) async throws -> CafeProduct {
        try await apiClient.patch("/api/cafe/products/\(id)", body: request)
    }
}
