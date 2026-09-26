import SwiftUI
import UIKit
import XCTest
@testable import Vitail

final class DocumentTests: XCTestCase {
    func testUploadRequestOmitsHiddenManualFieldsAndInventedDates() throws {
        let draft = try DocumentDraft.registration(dogID: 7, kind: .microchip, method: .upload,
            number: "not a chip number", councilName: "stale council", registrationYear: 2020,
            filename: "Registration.pdf", fileData: Data([1, 2, 3]))
        let id = UUID()
        let request = DocumentRequest(draft: draft, requestID: id)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(json["dog_id"] as? Int, 7)
        XCTAssertEqual(json["kind"] as? String, "MICROCHIP_REGISTRATION")
        XCTAssertEqual(json["file_base64"] as? String, "AQID")
        XCTAssertEqual((json["request_id"] as? String).flatMap(UUID.init(uuidString:)), id)
        for key in ["registration_number", "council_name", "registration_year", "event_date", "valid_from", "valid_to"] {
            XCTAssertNil(json[key], "Upload included hidden \(key)")
        }
    }

    func testTypedMicrochipPreservesLeadingZeroAndNormalizesSeparators() throws {
        let draft = try DocumentDraft.registration(dogID: 7, kind: .microchip, method: .details,
            number: " 012-345 678 901 234 ", councilName: "", registrationYear: 2027,
            filename: "hidden.jpg", fileData: Data([1]))
        XCTAssertEqual(draft.registrationNumber, "012345678901234")
        XCTAssertNil(draft.fileData)
        XCTAssertNil(draft.filename)
        for value in ["1234", "９12345678901234", "91234567890123A", "9123456789012345"] {
            XCTAssertThrowsError(try DocumentDraft.registration(dogID: 7, kind: .microchip, method: .details,
                number: value, councilName: "", registrationYear: 2027, filename: nil, fileData: nil))
        }
    }

