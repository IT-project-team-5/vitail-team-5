import XCTest
@testable import Vitail

final class DogModelsTests: XCTestCase {
    @MainActor
    func testOutOfOrderGoalPreviewsCannotReplaceCurrentPercentage() async {
        let service = DogGoalTestService()
        let model = DogGoalViewModel(service: service)
        await service.holdNextPreview()
        let old = Task { await model.load(dogID: 97, percentage: 50) }
        await service.waitForPreview()
        await model.load(dogID: 97, percentage: 200)
        await service.releasePreview()
        await old.value
        XCTAssertEqual(model.preview?.ownerAdjustment, "2")
        XCTAssertTrue(model.canSave(percentage: 200))
        XCTAssertFalse(model.canSave(percentage: 50))
    }

    @MainActor
    func testAmbiguousGoalSaveKeepsRequestAcrossRestart() async throws {
        let dogID = 987654
        let key = "goal-request:\(AppConfiguration.apiBaseURL?.absoluteString ?? ""):\(dogID)"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let service = DogGoalTestService()
        let model = DogGoalViewModel(service: service)
        await model.load(dogID: dogID, percentage: 50)
        await service.failNextSave()
        let first = await model.save(dogID: dogID, percentage: 50)
        XCTAssertFalse(first)
        let firstRequest = await service.savedRequest
        XCTAssertNotNil(firstRequest?.requestID)
        let resumed = DogGoalViewModel(service: service)
        await resumed.load(dogID: dogID, percentage: 50)
        let retried = await resumed.save(dogID: dogID, percentage: 50)
        XCTAssertTrue(retried)
        let retryRequest = await service.savedRequest
        XCTAssertEqual(firstRequest?.requestID, retryRequest?.requestID)
        XCTAssertNil(UserDefaults.standard.data(forKey: key))
    }
    @MainActor
    func testLateListCannotRestoreDeletedDog() async throws {
        let service = DeferredDogService()
        let model = DogViewModel(service: service)
        await model.load()
        let dog = try XCTUnwrap(model.dogs.first)
        await service.holdList()
        let refresh = Task { await model.load() }
        await service.waitUntilHeld()
        let deleted = await model.delete(dog)
        XCTAssertTrue(deleted)
        await service.release()
        await refresh.value
        XCTAssertTrue(model.dogs.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testAccountChangeDuringDogSavePreventsPhotoAndStaleResult() async {
        let auth = DogSessionAuth()
        let session = SessionStore(authService: auth)
        await session.restore()
        let service = DeferredDogService()
        let model = DogViewModel(service: service, session: session)
        await service.holdCreate()
        let save = Task {
            await model.save(dog: nil, request: DogWriteRequest(name: "Milo", breedID: 1,
                ageMonths: 24, size: .medium, isBrachycephalic: false), photoData: Data([1]))
        }
        await service.waitUntilHeld()
        await session.logout()
        try? await session.login(email: "new", password: "password", expectedRole: .owner)
        await service.release()
        let saved = await save.value
        let photos = await service.photoUploads
        XCTAssertFalse(saved)
        XCTAssertEqual(photos, 0)
        XCTAssertNil(model.lastSavedDog)
        XCTAssertTrue(model.dogs.isEmpty)
    }

    func testNewAndUnknownBreedEnergyDecodeWithoutBreakingDogList() throws {
        for (raw, expected) in [("VERY_HIGH", BreedEnergyLevel.veryHigh), ("UNKNOWN", .unknown), ("UNRECOGNISED", .unknown)] {
            XCTAssertEqual(try JSONDecoder().decode(BreedEnergyLevel.self, from: Data("\"\(raw)\"".utf8)), expected)
        }
    }

    func testGoalPreviewKeepsFractionalRecommendationAndRoundedServerTarget() throws {
        let result = try JSONDecoder().decode(DogGoalPreview.self, from: Data(#"""
        {"eligible":true,"missing_inputs":[],"reason":null,"effective_from":"2026-10-06",
         "owner_adjustment":"0.50","suggested_minutes":"62.500000","target_seconds":1875,
         "current_target":{"id":1,"effective_from":"2026-10-05","target_seconds":null,"policy_version":"manual-duration-v1"},
         "scheduled_targets":[]}
        """#.utf8))
        XCTAssertEqual(result.recommendation, "62.5 min")
        XCTAssertEqual(DogGoalPreview.duration(try XCTUnwrap(result.targetSeconds)), "31 min 15 sec")
        XCTAssertEqual(result.currentTarget?.duration, "Paused")
        let data = try JSONEncoder().encode(DogGoalRequest(ownerAdjustment: result.ownerAdjustment, effectiveFrom: result.effectiveFrom))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(body, ["owner_adjustment": "0.50", "effective_from": "2026-10-06"])
    }

    func testWeightWriteAndExplicitClear() throws {
        for weight in ["9.99", nil] as [String?] {
            let request = DogWriteRequest(name: "Milo", breedID: 1, ageMonths: 24,
                size: .medium, isBrachycephalic: false, weightKg: weight)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            if let weight { XCTAssertEqual(body["weight_kg"] as? String, weight) }
            else { XCTAssertTrue(body["weight_kg"] is NSNull) }
        }
    }

    func testSavedGoalExplainsPersistedPercentageAndRecommendation() throws {
        let target = try JSONDecoder().decode(DogGoalTarget.self, from: Data(#"""
        {"id":2,"effective_from":"2026-10-07","target_seconds":1875,"policy_version":"personalised-duration-v1",
         "calculation_inputs":{"owner_adjustment":"0.50","suggested_minutes":"62.500000"}}
        """#.utf8))
        XCTAssertEqual(target.duration, "31 min 15 sec")
        XCTAssertEqual(target.calculationInputs?.description, "50% of 62.5 min recommended")
    }

    @MainActor
    func testGoalSaveRequiresMatchingPreviewAndDoesNotResubmitSavedTarget() async {
        let service = DogGoalTestService()
        let model = DogGoalViewModel(service: service)
        XCTAssertFalse(model.canSave(percentage: 100))
        await model.load(dogID: 1, percentage: 50)
        XCTAssertTrue(model.canSave(percentage: 50))
        XCTAssertFalse(model.canSave(percentage: 100))
        let saved = await model.save(dogID: 1, percentage: 50)
        XCTAssertTrue(saved)
        XCTAssertFalse(model.canSave(percentage: 50))
        let request = await service.savedRequest
        XCTAssertEqual(request?.ownerAdjustment, "0.5")
        XCTAssertEqual(request?.effectiveFrom, "2026-10-06")
    }

    @MainActor
    func testFailedPreviewCannotSavePreviousRecommendation() async {
        let service = DogGoalTestService()
        let model = DogGoalViewModel(service: service)
        await model.load(dogID: 1, percentage: 100)
        await service.failNextPreview()
        await model.load(dogID: 1, percentage: 150)
        XCTAssertNil(model.preview)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.canSave(percentage: 100))
        XCTAssertFalse(model.canSave(percentage: 150))
    }

    func testDogDecodesBackendContractAndFormatsAge() throws {
        let json = #"""
        {
          "id": 7,
          "name": "Milo",
          "photo": null,
          "breed": {
            "id": 3,
            "name": "Mixed Breed",
            "energy_level": "MODERATE",
            "default_size": "MEDIUM",
            "is_brachycephalic": false
          },
          "age_months": 38,
          "size": "MEDIUM",
          "is_brachycephalic": false,
          "created_at": "2026-09-01T00:00:00Z"
        }
        """#.data(using: .utf8)!

        let dog = try JSONDecoder().decode(Dog.self, from: json)

        XCTAssertEqual(dog.name, "Milo")
        XCTAssertEqual(dog.breed.energyLevel, .moderate)
        XCTAssertEqual(dog.ageMonths, 38)
        XCTAssertNil(dog.dateOfBirth)
        XCTAssertEqual(dog.ageDescription, "3 yrs 2 mo")
    }

    func testDogWriteRequestEncodesSnakeCaseContract() throws {
        let request = DogWriteRequest(
            name: "Milo",
            breedID: 12,
            ageMonths: 38,
            size: .medium,
            isBrachycephalic: false
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["breed_id"] as? Int, 12)
        XCTAssertEqual(object["age_months"] as? Int, 38)
        XCTAssertEqual(object["size"] as? String, "MEDIUM")
        XCTAssertEqual(object["is_brachycephalic"] as? Bool, false)
        XCTAssertNil(object["breedID"])
        XCTAssertNil(object["date_of_birth"])
    }

    func testBirthdayRequestEncodesDateOnlyWithoutTimezoneConversion() throws {
        let request = DogWriteRequest(
            name: "Coco", breedID: 1, ageMonths: 24, size: .small,
            isBrachycephalic: false, dateOfBirth: "2024-02-29"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
        XCTAssertEqual(object["date_of_birth"] as? String, "2024-02-29")
    }

    func testBirthdayDecodeAndCurrentAgeUseBirthdayInsteadOfStaleAge() throws {
        let json = #"""
        {"id":7,"name":"Milo","breed":{"id":3,"name":"Mixed Breed",
         "energy_level":"MODERATE","default_size":"MEDIUM","is_brachycephalic":false},
         "age_months":1,"date_of_birth":"2024-09-25","size":"MEDIUM",
         "is_brachycephalic":false,"created_at":"2026-09-01T00:00:00Z"}
        """#.data(using: .utf8)!
        let dog = try JSONDecoder().decode(Dog.self, from: json)
        XCTAssertEqual(dog.dateOfBirth, "2024-09-25")
        XCTAssertEqual(dog.currentAgeMonths(on: try XCTUnwrap(DogBirthday.date(from: "2026-09-24"))), 23)
        XCTAssertEqual(dog.currentAgeMonths(on: try XCTUnwrap(DogBirthday.date(from: "2026-09-25"))), 24)
    }

    func testBirthdayAgeHandlesMonthEndsAndLeapDays() throws {
        for (birthday, today, expected) in [
            ("2025-01-31", "2025-02-27", 0),
            ("2025-01-31", "2025-02-28", 1),
            ("2024-02-29", "2025-02-27", 11),
            ("2024-02-29", "2025-02-28", 12),
            ("2024-02-29", "2028-02-28", 47),
            ("2024-02-29", "2028-02-29", 48),
            ("2026-09-25", "2026-09-25", 0)
        ] {
            let date = try XCTUnwrap(DogBirthday.date(from: today))
            XCTAssertEqual(DogBirthday.ageMonths(birthday: birthday, on: date), expected)
        }
    }

    func testBirthdayParsingRejectsInvalidOrFutureDatesAndPreservesDateOnly() throws {
        for invalid in ["2023-02-29", "2024-04-31", "2024-2-09", "2024-02-29T00:00:00Z", ""] {
            XCTAssertNil(DogBirthday.date(from: invalid))
        }
        for value in ["2024-02-29", "2026-09-25", "2025-12-31"] {
            let date = try XCTUnwrap(DogBirthday.date(from: value))
            XCTAssertEqual(DogBirthday.string(from: date), value)
        }
        let today = try XCTUnwrap(DogBirthday.date(from: "2026-09-25"))
        XCTAssertNil(DogBirthday.ageMonths(birthday: "2026-09-26", on: today))
    }

    @MainActor
    func testTwoDogLimitIsPreservedAfterServiceIntegration() async {
        let service = DogLimitService()
        let model = DogViewModel(service: service)
        await model.load()
        XCTAssertEqual(model.dogs.count, 2)
        XCTAssertFalse(model.canAddDog)
        let didSave = await model.save(
            dog: nil,
            request: DogWriteRequest(
                name: "Third", breedID: 1, ageMonths: 0,
                size: .small, isBrachycephalic: false
            )
        )
        XCTAssertFalse(didSave)
        let creates = await service.creates
        XCTAssertEqual(creates, 0)
    }
}

private actor DogLimitService: DogServicing {
    private(set) var creates = 0
    private let breed = Breed(
        id: 1, name: "Mixed", energyLevel: .moderate,
        defaultSize: .small, isBrachycephalic: false
    )
    func getDogs() async throws -> [Dog] {
        (1...2).map {
            Dog(
                id: $0, name: "Dog \($0)", breed: breed, ageMonths: 0,
                size: .small, isBrachycephalic: false, createdAt: "2026-09-09T00:00:00Z"
            )
        }
    }
    func getBreeds() async throws -> [Breed] { [breed] }
    func createDog(_ request: DogWriteRequest) async throws -> Dog {
        creates += 1
        throw APIError.invalidResponse
    }
    func updateDog(id: Int, request: DogWriteRequest) async throws -> Dog { throw APIError.invalidResponse }
    func deleteDog(id: Int) async throws {}
}

private actor DogGoalTestService: DogServicing {
    private(set) var savedRequest: DogGoalRequest?
    private var fail = false
    private var failSave = false
    private var holdPreview = false
    private var previewGate: CheckedContinuation<Void, Never>?
    private var previewStarted: CheckedContinuation<Void, Never>?
    func failNextSave() { failSave = true }
    func holdNextPreview() { holdPreview = true }
    func waitForPreview() async { if previewGate != nil { return }; await withCheckedContinuation { previewStarted = $0 } }
    func releasePreview() { previewGate?.resume(); previewGate = nil }
    func failNextPreview() { fail = true }
    func previewGoal(dogID: Int, percentage: Int) async throws -> DogGoalPreview {
        if holdPreview {
            holdPreview = false
            await withCheckedContinuation { previewGate = $0; previewStarted?.resume(); previewStarted = nil }
        }
        if fail { throw APIError.invalidResponse }
        return DogGoalPreview(eligible: true, missingInputs: [], reason: nil,
            effectiveFrom: "2026-10-06", ownerAdjustment: NSDecimalNumber(value: percentage).dividing(by: 100).stringValue,
            suggestedMinutes: "62.5", targetSeconds: 1875, currentTarget: nil, scheduledTargets: [])
    }
    func saveGoal(dogID: Int, request: DogGoalRequest) async throws -> DogGoalPreview {
        savedRequest = request
        if failSave { failSave = false; throw APIError.network("Response interrupted") }
        return try await previewGoal(dogID: dogID, percentage: 50)
    }
    func getDogs() async throws -> [Dog] { [] }
    func getBreeds() async throws -> [Breed] { [] }
    func createDog(_ request: DogWriteRequest) async throws -> Dog { throw APIError.invalidResponse }
    func updateDog(id: Int, request: DogWriteRequest) async throws -> Dog { throw APIError.invalidResponse }
    func deleteDog(id: Int) async throws {}
}

private actor DeferredDogService: DogServicing {
    private var listHeld = false
    private var createHeld = false
    private var gate: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private(set) var photoUploads = 0
    private let breed = Breed(id: 1, name: "Mixed", energyLevel: .moderate,
        defaultSize: .medium, isBrachycephalic: false)
    private var dog: Dog {
        Dog(id: 1, name: "Milo", breed: breed, ageMonths: 24, size: .medium,
            isBrachycephalic: false, createdAt: "2026-10-06T00:00:00Z")
    }
    func holdList() { listHeld = true }
    func holdCreate() { createHeld = true }
    func waitUntilHeld() async {
        if gate != nil { return }
        await withCheckedContinuation { entered = $0 }
    }
    private func pause() async {
        await withCheckedContinuation { continuation in
            gate = continuation
            entered?.resume()
            entered = nil
        }
    }
    func release() { gate?.resume(); gate = nil }
    func getDogs() async throws -> [Dog] { if listHeld { await pause() }; return [dog] }
    func getBreeds() async throws -> [Breed] { [breed] }
    func createDog(_ request: DogWriteRequest) async throws -> Dog { if createHeld { await pause() }; return dog }
    func updateDog(id: Int, request: DogWriteRequest) async throws -> Dog { dog }
    func deleteDog(id: Int) async throws {}
    func uploadPhoto(dogID: Int, data: Data) async throws -> Dog { photoUploads += 1; return dog }
}

private actor DogSessionAuth: AuthServing {
    nonisolated let credentialEvents = AsyncStream<CredentialEvent> { _ in }
    func restoreUser() async throws -> User? { User(id: 1, email: "old", displayName: "Old", role: .owner) }
    func login(email: String, password: String) async throws -> AuthResponse {
        AuthResponse(access: "new", refresh: "new", user: User(id: 2, email: email, displayName: "New", role: .owner))
    }
    func register(email: String, password: String, displayName: String) async throws -> AuthResponse { throw APIError.invalidResponse }
    func persist(_ tokens: AuthTokens) async throws {}
    func clearSession() async throws {}
    func updateProfile(displayName: String) async throws -> User { throw APIError.invalidResponse }
}
