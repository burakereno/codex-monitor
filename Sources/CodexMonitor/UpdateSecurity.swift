import CryptoKit
import Foundation

struct UpdateManifest: Codable, Equatable, Sendable {
    let version: String
    let asset: String
    let sha256: String
    let bundleIdentifier: String
    let teamIdentifier: String
}

enum UpdateSecurityError: LocalizedError, Equatable {
    case versionMismatch
    case assetMismatch
    case bundleIdentifierMismatch
    case teamIdentifierMismatch
    case invalidChecksum
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .versionMismatch:
            return "Update manifest version does not match the release."
        case .assetMismatch:
            return "Update manifest asset does not match the expected DMG."
        case .bundleIdentifierMismatch:
            return "Update manifest bundle identifier is invalid."
        case .teamIdentifierMismatch:
            return "Update publisher identity is invalid."
        case .invalidChecksum:
            return "Update manifest SHA-256 is invalid."
        case .checksumMismatch:
            return "Downloaded update failed SHA-256 verification."
        }
    }
}

enum UpdateSecurity {
    static let burakTeamIdentifier = "66K3EFBVB6"

    static func verify(
        manifest: UpdateManifest,
        artifactURL: URL,
        expectedVersion: String,
        expectedAsset: String,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String = burakTeamIdentifier
    ) throws {
        guard manifest.version == expectedVersion else {
            throw UpdateSecurityError.versionMismatch
        }
        guard manifest.asset == expectedAsset else {
            throw UpdateSecurityError.assetMismatch
        }
        guard manifest.bundleIdentifier == expectedBundleIdentifier else {
            throw UpdateSecurityError.bundleIdentifierMismatch
        }
        guard manifest.teamIdentifier == expectedTeamIdentifier else {
            throw UpdateSecurityError.teamIdentifierMismatch
        }

        let expectedHash = manifest.sha256.lowercased()
        guard expectedHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw UpdateSecurityError.invalidChecksum
        }
        guard try sha256(of: artifactURL) == expectedHash else {
            throw UpdateSecurityError.checksumMismatch
        }
    }

    static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func launchInstaller(
        parentPID: Int32,
        dmgURL: URL,
        targetURL: URL,
        expectedBundleIdentifier: String,
        expectedVersion: String,
        appBundleName: String,
        executableName: String,
        expectedSHA256: String
    ) throws {
        let workDirectory = dmgURL.deletingLastPathComponent()
        let scriptURL = workDirectory.appendingPathComponent("install-update.sh")
        try installerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )

        let process = Process()
        process.executableURL = scriptURL
        process.arguments = [
            String(parentPID),
            dmgURL.path,
            targetURL.path,
            expectedBundleIdentifier,
            expectedVersion,
            appBundleName,
            executableName,
            burakTeamIdentifier,
            expectedSHA256,
            workDirectory.path,
        ]
        try process.run()
    }

    private static let installerScript = #"""
    #!/bin/bash
    set -uo pipefail

    PARENT_PID="$1"
    DMG="$2"
    TARGET="$3"
    EXPECTED_BUNDLE_ID="$4"
    EXPECTED_VERSION="$5"
    APP_BUNDLE_NAME="$6"
    EXECUTABLE_NAME="$7"
    EXPECTED_TEAM_ID="$8"
    EXPECTED_SHA256="$9"
    shift 9
    WORK_DIR="$1"

    LOG="$WORK_DIR/install.log"
    MOUNT_POINT="$WORK_DIR/mount"
    TARGET_PARENT="$(/usr/bin/dirname "$TARGET")"
    STAGED_APP="$TARGET_PARENT/.$EXECUTABLE_NAME.update.$$"
    BACKUP_APP="$TARGET_PARENT/.$EXECUTABLE_NAME.previous.$$"
    MOUNT_ATTACHED=0

    exec >"$LOG" 2>&1

    cleanup_mount() {
        if [ "$MOUNT_ATTACHED" = "1" ]; then
            /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet -force 2>/dev/null || true
            MOUNT_ATTACHED=0
        fi
        /bin/rmdir "$MOUNT_POINT" 2>/dev/null || true
    }

    restore_backup() {
        if [ -d "$BACKUP_APP" ]; then
            /bin/rm -rf "$TARGET"
            /bin/mv "$BACKUP_APP" "$TARGET" 2>/dev/null || true
        fi
    }

    rollback() {
        cleanup_mount
        /bin/rm -rf "$STAGED_APP"
        restore_backup
        if [ -d "$TARGET" ]; then
            /usr/bin/open "$TARGET" 2>/dev/null || true
        fi
    }

    fail() {
        echo "[install] error: $*"
        rollback
        exit 1
    }

    verify_app() {
        local app="$1"
        local info="$app/Contents/Info.plist"
        local executable="$app/Contents/MacOS/$EXECUTABLE_NAME"
        local bundle_id version details team requirement

        [ -d "$app" ] || fail "app not found: $app"
        bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$info" 2>/dev/null || true)
        version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info" 2>/dev/null || true)
        [ "$bundle_id" = "$EXPECTED_BUNDLE_ID" ] || fail "bundle id mismatch"
        [ "$version" = "$EXPECTED_VERSION" ] || fail "version mismatch"
        [ -x "$executable" ] || fail "expected executable is missing"

        /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" || fail "strict app signature verification failed"
        details=$(/usr/bin/codesign -dv --verbose=4 "$app" 2>&1) || fail "could not read app signature"
        team=$(printf '%s\n' "$details" | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/tail -1)
        [ "$team" = "$EXPECTED_TEAM_ID" ] || fail "app TeamIdentifier mismatch"
        requirement="=identifier \"$EXPECTED_BUNDLE_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
        /usr/bin/codesign --verify --deep --strict -R "$requirement" "$app" || fail "designated requirement failed"
        /usr/sbin/spctl --assess --type execute --verbose=4 "$app" || fail "Gatekeeper rejected app"
    }

    echo "[install] waiting for parent $PARENT_PID"
    for _ in $(/usr/bin/seq 1 50); do
        /bin/kill -0 "$PARENT_PID" 2>/dev/null || break
        /bin/sleep 0.1
    done
    if /bin/kill -0 "$PARENT_PID" 2>/dev/null; then
        /bin/kill "$PARENT_PID" 2>/dev/null || true
        /bin/sleep 0.5
    fi
    /bin/kill -0 "$PARENT_PID" 2>/dev/null && fail "parent app did not exit"

    ACTUAL_SHA256=$(/usr/bin/shasum -a 256 "$DMG" | /usr/bin/awk '{print $1}') || fail "could not hash DMG"
    [ "$ACTUAL_SHA256" = "$EXPECTED_SHA256" ] || fail "DMG SHA-256 mismatch"

    /usr/bin/codesign --verify --strict --verbose=2 "$DMG" || fail "strict DMG signature verification failed"
    DMG_DETAILS=$(/usr/bin/codesign -dv --verbose=4 "$DMG" 2>&1) || fail "could not read DMG signature"
    DMG_TEAM=$(printf '%s\n' "$DMG_DETAILS" | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/tail -1)
    [ "$DMG_TEAM" = "$EXPECTED_TEAM_ID" ] || fail "DMG TeamIdentifier mismatch"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" || fail "Gatekeeper rejected DMG"

    /bin/mkdir -p "$MOUNT_POINT" || fail "could not create mount point"
    /usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_POINT" "$DMG" || fail "could not mount DMG"
    MOUNT_ATTACHED=1

    SOURCE_APP="$MOUNT_POINT/$APP_BUNDLE_NAME"
    verify_app "$SOURCE_APP"

    /bin/rm -rf "$STAGED_APP" "$BACKUP_APP"
    /usr/bin/ditto "$SOURCE_APP" "$STAGED_APP" || fail "could not stage app"
    verify_app "$STAGED_APP"

    if [ -d "$TARGET" ]; then
        /bin/mv "$TARGET" "$BACKUP_APP" || fail "could not create backup"
    fi
    /bin/mv "$STAGED_APP" "$TARGET" || fail "could not install staged app"

    /usr/bin/open "$TARGET" || fail "could not request app launch"
    LAUNCHED=0
    for _ in $(/usr/bin/seq 1 100); do
        if /usr/bin/pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
            LAUNCHED=1
            break
        fi
        /bin/sleep 0.1
    done
    [ "$LAUNCHED" = "1" ] || fail "new app did not launch"

    /bin/rm -rf "$BACKUP_APP"
    cleanup_mount
    /bin/rm -f "$DMG"
    /bin/rm -rf "$WORK_DIR"
    exit 0
    """#
}
