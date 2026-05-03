import AppKit
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    private static let owner = "burakereno"
    private static let repo = "codex-monitor"
    private static let assetName = "CodexMonitor.dmg"
    private static let productionBundleIdentifier = "dev.local.CodexMonitor"
    private static let checkInterval: TimeInterval = 2 * 60 * 60
    private static let minimumManualCheckInterval: TimeInterval = 30 * 60
    private static let minimumVisibleCheckDuration: UInt64 = 500_000_000

    @Published private(set) var latestVersion: String?
    @Published private(set) var downloadURL: URL?
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
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor in
                await UpdateChecker.shared.checkForUpdates(force: true)
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
        lastError = nil

        let url = URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexMonitor-UpdateChecker", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode)
            {
                throw UpdateError.badStatus(httpResponse.statusCode)
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let tag = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName

            latestVersion = tag
            downloadURL = release.assets.first(where: { $0.name == Self.assetName })?.browserDownloadURL
        } catch {
            lastError = error.localizedDescription
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

        guard let downloadURL, let latestVersion, !isDownloading else { return }

        isDownloading = true
        downloadProgress = 0
        lastError = nil

        let task = URLSession.shared.downloadTask(with: downloadURL) { [weak self] tmpURL, _, error in
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

                let downloads = try? FileManager.default.url(
                    for: .downloadsDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let fileName = "CodexMonitor-\(self.latestVersion ?? "latest")-\(UUID().uuidString).dmg"
                let destination = (downloads ?? FileManager.default.temporaryDirectory)
                    .appendingPathComponent(fileName)

                try? FileManager.default.removeItem(at: destination)

                do {
                    try FileManager.default.moveItem(at: tmpURL, to: destination)
                    self.installUpdate(dmgURL: destination, expectedVersion: latestVersion)
                } catch {
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

    private func installUpdate(dmgURL: URL, expectedVersion: String) {
        let currentBundle = URL(fileURLWithPath: Bundle.main.bundlePath)
        let targetBundle = currentBundle.path.hasPrefix("/Applications/")
            ? currentBundle
            : URL(fileURLWithPath: "/Applications/Codex Monitor.app")

        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-monitor-install-\(UUID().uuidString).sh")
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-monitor-install.log")
        let mountPointURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-monitor-mount-\(UUID().uuidString)")

        let script = """
        #!/bin/bash
        set -u
        exec >"\(logURL.path)" 2>&1

        PARENT_PID="$1"
        DMG="$2"
        EXPECTED_BUNDLE_ID="$3"
        EXPECTED_VERSION="$4"
        TARGET="\(targetBundle.path)"
        MOUNT_POINT="\(mountPointURL.path)"
        TARGET_PARENT="$(/usr/bin/dirname "$TARGET")"
        STAGED_APP="$TARGET_PARENT/.Codex Monitor.app.update.$$"
        BACKUP_APP="$TARGET_PARENT/.Codex Monitor.app.previous.$$"
        MOUNT_ATTACHED=0

        cleanup_mount() {
            if [ "$MOUNT_ATTACHED" = "1" ]; then
                /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet -force 2>/dev/null || true
                MOUNT_ATTACHED=0
            fi
            /bin/rmdir "$MOUNT_POINT" 2>/dev/null || true
        }

        relaunch_existing_app() {
            if [ -d "$TARGET" ]; then
                /usr/bin/open "$TARGET" 2>/dev/null || true
            fi
        }

        fail() {
            echo "[install] error: $*"
            cleanup_mount
            /bin/rm -rf "$STAGED_APP"
            if [ ! -d "$TARGET" ] && [ -d "$BACKUP_APP" ]; then
                /bin/mv "$BACKUP_APP" "$TARGET" 2>/dev/null || true
            fi
            relaunch_existing_app
            if [ -f "$DMG" ]; then
                /usr/bin/open "$DMG" 2>/dev/null || true
            fi
            exit 1
        }

        echo "[install] waiting for parent $PARENT_PID to exit"
        for _ in $(seq 1 50); do
            kill -0 "$PARENT_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -0 "$PARENT_PID" 2>/dev/null && kill "$PARENT_PID" 2>/dev/null
        sleep 0.5

        echo "[install] mounting $DMG"
        /bin/mkdir -p "$MOUNT_POINT" || fail "could not create mount point: $MOUNT_POINT"
        /usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_POINT" "$DMG" || fail "could not mount DMG"
        MOUNT_ATTACHED=1
        echo "[install] mount point: $MOUNT_POINT"

        SRC="$MOUNT_POINT/Codex Monitor.app"
        if [ ! -d "$SRC" ]; then
            fail "source app not found at $SRC"
        fi

        SRC_INFO="$SRC/Contents/Info.plist"
        SRC_EXEC="$SRC/Contents/MacOS/CodexMonitor"
        SRC_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$SRC_INFO" 2>/dev/null || true)
        SRC_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SRC_INFO" 2>/dev/null || true)

        if [ "$SRC_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
            fail "bundle id mismatch: expected $EXPECTED_BUNDLE_ID, got $SRC_BUNDLE_ID"
        fi

        if [ "$SRC_VERSION" != "$EXPECTED_VERSION" ]; then
            fail "version mismatch: expected $EXPECTED_VERSION, got $SRC_VERSION"
        fi

        if [ ! -x "$SRC_EXEC" ]; then
            fail "executable not found or not executable: $SRC_EXEC"
        fi

        echo "[install] staging new app at $STAGED_APP"
        /bin/rm -rf "$STAGED_APP" "$BACKUP_APP"
        /usr/bin/ditto "$SRC" "$STAGED_APP" || fail "could not stage new app"

        echo "[install] stripping quarantine"
        /usr/bin/xattr -cr "$STAGED_APP" || fail "could not strip quarantine"

        if [ -d "$TARGET" ]; then
            echo "[install] moving old app to backup"
            /bin/mv "$TARGET" "$BACKUP_APP" || fail "could not move old app to backup"
        fi

        echo "[install] installing staged app"
        if ! /bin/mv "$STAGED_APP" "$TARGET"; then
            if [ -d "$BACKUP_APP" ]; then
                /bin/mv "$BACKUP_APP" "$TARGET" 2>/dev/null || true
            fi
            fail "could not install staged app"
        fi

        /bin/rm -rf "$BACKUP_APP"

        echo "[install] detaching dmg"
        cleanup_mount

        echo "[install] removing downloaded dmg"
        rm -f "$DMG"

        echo "[install] launching new app"
        /usr/bin/open "$TARGET"

        rm -f "\(scriptURL.path)"
        echo "[install] done"
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            lastError = "Could not write installer script: \(error.localizedDescription)"
            NSWorkspace.shared.open(dmgURL)
            return
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = scriptURL
        task.arguments = ["\(pid)", dmgURL.path, Self.productionBundleIdentifier, expectedVersion]

        do {
            try task.run()
        } catch {
            lastError = "Could not launch installer: \(error.localizedDescription)"
            NSWorkspace.shared.open(dmgURL)
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

    private static func parse(_ value: String) -> [Int] {
        value
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}

private enum UpdateError: LocalizedError {
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badStatus(let statusCode):
            return "GitHub returned HTTP \(statusCode)"
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}
