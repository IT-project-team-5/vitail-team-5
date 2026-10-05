import Foundation

/// What a shared activity card may show. Deliberately has no route, coordinates or place
/// names: live or historical location must never leave the device through sharing.
struct ActivityShareSummary: Equatable, Sendable {
    let date: Date
    let distanceKilometres: Double
    let activeDuration: TimeInterval
    let dogNames: [String]
    /// Only known once the server has confirmed the walk.
    let pointsAwarded: Int?

    init(walk: WalkRecord) {
        date = walk.startedAt
        distanceKilometres = walk.distanceKilometres
        activeDuration = walk.activeDuration
        dogNames = walk.dogs.map(\.name)
        pointsAwarded = walk.serverSummary?.pointsAwarded
    }
}

/// The owner decides what is on the card; everything defaults to visible, nothing hidden by us.
struct ActivityShareOptions: Hashable, Sendable {
    var showDate = true
    var showDogNames = true
    var showPoints = true
}

enum ActivityShareFormat {
    static func distance(_ kilometres: Double) -> String {
        String(format: "%.2f km", max(0, kilometres))
    }

    static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval < Double(Int.max) else { return "—" }
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m \(total % 60)s"
    }

    static func dogs(_ names: [String]) -> String? {
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        switch cleaned.count {
        case 0: return nil
        case 1: return "with \(cleaned[0])"
        case 2: return "with \(cleaned[0]) & \(cleaned[1])"
        default: return "with \(cleaned[0]), \(cleaned[1]) & \(cleaned.count - 2) more"
        }
    }

    static func accessibilityDescription(_ summary: ActivityShareSummary, options: ActivityShareOptions) -> String {
        var parts = ["Vitail walk card", "Distance \(distance(summary.distanceKilometres))",
                     "Walking time \(duration(summary.activeDuration))"]
        if options.showDogNames, let dogs = dogs(summary.dogNames) { parts.append("Walked \(dogs)") }
        if options.showPoints, let points = summary.pointsAwarded { parts.append("\(points) points earned") }
        return parts.joined(separator: ". ")
    }
}
