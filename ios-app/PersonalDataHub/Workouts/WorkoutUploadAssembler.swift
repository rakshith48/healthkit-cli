import Foundation

/// Reassembles chunked BLE writes from the Mac CLI into a complete JSON payload.
///
/// Wire format (matches the existing BLE response framing, reversed):
///   Frame 0 : [4-byte BE uint32 totalLength][data bytes...]
///   Frame 1+: [data bytes...]
/// Upload is complete when `buffer.count == totalLength`.
///
/// The assembler is stateless across uploads — call `reset()` on failure or
/// finalization. Made a standalone type so it can be unit-tested without BLE
/// hardware.
struct WorkoutUploadAssembler {

    enum Result: Equatable {
        case idle                             // No upload in progress
        case inProgress(received: Int, expected: Int)
        case complete(Data)                   // Full payload ready for parsing
        case error(String)                    // Protocol violation
    }

    /// Hard cap to prevent hostile/buggy clients from pinning memory.
    static let maxPayloadBytes = 256 * 1024   // 256 KB

    private(set) var buffer = Data()
    private(set) var expectedLength: Int? = nil
    private(set) var lastActivityAt: Date? = nil

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        expectedLength = nil
        lastActivityAt = nil
    }

    /// Ingest a BLE write. Returns the current state of the upload.
    mutating func receive(_ chunk: Data) -> Result {
        lastActivityAt = Date()

        // First chunk — parse length prefix.
        if expectedLength == nil {
            guard chunk.count >= 4 else {
                reset()
                return .error("First chunk must contain 4-byte length prefix (got \(chunk.count) bytes)")
            }
            let len = chunk.prefix(4).withUnsafeBytes { buf in
                UInt32(bigEndian: buf.loadUnaligned(as: UInt32.self))
            }
            let total = Int(len)
            guard total > 0 else {
                reset()
                return .error("Declared length is 0")
            }
            guard total <= Self.maxPayloadBytes else {
                reset()
                return .error("Declared length \(total) exceeds max \(Self.maxPayloadBytes)")
            }
            expectedLength = total
            buffer.append(chunk.dropFirst(4))
        } else {
            buffer.append(chunk)
        }

        guard let expected = expectedLength else {
            return .error("unreachable")
        }

        if buffer.count > expected {
            reset()
            return .error("Received more bytes than declared (\(buffer.count) > \(expected))")
        }

        if buffer.count == expected {
            let done = buffer
            return .complete(done)
        }

        return .inProgress(received: buffer.count, expected: expected)
    }

    /// Returns true if the current upload has gone idle longer than `timeout`.
    /// Caller invokes this on a timer to free stuck uploads.
    func isStale(timeout: TimeInterval, now: Date = Date()) -> Bool {
        guard let last = lastActivityAt else { return false }
        return now.timeIntervalSince(last) > timeout
    }
}
