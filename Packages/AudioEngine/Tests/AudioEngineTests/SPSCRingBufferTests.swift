import XCTest
@testable import AudioEngine

final class SPSCRingBufferTests: XCTestCase {

    func testBasicWriteRead() {
        let ring = SPSCRingBuffer(capacityFrames: 1024)
        var input: [Float] = (0..<100).map { Float($0) }
        input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 100) }
        XCTAssertEqual(ring.availableToRead, 100)

        var out = [Float](repeating: -1, count: 100)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 100) }
        XCTAssertEqual(out, input)
        XCTAssertEqual(ring.availableToRead, 0)
    }

    func testUnderrunPadsSilence() {
        let ring = SPSCRingBuffer(capacityFrames: 64)
        var input: [Float] = [1, 2, 3]
        input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 3) }
        var out = [Float](repeating: -1, count: 10)
        let got = out.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: 10)
        }
        XCTAssertEqual(got, 3)
        XCTAssertEqual(Array(out[0..<3]), [1, 2, 3])
        XCTAssertEqual(Array(out[3...]), [Float](repeating: 0, count: 7))
        XCTAssertEqual(ring.underrunCount.load(ordering: .relaxed), 7)
    }

    func testWrapAround() {
        let ring = SPSCRingBuffer(capacityFrames: 128)
        var scratch = [Float](repeating: 0, count: 100)
        var next: Float = 0
        var expect: Float = 0
        for _ in 0..<50 {
            var chunk = (0..<77).map { _ -> Float in next += 1; return next }
            chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 77) }
            let got = scratch.withUnsafeMutableBufferPointer {
                ring.read(into: $0.baseAddress!, count: 77)
            }
            XCTAssertEqual(got, 77)
            for i in 0..<77 {
                expect += 1
                XCTAssertEqual(scratch[i], expect)
            }
        }
    }

    func testDropNewestOverflow() {
        let ring = SPSCRingBuffer(capacityFrames: 64, overflowPolicy: .dropNewest)
        var input = [Float](repeating: 1, count: 200)
        let written = input.withUnsafeBufferPointer {
            ring.write($0.baseAddress!, count: 200)
        }
        XCTAssertEqual(written, 64)
        XCTAssertEqual(ring.overflowCount.load(ordering: .relaxed), 136)
    }

    func testDropOldestOverflowKeepsLatest() {
        let ring = SPSCRingBuffer(capacityFrames: 64, overflowPolicy: .dropOldest)
        var first = [Float](repeating: 1, count: 64)
        first.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 64) }
        var second = [Float](repeating: 2, count: 32)
        second.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 32) }
        var out = [Float](repeating: 0, count: 64)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 64) }
        // Oldest 32 dropped: 32×1 then 32×2.
        XCTAssertEqual(Array(out[0..<32]), [Float](repeating: 1, count: 32))
        XCTAssertEqual(Array(out[32..<64]), [Float](repeating: 2, count: 32))
    }

    /// Two-thread torture: producer streams a deterministic sequence in
    /// random burst sizes; consumer must observe it gap-free and in order
    /// (dropNewest + backpressure-aware producer → lossless).
    func testConcurrentTorture() {
        let ring = SPSCRingBuffer(capacityFrames: 4096, overflowPolicy: .dropNewest)
        let total = 2_000_000
        let done = expectation(description: "consumer done")

        let producer = Thread {
            var value: Float = 0
            var rng = SystemRandomNumberGenerator()
            var sent = 0
            var chunk = [Float](repeating: 0, count: 613)
            while sent < total {
                let n = min(Int.random(in: 1...613, using: &rng), total - sent)
                if ring.availableToWrite < n {           // backpressure
                    usleep(100)
                    continue
                }
                for i in 0..<n { value += 1; chunk[i] = value }
                chunk.withUnsafeBufferPointer {
                    _ = ring.write($0.baseAddress!, count: n)
                }
                sent += n
            }
        }
        let consumer = Thread {
            var expect: Float = 0
            var received = 0
            var buf = [Float](repeating: 0, count: 977)
            var rng = SystemRandomNumberGenerator()
            while received < total {
                let want = min(Int.random(in: 1...977, using: &rng), total - received)
                let avail = ring.availableToRead
                if avail == 0 { usleep(50); continue }
                let n = min(want, avail)
                let got = buf.withUnsafeMutableBufferPointer {
                    ring.read(into: $0.baseAddress!, count: n)
                }
                for i in 0..<got {
                    expect += 1
                    if buf[i] != expect {
                        XCTFail("sequence break at \(received + i): got \(buf[i]) want \(expect)")
                        done.fulfill()
                        return
                    }
                }
                received += got
            }
            done.fulfill()
        }
        producer.start()
        consumer.start()
        wait(for: [done], timeout: 30)
    }
}
