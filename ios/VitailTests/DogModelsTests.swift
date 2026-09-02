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
    }

    func testPendingGoalDecodesWithoutInventedDuration() throws {
        let json = #"""
        {
          "dog_id": 7,
          "status": "RULES_PENDING",
          "recommended_duration_minutes": null,
          "factors": {
            "breed_energy_level": "HIGH",
            "age_months": 24,
            "size": "MEDIUM",
            "is_brachycephalic": false
          },
          "unresolved_requirements": ["Base duration by breed energy level"]
        }
        """#.data(using: .utf8)!

        let goal = try JSONDecoder().decode(DogGoal.self, from: json)
        XCTAssertEqual(goal.status, "RULES_PENDING")
        XCTAssertNil(goal.recommendedDurationMinutes)
    }

    func testDogAgeInputUsesZeroThroughElevenMonths() {
        XCTAssertEqual(DogAgeInput.monthOptions, Array(0...11))
    }

    func testDogAgeInputRoundTripsBackendValuesIncludingZero() throws {
        for storedAge in [0, 1, 11, 12, 13, 36, 38, 119] {
            let age = DogAgeInput.formValues(forAgeMonths: storedAge)
            let reconstructedAge = try XCTUnwrap(
                DogAgeInput.totalMonths(years: age.years, months: age.months)
            )

            XCTAssertEqual(reconstructedAge, storedAge)
        }
    }

    func testDogAgeInputRejectsInvalidAndOverflowingValues() {
        XCTAssertNil(DogAgeInput.totalMonths(years: -1, months: 0))
        XCTAssertNil(DogAgeInput.totalMonths(years: 0, months: -1))
        XCTAssertNil(DogAgeInput.totalMonths(years: 0, months: 12))
        XCTAssertNil(DogAgeInput.totalMonths(years: Int.max, months: 0))
    }
}
