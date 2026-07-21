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
    func rateLimitUpdateEvents() async -> AsyncStream<RateLimitsSnapshot>
}

extension CodexAccountReading {
    func rateLimitUpdateEvents() async -> AsyncStream<RateLimitsSnapshot> {
        AsyncStream { _ in }
    }
}

private actor CodexAppServerConnection {
    private enum State {
        case stopped
        case starting
        case ready
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeoutTask: Task<Void, Never>
    }

    private let binaryLocator: CodexBinaryLocator
    private let appVersion: String
    private let decoder = JSONDecoder()

    private var state = State.stopped
    private var process: Process?
    private var inputHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var startupWaiters: [CheckedContinuation<Void, Error>] = []
    private var eventContinuations: [UUID: AsyncStream<RateLimitsSnapshot>.Continuation] = [:]

    init(binaryLocator: CodexBinaryLocator, appVersion: String) {
        self.binaryLocator = binaryLocator
        self.appVersion = appVersion
    }

    func readRateLimits() async throws -> CodexAccountSnapshot {
        try await ensureStarted()
        let response = try await sendRequest(
            method: "account/rateLimits/read",
            params: NSNull()
        )

        if let error = response["error"] as? [String: Any] {
            throw CodexAppServerError.serverError(String(describing: error))
        }

        guard let result = response["result"] else {
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

    func rateLimitUpdateEvents() async -> AsyncStream<RateLimitsSnapshot> {
        let identifier = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: RateLimitsSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        eventContinuations[identifier] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeEventContinuation(identifier)
            }
        }

        do {
            try await ensureStarted()
        } catch {
            eventContinuations.removeValue(forKey: identifier)
            continuation.finish()
        }

        return stream
    }

    func stop() {
        failConnection(with: CancellationError())
    }

    private func ensureStarted() async throws {
        switch state {
        case .ready:
            return
        case .starting:
            try await withCheckedThrowingContinuation { continuation in
                startupWaiters.append(continuation)
            }
        case .stopped:
            state = .starting
            do {
                try startProcess()
                _ = try await sendRequest(
                    method: "initialize",
                    params: [
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
                )
                try sendNotification(method: "initialized")
                state = .ready
                let waiters = startupWaiters
                startupWaiters.removeAll()
                waiters.forEach { $0.resume() }
            } catch {
                failConnection(with: error)
                throw error
            }
        }
    }

    private func startProcess() throws {
        let codexURL = try binaryLocator.locate()
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()

        process.executableURL = codexURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }

        self.process = process
        inputHandle = stdin.fileHandleForWriting
        nextRequestID = 1

        let (lines, lineContinuation) = AsyncStream.makeStream(of: Data.self)
        let outputHandle = stdout.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while let line = Self.readLineData(from: outputHandle) {
                lineContinuation.yield(line)
            }
            lineContinuation.finish()
        }

        readerTask = Task { [weak self] in
            for await line in lines {
                guard !Task.isCancelled else { return }
                await self?.receive(line)
            }
            await self?.readerFinished()
        }
    }

    private func sendRequest(method: String, params: Any) async throws -> [String: Any] {
        guard process?.isRunning == true, let inputHandle else {
            throw CodexAppServerError.launchFailed("Connection is not running.")
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let data = try JSONSerialization.data(withJSONObject: [
            "id": requestID,
            "method": method,
            "params": params
        ])

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(8))
                } catch {
                    return
                }
                await self?.requestTimedOut(requestID)
            }
            pendingRequests[requestID] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            inputHandle.write(data)
            inputHandle.write(Data([0x0a]))
        }
    }

    private func sendNotification(method: String) throws {
        guard process?.isRunning == true, let inputHandle else {
            throw CodexAppServerError.launchFailed("Connection is not running.")
        }
        let data = try JSONSerialization.data(withJSONObject: ["method": method])
        inputHandle.write(data)
        inputHandle.write(Data([0x0a]))
    }

    private func receive(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }

        if let requestID = object["id"] as? Int,
           let request = pendingRequests.removeValue(forKey: requestID) {
            request.timeoutTask.cancel()
            request.continuation.resume(returning: object)
            return
        }

        guard
            object["method"] as? String == "account/rateLimits/updated",
            let params = object["params"],
            JSONSerialization.isValidJSONObject(params),
            let data = try? JSONSerialization.data(withJSONObject: params),
            let update = try? decoder.decode(RateLimitsUpdatedNotification.self, from: data)
        else {
            return
        }

        let snapshot = update.rateLimits.normalizedCodexWindows
        eventContinuations.values.forEach { $0.yield(snapshot) }
    }

    private func requestTimedOut(_ requestID: Int) {
        guard pendingRequests[requestID] != nil else { return }
        failConnection(with: CodexAppServerError.timeout)
    }

    private func readerFinished() {
        guard state != .stopped else { return }
        failConnection(with: CodexAppServerError.missingRateLimits)
    }

    private func removeEventContinuation(_ identifier: UUID) {
        eventContinuations.removeValue(forKey: identifier)
    }

    private func failConnection(with error: Error) {
        state = .stopped

        readerTask?.cancel()
        readerTask = nil

        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        try? inputHandle?.close()
        inputHandle = nil

        let requests = pendingRequests.values
        pendingRequests.removeAll()
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }

        let waiters = startupWaiters
        startupWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }

        let continuations = eventContinuations.values
        eventContinuations.removeAll()
        continuations.forEach { $0.finish() }
    }

    private nonisolated static func readLineData(from handle: FileHandle) -> Data? {
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

final class CodexAppServerClient: CodexAccountReading, Sendable {
    private let connection: CodexAppServerConnection

    init(binaryLocator: CodexBinaryLocator = CodexBinaryLocator()) {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        connection = CodexAppServerConnection(
            binaryLocator: binaryLocator,
            appVersion: appVersion
        )
    }

    deinit {
        let connection = connection
        Task {
            await connection.stop()
        }
    }

    func readRateLimits() async throws -> CodexAccountSnapshot {
        try await connection.readRateLimits()
    }

    func rateLimitUpdateEvents() async -> AsyncStream<RateLimitsSnapshot> {
        await connection.rateLimitUpdateEvents()
    }
}
