import Foundation
import XCTest
@testable import Vitail

final class APIIntegrationTests: XCTestCase {
    override func tearDown() {
        IntegrationURLProtocol.handler = nil
        super.tearDown()
    }

    func testAuthenticatedMethodsShareRefreshAndPreserveTrailingSlash() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = APIClient(baseURL: URL(string: "https://test.example"), session: session)
        let store = IntegrationTokenStore()
        let authority = CredentialAuthority(apiClient: client, store: store)
        try await authority.install(AuthTokens(access: "old", refresh: "refresh"))
        let authenticated = AuthenticatedAPIClient(apiClient: client, credentials: authority)
        let calls = RequestLog()
        IntegrationURLProtocol.handler = { request in
            calls.add(request)
            if request.url?.path == "/api/auth/refresh" {
                return (200, #"{"access":"new"}"#)
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
                return (401, #"{"detail":"Expired"}"#)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new")
            return request.httpMethod == "DELETE" ? (204, "") : (200, #"{"balance":50}"#)
        }

        let balance: WalletBalance = try await authenticated.get("/api/wallet/")
        XCTAssertEqual(balance.balance, 50)
        let _: WalletBalance = try await authenticated.post("/api/redemptions/", body: EmptyRequestBody())
        let _: WalletBalance = try await authenticated.patch("/api/auth/me", body: EmptyRequestBody())
        try await authenticated.delete("/api/dogs/1")

        XCTAssertEqual(calls.requests.filter { $0.url?.path == "/api/auth/refresh" }.count, 1)
        XCTAssertTrue(calls.requests.contains { $0.url?.absoluteString == "https://test.example/api/redemptions/" })
        XCTAssertEqual(store.load()?.access, "new")
    }

    func testUnboundLegacyCredentialsAreNotSentToAnyBackend() async throws {
        let store = IntegrationTokenStore()
        store.save(AuthTokens(access: "legacy", refresh: "legacy"))
        let authority = CredentialAuthority(store: store)
        do {
            _ = try await authority.lease()
            XCTFail("Legacy credentials must require a new login.")
        } catch {
            XCTAssertEqual(error as? APIError, .missingSession)
        }
        XCTAssertNil(store.load())
    }

    func testProfileDogAndCafeServicesUseInjectedAuthenticatedClient() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = APIClient(baseURL: URL(string: "https://shared.example"), session: session)
        let authority = CredentialAuthority(apiClient: client, store: IntegrationTokenStore())
        try await authority.install(AuthTokens(access: "shared-token", refresh: "refresh"))
        let authenticated = AuthenticatedAPIClient(apiClient: client, credentials: authority)
        let auth = AuthService(apiClient: client, authenticatedAPIClient: authenticated, credentials: authority)
        let dogs = DogService(apiClient: authenticated)
        let cafe = CafeOrdersService(apiClient: authenticated)
        let cafeProfile = CafeProfileService(apiClient: authenticated)
        let calls = RequestLog()
        IntegrationURLProtocol.handler = { request in
            calls.add(request)
            XCTAssertEqual(request.url?.host, "shared.example")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer shared-token")
            switch request.url?.path {
            case "/api/auth/me":
                XCTAssertEqual(request.httpMethod, "PATCH")
                return (200, #"{"id":1,"email":"owner@example.com","display_name":"Updated","role":"OWNER"}"#)
            case "/api/dogs":
                return (200, "[]")
            case "/api/dogs/1":
                XCTAssertEqual(request.httpMethod, "DELETE")
                return (204, "")
            case "/api/cafe/orders":
                XCTAssertEqual(request.url?.query, "since=4")
                return (200, #"{"cursor":5,"upserts":[],"removed_ids":[3]}"#)
            case "/api/cafe/profile":
                XCTAssertTrue(["GET", "PATCH"].contains(request.httpMethod ?? ""))
                return (200, #"{"name":"Updated Cafe","email":"cafe@example.com","address":"Main St","description":"Dog friendly","opening_hours":"Daily 7–3"}"#)
            default:
                XCTFail("Unexpected request")
                return (404, "{}")
            }
        }
        let updated = try await auth.updateProfile(displayName: "Updated")
        XCTAssertEqual(updated.displayName, "Updated")
        let dogList = try await dogs.getDogs()
        XCTAssertTrue(dogList.isEmpty)
        try await dogs.deleteDog(id: 1)
        let feed = try await cafe.fetchOrders(since: 4)
        XCTAssertEqual(feed, .updated(CafeOrdersFeed(cursor: 5, orders: [], removedOrderIDs: [3])))
        let profile = try await cafeProfile.getProfile()
        XCTAssertEqual(profile.email, "cafe@example.com")
        let savedProfile = try await cafeProfile.updateProfile(CafeProfileRequest(
            name: "Updated Cafe", address: "Main St",
            description: "Dog friendly", openingHours: "Daily 7–3"
        ))
        XCTAssertEqual(savedProfile.name, "Updated Cafe")
        XCTAssertEqual(calls.requests.count, 6)
    }

    #if DEBUG
    func testBackendSwitchRejectsOldCredentialsBeforeSending() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: AppConfiguration.debugAPIBaseURLKey)
        defer { restore(original) }
        try AppConfiguration.saveDebugAPIBaseURL("https://first.example")
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)
        let store = IntegrationTokenStore()
        let authority = CredentialAuthority(apiClient: client, store: store)
        try await authority.install(AuthTokens(access: "first-token", refresh: "refresh"))
        let authenticated = AuthenticatedAPIClient(apiClient: client, credentials: authority)
        IntegrationURLProtocol.handler = { _ in
            XCTFail("No old credentials should reach the newly selected server.")
            return (200, #"{"balance":50}"#)
        }

        try AppConfiguration.saveDebugAPIBaseURL("https://second.example")
        do {
            let _: WalletBalance = try await authenticated.get("/api/wallet/")
            XCTFail("Switching backend must require a new login.")
        } catch {
            XCTAssertEqual(error as? APIError, .missingSession)
        }
        XCTAssertNil(store.load())

        // The same dependencies are reusable after signing in to the new backend.
        try await authority.install(AuthTokens(access: "second-token", refresh: "refresh"))
        IntegrationURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "second.example")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer second-token")
            return (200, #"{"balance":50}"#)
        }
        let balance: WalletBalance = try await authenticated.get("/api/wallet/")
        XCTAssertEqual(balance.balance, 50)
    }

    func testBackendSwitchDuringRequestDiscardsResponse() async throws {
        let original = UserDefaults.standard.object(forKey: AppConfiguration.debugAPIBaseURLKey)
        defer { restore(original) }
        try AppConfiguration.saveDebugAPIBaseURL("https://first.example")
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = APIClient(session: session)
        let authority = CredentialAuthority(apiClient: client, store: IntegrationTokenStore())
        try await authority.install(AuthTokens(access: "old", refresh: "refresh"))
        let authenticated = AuthenticatedAPIClient(apiClient: client, credentials: authority)
        IntegrationURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "first.example")
            try! AppConfiguration.saveDebugAPIBaseURL("https://second.example")
            return (200, #"{"balance":50}"#)
        }
        do {
            let _: WalletBalance = try await authenticated.get("/api/wallet/")
            XCTFail("A response from the previous backend must not update the new session.")
        } catch {
            XCTAssertEqual(error as? APIError, .missingSession)
        }
    }

    private func restore(_ value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: AppConfiguration.debugAPIBaseURLKey)
        } else {
            AppConfiguration.resetDebugAPIBaseURL()
        }
    }
    #endif

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IntegrationURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class IntegrationTokenStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?
    func load() -> AuthTokens? { lock.withLock { tokens } }
    func save(_ tokens: AuthTokens) { lock.withLock { self.tokens = tokens } }
    func delete() { lock.withLock { tokens = nil } }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { storedRequests } }
    func add(_ request: URLRequest) { lock.withLock { storedRequests.append(request) } }
}

private final class IntegrationURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: APIError.invalidResponse)
            return
        }
        let (status, json) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
