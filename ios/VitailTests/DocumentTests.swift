import SwiftUI
import UIKit
import XCTest
@testable import Vitail

final class DocumentTests: XCTestCase {
    @MainActor func testReadingSuggestionsRequireConfirmationAndEditsInvalidateIt() async {
        let reader = ControlledDocumentReader()
        let model = DocumentReviewModel(reader: reader)
        let reading = Task { await model.read(data: Data([1]), filename: "proof.pdf", kind: .council) }
        await reader.waitForStart()
        XCTAssertTrue(model.isReading)
        XCTAssertFalse(model.isConfirmed)
        var result = DocumentReadResult(registrationNumber: "00042", councilName: "Yarra", dogName: "Coco",
            validTo: "2030-06-30", pagesRead: 1, source: .pdfText)
        result.candidates = [.init(field: .validTo, value: "2030-06-30", page: 1, source: .pdfText, context: "Expiry", confidence: nil)]
        await reader.finish(result)
        await reading.value
        XCTAssertEqual(model.expiryText, "30/06/2030")
        XCTAssertEqual(model.registrationNumber, "00042")
        XCTAssertFalse(model.isConfirmed)
        model.isConfirmed = true
        model.dogName = "Corrected Coco"
        XCTAssertFalse(model.isConfirmed)
        let json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(model.readingAudit)) as! [String: Any]
        XCTAssertNil(json["raw_text"])
        XCTAssertEqual(json["source"] as? String, "PDF_TEXT")
    }

    @MainActor func testLateReadingCannotRestoreClearedOrCancelledAttachment() async {
        for cancel in [false, true] {
            let reader = ControlledDocumentReader()
            let model = DocumentReviewModel(reader: reader)
            let reading = Task { await model.read(data: Data([1]), filename: "old.pdf", kind: .council) }
            await reader.waitForStart()
            if cancel { model.cancelReading() } else { model.clear() }
            await reader.finish(DocumentReadResult(registrationNumber: "WRONG", validTo: "2030-06-30", pagesRead: 1, source: .vision))
            await reading.value
            XCTAssertFalse(model.isReading)
            XCTAssertEqual(model.registrationNumber, "")
            XCTAssertEqual(model.expiryText, "")
            XCTAssertNil(model.readingAudit)
            XCTAssertFalse(model.isConfirmed)
        }
    }

    @MainActor func testUnresolvedReadingLeavesExpiryEmptyForCorrection() async {
        let reader = ControlledDocumentReader()
        let model = DocumentReviewModel(reader: reader)
        let reading = Task { await model.read(data: Data([1]), filename: "unclear.jpg", kind: .council) }
        await reader.waitForStart()
        await reader.finish(DocumentReadResult(pagesRead: 1, source: .vision, warnings: ["Ambiguous expiry"]))
        await reading.value
        XCTAssertTrue(model.didRead)
        XCTAssertTrue(model.needsCorrection)
        XCTAssertEqual(model.expiryText, "")
        XCTAssertFalse(model.isConfirmed)
    }

    func testUploadRequestIncludesConfirmedFieldsAndActualExpiry() throws {
        let draft = try DocumentDraft.registration(dogID: 7, kind: .council, method: .upload,
            number: "A/001", councilName: "Yarra", validTo: "30/06/2030", filename: "proof.pdf", fileData: Data([1, 2, 3]))
        let id = UUID()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DocumentRequest(draft: draft, requestID: id))) as? [String: Any])
        XCTAssertEqual(json["registration_number"] as? String, "A/001")
        XCTAssertEqual(json["council_name"] as? String, "Yarra")
        XCTAssertEqual(json["valid_to"] as? String, "2030-06-30")
        XCTAssertEqual(json["file_base64"] as? String, "AQID")
        XCTAssertNil(json["registration_year"])
        XCTAssertNil(json["valid_from"])
        XCTAssertNil(json["event_date"])
        XCTAssertEqual((json["request_id"] as? String).flatMap(UUID.init(uuidString:)), id)
    }

    func testTypedMicrochipNormalizesButUploadedLegacyIdentifierIsPreserved() throws {
        let manual = try DocumentDraft.registration(dogID: 7, kind: .microchip, method: .details,
            number: " 012-345 678 901 234 ", councilName: "", filename: "hidden.jpg", fileData: Data([1]))
        XCTAssertEqual(manual.registrationNumber, "012345678901234")
        XCTAssertNil(manual.fileData)
        for number in ["1234", "９12345678901234", "91234567890123A"] {
            XCTAssertThrowsError(try DocumentDraft.registration(dogID: 7, kind: .microchip, method: .details,
                number: number, councilName: "", filename: nil, fileData: nil))
        }
        let upload = try DocumentDraft.registration(dogID: 7, kind: .microchip, method: .upload,
            number: " legacy/A-012 ", councilName: "", registryName: "CAR", filename: "proof.png", fileData: Data([1]))
        XCTAssertEqual(upload.registrationNumber, "legacy/A-012")
        XCTAssertEqual(upload.registryName, "CAR")
    }

    func testExpiryHasNoInventedDefaultAndRemainsValidThroughMelbourneDay() throws {
        XCTAssertNil(DocumentRegistration.normalizedExpiry(""))
        XCTAssertNil(DocumentRegistration.normalizedExpiry("31/02/2030"))
        XCTAssertEqual(DocumentRegistration.normalizedExpiry("30/6/2030"), "2030-06-30")
        let format = ISO8601DateFormatter()
        XCTAssertTrue(DocumentRegistration.isCurrent("2030-06-30", on: try XCTUnwrap(format.date(from: "2030-06-30T13:59:59Z"))))
        XCTAssertFalse(DocumentRegistration.isCurrent("2030-06-30", on: try XCTUnwrap(format.date(from: "2030-06-30T14:00:00Z"))))
        XCTAssertFalse(DocumentRegistration.isCurrent(nil))
    }

    func testPastExpiryCanOnlyBindExistingUnknownExpiryReward() throws {
        let today = try XCTUnwrap(DogBirthday.date(from: "2030-07-01"))
        XCTAssertThrowsError(try DocumentDraft.registration(dogID: 7, kind: .council, method: .upload,
            number: "001", councilName: "Yarra", validTo: "30/06/2030", filename: "old.pdf", fileData: Data([1]), today: today))
        let update = try DocumentDraft.registration(dogID: 7, kind: .council, method: .upload,
            number: "001", councilName: "Yarra", validTo: "30/06/2030", filename: "old.pdf", fileData: Data([1]),
            expectedEntitlementID: 91, needsExpiry: true, today: today)
        XCTAssertEqual(update.expectedEntitlementID, 91)
        XCTAssertEqual(update.validTo, "2030-06-30")
        XCTAssertThrowsError(try DocumentDraft.registration(dogID: 7, kind: .council, method: .upload,
            number: "001", councilName: "Yarra", validTo: "", filename: "old.pdf", fileData: Data([1])))
    }

    func testExpiredAndUnknownSubmissionsDoNotHideRefreshedCouncilForm() {
        func submission(_ id: Int, expiry: String?) -> DocumentSubmission {
            DocumentSubmission(id: id, requestID: UUID(), dogID: 7, dogName: "Coco", kind: .council,
                status: "SELF_REPORTED", registrationNumber: "1", eventDate: nil, validFrom: nil, validTo: expiry,
                filename: "", fileURL: nil, awardedPoints: 0, submittedAt: "2026-09-25T00:00:00Z",
                entitlementID: id, rewardStatus: .ready)
        }
        let dashboard = DocumentDashboard(dogs: [], submissions: [submission(3, expiry: nil),
            submission(2, expiry: "2020-06-30"), submission(1, expiry: "2030-06-30")], eligibility: [])
        XCTAssertEqual(dashboard.latestPendingSubmission(dogID: 7, kind: .council)?.id, 1)
        XCTAssertNil(dashboard.latestPendingSubmission(dogID: 7, kind: .council, entitlementID: 2))
    }

    func testPendingSubmissionNeverFallsBackToAnotherDogOrDocumentKindOrCollectedHistory() throws {
        func submission(_ id: Int, dog: Int, kind: DocumentKind) -> DocumentSubmission {
            DocumentSubmission(id: id, requestID: UUID(), dogID: dog, dogName: "Dog", kind: kind,
                status: "SELF_REPORTED", registrationNumber: "123", eventDate: nil, validFrom: nil,
                validTo: kind == .council ? "2030-06-30" : nil, filename: "", fileURL: nil, awardedPoints: 0, submittedAt: "2026-09-25T00:00:00Z",
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
    func testCouncilUploadReceiptRequiresSameConfirmedExpiryAndEntitlement() async throws {
        let draft = try DocumentDraft.registration(dogID: 7, kind: .council, method: .upload,
            number: "000123", councilName: "Yarra", validTo: "2030-06-30", filename: "proof.pdf", fileData: Data([1]),
            expectedEntitlementID: 91, needsExpiry: true)
        let model = DocumentViewModel(service: DocumentControlledService(readySubmission: true))
        let succeeded = await model.submit(draft)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.receipt?.submission.validTo, "2030-06-30")
        XCTAssertNotNil(model.currentSubmission(dogID: 7, kind: .council, entitlementID: 91))
        XCTAssertNil(model.currentSubmission(dogID: 7, kind: .council, entitlementID: 92))
        let nextDay = try XCTUnwrap(DogBirthday.date(from: "2030-07-01"))
        XCTAssertNil(model.currentSubmission(dogID: 7, kind: .council, today: nextDay))
    }

    @MainActor
    func testCouncilCollectionRejectsWrongExpiryAndUnknownExpiry() async {
        let entitlement = DocumentEntitlement(id: 91, dogID: 7, dogName: "Coco", kind: .council,
            rewardStatus: .ready, rewardPoints: 300, collectedAt: nil, canCollect: true, validTo: "2030-06-30")
        for expiry in ["2031-06-30", "2030-06-30", ""] {
            let model = DocumentViewModel(service: DocumentControlledService(expiryOverride: expiry))
            let succeeded = await model.collect(entitlement)
            XCTAssertEqual(succeeded, expiry == "2030-06-30")
            XCTAssertEqual(model.isCollected(entitlement), expiry == "2030-06-30")
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
            rewardStatus: .ready, rewardPoints: 300, collectedAt: nil, canCollect: true, validTo: "2030-06-30")
    }

    @MainActor
    private func makeSession() async -> SessionStore {
        let session = SessionStore(authService: DocumentAuthFixture())
        await session.restore()
        return session
    }

    private func makeDraft(number: String) -> DocumentDraft {
        DocumentDraft(dogID: 7, kind: .council, registrationNumber: number,
                      eventDate: nil, filename: nil, fileData: nil, validTo: "2030-06-30")
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
    case id, request, dog, kind, status, date, number, council, expiry, amount, submissionAmount, balance
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
    private let expiryOverride: String?
    private var failFetch = false
    private var failCollection = false
    private var paused: Set<String> = []
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var started: [String: CheckedContinuation<Void, Never>] = [:]

    init(fault: DocumentReceiptFault? = nil, award: Int = 300, readySubmission: Bool = false,
         collectionFault: DocumentCollectionFault? = nil, expiryOverride: String? = nil) {
        self.fault = fault
        self.award = award
        self.readySubmission = readySubmission
        self.collectionFault = collectionFault
        self.expiryOverride = expiryOverride
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
            validFrom: nil, validTo: fault == .expiry ? "2099-01-01" : request.validTo,
            filename: "", fileURL: nil,
            awardedPoints: fault == .submissionAmount ? 0 : amount,
            submittedAt: "2026-09-25T01:00:00Z",
            entitlementID: readySubmission ? 91 : nil, rewardStatus: readySubmission ? .ready : nil,
            rewardPoints: readySubmission ? 300 : nil,
            councilName: fault == .council ? "Wrong council" : (request.councilName ?? ""),
            registryName: request.registryName, documentDogName: request.documentDogName
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
            validTo: expiryOverride ?? "2030-06-30")
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
                eventDate: nil, validFrom: nil, validTo: request.validTo, filename: "", fileURL: nil,
                awardedPoints: 300, submittedAt: "2026-09-25T01:00:00Z"
            ), balance: 300, awardedPoints: 300, created: true
        )
    }
    func download(submissionID: Int) async throws -> Data { Data() }
}

private actor ControlledDocumentReader: DocumentReading {
    private var continuation: CheckedContinuation<DocumentReadResult, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func read(data: Data, filename: String, kind: DocumentKind) async throws -> DocumentReadResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume(); started = nil
        }
    }
    func waitForStart() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ result: DocumentReadResult) { continuation?.resume(returning: result); continuation = nil }
}
