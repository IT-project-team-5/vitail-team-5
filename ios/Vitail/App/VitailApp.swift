import SwiftUI

@main
struct VitailApp: App {
    @StateObject private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView(session: session)
        }
    }
}
