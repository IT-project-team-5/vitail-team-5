import SwiftUI

@main
struct VitailApp: App {
    @StateObject private var session: SessionStore
    private let cafeOrdersService: CafeOrdersService
    private let dogService: DogService
    private let redemptionService: RedemptionService
    private let walkService: WalkService
    private let venueCheckInService: VenueCheckInService
    private let walkVenueCheckInService: WalkVenueCheckInService
    private let checkInProgressService: CheckInProgressService
    private let cafeProfileService: CafeProfileService
    private let cafeProductsService: CafeProductsService
    private let questService: QuestService
    private let documentService: DocumentService
    private let friendsService: FriendsService

    init() {
        let dependencies = AppDependencies.live()
        _session = StateObject(
            wrappedValue: SessionStore(authService: dependencies.authService)
        )
        cafeOrdersService = dependencies.cafeOrdersService
        dogService = dependencies.dogService
        redemptionService = dependencies.redemptionService
        walkService = dependencies.walkService
        venueCheckInService = dependencies.venueCheckInService
        walkVenueCheckInService = dependencies.walkVenueCheckInService
        checkInProgressService = dependencies.checkInProgressService
        cafeProfileService = dependencies.cafeProfileService
        cafeProductsService = dependencies.cafeProductsService
        questService = dependencies.questService
        documentService = dependencies.documentService
        friendsService = dependencies.friendsService
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                session: session,
                cafeOrdersService: cafeOrdersService,
                dogService: dogService,
                redemptionService: redemptionService,
                walkService: walkService,
                venueCheckInService: venueCheckInService,
                checkInProgressService: checkInProgressService,
                cafeProfileService: cafeProfileService,
                cafeProductsService: cafeProductsService,
                questService: questService,
                documentService: documentService,
                friendsService: friendsService,
                walkVenueCheckInService: walkVenueCheckInService
            )
        }
    }
}
