import Foundation

protocol CodexUsageSummaryReading: Sendable {
    func readUsageSummary(referenceDate: Date) async throws -> CodexUsageSummary
}

actor CodexUsageLogReader: CodexUsageSummaryReading {
    private let rootURL: URL
    private let calendar: Calendar
    private let iso8601FormatStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private var fileCache: [URL: CachedFileUsage] = [:]

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
        let files = sessionFiles(referenceDate: referenceDate)
        guard !files.isEmpty else {
            fileCache.removeAll()
            return .empty(referenceDate: referenceDate, calendar: calendar)
        }

        let activeFiles = Set(files)
        fileCache = fileCache.filter { activeFiles.contains($0.key) }

        let todayStart = calendar.startOfDay(for: referenceDate)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? referenceDate
        let fifteenDayStart = calendar.date(byAdding: .day, value: -14, to: todayStart) ?? todayStart
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: referenceDate)) ?? todayStart

        var dailyTotals: [Date: Int] = [:]
        var todayTotals = TokenUsageTotals.zero
        var monthTotals = TokenUsageTotals.zero
        var modelTotals: [String: Int] = [:]

        for file in files {
            let fingerprint = try fileFingerprint(for: file)
            let usage: FileUsageContribution
            if let cached = fileCache[file], cached.fingerprint == fingerprint {
                usage = cached.usage
            } else {
                usage = try fileUsage(in: file)
                fileCache[file] = CachedFileUsage(fingerprint: fingerprint, usage: usage)
            }

            for (day, totals) in usage.totalsByDay
                where day >= fifteenDayStart && day < tomorrowStart {
                dailyTotals[day, default: 0] += totals.totalTokens
            }

            if let totals = usage.totalsByDay[todayStart] {
                todayTotals.add(totals)
            }

            if let totals = usage.totalsByMonth[monthStart] {
                monthTotals.add(totals)
            }

            if let fileModelTotals = usage.modelTotalsByMonth[monthStart] {
                for (model, total) in fileModelTotals {
                    modelTotals[model, default: 0] += total
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

    private func fileFingerprint(for file: URL) throws -> FileFingerprint {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileFingerprint(
            size: values.fileSize ?? 0,
            modificationDate: values.contentModificationDate
        )
    }

    private func fileUsage(in file: URL) throws -> FileUsageContribution {
        let decoder = sessionLogDecoder()
        var model = "unknown"
        var usage = FileUsageContribution()

        try forEachLine(in: file) { line in
            guard !line.isEmpty else { return }
            guard let entry = try? decoder.decode(CodexSessionLogEntry.self, from: line) else { return }

            if let entryModel = modelName(from: entry.payload) {
                model = entryModel
            }

            guard
                entry.type == "event_msg",
                entry.payload?.type == "token_count",
                let timestamp = entry.timestamp,
                let tokenUsage = entry.payload?.info?.lastTokenUsage
            else {
                return
            }

            let totals = tokenUsage.totals
            let day = calendar.startOfDay(for: timestamp)
            let month = calendar.date(
                from: calendar.dateComponents([.year, .month], from: timestamp)
            ) ?? day
            usage.totalsByDay[day, default: .zero].add(totals)
            usage.totalsByMonth[month, default: .zero].add(totals)
            usage.modelTotalsByMonth[month, default: [:]][model, default: 0] += totals.totalTokens
        }

        return usage
    }

    private func forEachLine(in file: URL, body: (Data) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var buffer = Data()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            buffer.append(chunk)
            var lineStart = buffer.startIndex

            while lineStart < buffer.endIndex,
                  let newline = buffer[lineStart...].firstIndex(of: 0x0a) {
                body(Data(buffer[lineStart..<newline]))
                lineStart = buffer.index(after: newline)
            }

            if lineStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
        }

        if !buffer.isEmpty {
            body(buffer)
        }
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
            if let date = try? Date(value, strategy: self.iso8601FormatStyle) {
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

}

private struct FileFingerprint: Equatable {
    let size: Int
    let modificationDate: Date?
}

private struct CachedFileUsage {
    let fingerprint: FileFingerprint
    let usage: FileUsageContribution
}

private struct FileUsageContribution {
    var totalsByDay: [Date: TokenUsageTotals] = [:]
    var totalsByMonth: [Date: TokenUsageTotals] = [:]
    var modelTotalsByMonth: [Date: [String: Int]] = [:]
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
