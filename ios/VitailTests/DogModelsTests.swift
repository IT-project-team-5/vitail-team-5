import XCTest
@testable import Vitail

final class DogModelsTests: XCTestCase {
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
    func testTenDogLimitIsPreservedAfterServiceIntegration() async {
        let service = DogLimitService()
        let model = DogViewModel(service: service)
        await model.load()
        XCTAssertEqual(model.dogs.count, 10)
        XCTAssertFalse(model.canAddDog)
        let didSave = await model.save(
            dog: nil,
            request: DogWriteRequest(
                name: "Eleventh", breedID: 1, ageMonths: 0,
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
        (1...10).map {
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
