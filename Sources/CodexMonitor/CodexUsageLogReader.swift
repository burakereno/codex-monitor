import Foundation

protocol CodexUsageSummaryReading: Sendable {
    func readUsageSummary(referenceDate: Date) async throws -> CodexUsageSummary
}

final class CodexUsageLogReader: CodexUsageSummaryReading, @unchecked Sendable {
    private let rootURL: URL
    private let calendar: Calendar

    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions"),
        calendar: Calendar = .current
    ) {
        self.rootURL = rootURL
        self.calendar = calendar
    }

    func readUsageSummary(referenceDate: Date = Date()) async throws -> CodexUsageSummary {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.readUsageSummarySync(referenceDate: referenceDate))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func readUsageSummarySync(referenceDate: Date) throws -> CodexUsageSummary {
        let files = sessionFiles(referenceDate: referenceDate)
        guard !files.isEmpty else {
            return .empty(referenceDate: referenceDate, calendar: calendar)
        }

        let todayStart = calendar.startOfDay(for: referenceDate)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
        let fifteenDayStart = calendar.date(byAdding: .day, value: -14, to: todayStart) ?? todayStart
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: referenceDate)) ?? todayStart
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? tomorrowStart

        var dailyTotals: [Date: Int] = [:]
        var todayTotals = TokenUsageTotals.zero
        var monthTotals = TokenUsageTotals.zero
        var modelTotals: [String: Int] = [:]

        for file in files {
            let fileEvents = try tokenEvents(in: file)
            for event in fileEvents {
                if event.timestamp >= fifteenDayStart && event.timestamp < tomorrowStart {
                    let day = calendar.startOfDay(for: event.timestamp)
                    dailyTotals[day, default: 0] += event.tokens.totalTokens
                }

                if event.timestamp >= todayStart && event.timestamp < tomorrowStart {
                    todayTotals.add(event.tokens)
                }

                if event.timestamp >= monthStart && event.timestamp < nextMonthStart {
                    monthTotals.add(event.tokens)
                    modelTotals[event.model, default: 0] += event.tokens.totalTokens
                }
            }
        }

        let dailyUsage = (0..<15).reversed().map { offset -> DailyTokenUsage in
            let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
            return DailyTokenUsage(date: date, totalTokens: dailyTotals[date, default: 0])
        }

        return CodexUsageSummary(
            dailyUsage: dailyUsage,
            today: todayTotals,
            currentMonth: monthTotals,
            modelBreakdown: modelBreakdown(from: modelTotals)
        )
    }

    private func sessionFiles(referenceDate: Date) -> [URL] {
        var directories = Set<URL>()
        if let monthDirectory = monthDirectory(for: referenceDate) {
            directories.insert(monthDirectory)
        }

        let todayStart = calendar.startOfDay(for: referenceDate)
        for offset in 0..<15 {
            guard
                let date = calendar.date(byAdding: .day, value: -offset, to: todayStart),
                let directory = dayDirectory(for: date)
            else {
                continue
            }
            directories.insert(directory)
        }

        var files = Set<URL>()
        for directory in directories {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                files.insert(url)
            }
        }

        return files.sorted { $0.path < $1.path }
    }

    private func monthDirectory(for date: Date) -> URL? {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else { return nil }
        return rootURL
            .appendingPathComponent(String(format: "%04d", year))
            .appendingPathComponent(String(format: "%02d", month))
    }

    private func dayDirectory(for date: Date) -> URL? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard
            let year = components.year,
            let month = components.month,
            let day = components.day
        else {
            return nil
        }

        return rootURL
            .appendingPathComponent(String(format: "%04d", year))
            .appendingPathComponent(String(format: "%02d", month))
            .appendingPathComponent(String(format: "%02d", day))
    }

    private func tokenEvents(in file: URL) throws -> [CodexTokenEvent] {
        let content = try String(contentsOf: file, encoding: .utf8)
        let decoder = sessionLogDecoder()
        var model = "unknown"
        var events: [CodexTokenEvent] = []

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8) else { continue }
            guard let entry = try? decoder.decode(CodexSessionLogEntry.self, from: data) else { continue }

            if let entryModel = modelName(from: entry.payload) {
                model = entryModel
            }

            guard
                entry.type == "event_msg",
                entry.payload?.type == "token_count",
                let timestamp = entry.timestamp,
                let usage = entry.payload?.info?.lastTokenUsage
            else {
                continue
            }

            events.append(CodexTokenEvent(timestamp: timestamp, model: model, tokens: usage.totals))
        }

        return events
    }

    private func modelName(from payload: CodexSessionLogPayload?) -> String? {
        let directModel = payload?.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let directModel, !directModel.isEmpty {
            return directModel
        }

        let settingsModel = payload?.collaborationMode?.settings?.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let settingsModel, !settingsModel.isEmpty {
            return settingsModel
        }

        return nil
    }

    private func sessionLogDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = CodexUsageLogReader.iso8601Formatter.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp."
            )
        }
        return decoder
    }

    private func modelBreakdown(from totals: [String: Int]) -> [ModelTokenUsage] {
        let total = totals.values.reduce(0, +)
        guard total > 0 else { return [] }

        return totals
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(3)
            .map { model, tokens in
                ModelTokenUsage(
                    model: model,
                    totalTokens: tokens,
                    percentage: Int((Double(tokens) / Double(total) * 100).rounded())
                )
            }
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct CodexSessionLogEntry: Decodable {
    let timestamp: Date?
    let type: String
    let payload: CodexSessionLogPayload?
}

private struct CodexSessionLogPayload: Decodable {
    let type: String?
    let model: String?
    let collaborationMode: CodexSessionCollaborationMode?
    let info: CodexSessionTokenInfo?
}

private struct CodexSessionCollaborationMode: Decodable {
    let settings: CodexSessionCollaborationSettings?
}

private struct CodexSessionCollaborationSettings: Decodable {
    let model: String?
}

private struct CodexSessionTokenInfo: Decodable {
    let lastTokenUsage: CodexSessionTokenUsage?
}

private struct CodexSessionTokenUsage: Decodable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int

    var totals: TokenUsageTotals {
        TokenUsageTotals(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            totalTokens: totalTokens
        )
    }
}

private struct CodexTokenEvent {
    let timestamp: Date
    let model: String
    let tokens: TokenUsageTotals
}