    func testCouncilRequestPreservesIdentifierAndEncodesCurrentYear() throws {
        let today = try XCTUnwrap(DogBirthday.date(from: "2026-09-25"))
        let draft = try DocumentDraft.registration(dogID: 7, kind: .council, method: .details,
            number: " 000-ABC 42 ", councilName: " City of Melbourne ", registrationYear: 2027,
            filename: nil, fileData: nil, today: today)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DocumentRequest(draft: draft))) as? [String: Any])
        XCTAssertEqual(json["registration_number"] as? String, "000-ABC 42")
        XCTAssertEqual(json["council_name"] as? String, "City of Melbourne")
        XCTAssertEqual(json["registration_year"] as? Int, 2027)
        XCTAssertNil(json["valid_from"])
        XCTAssertNil(json["valid_to"])
        for (number, council, year) in [("123", "", 2027), ("123", "Yarra", 2026), ("---", "Yarra", 2027), ("ABC/12", "Yarra", 2027)] {
            XCTAssertThrowsError(try DocumentDraft.registration(dogID: 7, kind: .council, method: .details,
                number: number, councilName: council, registrationYear: year, filename: nil, fileData: nil, today: today))
        }
    }

    func testCouncilYearUsesMelbourneRolloverOnAprilTen() throws {
        let formatter = ISO8601DateFormatter()
        let before = try XCTUnwrap(formatter.date(from: "2026-04-09T13:59:59Z"))
        let after = try XCTUnwrap(formatter.date(from: "2026-04-09T14:00:00Z"))
        XCTAssertEqual(DocumentRegistration.currentCouncilYear(on: before), 2026)
        XCTAssertEqual(DocumentRegistration.currentCouncilYear(on: after), 2027)
        XCTAssertEqual(DocumentRegistration.councilYearLabel(2027), "2026–27")
    }

    func testCouncilUploadStaysSimpleButExpiredQuestCannotSubmitForAnotherYear() throws {
        let today = try XCTUnwrap(DogBirthday.date(from: "2027-04-10"))
        XCTAssertThrowsError(try DocumentDraft.registration(dogID: 7, kind: .council, method: .upload,
            number: "", councilName: "", registrationYear: 2027, filename: "proof.png", fileData: Data([1]),
            today: today, questRegistrationYear: 2027))
        let draft = try DocumentDraft.registration(dogID: 7, kind: .council, method: .upload,
            number: "old hidden number", councilName: "old hidden council", registrationYear: 2027,
            filename: "proof.png", fileData: Data([1]), today: today, questRegistrationYear: 2028)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DocumentRequest(draft: draft))) as? [String: Any])
        XCTAssertNil(payload["registration_year"])
        XCTAssertNil(payload["registration_number"])
        XCTAssertNil(payload["council_name"])
        XCTAssertEqual(payload["file_base64"] as? String, "AQ==")
    }

    func testCouncilRewardYearDecodesSeparatelyFromUploadedDocumentDetails() throws {
        let json = #"""
        {"dogs":[],"submissions":[{"id":1,"request_id":"11111111-1111-1111-1111-111111111111",
        "dog_id":7,"dog_name":"Coco","kind":"COUNCIL_REGISTRATION","status":"SELF_REPORTED",
        "registration_number":"","registration_year":null,"reward_registration_year":2027,
        "event_date":null,"valid_from":null,"valid_to":null,"filename":"proof.pdf","file_url":"/private/1",
        "awarded_points":0,"submitted_at":"2026-09-25T01:00:00Z","entitlement_id":91,"reward_status":"READY"}],
        "eligibility":[{"dog_id":7,"kind":"COUNCIL_REGISTRATION","awards_count":0,"message":"Annual reward","registration_year":2027}],
        "entitlements":[{"id":91,"dog_id":7,"dog_name":"Coco","kind":"COUNCIL_REGISTRATION",
        "reward_status":"READY","reward_points":300,"collected_at":null,"can_collect":true,"registration_year":2027}]}
        """#
        let dashboard = try JSONDecoder().decode(DocumentDashboard.self, from: Data(json.utf8))
        let submission = try XCTUnwrap(dashboard.submissions.first)
        XCTAssertNil(submission.registrationYear)
        XCTAssertEqual(submission.rewardRegistrationYear, 2027)
        XCTAssertEqual(dashboard.entitlements?.first?.registrationYear, 2027)
        XCTAssertEqual(dashboard.eligibility.first?.registrationYear, 2027)
        XCTAssertNotNil(dashboard.latestPendingSubmission(dogID: 7, kind: .council, registrationYear: 2027))
        XCTAssertNil(dashboard.latestPendingSubmission(dogID: 7, kind: .council, registrationYear: 2028))
    }

    func testCouncilPendingEvidenceIsScopedByRewardYearEvenWhenOlderYearWasUploadedLast() {
        func submission(_ id: Int, rewardYear: Int?) -> DocumentSubmission {
            DocumentSubmission(id: id, requestID: UUID(), dogID: 7, dogName: "Coco", kind: .council,
                status: "SELF_REPORTED", registrationNumber: "", eventDate: nil, validFrom: nil, validTo: nil,
                filename: "proof.pdf", fileURL: "/private/\(id)", awardedPoints: 0, submittedAt: "2027-04-10T01:00:00Z",
                entitlementID: id, rewardStatus: .ready, rewardPoints: 300, rewardRegistrationYear: rewardYear)
        }
        let previous = submission(2, rewardYear: 2027)
        let current = submission(1, rewardYear: nil) // Older exact receipt: resolve through its entitlement.
        let dashboard = DocumentDashboard(dogs: [], submissions: [previous, current], eligibility: [], entitlements: [
            DocumentEntitlement(id: 2, dogID: 7, dogName: "Coco", kind: .council, rewardStatus: .ready,
                rewardPoints: 300, collectedAt: nil, canCollect: true, registrationYear: 2027),
            DocumentEntitlement(id: 1, dogID: 7, dogName: "Coco", kind: .council, rewardStatus: .ready,
                rewardPoints: 300, collectedAt: nil, canCollect: true, registrationYear: 2028)
        ])
        XCTAssertEqual(dashboard.latestPendingSubmission(dogID: 7, kind: .council, registrationYear: 2027)?.id, 2)
        XCTAssertEqual(dashboard.latestPendingSubmission(dogID: 7, kind: .council, registrationYear: 2028)?.id, 1)
        XCTAssertNil(dashboard.latestPendingSubmission(dogID: 7, kind: .council, registrationYear: 2029))
    }

    func testPendingSubmissionNeverFallsBackToAnotherDogOrDocumentKindOrCollectedHistory() throws {
        func submission(_ id: Int, dog: Int, kind: DocumentKind) -> DocumentSubmission {
            DocumentSubmission(id: id, requestID: UUID(), dogID: dog, dogName: "Dog", kind: kind,
                status: "SELF_REPORTED", registrationNumber: "123", eventDate: nil, validFrom: nil,
                validTo: nil, filename: "", fileURL: nil, awardedPoints: 0, submittedAt: "2026-09-25T00:00:00Z",
                entitlementID: id, rewardStatus: .ready)
        }
        var collectedVisit = submission(5, dog: 7, kind: .vet)
        collectedVisit.rewardStatus = .collected
        let staleReadyVisit = submission(6, dog: 7, kind: .vet)
        let dashboard = DocumentDashboard(dogs: [], submissions: [submission(1, dog: 7, kind: .council),
            submission(2, dog: 7, kind: .council), submission(3, dog: 8, kind: .council),
            submission(4, dog: 7, kind: .microchip), collectedVisit, staleReadyVisit], eligibility: [],
            entitlements: (1...4).map { id in
                DocumentEntitlement(id: id, dogID: id == 3 ? 8 : 7, dogName: "Dog", kind: id == 4 ? .microchip : .council,
                    rewardStatus: .ready, rewardPoints: 300, collectedAt: nil, canCollect: true)
            } + [DocumentEntitlement(id: 6, dogID: 7, dogName: "Dog", kind: .vet,
                rewardStatus: .collected, rewardPoints: 200, collectedAt: "2026-09-25T00:00:00Z", canCollect: false)])
        XCTAssertEqual(dashboard.latestPendingSubmission(dogID: 7, kind: .council)?.id, 2)
        XCTAssertNil(dashboard.latestPendingSubmission(dogID: 9, kind: .council))
        XCTAssertNil(dashboard.latestPendingSubmission(dogID: 7, kind: .vet))
        XCTAssertEqual(dashboard.latestPendingSubmission(dogID: 7, kind: .microchip)?.id, 4)
    }

    func testPendingMicrochipSelectsCanonicalEntitlementAndHidesSupersededRewards() {
        let submissions = [10, 11].map { id in
            DocumentSubmission(id: id, requestID: UUID(), dogID: 7, dogName: "Coco", kind: .microchip,
                status: "SELF_REPORTED", registrationNumber: "012345678901234", eventDate: nil,
                validFrom: nil, validTo: nil, filename: "", fileURL: nil, awardedPoints: 0,
                submittedAt: "2026-09-25T00:00:00Z", entitlementID: id, rewardStatus: .ready)
        }
        let canonical = DocumentEntitlement(id: 10, dogID: 7, dogName: "Coco", kind: .microchip,
            rewardStatus: .ready, rewardPoints: 300, collectedAt: nil, canCollect: true)
        let superseded = DocumentEntitlement(id: 11, dogID: 7, dogName: "Coco", kind: .microchip,
            rewardStatus: .ready, rewardPoints: 300, collectedAt: nil, canCollect: false)
        var dashboard = DocumentDashboard(dogs: [], submissions: submissions, eligibility: [],
            entitlements: [canonical, superseded])
        XCTAssertEqual(dashboard.latestPendingSubmission(dogID: 7, kind: .microchip)?.id, 10)
        dashboard.entitlements = [DocumentEntitlement(id: 10, dogID: 7, dogName: "Coco", kind: .microchip,
            rewardStatus: .collected, rewardPoints: 300, collectedAt: "2026-09-25T00:00:00Z", canCollect: false), superseded]
        XCTAssertNil(dashboard.latestPendingSubmission(dogID: 7, kind: .microchip))
        dashboard.entitlements = []
        XCTAssertNil(dashboard.latestPendingSubmission(dogID: 7, kind: .microchip))
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
    func testTypedCouncilReceiptMatchesSubmittedIdentifierCouncilAndYear() async throws {
        let draft = try DocumentDraft.registration(dogID: 7, kind: .council, method: .details,
            number: "000123", councilName: "City of Melbourne", registrationYear: 2027,
            filename: nil, fileData: nil, today: XCTUnwrap(DogBirthday.date(from: "2026-09-25")))
        let model = DocumentViewModel(service: DocumentControlledService())
        let succeeded = await model.submit(draft)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.receipt?.submission.registrationNumber, "000123")
        XCTAssertEqual(model.receipt?.submission.councilName, "City of Melbourne")
        XCTAssertEqual(model.receipt?.submission.registrationYear, 2027)
    }

    @MainActor
    func testUploadReceiptAcceptsBackendEmptyCouncilNameWithoutManualFields() async throws {
        let draft = try DocumentDraft.registration(dogID: 7, kind: .microchip, method: .upload,
            number: "", councilName: "", registrationYear: 2027,
            filename: "certificate.png", fileData: Data([1]))
        let model = DocumentViewModel(service: DocumentControlledService())
        let succeeded = await model.submit(draft)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.receipt?.submission.councilName, "")
        XCTAssertNil(model.receipt?.submission.registrationYear)
    }

    @MainActor
    func testCouncilUploadReceiptKeepsRewardYearAndDoesNotLeakIntoNextYearSheet() async throws {
        let draft = try DocumentDraft.registration(dogID: 7, kind: .council, method: .upload,
            number: "", councilName: "", registrationYear: 2027, filename: "proof.png", fileData: Data([1]))
        let service = DocumentControlledService(readySubmission: true, rewardYear: 2027)
        let model = DocumentViewModel(service: service)
        await service.failNextFetch()
        let succeeded = await model.submit(draft)
        XCTAssertTrue(succeeded)
        XCTAssertNil(model.receipt?.submission.registrationYear)
        XCTAssertEqual(model.receipt?.submission.rewardRegistrationYear, 2027)
        XCTAssertNotNil(model.currentSubmission(dogID: 7, kind: .council, registrationYear: 2027))
        XCTAssertNil(model.currentSubmission(dogID: 7, kind: .council, registrationYear: 2028))
    }

    @MainActor
    func testCouncilCollectionRejectsWrongYearAndAcceptsMatchingOrLegacyReceipt() async {
        let entitlement = DocumentEntitlement(id: 91, dogID: 7, dogName: "Coco", kind: .council,
            rewardStatus: .ready, rewardPoints: 300, collectedAt: nil, canCollect: true, registrationYear: 2027)
        for receivedYear in [2028, 2027, nil] as [Int?] {
            let model = DocumentViewModel(service: DocumentControlledService(rewardYear: receivedYear))
            let succeeded = await model.collect(entitlement)
            XCTAssertEqual(succeeded, receivedYear != 2028)
            XCTAssertEqual(model.isCollected(entitlement), receivedYear != 2028)
        }
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
    func testSubmissionIsReadyWithoutCreditUntilExplicitCollect() async throws {
        let service = DocumentControlledService(readySubmission: true)
        let model = DocumentViewModel(service: service)
        let submitted = await model.submit(makeDraft(number: "ABC-42"))
        XCTAssertTrue(submitted)
        XCTAssertEqual(model.receipt?.awardedPoints, 0)
        XCTAssertEqual(model.receipt?.rewardStatus, .ready)
        XCTAssertNil(model.lastCollection)
        let before = await service.collectionIDs
        XCTAssertTrue(before.isEmpty)
        let submission = try XCTUnwrap(model.receipt?.submission)
        let entitlement = try XCTUnwrap(model.entitlement(for: submission))
        let collected = await model.collect(entitlement)
        XCTAssertTrue(collected)
        XCTAssertEqual(model.lastCollection?.points, 300)
        XCTAssertTrue(model.isCollected(entitlement))
        XCTAssertFalse(model.canCollect(entitlement))
        let second = await model.collect(entitlement)
        XCTAssertFalse(second)
        let ids = await service.collectionIDs
        XCTAssertEqual(ids, [91])
    }

    @MainActor
    func testCollectionRetryUsesSameEntitlementAfterAmbiguousFailure() async {
        let service = DocumentControlledService()
        await service.failNextCollection()
        let model = DocumentViewModel(service: service)
        let first = await model.collect(makeEntitlement())
        let second = await model.collect(makeEntitlement())
        XCTAssertFalse(first)
        XCTAssertTrue(second)
        let ids = await service.collectionIDs
        XCTAssertEqual(ids, [91, 91])
        XCTAssertEqual(model.lastCollection?.created, false)
    }

    @MainActor
    func testStaleOwnerCollectionCannotPublishOrRefresh() async throws {
        let session = await makeSession()
        let service = DocumentControlledService()
        await service.pause("collect")
        let model = DocumentViewModel(service: service, session: session)
        let task = Task { await model.collect(makeEntitlement()) }
        await service.waitFor("collect")
        await session.logout()
        try await session.login(email: "other@example.com", password: "unused", expectedRole: .owner)
        await service.release("collect")
        let collected = await task.value
        XCTAssertFalse(collected)
        XCTAssertNil(model.lastCollection)
        XCTAssertTrue(model.confirmedCollections.isEmpty)
        XCTAssertNil(model.dashboard)
        let fetchCount = await service.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    @MainActor
    func testInvalidCollectionReceiptsNeverConfirmOrRefresh() async {
        for fault in DocumentCollectionFault.allCases {
            let service = DocumentControlledService(collectionFault: fault)
            let model = DocumentViewModel(service: service)
            let collected = await model.collect(makeEntitlement())
            XCTAssertFalse(collected, "Accepted invalid collection \(fault)")
            XCTAssertNil(model.lastCollection)
            XCTAssertTrue(model.confirmedCollections.isEmpty)
            let fetchCount = await service.fetchCount
            XCTAssertEqual(fetchCount, 0)
        }
    }

    @MainActor
    func testConfirmedCollectionSurvivesHistoryFailureAndStopClearsIt() async {
        let service = DocumentControlledService()
        await service.failNextFetch()
        let model = DocumentViewModel(service: service)
        let collected = await model.collect(makeEntitlement())
        XCTAssertTrue(collected)
        XCTAssertEqual(model.lastCollection?.points, 300)
        XCTAssertEqual(model.errorMessage, "Your points were collected. Refresh to update your documents.")
        XCTAssertFalse(model.canCollect(makeEntitlement()))
        await model.load()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isCollected(makeEntitlement()))
        model.stop()
        XCTAssertNil(model.lastCollection)
        XCTAssertTrue(model.confirmedCollections.isEmpty)
    }

    @MainActor
    func testFixedDocumentEntryAppearanceSnapshots() async throws {
        let service = DocumentControlledService()
        for dark in [false, true] {
            let mode = dark ? "Dark" : "Light"
            try await snapshot(DocumentSubmissionView(service: service, initialDogID: 7, initialKind: .council),
                name: "Document-Council-\(mode)", dark: dark)
            try await snapshot(DocumentSubmissionView(service: service, initialDogID: 7, initialKind: .microchip),
                name: "Document-Microchip-\(mode)", dark: dark)
            try await snapshot(DocumentSubmissionView(service: service, initialDogID: 7,
                initialKind: .council, initialMethod: .upload), name: "Document-Upload-\(mode)", dark: dark, bottom: true)
        }
        try await snapshot(DocumentSubmissionView(service: service, initialDogID: 7, initialKind: .council)
            .environment(\.dynamicTypeSize, .accessibility3), name: "Document-Council-Large-Text", dark: false, bottom: true)
        try await snapshot(DocumentSubmissionView(service: service, initialDogID: 999, initialKind: .microchip),
            name: "Document-Missing-Dog", dark: false)
    }

    @MainActor
    private func snapshot<Content: View>(_ content: Content, name: String, dark: Bool, bottom: Bool = false) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationStack { content }
            .vitailAppearance().preferredColorScheme(dark ? .dark : .light))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 250_000_000)
        if bottom, let scroll = firstScrollView(in: host.view) {
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
            host.view.layoutIfNeeded()
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews {
            if let scroll = firstScrollView(in: child) { return scroll }
        }
        return nil
    }

    private func makeEntitlement() -> DocumentEntitlement {
        DocumentEntitlement(id: 91, dogID: 7, dogName: "Coco", kind: .council,
            rewardStatus: .ready, rewardPoints: 300, collectedAt: nil, canCollect: true)
    }

    @MainActor
    private func makeSession() async -> SessionStore {
        let session = SessionStore(authService: DocumentAuthFixture())
        await session.restore()
        return session
    }

    private func makeDraft(number: String) -> DocumentDraft {
        DocumentDraft(dogID: 7, kind: .council, registrationNumber: number,
                      eventDate: nil, filename: nil, fileData: nil)
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
    case id, request, dog, kind, status, date, number, council, year, amount, submissionAmount, balance
}

private enum DocumentCollectionFault: CaseIterable, Sendable { case id, dog, kind, amount, balance, date }

private actor DocumentControlledService: DocumentServing {
    private(set) var requests: [DocumentRequest] = []
    private(set) var fetchCount = 0
    private(set) var collectionIDs: [Int] = []
    private let fault: DocumentReceiptFault?
    private let collectionFault: DocumentCollectionFault?
    private let award: Int
    private let readySubmission: Bool
    private let rewardYear: Int?
    private var failFetch = false
    private var failCollection = false
    private var paused: Set<String> = []
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var started: [String: CheckedContinuation<Void, Never>] = [:]

    init(fault: DocumentReceiptFault? = nil, award: Int = 300, readySubmission: Bool = false,
         collectionFault: DocumentCollectionFault? = nil, rewardYear: Int? = nil) {
        self.fault = fault
        self.award = award
        self.readySubmission = readySubmission
        self.collectionFault = collectionFault
        self.rewardYear = rewardYear
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
        let amount = fault == .amount ? 999 : (readySubmission ? 0 : award)
        return DocumentReceipt(submission: DocumentSubmission(
            id: fault == .id ? 0 : 1,
            requestID: fault == .request ? UUID() : request.requestID,
            dogID: fault == .dog ? 8 : request.dogID, dogName: "Coco",
            kind: fault == .kind ? .vet : request.kind,
            status: fault == .status ? "VERIFIED" : "SELF_REPORTED",
            registrationNumber: fault == .number ? "different" : (request.registrationNumber ?? ""),
            eventDate: fault == .date ? "2026-01-01" : request.eventDate,
            validFrom: nil, validTo: nil,
            filename: "", fileURL: nil,
            awardedPoints: fault == .submissionAmount ? 0 : amount,
            submittedAt: "2026-09-25T01:00:00Z",
            entitlementID: readySubmission ? 91 : nil, rewardStatus: readySubmission ? .ready : nil,
            rewardPoints: readySubmission ? 300 : nil,
            councilName: fault == .council ? "Wrong council" : (request.councilName ?? ""),
            registrationYear: fault == .year ? 2099 : request.registrationYear,
            rewardRegistrationYear: request.kind == .council ? (rewardYear ?? request.registrationYear) : nil
        ), balance: fault == .balance ? -1 : 300, awardedPoints: amount, created: true,
           entitlementID: readySubmission ? 91 : nil, rewardStatus: readySubmission ? .ready : nil,
           rewardPoints: readySubmission ? 300 : nil)
    }
    func download(submissionID: Int) async throws -> Data {
        await suspendIfNeeded("download")
        return Data("private evidence".utf8)
    }
    func failNextFetch() { failFetch = true }
    func failNextCollection() { failCollection = true }
    func collect(entitlementID: Int) async throws -> DocumentCollectionReceipt {
        collectionIDs.append(entitlementID)
        await suspendIfNeeded("collect")
        if failCollection { failCollection = false; throw APIError.network("Connection lost") }
        return DocumentCollectionReceipt(entitlementID: collectionFault == .id ? 92 : entitlementID,
            kind: collectionFault == .kind ? .vet : .council, dogID: collectionFault == .dog ? 8 : 7,
            points: collectionFault == .amount ? 999 : 300, balance: collectionFault == .balance ? -1 : 300,
            collectedAt: collectionFault == .date ? "invalid" : "2026-09-25T01:00:00.123456Z", created: collectionIDs.count == 1,
            registrationYear: rewardYear)
    }
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
