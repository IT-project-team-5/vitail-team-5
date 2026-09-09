import Foundation
import XCTest
@testable import Vitail

final class CredentialAuthorityTests: XCTestCase {
    func testConcurrentUnauthorizedRequestsShareOneRefresh() async throws {
        let oldTokens = makeTokens("old")
        let newTokens = makeTokens("new")
        let store = InMemoryCredentialStore(tokens: oldTokens)
        let probe = RefreshProbe(result: .success(newTokens))
        let authority = makeAuthority(store: store, probe: probe)
        let lease = try await authority.lease()

        async let first = authority.renew(afterUnauthorized: lease)
        async let second = authority.renew(afterUnauthorized: lease)
        await probe.waitUntilStarted()
        await probe.release()

        let (firstLease, secondLease) = try await (first, second)
        let refreshCount = await probe.callCount()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(firstLease.accessToken, newTokens.access)
        XCTAssertEqual(secondLease.accessToken, newTokens.access)
        XCTAssertEqual(store.savedTokens(), newTokens)
        XCTAssertEqual(store.saveCount(), 1)
    }

    func testLogoutWhileRefreshIsInFlightCannotRestoreCredentials() async throws {
        let oldTokens = makeTokens("old")
        let store = InMemoryCredentialStore(tokens: oldTokens)
        let probe = RefreshProbe(result: .success(makeTokens("stale-refresh")))
        let authority = makeAuthority(store: store, probe: probe)
        let lease = try await authority.lease()
        let renewal = Task {
            try await authority.renew(afterUnauthorized: lease)
        }

        await probe.waitUntilStarted()
        try await authority.logout()
        await probe.release()

        do {
            _ = try await renewal.value
            XCTFail("A refresh from a logged-out session must not be committed.")
        } catch {
            XCTAssertEqual(error as? APIError, .missingSession)
        }
        XCTAssertNil(store.savedTokens())
        XCTAssertEqual(store.saveCount(), 0)
    }

    func testNewLoginCannotBeOverwrittenByOlderRefresh() async throws {
        let oldTokens = makeTokens("old")
        let replacementTokens = makeTokens("replacement")
        let store = InMemoryCredentialStore(tokens: oldTokens)
        let probe = RefreshProbe(result: .success(makeTokens("stale-refresh")))
        let authority = makeAuthority(store: store, probe: probe)
        let oldLease = try await authority.lease()
        let renewal = Task {
            try await authority.renew(afterUnauthorized: oldLease)
        }

        await probe.waitUntilStarted()
        try await authority.install(replacementTokens)
        await probe.release()

        do {
            _ = try await renewal.value
            XCTFail("A refresh from a replaced session must be rejected.")
        } catch {
            XCTAssertEqual(error as? APIError, .missingSession)
        }
        XCTAssertEqual(store.savedTokens(), replacementTokens)
        XCTAssertEqual(store.saveCount(), 1)
    }

    func testTerminalRefreshFailureClearsCredentialsAndEmitsExpiry() async throws {
        let oldTokens = makeTokens("old")
        let store = InMemoryCredentialStore(tokens: oldTokens)
        let probe = RefreshProbe(
            result: .failure(.http(status: 401, message: "Token is invalid or expired."))
        )
        let authority = makeAuthority(store: store, probe: probe)
        let lease = try await authority.lease()
        let eventTask = Task {
            var iterator = authority.events.makeAsyncIterator()
            return await iterator.next()
        }
        let renewal = Task {
            try await authority.renew(afterUnauthorized: lease)
        }

        await probe.waitUntilStarted()
        await probe.release()

        do {
            _ = try await renewal.value
            XCTFail("An invalid refresh token must expire the session.")
        } catch {
            XCTAssertEqual(error as? APIError, .missingSession)
        }
        let event = await eventTask.value
        XCTAssertEqual(event, .sessionExpired)
        XCTAssertNil(store.savedTokens())
        XCTAssertEqual(store.deleteCount(), 1)
    }

