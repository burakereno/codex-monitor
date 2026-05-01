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

protocol RateLimitsReading: Sendable {
    func readRateLimits() async throws -> RateLimitsSnapshot
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

final class CodexAppServerClient: RateLimitsReading, @unchecked Sendable {
    private let decoder = JSONDecoder()

    func readRateLimits() async throws -> RateLimitsSnapshot {
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

    private func readRateLimitsSync() throws -> RateLimitsSnapshot {
        let codexURL = try locateCodexBinary()
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
        return decoded.rateLimitsByLimitId?["codex"] ?? decoded.rateLimits
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private func locateCodexBinary() throws -> URL {
        let bundled = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let commonPaths = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]

        for path in commonPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        throw CodexAppServerError.codexBinaryNotFound
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
