import Foundation
import XCTest
@testable import CodexMonitor

final class CodexBinaryLocatorTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBinaryLocatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: rootURL)
        rootURL = nil
    }

    func testFindsNestedCLIInsideResolvedApplication() throws {
        let applicationURL = rootURL.appendingPathComponent("Renamed Codex.app")
        let binaryURL = try makeBinary(
            in: applicationURL,
            relativePath: "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        )
        let locator = CodexBinaryLocator(
            applicationURLProvider: { applicationURL },
            fallbackPaths: []
        )

        XCTAssertEqual(try locator.locate(), binaryURL)
    }

    func testPrefersNestedCLIOverLegacyBinary() throws {
        let applicationURL = rootURL.appendingPathComponent("ChatGPT.app")
        let binaryURL = try makeBinary(
            in: applicationURL,
            relativePath: "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        )
        _ = try makeBinary(in: applicationURL, relativePath: "Contents/Resources/codex")
        let locator = CodexBinaryLocator(
            applicationURLProvider: { applicationURL },
            fallbackPaths: []
        )

        XCTAssertEqual(try locator.locate(), binaryURL)
    }

    func testFallsBackToLegacyBinaryWhenNestedCLIIsNotExecutable() throws {
        let applicationURL = rootURL.appendingPathComponent("ChatGPT.app")
        _ = try makeBinary(
            in: applicationURL,
            relativePath: "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            permissions: 0o644
        )
        let binaryURL = try makeBinary(in: applicationURL, relativePath: "Contents/Resources/codex")
        let locator = CodexBinaryLocator(
            applicationURLProvider: { applicationURL },
            fallbackPaths: []
        )

        XCTAssertEqual(try locator.locate(), binaryURL)
    }

    func testFindsNestedCLIFallbacksWithoutApplicationRegistration() throws {
        for applicationName in ["ChatGPT.app", "Codex.app"] {
            let binaryPath = "/Applications/\(applicationName)/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
            let fileManager = ExecutableFileManager(executablePath: binaryPath)
            let locator = CodexBinaryLocator(
                fileManager: fileManager,
                applicationURLProvider: { nil }
            )

            XCTAssertEqual(try locator.locate().path, binaryPath)
        }
    }

    private func makeBinary(in applicationURL: URL, relativePath: String, permissions: Int = 0o755) throws -> URL {
        let binaryURL = applicationURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: binaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: binaryURL)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: binaryURL.path)
        return binaryURL
    }
}

private final class ExecutableFileManager: FileManager, @unchecked Sendable {
    private let executablePath: String

    init(executablePath: String) {
        self.executablePath = executablePath
        super.init()
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        path == executablePath
    }
}
