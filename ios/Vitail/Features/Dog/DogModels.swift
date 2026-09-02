import Foundation

enum BreedEnergyLevel: String, Codable, Sendable {
    case low = "LOW"
    case moderate = "MODERATE"
    case high = "HIGH"
}

enum DogSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small = "SMALL"
    case medium = "MEDIUM"
    case large = "LARGE"

    var id: Self { self }
    var label: String { rawValue.capitalized }
}

enum DogAgeInput {
    static let monthOptions = Array(0...11)

    static func formValues(forAgeMonths ageMonths: Int) -> (years: Int, months: Int) {
        let normalizedAge = max(ageMonths, 0)
        return (
            years: normalizedAge / 12,
            months: normalizedAge % 12
        )
    }

    static func totalMonths(years: Int, months: Int) -> Int? {
        guard years >= 0, monthOptions.contains(months) else { return nil }
        let (yearMonths, yearOverflow) = years.multipliedReportingOverflow(by: 12)
        let (totalMonths, totalOverflow) = yearMonths.addingReportingOverflow(months)
        return yearOverflow || totalOverflow ? nil : totalMonths
    }
}

struct Breed: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let name: String
    let energyLevel: BreedEnergyLevel
    let defaultSize: DogSize
    let isBrachycephalic: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case energyLevel = "energy_level"
        case defaultSize = "default_size"
        case isBrachycephalic = "is_brachycephalic"
    }
}

struct Dog: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    var name: String
    var photo: String?
    var breed: Breed
    var ageMonths: Int
    var size: DogSize
    var isBrachycephalic: Bool
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, photo, breed, size
        case ageMonths = "age_months"
        case isBrachycephalic = "is_brachycephalic"
        case createdAt = "created_at"
    }

    var ageDescription: String {
        let years = ageMonths / 12
        let months = ageMonths % 12
        if years == 0 { return "\(months) mo" }
        if months == 0 { return "\(years) yr\(years == 1 ? "" : "s")" }
        return "\(years) yr\(years == 1 ? "" : "s") \(months) mo"
    }
}

struct DogWriteRequest: Encodable, Sendable {
    let name: String
    let breedID: Int
    let ageMonths: Int
    let size: DogSize
    let isBrachycephalic: Bool

    enum CodingKeys: String, CodingKey {
        case name, size
        case breedID = "breed_id"
        case ageMonths = "age_months"
        case isBrachycephalic = "is_brachycephalic"
    }
}

struct DogGoal: Decodable, Sendable {
    struct Factors: Decodable, Sendable {
        let breedEnergyLevel: BreedEnergyLevel
        let ageMonths: Int
        let size: DogSize
        let isBrachycephalic: Bool

        enum CodingKeys: String, CodingKey {
            case size
            case breedEnergyLevel = "breed_energy_level"
            case ageMonths = "age_months"
            case isBrachycephalic = "is_brachycephalic"
        }
    }

    let dogID: Int
    let status: String
    let recommendedDurationMinutes: Int?
    let factors: Factors
    let unresolvedRequirements: [String]

    enum CodingKeys: String, CodingKey {
        case status, factors
        case dogID = "dog_id"
        case recommendedDurationMinutes = "recommended_duration_minutes"
        case unresolvedRequirements = "unresolved_requirements"
    }
}
