import XCTest
@testable import AudioCore

final class FloatRingBufferTests: XCTestCase {

    func test_write_then_read_roundtrip() {
        let rb = FloatRingBuffer(capacity: 1024)
        let input: [Float] = (0..<256).map { Float($0) }
        rb.write(input)
        let out = rb.read(count: 256)
        XCTAssertEqual(out, input)
    }

    func test_partial_read_pads_with_silence() {
        let rb = FloatRingBuffer(capacity: 1024)
        rb.write([1, 2, 3])
        let out = rb.read(count: 8)
        XCTAssertEqual(out, [1, 2, 3, 0, 0, 0, 0, 0])
    }

    func test_overflow_drops_oldest_and_counts() {
        let rb = FloatRingBuffer(capacity: 8)   // usable = 7
        rb.write([1, 2, 3, 4, 5])
        rb.write([6, 7, 8, 9, 10])              // 10 written total → 3 dropped
        XCTAssertEqual(rb.droppedSamples, 3)
        let out = rb.read(count: 7)
        XCTAssertEqual(out, [4, 5, 6, 7, 8, 9, 10])
    }

    func test_wraparound_correctness() {
        let rb = FloatRingBuffer(capacity: 8)   // usable = 7
        for cycle in 0..<10 {
            let chunk: [Float] = (0..<5).map { Float(cycle * 100 + $0) }
            rb.write(chunk)
            let out = rb.read(count: 5)
            XCTAssertEqual(out, chunk, "Cycle \(cycle) failed")
        }
    }

    func test_clear_resets_state() {
        let rb = FloatRingBuffer(capacity: 16)
        rb.write([1, 2, 3, 4, 5])
        rb.clear()
        XCTAssertEqual(rb.availableRead, 0)
        XCTAssertEqual(rb.read(count: 4), [0, 0, 0, 0])
    }
}
