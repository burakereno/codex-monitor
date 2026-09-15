import Darwin
import Foundation

/// Reads newline-delimited messages from a blocking pipe on its owning worker.
struct AppServerLineReader {
    private let handle: FileHandle
    private var buffer = [UInt8](repeating: 0, count: 16_384)
    private var position = 0
    private var count = 0

    init(handle: FileHandle) {
        self.handle = handle
    }

    mutating func readLine() throws -> Data? {
        var line = Data()

        while true {
            if position == count {
                // FileHandle.readData(ofLength: 1) creates autoreleased NSData
                // storage for every byte. This worker can live for days, so use
                // one reusable buffer without Foundation's temporary objects.
                let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
                }
                if bytesRead < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
                guard bytesRead > 0 else {
                    return line.isEmpty ? nil : line
                }
                position = 0
                count = bytesRead
            }

            let end = buffer[position..<count].firstIndex(of: 0x0a) ?? count
            line.append(contentsOf: buffer[position..<end])
            position = end

            if position < count {
                position += 1
                return line
            }
        }
    }
}
