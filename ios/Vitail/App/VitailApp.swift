import SwiftUI

@main
struct VitailApp: App {
    @StateObject private var session: SessionStore
    private let cafeOrdersService: CafeOrdersService
    private let dogService: DogService
    private let redemptionService: RedemptionService
    private let walkService: WalkService
    private let cafeProfileService: CafeProfileService
    private let cafeProductsService: CafeProductsService
    private let questService: QuestService
    private let leaderboardService: LeaderboardService
    private let documentService: DocumentService

    init() {
        let dependencies = AppDependencies.live()
        _session = StateObject(
            wrappedValue: SessionStore(authService: dependencies.authService)
        )
        cafeOrdersService = dependencies.cafeOrdersService
        dogService = dependencies.dogService
        redemptionService = dependencies.redemptionService
        walkService = dependencies.walkService
        cafeProfileService = dependencies.cafeProfileService
        cafeProductsService = dependencies.cafeProductsService
        questService = dependencies.questService
        leaderboardService = dependencies.leaderboardService
        documentService = dependencies.documentService
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                session: session,
                cafeOrdersService: cafeOrdersService,
                dogService: dogService,
                redemptionService: redemptionService,
                walkService: walkService,
                cafeProfileService: cafeProfileService,
                cafeProductsService: cafeProductsService,
                questService: questService,
                leaderboardService: leaderboardService,
                documentService: documentService
            )
        }
    }
}
