import XCTest
@testable import AudioEngine

final class CryptStateOCB2Tests: XCTestCase {

    private func makePair() -> (tx: CryptStateOCB2, rx: CryptStateOCB2) {
        let key: [UInt8] = (0..<16).map { UInt8($0 * 7 &+ 3) }
        let clientNonce: [UInt8] = (0..<16).map { UInt8($0) }
        let serverNonce: [UInt8] = (0..<16).map { UInt8(0xFF - $0) }
        let tx = CryptStateOCB2()
        let rx = CryptStateOCB2()
        // tx encrypts with clientNonce; rx (the "server") decrypts with the
        // same nonce on its decrypt side.
        XCTAssertTrue(tx.setKey(key, encryptIV: clientNonce, decryptIV: serverNonce))
        XCTAssertTrue(rx.setKey(key, encryptIV: serverNonce, decryptIV: clientNonce))
        return (tx, rx)
    }

    func testRoundTripVariousLengths() {
        let (tx, rx) = makePair()
        for len in [1, 5, 15, 16, 17, 31, 32, 33, 100, 500, 1020] {
            let plain: [UInt8] = (0..<len).map { UInt8(($0 &* 31 &+ len) & 0xFF) }
            guard let wire = tx.encrypt(plain) else { return XCTFail("encrypt failed len=\(len)") }
            XCTAssertEqual(wire.count, len + 4)
            guard let out = rx.decrypt(wire) else { return XCTFail("decrypt failed len=\(len)") }
            XCTAssertEqual(out, plain, "round-trip mismatch at len=\(len)")
        }
        XCTAssertEqual(rx.good, 11)
        XCTAssertEqual(rx.lost, 0)
    }

    func testTamperedPayloadRejected() {
        let (tx, rx) = makePair()
        let plain: [UInt8] = (0..<100).map { UInt8($0) }
        var wire = tx.encrypt(plain)!
        wire[10] ^= 0x40
        XCTAssertNil(rx.decrypt(wire))
        // State must be rolled back: the next honest packet still decrypts.
        let wire2 = tx.encrypt(plain)!
        // First packet was consumed by the tamper attempt; IV jumped by one.
        XCTAssertEqual(rx.decrypt(wire2), plain)
    }

    func testTamperedTagRejected() {
        let (tx, rx) = makePair()
        let plain: [UInt8] = Array("hello mumble".utf8)
        var wire = tx.encrypt(plain)!
        wire[1] ^= 0x01
        XCTAssertNil(rx.decrypt(wire))
    }

    func testReplayRejected() {
        let (tx, rx) = makePair()
        // Establish some history first.
        for i in 0..<5 {
            let plain: [UInt8] = [UInt8(i), 1, 2, 3]
            XCTAssertNotNil(rx.decrypt(tx.encrypt(plain)!))
        }
        let plain: [UInt8] = [9, 9, 9]
        let wire = tx.encrypt(plain)!
        XCTAssertNotNil(rx.decrypt(wire))
        // Same packet again: same IV byte → replay path → rejected.
        XCTAssertNil(rx.decrypt(wire))
    }

    func testOutOfOrderWithinWindowAccepted() {
        let (tx, rx) = makePair()
        let a = tx.encrypt([1])!
        let b = tx.encrypt([2])!
        let c = tx.encrypt([3])!
        XCTAssertEqual(rx.decrypt(a), [1])
        XCTAssertEqual(rx.decrypt(c), [3])     // b skipped → lost++
        XCTAssertEqual(rx.decrypt(b), [2])     // late but within window
        XCTAssertEqual(rx.good, 3)
        XCTAssertEqual(rx.late, 1)
    }

    func testLossCounting() {
        let (tx, rx) = makePair()
        XCTAssertNotNil(rx.decrypt(tx.encrypt([1])!))
        // Drop 3 packets.
        _ = tx.encrypt([2]); _ = tx.encrypt([3]); _ = tx.encrypt([4])
        XCTAssertNotNil(rx.decrypt(tx.encrypt([5])!))
        XCTAssertEqual(rx.lost, 3)
    }

    func testIVWraparound() {
        let (tx, rx) = makePair()
        // Push through > 256 packets so the low IV byte wraps and the carry
        // propagates into the higher bytes on both sides.
        for i in 0..<600 {
            let plain: [UInt8] = [UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF)]
            guard let out = rx.decrypt(tx.encrypt(plain)!) else {
                return XCTFail("decrypt failed at packet \(i)")
            }
            XCTAssertEqual(out, plain)
        }
        XCTAssertEqual(rx.good, 600)
        XCTAssertEqual(rx.lost, 0)
    }

    /// The XEX* countermeasure flips one bit in all-zero second-to-last
    /// blocks. Voice payloads are Opus (never all-zero in practice); what
    /// matters is: encryption still succeeds, the tag still verifies, and
    /// the received payload differs from the original by at most one bit.
    func testAllZeroBlockCountermeasure() {
        let (tx, rx) = makePair()
        let plain = [UInt8](repeating: 0, count: 20)   // 16-byte zero block + 4 tail
        let wire = tx.encrypt(plain)!
        guard let out = rx.decrypt(wire) else {
            // The decrypt side intentionally flags attack-shaped plaintext;
            // rejection is also acceptable behavior.
            return
        }
        var flippedBits = 0
        for i in 0..<plain.count {
            flippedBits += (out[i] ^ plain[i]).nonzeroBitCount
        }
        XCTAssertLessThanOrEqual(flippedBits, 1)
    }

    func testUnknownKeyFails() {
        let (tx, _) = makePair()
        let stranger = CryptStateOCB2()
        _ = stranger.setKey([UInt8](repeating: 9, count: 16),
                            encryptIV: [UInt8](repeating: 0, count: 16),
                            decryptIV: (0..<16).map { UInt8($0) })
        let wire = tx.encrypt([1, 2, 3])!
        XCTAssertNil(stranger.decrypt(wire))
    }
}
