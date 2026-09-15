import Foundation

struct AppDependencies: Sendable {
    let authService: AuthService
    let cafeOrdersService: CafeOrdersService
    let dogService: DogService
    let redemptionService: RedemptionService
    let walkService: WalkService
    let cafeProfileService: CafeProfileService

    static func live() -> AppDependencies {
        let apiClient = APIClient()
        let credentials = CredentialAuthority(
            apiClient: apiClient,
            store: KeychainStore()
        )
        let authenticatedAPIClient = AuthenticatedAPIClient(
            apiClient: apiClient,
            credentials: credentials
        )

        return AppDependencies(
            authService: AuthService(
                apiClient: apiClient,
                authenticatedAPIClient: authenticatedAPIClient,
                credentials: credentials
            ),
            cafeOrdersService: CafeOrdersService(apiClient: authenticatedAPIClient),
            dogService: DogService(apiClient: authenticatedAPIClient),
            redemptionService: RedemptionService(apiClient: authenticatedAPIClient),
            walkService: WalkService(apiClient: authenticatedAPIClient),
            cafeProfileService: CafeProfileService(apiClient: authenticatedAPIClient)
        )
    }
}
