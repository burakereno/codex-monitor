import Darwin
import XCTest
@testable import CodexMonitor

final class AppServerLineReaderTests: XCTestCase {
    func testReadsMultipleLinesEmptyLinesAndUnterminatedTail() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        pipe.fileHandleForWriting.write(Data("first\n\nüçüncü 🐈\ntail".utf8))
        try pipe.fileHandleForWriting.close()
        var reader = AppServerLineReader(handle: pipe.fileHandleForReading)

        XCTAssertEqual(try reader.readLine(), Data("first".utf8))
        XCTAssertEqual(try reader.readLine(), Data())
        XCTAssertEqual(try reader.readLine(), Data("üçüncü 🐈".utf8))
        XCTAssertEqual(try reader.readLine(), Data("tail".utf8))
        XCTAssertNil(try reader.readLine())
    }

    func testReturnsShortResponseWhileWriterRemainsOpen() throws {
        let pipe = Pipe()
        let received = expectation(description: "Response arrives before EOF")
        DispatchQueue.global(qos: .utility).async {
            defer { try? pipe.fileHandleForReading.close() }
            var reader = AppServerLineReader(handle: pipe.fileHandleForReading)
            do {
                let line = try reader.readLine()
                XCTAssertEqual(line, Data("response".utf8))
            } catch {
                XCTFail("Reading response failed: \(error)")
            }
            received.fulfill()
        }

        pipe.fileHandleForWriting.write(Data("response\n".utf8))
        wait(for: [received], timeout: 2)
        try pipe.fileHandleForWriting.close()
    }

    func testReadsMessageLargerThanBufferAndPreservesFollowingMessage() throws {
        let pipe = Pipe()
        let finished = expectation(description: "Writer finished")
        let message = String(repeating: "a", count: 16_383) + "🐈" + String(repeating: "z", count: 40_000)
        DispatchQueue.global(qos: .utility).async {
            pipe.fileHandleForWriting.write(Data((message + "\nnext\n").utf8))
            try? pipe.fileHandleForWriting.close()
            finished.fulfill()
        }
        defer { try? pipe.fileHandleForReading.close() }
        var reader = AppServerLineReader(handle: pipe.fileHandleForReading)

        XCTAssertEqual(try reader.readLine(), Data(message.utf8))
        XCTAssertEqual(try reader.readLine(), Data("next".utf8))
        XCTAssertNil(try reader.readLine())
        wait(for: [finished], timeout: 2)
    }

    func testEmptyPipeReturnsEOF() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        try pipe.fileHandleForWriting.close()
        var reader = AppServerLineReader(handle: pipe.fileHandleForReading)
        XCTAssertNil(try reader.readLine())
    }

    func testReadErrorIsReported() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        defer { try? pipe.fileHandleForWriting.close() }
        var reader = AppServerLineReader(handle: pipe.fileHandleForWriting)

        XCTAssertThrowsError(try reader.readLine()) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EBADF))
        }
    }

    func testLongLivedReaderDoesNotAccumulateTemporaryData() throws {
        let pipe = Pipe()
        let finished = expectation(description: "Memory measured before worker exits")
        let lineCount = 20_000

        DispatchQueue.global(qos: .utility).async {
            defer { try? pipe.fileHandleForReading.close() }
            // Keep the outer pool alive for the entire read, just like the
            // app-server worker. Measuring after it drains would hide the bug.
            do {
                try autoreleasepool {
                    var reader = AppServerLineReader(handle: pipe.fileHandleForReading)
                    let baseline = Self.allocatedBytes()
                    for _ in 0..<lineCount {
                        let line = try reader.readLine()
                        XCTAssertEqual(line, Data([0x61]))
                    }
                    let growth = Int64(Self.allocatedBytes()) - Int64(baseline)
                    // The old one-byte FileHandle loop retains over 300 MiB here.
                    // Leave room for unrelated XCTest/runtime allocations.
                    XCTAssertLessThan(growth, 8 * 1_048_576)
                }
            } catch {
                XCTFail("Reading messages failed: \(error)")
            }
            finished.fulfill()
        }

        pipe.fileHandleForWriting.write(Data(String(repeating: "a\n", count: lineCount).utf8))
        wait(for: [finished], timeout: 5)
        try pipe.fileHandleForWriting.close()
    }

    private static func allocatedBytes() -> UInt64 {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return UInt64(statistics.size_in_use)
    }
}
