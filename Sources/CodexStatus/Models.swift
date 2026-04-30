import Foundation

struct RateLimitsResponse: Decodable {
    let rateLimits: RateLimitsSnapshot
    let rateLimitsByLimitId: [String: RateLimitsSnapshot]?
}

struct RateLimitsSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
    let planType: String?
    let rateLimitReachedType: String?
}

struct RateLimitWindow: Decodable {
    let usedPercent: Int
    let resetsAt: Int?
    let windowDurationMins: Int?
}

struct CreditsSnapshot: Decodable {
    let balance: String?
    let hasCredits: Bool
    let unlimited: Bool
}

extension RateLimitWindow {
    var remainingPercent: Int {
        min(100, max(0, 100 - usedPercent))
    }

    var remainingColorLevel: RateLimitColorLevel {
        if remainingPercent <= 20 { return .low }
        if remainingPercent <= 50 { return .medium }
        return .high
    }

    var resetDate: Date? {
        resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    var displayName: String {
        guard let windowDurationMins else { return "Usage" }
        if windowDurationMins == 300 { return "5 hours" }
        if windowDurationMins == 10_080 { return "Weekly" }
        if windowDurationMins % 1_440 == 0 { return "\(windowDurationMins / 1_440)d window" }
        if windowDurationMins % 60 == 0 { return "\(windowDurationMins / 60)h window" }
        return "\(windowDurationMins)m window"
    }
}

enum RateLimitColorLevel {
    case high
    case medium
    case low
}

enum MenuBarDisplayVersion: String, CaseIterable, Identifiable {
    case version1
    case version2

    static let storageKey = "menuBarDisplayVersion"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .version1:
            return "V1"
        case .version2:
            return "V2"
        }
    }

    var description: String {
        switch self {
        case .version1:
            return "Icon and compact percentages"
        case .version2:
            return "Icon, 5h percent, then W percent"
        }
    }
}
