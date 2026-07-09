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

struct CodexUsageSummary: Equatable {
    let dailyUsage: [DailyTokenUsage]
    let today: TokenUsageTotals
    let currentMonth: TokenUsageTotals
    let modelBreakdown: [ModelTokenUsage]

    static func empty(referenceDate: Date = Date(), calendar: Calendar = .current) -> CodexUsageSummary {
        let todayStart = calendar.startOfDay(for: referenceDate)
        let days = (0..<7).reversed().map { offset -> DailyTokenUsage in
            let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
            return DailyTokenUsage(date: date, totalTokens: 0)
        }

        return CodexUsageSummary(
            dailyUsage: days,
            today: .zero,
            currentMonth: .zero,
            modelBreakdown: []
        )
    }
}

struct DailyTokenUsage: Equatable, Identifiable {
    let date: Date
    let totalTokens: Int

    var id: Date { date }
}

struct TokenUsageTotals: Equatable {
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var reasoningOutputTokens: Int
    var totalTokens: Int

    static let zero = TokenUsageTotals(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0
    )

    mutating func add(_ other: TokenUsageTotals) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        outputTokens += other.outputTokens
        reasoningOutputTokens += other.reasoningOutputTokens
        totalTokens += other.totalTokens
    }
}

struct ModelTokenUsage: Equatable, Identifiable {
    let model: String
    let totalTokens: Int
    let percentage: Int

    var id: String { model }
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

    var pace: RateLimitPace {
        if remainingPercent == 0 { return .limited }
        if remainingPercent <= 20 { return .tight }
        if remainingPercent <= 50 { return .steady }
        return .safe
    }

    var resetDate: Date? {
        resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    func compactResetText(relativeTo date: Date = Date()) -> String? {
        guard let resetDate else { return nil }

        let seconds = max(0, Int(resetDate.timeIntervalSince(date)))
        let minutes = max(1, Int(ceil(Double(seconds) / 60)))

        if minutes < 60 {
            return "\(minutes)m"
        }

        if windowDurationMins == 300 || minutes < 1_440 {
            let hours = max(1, Int(ceil(Double(minutes) / 60)))
            return "\(hours)h"
        }

        let days = max(1, Int(ceil(Double(minutes) / 1_440)))
        return "\(days)d"
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

enum RateLimitPace: Equatable {
    case safe
    case steady
    case tight
    case limited

    var title: String {
        switch self {
        case .safe:
            return "safe"
        case .steady:
            return "steady"
        case .tight:
            return "tight"
        case .limited:
            return "limited"
        }
    }
}

enum MenuBarDisplayVersion: String, CaseIterable, Identifiable {
    case version1
    case version2

    static let storageKey = "menuBarDisplayVersion"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .version1:
            return "Small"
        case .version2:
            return "Large"
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

enum MenuBarResetTimePreference {
    static let storageKey = "menuBarShowsResetTimes"

    static var showsResetTimes: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? false
    }
}
