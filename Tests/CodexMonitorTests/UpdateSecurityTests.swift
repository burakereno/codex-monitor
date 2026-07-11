import Foundation
import XCTest
@testable import CodexMonitor

final class UpdateSecurityTests: XCTestCase {
    private let validSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testVerifiedManifestAcceptsMatchingArtifactContract() throws {
        let artifact = try makeArtifact(contents: Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: artifact.deletingLastPathComponent()) }

        let manifest = UpdateManifest(
            version: "1.2.3",
            asset: "CodexMonitor.dmg",
            sha256: validSHA256,
            bundleIdentifier: "dev.local.CodexMonitor",
            teamIdentifier: "66K3EFBVB6"
        )

        XCTAssertNoThrow(
            try UpdateSecurity.verify(
                manifest: manifest,
                artifactURL: artifact,
                expectedVersion: "1.2.3",
                expectedAsset: "CodexMonitor.dmg",
                expectedBundleIdentifier: "dev.local.CodexMonitor",
                expectedTeamIdentifier: "66K3EFBVB6"
            )
        )
    }

    func testVerifiedManifestRejectsWrongPublisherAndCorruptArtifact() throws {
        let artifact = try makeArtifact(contents: Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: artifact.deletingLastPathComponent()) }

        let wrongPublisher = UpdateManifest(
            version: "1.2.3",
            asset: "CodexMonitor.dmg",
            sha256: validSHA256,
            bundleIdentifier: "dev.local.CodexMonitor",
            teamIdentifier: "OTHERTEAM"
        )
        XCTAssertThrowsError(
            try UpdateSecurity.verify(
                manifest: wrongPublisher,
                artifactURL: artifact,
                expectedVersion: "1.2.3",
                expectedAsset: "CodexMonitor.dmg",
                expectedBundleIdentifier: "dev.local.CodexMonitor",
                expectedTeamIdentifier: "66K3EFBVB6"
            )
        ) { error in
            XCTAssertEqual(error as? UpdateSecurityError, .teamIdentifierMismatch)
        }

        let wrongHash = UpdateManifest(
            version: "1.2.3",
            asset: "CodexMonitor.dmg",
            sha256: String(repeating: "0", count: 64),
            bundleIdentifier: "dev.local.CodexMonitor",
            teamIdentifier: "66K3EFBVB6"
        )
        XCTAssertThrowsError(
            try UpdateSecurity.verify(
                manifest: wrongHash,
                artifactURL: artifact,
                expectedVersion: "1.2.3",
                expectedAsset: "CodexMonitor.dmg",
                expectedBundleIdentifier: "dev.local.CodexMonitor",
                expectedTeamIdentifier: "66K3EFBVB6"
            )
        ) { error in
            XCTAssertEqual(error as? UpdateSecurityError, .checksumMismatch)
        }
    }

    private func makeArtifact(contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let artifact = directory.appendingPathComponent("CodexMonitor.dmg")
        try contents.write(to: artifact)
        return artifact
    }
}
