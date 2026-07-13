import AppKit
import Foundation

enum CodexAppServerError: LocalizedError {
    case codexBinaryNotFound
    case launchFailed(String)
    case timeout
    case missingRateLimits
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .codexBinaryNotFound:
            return "Codex CLI bulunamadi."
        case .launchFailed(let message):
            return "Codex app-server baslatilamadi: \(message)"
        case .timeout:
            return "Codex app-server yanit vermedi."
        case .missingRateLimits:
            return "Codex limit verisi okunamadi."
        case .serverError(let message):
            return message
        }
    }
}

struct CodexBinaryLocator: @unchecked Sendable {
    private let fileManager: FileManager
    private let applicationURLProvider: () -> URL?
    private let fallbackPaths: [String]

    init(
        fileManager: FileManager = .default,
        applicationURLProvider: @escaping () -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        },
        fallbackPaths: [String] = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
    ) {
        self.fileManager = fileManager
        self.applicationURLProvider = applicationURLProvider
        self.fallbackPaths = fallbackPaths
    }

    func locate() throws -> URL {
        var candidates: [URL] = []

        if let applicationURL = applicationURLProvider() {
            candidates.append(applicationURL.appendingPathComponent("Contents/Resources/codex"))
        }

        candidates.append(contentsOf: fallbackPaths.map { URL(fileURLWithPath: $0) })

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        throw CodexAppServerError.codexBinaryNotFound
    }
}

protocol CodexAccountReading: Sendable {
    func readRateLimits() async throws -> CodexAccountSnapshot
    func rateLimitUpdateEvents() async -> AsyncStream<Void>
}

extension CodexAccountReading {
    func rateLimitUpdateEvents() async -> AsyncStream<Void> {
        AsyncStream { _ in }
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }
}

/// Bridges the blocking stdio app-server transport into an AsyncStream.
/// All mutable Process state is protected by `lock`; this is the safety
/// invariant behind the narrowly scoped `@unchecked Sendable` conformance.
private final class CodexRateLimitEventObserver: @unchecked Sendable {
    private let binaryLocator: CodexBinaryLocator
    private let appVersion: String
    private let lock = NSLock()
    private var process: Process?
    private var isStopped = false

    init(binaryLocator: CodexBinaryLocator, appVersion: String) {
        self.binaryLocator = binaryLocator
        self.appVersion = appVersion
    }

    func start(continuation: AsyncStream<Void>.Continuation) {
        DispatchQueue.global(qos: .utility).async { [self] in
            run(continuation: continuation)
        }
    }

    func stop() {
        lock.lock()
        isStopped = true
        let process = process
        lock.unlock()

        if process?.isRunning == true {
            process?.terminate()
        }
    }

    private func run(continuation: AsyncStream<Void>.Continuation) {
        defer { continuation.finish() }

        do {
            let codexURL = try binaryLocator.locate()
            let process = Process()
            let stdin = Pipe()
            let stdout = Pipe()

            process.executableURL = codexURL
            process.arguments = ["app-server", "--listen", "stdio://"]
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice

            guard register(process: process) else { return }
            defer {
                if process.isRunning {
                    process.terminate()
                }
                try? stdin.fileHandleForWriting.close()
                clear(process: process)
            }

            do {
                try process.run()
            } catch {
                return
            }

            if stopped {
                process.terminate()
                return
            }

            let timeoutState = TimeoutState()
            let initializationTimeout = DispatchWorkItem {
                if process.isRunning {
                    timeoutState.markTimedOut()
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + 8,
                execute: initializationTimeout
            )

            try send([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-monitor",
                        "title": "Codex Monitor",
                        "version": appVersion
                    ],
                    "capabilities": [
                        "experimentalApi": true,
                        "optOutNotificationMethods": [
                            "thread/started",
                            "thread/status/changed",
                            "thread/tokenUsage/updated"
                        ]
                    ]
                ]
            ], to: stdin.fileHandleForWriting)

            _ = try readJSONLine(
                from: stdout.fileHandleForReading,
                matchingId: 1,
                timeoutState: timeoutState
            )
            initializationTimeout.cancel()

            try send(["method": "initialized"], to: stdin.fileHandleForWriting)

            while !stopped, let line = readLineData(from: stdout.fileHandleForReading) {
                guard
                    let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    object["method"] as? String == "account/rateLimits/updated"
                else {
                    continue
                }

                continuation.yield(())
            }
        } catch {
            return
        }
    }

    private var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    private func register(process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return false }
        self.process = process
        return true
    }

    private func clear(process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        handle.write(data)
        handle.write(Data([0x0a]))
    }

    private func readJSONLine(
        from handle: FileHandle,
        matchingId expectedId: Int,
        timeoutState: TimeoutState
    ) throws -> [String: Any] {
        while true {
            guard let line = readLineData(from: handle) else {
                if timeoutState.didTimeOut {
                    throw CodexAppServerError.timeout
                }
                throw CodexAppServerError.missingRateLimits
            }

            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let id = object["id"] as? Int,
                id == expectedId
            else {
                continue
            }

            return object
        }
    }

    private func readLineData(from handle: FileHandle) -> Data? {
        var buffer = Data()

        while true {
            let chunk = handle.readData(ofLength: 1)
            if chunk.isEmpty {
                return buffer.isEmpty ? nil : buffer
            }

            if chunk.first == 0x0a {
                return buffer
            }

            buffer.append(chunk)
        }
    }
}

