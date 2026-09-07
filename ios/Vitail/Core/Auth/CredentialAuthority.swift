import Foundation

protocol CredentialStoring: Sendable {
    func load() throws -> AuthTokens?
    func save(_ tokens: AuthTokens) throws
    func delete() throws
}

enum CredentialEvent: Equatable, Sendable {
    case sessionExpired
}

actor CredentialAuthority {
    static let shared = CredentialAuthority()

    struct Lease: Equatable, Sendable {
        let accessToken: String

        fileprivate let tokens: AuthTokens
        fileprivate let generation: UInt64
    }

    typealias RefreshOperation = @Sendable (AuthTokens) async throws -> AuthTokens

    nonisolated let events: AsyncStream<CredentialEvent>

    private struct RefreshState {
        let id: UUID
        let generation: UInt64
        let rejectedTokens: AuthTokens
        let task: Task<AuthTokens, Error>
    }

    private let store: any CredentialStoring
    private let refreshOperation: RefreshOperation
    private let eventContinuation: AsyncStream<CredentialEvent>.Continuation

    private var cachedTokens: AuthTokens?
    private var hasLoadedStore = false
    private var sessionGeneration: UInt64 = 0
    private var refreshState: RefreshState?

    init(
        apiClient: APIClient = APIClient(),
        store: any CredentialStoring = KeychainStore(),
        refreshOperation: RefreshOperation? = nil
    ) {
        let eventChannel = AsyncStream<CredentialEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        events = eventChannel.stream
        eventContinuation = eventChannel.continuation
        self.store = store
        self.refreshOperation = refreshOperation ?? { tokens in
            let response: RefreshResponse = try await apiClient.post(
                "/api/auth/refresh",
                body: RefreshRequest(refresh: tokens.refresh)
            )
            return AuthTokens(
                access: response.access,
                refresh: response.refresh ?? tokens.refresh
            )
        }
    }

    func hasCredentials() throws -> Bool {
        try loadStoreIfNeeded()
        return cachedTokens != nil
    }

    func lease() throws -> Lease {
        try loadStoreIfNeeded()
        guard let cachedTokens else {
            throw APIError.missingSession
        }
        return makeLease(for: cachedTokens)
    }

    func install(_ tokens: AuthTokens) throws {
        try store.save(tokens)
        advanceSession(to: tokens)
    }

    func logout() throws {
        advanceSession(to: nil)
        try store.delete()
    }

    func renew(afterUnauthorized lease: Lease) async throws -> Lease {
        try Task.checkCancellation()
        try loadStoreIfNeeded()

        guard lease.generation == sessionGeneration, let currentTokens = cachedTokens else {
            throw APIError.missingSession
        }

        if currentTokens.access != lease.accessToken {
            return makeLease(for: currentTokens)
        }
        guard currentTokens == lease.tokens else {
            throw APIError.missingSession
        }

        let state: RefreshState
        if let refreshState,
           refreshState.generation == lease.generation,
           refreshState.rejectedTokens == lease.tokens {
            state = refreshState
        } else {
            let refreshOperation = self.refreshOperation
            let rejectedTokens = lease.tokens
            let task = Task {
                try await refreshOperation(rejectedTokens)
            }
            state = RefreshState(
                id: UUID(),
                generation: lease.generation,
                rejectedTokens: rejectedTokens,
                task: task
            )
            refreshState = state
        }

        return try await finishRefresh(state)
    }

    func invalidate(_ lease: Lease) {
        guard
            lease.generation == sessionGeneration,
            cachedTokens?.access == lease.accessToken
        else {
            return
        }

        expireCurrentSession()
    }

    private func finishRefresh(_ state: RefreshState) async throws -> Lease {
        let refreshedTokens: AuthTokens
        do {
            refreshedTokens = try await state.task.value
        } catch {
            return try handleRefreshFailure(error, state: state)
        }

        guard state.generation == sessionGeneration, let currentTokens = cachedTokens else {
            throw APIError.missingSession
        }

        if currentTokens.access != state.rejectedTokens.access {
            return makeLease(for: currentTokens)
        }
        guard
            currentTokens == state.rejectedTokens,
            refreshState?.id == state.id
        else {
            throw APIError.missingSession
        }

        try store.save(refreshedTokens)
        cachedTokens = refreshedTokens
        refreshState = nil
        return makeLease(for: refreshedTokens)
    }

    private func handleRefreshFailure(
        _ error: Error,
        state: RefreshState
    ) throws -> Lease {
        guard state.generation == sessionGeneration else {
            throw APIError.missingSession
        }

        if refreshState?.id == state.id {
            refreshState = nil
        }

        if Self.isTerminalRefreshFailure(error),
           cachedTokens == state.rejectedTokens {
            expireCurrentSession()
            throw APIError.missingSession
        }

        throw error
    }

    private func loadStoreIfNeeded() throws {
        guard !hasLoadedStore else { return }
        cachedTokens = try store.load()
        hasLoadedStore = true
    }

    private func makeLease(for tokens: AuthTokens) -> Lease {
        Lease(
            accessToken: tokens.access,
            tokens: tokens,
            generation: sessionGeneration
        )
    }

    private func advanceSession(to tokens: AuthTokens?) {
        sessionGeneration &+= 1
        refreshState?.task.cancel()
        refreshState = nil
        cachedTokens = tokens
        hasLoadedStore = true
    }

    private func expireCurrentSession() {
        advanceSession(to: nil)
        try? store.delete()
        eventContinuation.yield(.sessionExpired)
    }

    private static func isTerminalRefreshFailure(_ error: Error) -> Bool {
        guard case let APIError.http(status, _) = error else {
            return error as? APIError == .missingSession
        }
        return status == 400 || status == 401 || status == 403
    }
}