    func testTransientRefreshFailureKeepsCredentials() async throws {
        let oldTokens = makeTokens("old")
        let store = InMemoryCredentialStore(tokens: oldTokens)
        let probe = RefreshProbe(result: .failure(.network("Offline")))
        let authority = makeAuthority(store: store, probe: probe)
        let lease = try await authority.lease()
        let renewal = Task {
            try await authority.renew(afterUnauthorized: lease)
        }

        await probe.waitUntilStarted()
        await probe.release()

        do {
            _ = try await renewal.value
            XCTFail("A transient refresh failure should be surfaced.")
        } catch {
            XCTAssertEqual(error as? APIError, .network("Offline"))
        }
        XCTAssertEqual(store.savedTokens(), oldTokens)
        XCTAssertEqual(store.deleteCount(), 0)
    }

    func testOldLeaseCannotInvalidateReplacementSession() async throws {
        let oldTokens = makeTokens("old")
        let replacementTokens = makeTokens("replacement")
        let store = InMemoryCredentialStore(tokens: oldTokens)
        let authority = CredentialAuthority(
            store: store,
            refreshOperation: { _ in replacementTokens }
        )
        let oldLease = try await authority.lease()

        try await authority.install(replacementTokens)
        await authority.invalidate(oldLease)

        XCTAssertEqual(store.savedTokens(), replacementTokens)
        XCTAssertEqual(store.deleteCount(), 0)
    }

    @MainActor
    func testSessionStoreSignsOutWhenCredentialsExpire() async {
        let user = User(
            id: 1,
            email: "cafe@example.com",
            displayName: "Cafe",
            role: .cafe
        )
        let authService = AuthServingStub(restoredUser: user)
        let session = SessionStore(authService: authService)

        await session.restore()
        XCTAssertEqual(session.state, .signedIn(user))

        await authService.expireSession()
        for _ in 0..<20 where session.state != .signedOut {
            await Task.yield()
        }

        XCTAssertEqual(session.state, .signedOut)
    }

    private func makeAuthority(
        store: InMemoryCredentialStore,
        probe: RefreshProbe
    ) -> CredentialAuthority {
        CredentialAuthority(
            store: store,
            refreshOperation: { tokens in
                try await probe.refresh(tokens)
            }
        )
    }

    private func makeTokens(_ suffix: String) -> AuthTokens {
        AuthTokens(
            access: "access-\(suffix)", refresh: "refresh-\(suffix)",
            backendURL: AppConfiguration.apiBaseURL?.absoluteString
        )
    }
}

private final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?
    private var saves = 0
    private var deletions = 0

    init(tokens: AuthTokens?) {
        self.tokens = tokens
    }

    func load() throws -> AuthTokens? {
        withLock { tokens }
    }

    func save(_ tokens: AuthTokens) throws {
        withLock {
            self.tokens = tokens
            saves += 1
        }
    }

    func delete() throws {
        withLock {
            tokens = nil
            deletions += 1
        }
    }

    func savedTokens() -> AuthTokens? {
        withLock { tokens }
    }

    func saveCount() -> Int {
        withLock { saves }
    }

    func deleteCount() -> Int {
        withLock { deletions }
    }

    private func withLock<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private actor RefreshProbe {
    private let result: Result<AuthTokens, APIError>
    private var calls = 0
    private var hasBeenReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: Result<AuthTokens, APIError>) {
        self.result = result
    }

    func refresh(_ tokens: AuthTokens) async throws -> AuthTokens {
        calls += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        if !hasBeenReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return try result.get()
    }

    func waitUntilStarted() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        hasBeenReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func callCount() -> Int {
        calls
    }
}

private actor AuthServingStub: AuthServing {
    nonisolated let credentialEvents: AsyncStream<CredentialEvent>

    private let eventContinuation: AsyncStream<CredentialEvent>.Continuation
    private let restoredUser: User?

    init(restoredUser: User?) {
        let eventChannel = AsyncStream<CredentialEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        credentialEvents = eventChannel.stream
        eventContinuation = eventChannel.continuation
        self.restoredUser = restoredUser
    }

    func login(email: String, password: String) async throws -> AuthResponse {
        throw APIError.invalidResponse
    }

    func register(
        email: String,
        password: String,
        displayName: String
    ) async throws -> AuthResponse {
        throw APIError.invalidResponse
    }

    func persist(_ tokens: AuthTokens) async throws {}

    func restoreUser() async throws -> User? {
        restoredUser
    }

    func clearSession() async throws {}

    func updateProfile(displayName: String) async throws -> User {
        throw APIError.invalidResponse
    }

    func expireSession() {
        eventContinuation.yield(.sessionExpired)
    }
}
