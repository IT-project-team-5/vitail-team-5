import SwiftUI

struct RootView: View {
    @ObservedObject var session: SessionStore
    let cafeOrdersService: any CafeOrdersServing
    let dogService: any DogServicing
    let redemptionService: any RedemptionServing
    let walkService: any WalkServing
    let cafeProfileService: any CafeProfileServing

    var body: some View {
        Group {
            switch session.state {
            case .restoring:
                LoadingView(message: "Restoring session…")
            case .signedOut:
                AuthView(session: session)
            case let .signedIn(user):
                destination(for: user)
            case let .restoreFailed(message):
                AppErrorView(
                    message: message,
                    retry: {
                        Task { await session.restore() }
                    },
                    signOut: {
                        Task { await session.logout() }
                    }
                )
            }
        }
        .task {
            if session.state == .restoring {
                await session.restore()
            }
        }
    }

    @ViewBuilder
    private func destination(for user: User) -> some View {
        switch user.role {
        case .owner:
            OwnerHomeView(
                user: user, session: session,
                dogService: dogService, redemptionService: redemptionService,
                walkService: walkService
            )
            .id(user.id)
        case .cafe:
            CafeOrdersView(
                user: user,
                session: session,
                service: cafeOrdersService,
                profileService: cafeProfileService
            )
            .id(user.id)
        case .admin:
            AppErrorView(
                message: APIError.unsupportedRole.localizedDescription,
                retry: {},
                signOut: {
                    Task { await session.logout() }
                }
            )
        }
    }
}
