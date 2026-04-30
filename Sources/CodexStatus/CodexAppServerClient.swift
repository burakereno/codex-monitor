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

final class CodexAppServerClient: @unchecked Sendable {
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

        var didTimeOut = false
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            if process.isRunning {
                didTimeOut = true
                process.terminate()
            }
        }

        try send([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codex-status",
                    "title": "Codex Status",
                    "version": "0.1.0"
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

        _ = try readJSONLine(from: stdout.fileHandleForReading, matchingId: 1)

        try send(["method": "initialized"], to: stdin.fileHandleForWriting)
        try send([
            "id": 2,
            "method": "account/rateLimits/read",
            "params": NSNull()
        ], to: stdin.fileHandleForWriting)

        let response = try readJSONLine(from: stdout.fileHandleForReading, matchingId: 2)
        if let error = response["error"] as? [String: Any] {
            throw CodexAppServerError.serverError(String(describing: error))
        }

        guard let result = response["result"] else {
            if didTimeOut { throw CodexAppServerError.timeout }
            throw CodexAppServerError.missingRateLimits
        }

        let data = try JSONSerialization.data(withJSONObject: result)
        let decoded = try decoder.decode(RateLimitsResponse.self, from: data)
        return decoded.rateLimitsByLimitId?["codex"] ?? decoded.rateLimits
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

    private func readJSONLine(from handle: FileHandle, matchingId expectedId: Int) throws -> [String: Any] {
        while true {
            guard let line = readLineData(from: handle) else {
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
