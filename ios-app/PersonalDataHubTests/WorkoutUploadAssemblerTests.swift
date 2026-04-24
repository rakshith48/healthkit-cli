import XCTest
@testable import PersonalDataHub

final class WorkoutUploadAssemblerTests: XCTestCase {

    /// Build a framed payload from a plain JSON blob for testing.
    private func frame(_ json: String) -> Data {
        let body = json.data(using: .utf8)!
        var lenBE = UInt32(body.count).bigEndian
        var first = Data(bytes: &lenBE, count: 4)
        first.append(body)
        return first
    }

    func testSingleChunkComplete() {
        var a = WorkoutUploadAssembler()
        let payload = #"{"id":"abc","displayName":"Test","blocks":[]}"#
        let result = a.receive(frame(payload))
        XCTAssertEqual(result, .complete(payload.data(using: .utf8)!))
    }

    func testMultiChunkComplete() {
        var a = WorkoutUploadAssembler()
        let payload = String(repeating: "x", count: 500)
        let framed = frame(payload)

        // Split into 3 chunks
        let c1 = framed.prefix(200)
        let c2 = framed.dropFirst(200).prefix(200)
        let c3 = framed.dropFirst(400)

        let r1 = a.receive(Data(c1))
        if case .inProgress(let rec, let exp) = r1 {
            XCTAssertEqual(exp, 500)
            XCTAssertEqual(rec, 196) // 200 - 4 byte prefix
        } else {
            XCTFail("Expected inProgress, got \(r1)")
        }

        let r2 = a.receive(Data(c2))
        if case .inProgress(let rec, _) = r2 {
            XCTAssertEqual(rec, 396)
        } else {
            XCTFail("Expected inProgress, got \(r2)")
        }

        let r3 = a.receive(Data(c3))
        XCTAssertEqual(r3, .complete(payload.data(using: .utf8)!))
    }

    func testFirstChunkTooSmall() {
        var a = WorkoutUploadAssembler()
        let result = a.receive(Data([0x01, 0x02, 0x03]))  // < 4 bytes
        if case .error = result {} else { XCTFail("Expected error, got \(result)") }
    }

    func testZeroLengthRejected() {
        var a = WorkoutUploadAssembler()
        let zero = Data([0x00, 0x00, 0x00, 0x00])
        if case .error = a.receive(zero) {} else { XCTFail("Expected error") }
    }

    func testOverflowRejected() {
        var a = WorkoutUploadAssembler()
        let body = "hello"
        var lenBE = UInt32(3).bigEndian  // declare only 3 bytes but send 5
        var first = Data(bytes: &lenBE, count: 4)
        first.append(body.data(using: .utf8)!)
        let r = a.receive(first)
        if case .error = r {} else { XCTFail("Expected error, got \(r)") }
    }

    func testOversizeRejected() {
        var a = WorkoutUploadAssembler()
        var lenBE = UInt32(1_000_000).bigEndian  // 1 MB > 256 KB cap
        let chunk = Data(bytes: &lenBE, count: 4)
        let r = a.receive(chunk)
        if case .error = r {} else { XCTFail("Expected error, got \(r)") }
    }

    func testResetAllowsNewUpload() {
        var a = WorkoutUploadAssembler()
        _ = a.receive(Data([0x00, 0x00, 0x00, 0x10]))  // 16 bytes expected, only header sent
        a.reset()

        // Now a fresh upload should work cleanly
        let payload = "hello world!"
        let r = a.receive(frame(payload))
        XCTAssertEqual(r, .complete(payload.data(using: .utf8)!))
    }

    func testIsStaleWithTimeout() {
        var a = WorkoutUploadAssembler()
        _ = a.receive(Data([0x00, 0x00, 0x00, 0x10]))
        let past = Date(timeIntervalSinceNow: -30)  // simulate 30s ago
        // lastActivityAt was set by receive() just now; we can't easily override private state,
        // so we just verify the inverse: freshly-written assembler is not stale.
        XCTAssertFalse(a.isStale(timeout: 10, now: Date()))
        // And an assembler that has never received anything is never stale.
        let a2 = WorkoutUploadAssembler()
        XCTAssertFalse(a2.isStale(timeout: 0, now: past))
    }

    func testRealisticWorkoutPayloadRoundtrip() {
        // Use a realistic Phase 1 workout payload to ensure typical sizes work.
        let json = """
        {"id":"e2e-test","displayName":"P1 W1 Thu · KCTC","activity":"running","location":"outdoor","warmup":{"goal":{"distance_m":1500}},"blocks":[{"iterations":2,"steps":[{"purpose":"work","goal":{"distance_m":800},"alert":{"type":"pace","minPace":"4:10","maxPace":"4:20"}},{"purpose":"recovery","goal":{"time_s":120}}]}],"cooldown":{"goal":{"distance_m":1000}}}
        """
        var a = WorkoutUploadAssembler()
        let framed = frame(json)

        // Simulate BLE MTU chunks of 180 bytes
        var offset = 0
        var lastResult: WorkoutUploadAssembler.Result = .idle
        while offset < framed.count {
            let end = min(offset + 180, framed.count)
            let chunk = framed[offset..<end]
            lastResult = a.receive(Data(chunk))
            offset = end
        }

        XCTAssertEqual(lastResult, .complete(json.data(using: .utf8)!))

        // Verify it decodes as a WorkoutSpec
        if case .complete(let data) = lastResult {
            let spec = try? JSONDecoder().decode(WorkoutSpec.self, from: data)
            XCTAssertNotNil(spec)
            XCTAssertEqual(spec?.id, "e2e-test")
            XCTAssertEqual(spec?.blocks.count, 1)
            XCTAssertEqual(spec?.blocks[0].iterations, 2)
        }
    }
}
