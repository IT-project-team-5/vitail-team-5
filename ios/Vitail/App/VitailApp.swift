import SwiftUI

@main
struct VitailApp: App {
    @StateObject private var session: SessionStore
    private let cafeOrdersService: CafeOrdersService

    init() {
        let dependencies = AppDependencies.live()
        _session = StateObject(
            wrappedValue: SessionStore(authService: dependencies.authService)
        )
        cafeOrdersService = dependencies.cafeOrdersService
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                session: session,
                cafeOrdersService: cafeOrdersService
            )
        }
    }
}
