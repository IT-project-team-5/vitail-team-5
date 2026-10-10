import Foundation

enum BreedEnergyLevel: String, Codable, Sendable {
    case low = "LOW"
    case moderate = "MODERATE"
    case high = "HIGH"
    case veryHigh = "VERY_HIGH"
    case unknown = "UNKNOWN"

    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

enum DogSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small = "SMALL"
    case medium = "MEDIUM"
    case large = "LARGE"

    var id: Self { self }
    var label: String { rawValue.capitalized }
}

enum DogBirthday {
    // Date-only values use the product's calendar, not the device's time zone.
    static let timeZone = TimeZone(identifier: "Australia/Melbourne")!
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func date(from value: String) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard value.count == 10, parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              year > 0, (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              string(from: date) == value else { return nil }
        return date
    }

    static func string(from date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func ageMonths(birthday: String, on date: Date = Date()) -> Int? {
        guard let birthDate = self.date(from: birthday) else { return nil }
        let birth = calendar.dateComponents([.year, .month, .day], from: birthDate)
        let today = calendar.dateComponents([.year, .month, .day], from: date)
        guard string(from: date) >= birthday,
              let lastDay = calendar.range(of: .day, in: .month, for: date)?.last else { return nil }
        let months = (today.year! - birth.year!) * 12 + today.month! - birth.month!
        let anniversaryDay = min(birth.day!, lastDay)
        return max(0, months - (today.day! < anniversaryDay ? 1 : 0))
    }

    static func display(_ birthday: String) -> String {
        guard let date = date(from: birthday) else { return "Not recorded" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        return formatter.string(from: date)
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
    var dateOfBirth: String? = nil
    var weightKg: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, photo, breed, size
        case ageMonths = "age_months"
        case isBrachycephalic = "is_brachycephalic"
        case createdAt = "created_at"
        case dateOfBirth = "date_of_birth"
        case weightKg = "weight_kg"
    }

    func currentAgeMonths(on date: Date = Date()) -> Int {
        dateOfBirth.flatMap { DogBirthday.ageMonths(birthday: $0, on: date) } ?? ageMonths
    }

    var ageDescription: String {
        let currentAge = currentAgeMonths()
        let years = currentAge / 12
        let months = currentAge % 12
        if years == 0 { return "\(months) mo" }
        if months == 0 { return "\(years) yr\(years == 1 ? "" : "s")" }
        return "\(years) yr\(years == 1 ? "" : "s") \(months) mo"
    }
}

struct DogWriteRequest: Codable, Sendable {
    var requestID: UUID? = nil
    let name: String
    let breedID: Int
    let ageMonths: Int
    let size: DogSize
    let isBrachycephalic: Bool
    let dateOfBirth: String?
    let weightKg: String?

    init(name: String, breedID: Int, ageMonths: Int, size: DogSize,
         isBrachycephalic: Bool, dateOfBirth: String? = nil, weightKg: String? = nil) {
        self.name = name
        self.breedID = breedID
        self.ageMonths = ageMonths
        self.size = size
        self.isBrachycephalic = isBrachycephalic
        self.dateOfBirth = dateOfBirth
        self.weightKg = weightKg
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(requestID, forKey: .requestID)
        try container.encode(breedID, forKey: .breedID)
        try container.encode(ageMonths, forKey: .ageMonths)
        try container.encode(size, forKey: .size)
        try container.encode(isBrachycephalic, forKey: .isBrachycephalic)
        try container.encodeIfPresent(dateOfBirth, forKey: .dateOfBirth)
        try container.encode(weightKg, forKey: .weightKg)
    }

    enum CodingKeys: String, CodingKey {
        case name, size
        case requestID = "request_id"
        case breedID = "breed_id"
        case ageMonths = "age_months"
        case dateOfBirth = "date_of_birth"
        case isBrachycephalic = "is_brachycephalic"
        case weightKg = "weight_kg"
    }
}

struct DogGoalRequest: Codable, Sendable {
    var requestID: UUID? = nil
    let ownerAdjustment: String
    let effectiveFrom: String
    enum CodingKeys: String, CodingKey {
        case ownerAdjustment = "owner_adjustment", effectiveFrom = "effective_from"
        case requestID = "request_id"
    }
}

struct DogGoalTarget: Decodable, Identifiable, Sendable {
    let id: Int
    let effectiveFrom: String
    let targetSeconds: Int?
    let policyVersion: String
    let calculationInputs: DogGoalCalculationInputs?
    enum CodingKeys: String, CodingKey {
        case id, effectiveFrom = "effective_from", targetSeconds = "target_seconds", policyVersion = "policy_version"
        case calculationInputs = "calculation_inputs"
    }
    var duration: String { targetSeconds.map(DogGoalPreview.duration) ?? "Paused" }
}

struct DogGoalCalculationInputs: Decodable, Sendable {
    let ownerAdjustment: String?
    let suggestedMinutes: String?
    enum CodingKeys: String, CodingKey {
        case ownerAdjustment = "owner_adjustment", suggestedMinutes = "suggested_minutes"
    }
    var description: String? {
        guard let ownerAdjustment, let adjustment = Decimal(string: ownerAdjustment),
              let suggestedMinutes, let recommendation = Decimal(string: suggestedMinutes) else { return nil }
        return "\(NSDecimalNumber(decimal: adjustment * 100).stringValue)% of \(NSDecimalNumber(decimal: recommendation).stringValue) min recommended"
    }
}

struct DogGoalPreview: Decodable, Sendable {
    let eligible: Bool
    let missingInputs: [String]
    let reason: String?
    let effectiveFrom: String
    let ownerAdjustment: String
    let suggestedMinutes: String?
    let targetSeconds: Int?
    let currentTarget: DogGoalTarget?
    let scheduledTargets: [DogGoalTarget]
    enum CodingKeys: String, CodingKey {
        case eligible, reason, missingInputs = "missing_inputs", effectiveFrom = "effective_from"
        case ownerAdjustment = "owner_adjustment", suggestedMinutes = "suggested_minutes"
        case targetSeconds = "target_seconds", currentTarget = "current_target", scheduledTargets = "scheduled_targets"
    }
    var recommendation: String {
        guard let suggestedMinutes, let value = Decimal(string: suggestedMinutes) else { return "Unavailable" }
        return "\(NSDecimalNumber(decimal: value).stringValue) min"
    }
    static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60, remainder = seconds % 60
        return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder) sec"
    }
}
