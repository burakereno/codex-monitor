import AppKit
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    private static let owner = "burakereno"
    private static let repo = "codex-monitor"
    private static let assetName = "CodexMonitor.dmg"
    private static let manifestName = "CodexMonitor.dmg.update.json"
    private static let productionBundleIdentifier = "dev.local.CodexMonitor"
    private static let appBundleName = "Codex Monitor.app"
    private static let executableName = "CodexMonitor"
    private static let checkInterval: TimeInterval = 2 * 60 * 60
    private static let minimumManualCheckInterval: TimeInterval = 30 * 60
    private static let minimumVisibleCheckDuration: UInt64 = 500_000_000

    @Published private(set) var latestVersion: String?
    @Published private(set) var downloadURL: URL?
    private var manifestURL: URL?
    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var lastError: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastCheckCompletedAt: Date?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var updateAvailable: Bool {
        guard isProductionBuild else { return false }
        guard let latestVersion else { return false }
        return Self.compare(latestVersion, isNewerThan: currentVersion)
    }

    var isUpToDate: Bool {
        guard let latestVersion, lastError == nil else { return false }
        return !Self.compare(latestVersion, isNewerThan: currentVersion)
    }

    private var timer: Timer?
    private var progressObservation: NSKeyValueObservation?

    private var isProductionBuild: Bool {
        Bundle.main.bundleIdentifier == Self.productionBundleIdentifier
    }

    private init() {}

    func start() {
        timer?.invalidate()
        Task { @MainActor in
            await UpdateChecker.shared.checkForUpdates(force: false, reportsErrors: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor in
                await UpdateChecker.shared.checkForUpdates(force: false, reportsErrors: false)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        progressObservation?.invalidate()
        progressObservation = nil
    }

    func checkForUpdates(force: Bool = false) async {
        await checkForUpdates(force: force, reportsErrors: force)
    }

    private func checkForUpdates(force: Bool, reportsErrors: Bool) async {
        guard !isChecking else { return }

        let now = Date()
        if !force,
           let lastCheckedAt,
           now.timeIntervalSince(lastCheckedAt) < Self.minimumManualCheckInterval
        {
            return
        }

        lastCheckedAt = now
        isChecking = true
        if reportsErrors {
            lastError = nil
        }

        do {
            let releaseInfo = try await Self.fetchLatestReleaseInfo()
            latestVersion = releaseInfo.version
            downloadURL = releaseInfo.downloadURL
            manifestURL = releaseInfo.manifestURL
            lastError = nil
        } catch {
            if reportsErrors {
                lastError = error.localizedDescription
            }
        }

        let elapsed = Date().timeIntervalSince(now)
        if elapsed < 0.5 {
            let remaining = Self.minimumVisibleCheckDuration - UInt64(elapsed * 1_000_000_000)
            try? await Task.sleep(nanoseconds: remaining)
        }

        lastCheckCompletedAt = Date()
        isChecking = false
    }

    func downloadAndInstall() {
        guard isProductionBuild else {
            lastError = "Updates are disabled for local builds."
            return
        }

        guard !isDownloading else { return }

        guard let downloadURL, let manifestURL, let latestVersion else {
            lastError = "Update download is unavailable."
            return
        }

        isDownloading = true
        downloadProgress = 0
        lastError = nil

        let task = URLSession.shared.downloadTask(with: downloadURL) { [weak self] tmpURL, response, error in
            Task { @MainActor in
                guard let self else { return }
                defer {
                    self.isDownloading = false
                    self.downloadProgress = 0
                }

                if let error {
                    self.lastError = error.localizedDescription
                    return
                }

                guard let tmpURL else {
                    self.lastError = "Download failed"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode)
                else {
                    self.lastError = UpdateError.badResponse.localizedDescription
                    return
                }

                let workDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("codex-monitor-update-\(UUID().uuidString)", isDirectory: true)
                let destination = workDirectory.appendingPathComponent(Self.assetName)

                do {
                    try FileManager.default.createDirectory(
                        at: workDirectory,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                    try FileManager.default.moveItem(at: tmpURL, to: destination)
                    let manifest = try await Self.fetchManifest(at: manifestURL)
                    let assetName = Self.assetName
                    let bundleIdentifier = Self.productionBundleIdentifier
                    try await Task.detached {
                        try UpdateSecurity.verify(
                            manifest: manifest,
                            artifactURL: destination,
                            expectedVersion: latestVersion,
                            expectedAsset: assetName,
                            expectedBundleIdentifier: bundleIdentifier
                        )
                    }.value
                    self.installUpdate(
                        dmgURL: destination,
                        expectedVersion: latestVersion,
                        expectedSHA256: manifest.sha256.lowercased()
                    )
                } catch {
                    try? FileManager.default.removeItem(at: workDirectory)
                    self.lastError = error.localizedDescription
                }
            }
        }

        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor in
                self?.downloadProgress = progress.fractionCompleted
            }
        }
        task.resume()
    }

    private func installUpdate(dmgURL: URL, expectedVersion: String, expectedSHA256: String) {
        let currentBundle = URL(fileURLWithPath: Bundle.main.bundlePath)
        let targetBundle = currentBundle.path.hasPrefix("/Applications/")
            ? currentBundle
            : URL(fileURLWithPath: "/Applications/\(Self.appBundleName)")

        do {
            try UpdateSecurity.launchInstaller(
                parentPID: ProcessInfo.processInfo.processIdentifier,
                dmgURL: dmgURL,
                targetURL: targetBundle,
                expectedBundleIdentifier: Self.productionBundleIdentifier,
                expectedVersion: expectedVersion,
                appBundleName: Self.appBundleName,
                executableName: Self.executableName,
                expectedSHA256: expectedSHA256
            )
        } catch {
            lastError = "Could not launch installer: \(error.localizedDescription)"
            return
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        }
    }

    static func compare(_ a: String, isNewerThan b: String) -> Bool {
        let parsedA = parse(a)
        let parsedB = parse(b)

        for index in 0..<max(parsedA.count, parsedB.count) {
            let valueA = index < parsedA.count ? parsedA[index] : 0
            let valueB = index < parsedB.count ? parsedB[index] : 0
            if valueA != valueB { return valueA > valueB }
        }

        return false
    }

    private static func fetchLatestReleaseInfo() async throws -> UpdateReleaseInfo {
        let latestURL = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 12
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("CodexMonitor-UpdateChecker", forHTTPHeaderField: "User-Agent")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.badResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateError.badStatus(httpResponse.statusCode)
        }
        guard let resolvedURL = httpResponse.url else {
            throw UpdateError.missingVersion
        }

        let releaseInfo = try releaseInfo(fromResolvedLatestURL: resolvedURL)
        try await validateDownloadURL(releaseInfo.downloadURL, assetName: assetName)
        try await validateDownloadURL(releaseInfo.manifestURL, assetName: manifestName)
        return releaseInfo
    }

    static func releaseInfo(fromResolvedLatestURL url: URL) throws -> UpdateReleaseInfo {
        let tag = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tag != "latest" else {
            throw UpdateError.missingVersion
        }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty else {
            throw UpdateError.missingVersion
        }

        let downloadURL = URL(string: "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\(assetName)")!
        let manifestURL = URL(string: "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\(manifestName)")!
        return UpdateReleaseInfo(version: version, downloadURL: downloadURL, manifestURL: manifestURL)
    }

    private static func fetchManifest(at url: URL) async throws -> UpdateManifest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexMonitor-UpdateChecker", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw UpdateError.badResponse
        }
        do {
            return try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            throw UpdateError.invalidManifest
        }
    }

    private static func validateDownloadURL(_ url: URL, assetName: String) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 12
        request.setValue("CodexMonitor-UpdateChecker", forHTTPHeaderField: "User-Agent")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateError.badResponse
        }
        if httpResponse.statusCode == 404 {
            throw UpdateError.missingAsset(assetName)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateError.badStatus(httpResponse.statusCode)
        }
    }

    private static func parse(_ value: String) -> [Int] {
        value
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}

enum UpdateError: LocalizedError {
    case badResponse
    case badStatus(Int)
    case missingAsset(String)
    case missingVersion
    case invalidManifest

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "GitHub returned an invalid response"
        case .badStatus(let statusCode):
            return "GitHub returned HTTP \(statusCode)"
        case .missingAsset(let assetName):
            return "GitHub release is missing \(assetName)"
        case .missingVersion:
            return "GitHub release is missing a version tag"
        case .invalidManifest:
            return "GitHub release contains an invalid update manifest"
        }
    }
}

struct UpdateReleaseInfo: Equatable {
    let version: String
    let downloadURL: URL
    let manifestURL: URL
}
