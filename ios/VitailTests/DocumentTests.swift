import XCTest
@testable import Vitail

final class DocumentTests: XCTestCase {
    func testRequestPreservesDateOnlyValuesAndEncodesFileInBase64() throws {
        let draft = DocumentDraft(
            dogID: 7, kind: .microchip, registrationNumber: "ABC-42",
            eventDate: nil, validFrom: "2026-01-01", validTo: "2026-12-31",
            filename: "Registration.pdf", fileData: Data([1, 2, 3])
        )
        let id = UUID()
        let request = DocumentRequest(draft: draft, requestID: id)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(json["dog_id"] as? Int, 7)
        XCTAssertEqual(json["kind"] as? String, "MICROCHIP_REGISTRATION")
        XCTAssertEqual(json["valid_from"] as? String, "2026-01-01")
        XCTAssertEqual(json["valid_to"] as? String, "2026-12-31")
        XCTAssertEqual(json["file_base64"] as? String, "AQID")
        XCTAssertEqual((json["request_id"] as? String).flatMap(UUID.init(uuidString:)), id)
        XCTAssertNil(json["event_date"])
    }

    func testSelfReportedReceiptDecodesWithoutVerifiedState() throws {
        let data = #"""
        {"submission":{"id":1,"request_id":"11111111-1111-1111-1111-111111111111",
        "dog_id":7,"dog_name":"Coco","kind":"COUNCIL_REGISTRATION","status":"SELF_REPORTED",
        "registration_number":"ABC-42","event_date":null,"valid_from":null,"valid_to":null,
        "filename":"","file_url":null,"awarded_points":300,"submitted_at":"2026-09-25T01:00:00Z"},
        "balance":400,"awarded_points":300,"created":true}
        """#.data(using: .utf8)!
        let receipt = try JSONDecoder().decode(DocumentReceipt.self, from: data)
        XCTAssertEqual(receipt.awardedPoints, 300)
        XCTAssertEqual(receipt.submission.status, "SELF_REPORTED")
        XCTAssertNil(receipt.submission.fileURL)
    }

    @MainActor
    func testRetryAfterAmbiguousFailureReusesRequestID() async {
        let service = DocumentServiceStub()
        let model = DocumentViewModel(service: service)
        let draft = makeDraft(number: "ABC-42")
        let first = await model.submit(draft)
        let second = await model.submit(draft)
        XCTAssertFalse(first)
        XCTAssertTrue(second)
        let requests = await service.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].requestID, requests[1].requestID)
        XCTAssertEqual(model.receipt?.awardedPoints, 300)
        XCTAssertFalse(model.isSubmitting)
    }

    @MainActor
    func testEditedEvidenceUsesNewRequestIDAfterFailure() async {
        let service = DocumentServiceStub()
        let model = DocumentViewModel(service: service)
        _ = await model.submit(makeDraft(number: "ABC-42"))
        _ = await model.submit(makeDraft(number: "Changed"))
        let requests = await service.requests
        XCTAssertNotEqual(requests[0].requestID, requests[1].requestID)
    }

    @MainActor
    func testSubmissionFromPreviousOwnerCannotPublishOrReloadNewOwnerDocuments() async throws {
        let session = await makeSession()
        let service = DocumentControlledService()
        await service.pause("submit")
        let model = DocumentViewModel(service: service, session: session)
        let task = Task { await model.submit(makeDraft(number: "ABC-42")) }
        await service.waitFor("submit")
        await session.logout()
        try await session.login(email: "other@example.com", password: "unused", expectedRole: .owner)
        await service.release("submit")
        let succeeded = await task.value
        XCTAssertFalse(succeeded)
        XCTAssertFalse(model.isActive)
        XCTAssertNil(model.receipt)
        XCTAssertNil(model.dashboard)
        XCTAssertNil(model.errorMessage)
        await model.load()
        let fetchCount = await service.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    @MainActor
    func testSignOutTerminatesLoadEvenWhenSameOwnerSignsBackIn() async throws {
        let session = await makeSession()
        let service = DocumentControlledService()
        await service.pause("fetch")
        let model = DocumentViewModel(service: service, session: session)
        let task = Task { await model.load() }
        await service.waitFor("fetch")
        await session.logout()
        try await session.login(email: "owner@example.com", password: "unused", expectedRole: .owner)
        await service.release("fetch")
        await task.value
        XCTAssertFalse(model.isActive)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.dashboard)
        await model.load()
        let fetchCount = await service.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    @MainActor
    func testAttachmentResponseIsDiscardedAfterSessionEnds() async throws {
        let session = await makeSession()
        let service = DocumentControlledService()
        let model = DocumentViewModel(service: service, session: session)
        _ = await model.submit(makeDraft(number: "ABC-42"))
        let submission = try XCTUnwrap(model.receipt?.submission)
        await service.pause("download")
        let task = Task { try await model.download(submission) }
        await service.waitFor("download")
        await session.logout()
        await service.release("download")
        do {
            _ = try await task.value
            XCTFail("A previous account's attachment must not be returned")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(model.receipt)
        XCTAssertNil(model.dashboard)
    }

    @MainActor
    func testInvalidReceiptsDoNotReportSuccessOrRefreshDocuments() async {
        for fault in DocumentReceiptFault.allCases {
            let service = DocumentControlledService(fault: fault)
            let model = DocumentViewModel(service: service)
            let succeeded = await model.submit(makeDraft(number: "ABC-42"))
            XCTAssertFalse(succeeded, "Accepted invalid \(fault) receipt")
            XCTAssertNil(model.receipt)
            XCTAssertNotNil(model.errorMessage)
            let fetchCount = await service.fetchCount
            XCTAssertEqual(fetchCount, 0)
        }
    }

    @MainActor
    func testZeroPointReuploadReceiptIsAccepted() async {
        let service = DocumentControlledService(award: 0)
        let model = DocumentViewModel(service: service)
        let succeeded = await model.submit(makeDraft(number: "ABC-42"))
        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.receipt?.awardedPoints, 0)
    }

    @MainActor
    func testConfirmedSubmissionSurvivesHistoryRefreshFailure() async {
        let service = DocumentControlledService()
        await service.failNextFetch()
        let model = DocumentViewModel(service: service)
        let succeeded = await model.submit(makeDraft(number: "ABC-42"))
        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.receipt?.awardedPoints, 300)
        XCTAssertEqual(model.errorMessage, "Your evidence was submitted. Refresh to update your documents.")
        await model.load()
        XCTAssertNotNil(model.dashboard)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.receipt?.awardedPoints, 300)
    }

    @MainActor
    func testSuccessfulLoadClearsEarlierErrorAndStopPermanentlyClearsData() async {
        let service = DocumentControlledService()
        await service.failNextFetch()
        let model = DocumentViewModel(service: service)
        await model.load()
        XCTAssertNotNil(model.errorMessage)
        await model.load()
        XCTAssertNotNil(model.dashboard)
        XCTAssertNil(model.errorMessage)
        model.stop()
        XCTAssertNil(model.dashboard)
        await model.load()
        let submitted = await model.submit(makeDraft(number: "ABC-42"))
        XCTAssertFalse(submitted)
        XCTAssertNil(model.receipt)
        let fetchCount = await service.fetchCount
        let requests = await service.requests
        XCTAssertEqual(fetchCount, 2)
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    private func makeSession() async -> SessionStore {
        let session = SessionStore(authService: DocumentAuthFixture())
        await session.restore()
        return session
    }

    private func makeDraft(number: String) -> DocumentDraft {
        DocumentDraft(dogID: 7, kind: .council, registrationNumber: number,
                      eventDate: nil, validFrom: nil, validTo: nil, filename: nil, fileData: nil)
    }
}

private actor DocumentAuthFixture: AuthServing {
    nonisolated let credentialEvents = AsyncStream<CredentialEvent> { _ in }
    func restoreUser() async throws -> User? {
        User(id: 1, email: "owner@example.com", displayName: "Owner", role: .owner)
    }
    func login(email: String, password: String) async throws -> AuthResponse {
        AuthResponse(access: "unused", refresh: "unused", user: User(
            id: email == "other@example.com" ? 2 : 1, email: email, displayName: "Owner", role: .owner
        ))
    }
    func register(email: String, password: String, displayName: String) async throws -> AuthResponse {
        throw APIError.invalidResponse
    }
    func persist(_ tokens: AuthTokens) async throws {}
    func clearSession() async throws {}
    func updateProfile(displayName: String) async throws -> User { throw APIError.invalidResponse }
}

private enum DocumentReceiptFault: CaseIterable, Sendable {
    case id, request, dog, kind, status, date, amount, submissionAmount, balance
}

private actor DocumentControlledService: DocumentServing {
    private(set) var requests: [DocumentRequest] = []
    private(set) var fetchCount = 0
    private let fault: DocumentReceiptFault?
    private let award: Int
    private var failFetch = false
    private var paused: Set<String> = []
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var started: [String: CheckedContinuation<Void, Never>] = [:]

    init(fault: DocumentReceiptFault? = nil, award: Int = 300) {
        self.fault = fault
        self.award = award
    }
    func fetchDocuments() async throws -> DocumentDashboard {
        fetchCount += 1
        await suspendIfNeeded("fetch")
        if failFetch { failFetch = false; throw APIError.network("Connection lost") }
        return DocumentDashboard(dogs: [DocumentDog(id: 7, name: "Coco", photo: nil)], submissions: [], eligibility: [])
    }
    func submit(_ request: DocumentRequest) async throws -> DocumentReceipt {
        requests.append(request)
        await suspendIfNeeded("submit")
        let amount = fault == .amount ? 999 : award
        return DocumentReceipt(submission: DocumentSubmission(
            id: fault == .id ? 0 : 1,
            requestID: fault == .request ? UUID() : request.requestID,
            dogID: fault == .dog ? 8 : request.dogID, dogName: "Coco",
            kind: fault == .kind ? .vet : request.kind,
            status: fault == .status ? "VERIFIED" : "SELF_REPORTED",
            registrationNumber: request.registrationNumber ?? "",
            eventDate: fault == .date ? "2026-01-01" : request.eventDate,
            validFrom: request.validFrom, validTo: request.validTo,
            filename: "", fileURL: nil,
            awardedPoints: fault == .submissionAmount ? 0 : amount,
            submittedAt: "2026-09-25T01:00:00Z"
        ), balance: fault == .balance ? -1 : 300, awardedPoints: amount, created: true)
    }
    func download(submissionID: Int) async throws -> Data {
        await suspendIfNeeded("download")
        return Data("private evidence".utf8)
    }
    func failNextFetch() { failFetch = true }
    func pause(_ operation: String) { paused.insert(operation) }
    func waitFor(_ operation: String) async {
        if continuations[operation] != nil { return }
        await withCheckedContinuation { started[operation] = $0 }
    }
    func release(_ operation: String) {
        paused.remove(operation)
        continuations.removeValue(forKey: operation)?.resume()
    }
    private func suspendIfNeeded(_ operation: String) async {
        guard paused.contains(operation) else { return }
        await withCheckedContinuation { continuation in
            continuations[operation] = continuation
            started.removeValue(forKey: operation)?.resume()
        }
    }
}

private actor DocumentServiceStub: DocumentServing {
    private(set) var requests: [DocumentRequest] = []
    func fetchDocuments() async throws -> DocumentDashboard {
        DocumentDashboard(dogs: [DocumentDog(id: 7, name: "Coco", photo: nil)], submissions: [], eligibility: [])
    }
    func submit(_ request: DocumentRequest) async throws -> DocumentReceipt {
        requests.append(request)
        if requests.count == 1 { throw APIError.network("Connection lost") }
        return DocumentReceipt(
            submission: DocumentSubmission(
                id: 1, requestID: request.requestID, dogID: 7, dogName: "Coco", kind: request.kind,
                status: "SELF_REPORTED", registrationNumber: request.registrationNumber ?? "",
                eventDate: nil, validFrom: nil, validTo: nil, filename: "", fileURL: nil,
                awardedPoints: 300, submittedAt: "2026-09-25T01:00:00Z"
            ), balance: 300, awardedPoints: 300, created: true
        )
    }
    func download(submissionID: Int) async throws -> Data { Data() }
}