final class CodexAppServerClient: CodexAccountReading, @unchecked Sendable {
    private let decoder = JSONDecoder()
    private let binaryLocator: CodexBinaryLocator

    init(binaryLocator: CodexBinaryLocator = CodexBinaryLocator()) {
        self.binaryLocator = binaryLocator
    }

    func readRateLimits() async throws -> CodexAccountSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try self.readRateLimitsSync())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func rateLimitUpdateEvents() async -> AsyncStream<Void> {
        let observer = CodexRateLimitEventObserver(
            binaryLocator: binaryLocator,
            appVersion: appVersion
        )

        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { @Sendable _ in
                observer.stop()
            }
            observer.start(continuation: continuation)
        }
    }

    private func readRateLimitsSync() throws -> CodexAccountSnapshot {
        let codexURL = try binaryLocator.locate()
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = codexURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        defer {
            if process.isRunning {
                process.terminate()
            }
            try? stdin.fileHandleForWriting.close()
        }

        let timeoutState = TimeoutState()
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            if process.isRunning {
                timeoutState.markTimedOut()
                process.terminate()
            }
        }

        try send([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codex-monitor",
                    "title": "Codex Monitor",
                    "version": appVersion
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "optOutNotificationMethods": [
                        "thread/started",
                        "thread/status/changed",
                        "thread/tokenUsage/updated"
                    ]
                ]
            ]
        ], to: stdin.fileHandleForWriting)

        _ = try readJSONLine(from: stdout.fileHandleForReading, matchingId: 1, timeoutState: timeoutState)

        try send(["method": "initialized"], to: stdin.fileHandleForWriting)
        try send([
            "id": 2,
            "method": "account/rateLimits/read",
            "params": NSNull()
        ], to: stdin.fileHandleForWriting)

        let response = try readJSONLine(from: stdout.fileHandleForReading, matchingId: 2, timeoutState: timeoutState)
        if let error = response["error"] as? [String: Any] {
            throw CodexAppServerError.serverError(String(describing: error))
        }

        guard let result = response["result"] else {
            if timeoutState.didTimeOut { throw CodexAppServerError.timeout }
            throw CodexAppServerError.missingRateLimits
        }

        let data = try JSONSerialization.data(withJSONObject: result)
        let decoded = try decoder.decode(RateLimitsResponse.self, from: data)
        let rateLimits = (decoded.rateLimitsByLimitId?["codex"] ?? decoded.rateLimits)
            .normalizedCodexWindows
        return CodexAccountSnapshot(
            rateLimits: rateLimits,
            rateLimitResetCredits: decoded.rateLimitResetCredits
        )
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        handle.write(data)
        handle.write(Data([0x0a]))
    }

    private func readJSONLine(
        from handle: FileHandle,
        matchingId expectedId: Int,
        timeoutState: TimeoutState
    ) throws -> [String: Any] {
        while true {
            guard let line = readLineData(from: handle) else {
                if timeoutState.didTimeOut {
                    throw CodexAppServerError.timeout
                }
                throw CodexAppServerError.missingRateLimits
            }

            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let id = object["id"] as? Int,
                id == expectedId
            else {
                continue
            }

            return object
        }
    }

    private func readLineData(from handle: FileHandle) -> Data? {
        var buffer = Data()

        while true {
            let chunk = handle.readData(ofLength: 1)
            if chunk.isEmpty {
                return buffer.isEmpty ? nil : buffer
            }

            if chunk.first == 0x0a {
                return buffer
            }

            buffer.append(chunk)
        }
    }
}
