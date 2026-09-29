import SwiftUI

@main
struct VitailApp: App {
    @StateObject private var session: SessionStore
    private let cafeOrdersService: CafeOrdersService
    private let dogService: DogService
    private let redemptionService: RedemptionService
    private let walkService: WalkService
    private let venueService: VenueService
    private let cafeProfileService: CafeProfileService
    private let cafeProductsService: CafeProductsService

    init() {
        let dependencies = AppDependencies.live()
        _session = StateObject(
            wrappedValue: SessionStore(authService: dependencies.authService)
        )
        cafeOrdersService = dependencies.cafeOrdersService
        dogService = dependencies.dogService
        redemptionService = dependencies.redemptionService
        walkService = dependencies.walkService
        venueService = dependencies.venueService
        cafeProfileService = dependencies.cafeProfileService
        cafeProductsService = dependencies.cafeProductsService
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                session: session,
                cafeOrdersService: cafeOrdersService,
                dogService: dogService,
                redemptionService: redemptionService,
                walkService: walkService,
                venueService: venueService,
                cafeProfileService: cafeProfileService,
                cafeProductsService: cafeProductsService
            )
        }
    }
}
