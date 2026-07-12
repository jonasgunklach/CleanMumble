//
//  CryptStateOCB2.swift
//  AudioEngine
//
//  OCB2-AES128 for Mumble's encrypted UDP voice channel — a faithful port of
//  the reference client's CryptState (mumble/src/crypto/CryptStateOCB2.cpp,
//  BSD-3-Clause, © The Mumble Developers), including:
//   • the short-IV packet format: [iv byte][3-byte tag][ciphertext]
//   • full 128-bit little-endian IV increment per packet
//   • the out-of-order / lost / wraparound IV recovery logic and the
//     per-IV replay history
//   • the countermeasure for the 2019 XEX* forgery attack
//     (https://eprint.iacr.org/2019/311 §9): all-zero second-to-last
//     plaintext blocks get one bit flipped before encryption, and such
//     blocks are rejected on decryption.
//
//  OCB2 has known theoretical weaknesses; it is what the Mumble protocol
//  mandates. Do not reuse this outside the Mumble UDP channel.
//
//  Thread-safety: none. Confine one instance to one queue.
//

import Foundation
import CommonCrypto

public final class CryptStateOCB2 {

    static let blockSize = 16
    static let keySize = 16

    private var rawKey = [UInt8](repeating: 0, count: CryptStateOCB2.keySize)
    private var encryptIV = [UInt8](repeating: 0, count: CryptStateOCB2.blockSize)
    private var decryptIV = [UInt8](repeating: 0, count: CryptStateOCB2.blockSize)
    private var decryptHistory = [UInt8](repeating: 0, count: 256)

    private var encCryptor: CCCryptorRef?
    private var decCryptor: CCCryptorRef?

    public private(set) var isValid = false

    // Stats — mirror Mumble's CryptState counters.
    public private(set) var good: UInt32 = 0
    public private(set) var late: UInt32 = 0
    public private(set) var lost: UInt32 = 0
    public private(set) var lastGoodAt: TimeInterval = 0

    public init() {}

    deinit {
        if let c = encCryptor { CCCryptorRelease(c) }
        if let c = decCryptor { CCCryptorRelease(c) }
    }

    // MARK: - Key management (CryptSetup handling)

    public func setKey(_ key: [UInt8], encryptIV eiv: [UInt8], decryptIV div: [UInt8]) -> Bool {
        guard key.count == Self.keySize,
              eiv.count == Self.blockSize,
              div.count == Self.blockSize else { return false }
        rawKey = key
        encryptIV = eiv
        decryptIV = div
        decryptHistory = [UInt8](repeating: 0, count: 256)
        if let c = encCryptor { CCCryptorRelease(c); encCryptor = nil }
        if let c = decCryptor { CCCryptorRelease(c); decCryptor = nil }
        var enc: CCCryptorRef?
        var dec: CCCryptorRef?
        let e1 = CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128),
                                 CCOptions(kCCOptionECBMode), key, key.count, nil, &enc)
        let e2 = CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128),
                                 CCOptions(kCCOptionECBMode), key, key.count, nil, &dec)
        guard e1 == kCCSuccess, e2 == kCCSuccess, let enc, let dec else { return false }
        encCryptor = enc
        decCryptor = dec
        good = 0; late = 0; lost = 0
        isValid = true
        return true
    }

    /// Server pushed a fresh server_nonce (resync response).
    public func setDecryptIV(_ iv: [UInt8]) -> Bool {
        guard iv.count == Self.blockSize else { return false }
        decryptIV = iv
        return true
    }

    /// Our current client_nonce — sent when the server requests a resync.
    public var currentEncryptIV: [UInt8] { encryptIV }

    // MARK: - Packet interface

    /// Encrypt `plain`; returns the wire packet (4-byte header + ciphertext),
    /// or nil if the state is unusable.
    public func encrypt(_ plain: [UInt8]) -> [UInt8]? {
        guard isValid else { return nil }
        // Full 128-bit little-endian increment of the encrypt IV.
        for i in 0..<Self.blockSize {
            encryptIV[i] &+= 1
            if encryptIV[i] != 0 { break }
        }
        var tag = [UInt8](repeating: 0, count: Self.blockSize)
        var cipher = [UInt8](repeating: 0, count: plain.count)
        ocbEncrypt(plain: plain, encrypted: &cipher, nonce: encryptIV, tag: &tag)
        var out = [UInt8](repeating: 0, count: 4 + plain.count)
        out[0] = encryptIV[0]
        out[1] = tag[0]; out[2] = tag[1]; out[3] = tag[2]
        if !plain.isEmpty {
            out.replaceSubrange(4..., with: cipher)
        }
        return out
    }

    /// Decrypt a wire packet. Returns plaintext, or nil on any failure
    /// (bad tag, replay, out-of-window IV) — the IV state is rolled back so
    /// a forged packet can't desync us.
    public func decrypt(_ source: [UInt8]) -> [UInt8]? {
        guard isValid, source.count >= 4 else { return nil }
        let plainLength = source.count - 4
        let ivByte = source[0]
        let saveIV = decryptIV
        var restore = false
        var lateInc: UInt32 = 0
        var lostInc: Int = 0

        if ((decryptIV[0] &+ 1) & 0xFF) == ivByte {
            // In order.
            if ivByte > decryptIV[0] {
                decryptIV[0] = ivByte
            } else if ivByte < decryptIV[0] {
                decryptIV[0] = ivByte
                carryIncrementHighBytes()
            } else {
                return nil
            }
        } else {
            // Out of order or repeat.
            var diff = Int(ivByte) - Int(decryptIV[0])
            if diff > 128 { diff -= 256 } else if diff < -128 { diff += 256 }

            if ivByte < decryptIV[0] && diff > -30 && diff < 0 {
                // Late packet, no wraparound.
                lateInc = 1; lostInc = -1
                decryptIV[0] = ivByte
                restore = true
            } else if ivByte > decryptIV[0] && diff > -30 && diff < 0 {
                // Late packet from the previous IV epoch (0x02 → 0xFF case).
                lateInc = 1; lostInc = -1
                decryptIV[0] = ivByte
                carryDecrementHighBytes()
                restore = true
            } else if ivByte > decryptIV[0] && diff > 0 {
                // Lost some packets.
                lostInc = Int(ivByte) - Int(saveIV[0]) - 1
                decryptIV[0] = ivByte
            } else if ivByte < decryptIV[0] && diff > 0 {
                // Lost some packets and wrapped.
                lostInc = 256 - Int(saveIV[0]) + Int(ivByte) - 1
                decryptIV[0] = ivByte
                carryIncrementHighBytes()
            } else {
                return nil
            }

            if decryptHistory[Int(decryptIV[0])] == decryptIV[1] {
                decryptIV = saveIV
                return nil        // replay
            }
        }

        var plain = [UInt8](repeating: 0, count: plainLength)
        var tag = [UInt8](repeating: 0, count: Self.blockSize)
        let cipherBody = Array(source[4...])
        let ok = ocbDecrypt(encrypted: cipherBody, plain: &plain,
                            nonce: decryptIV, tag: &tag)
        guard ok, tag[0] == source[1], tag[1] == source[2], tag[2] == source[3] else {
            decryptIV = saveIV
            return nil
        }

        decryptHistory[Int(decryptIV[0])] = decryptIV[1]
        if restore { decryptIV = saveIV }

        good &+= 1
        late &+= lateInc
        if lostInc > 0 { lost &+= UInt32(lostInc) } else if lostInc < 0, lost > 0 { lost &-= 1 }
        lastGoodAt = ProcessInfo.processInfo.systemUptime
        return plain
    }

    // MARK: - IV helpers

    private func carryIncrementHighBytes() {
        for i in 1..<Self.blockSize {
            decryptIV[i] &+= 1
            if decryptIV[i] != 0 { break }
        }
    }

    private func carryDecrementHighBytes() {
        for i in 1..<Self.blockSize {
            let old = decryptIV[i]
            decryptIV[i] &-= 1
            if old != 0 { break }   // no borrow
        }
    }

    // MARK: - AES primitives

    private func aesEncryptBlock(_ input: UnsafePointer<UInt8>, _ output: UnsafeMutablePointer<UInt8>) {
        var moved = 0
        CCCryptorUpdate(encCryptor, input, Self.blockSize, output, Self.blockSize, &moved)
    }

    private func aesDecryptBlock(_ input: UnsafePointer<UInt8>, _ output: UnsafeMutablePointer<UInt8>) {
        var moved = 0
        CCCryptorUpdate(decCryptor, input, Self.blockSize, output, Self.blockSize, &moved)
    }

    // MARK: - OCB2 core (byte-oriented port of Mumble's subblock math)

    /// GF(2^128) doubling: shift the 16-byte block left one bit; on carry,
    /// fold with the field polynomial (0x87 into the last byte).
    private static func times2(_ b: inout [UInt8]) {
        let carry = b[0] >> 7
        for i in 0..<(blockSize - 1) {
            b[i] = (b[i] << 1) | (b[i + 1] >> 7)
        }
        b[blockSize - 1] = (b[blockSize - 1] << 1) ^ (carry &* 0x87)
    }

    /// times3(x) = times2(x) ^ x.
    private static func times3(_ b: inout [UInt8]) {
        var doubled = b
        times2(&doubled)
        for i in 0..<blockSize { b[i] ^= doubled[i] }
    }

    private static func xorInto(_ dst: inout [UInt8], _ a: [UInt8], _ b: [UInt8]) {
        for i in 0..<blockSize { dst[i] = a[i] ^ b[i] }
    }

    @discardableResult
    private func ocbEncrypt(plain: [UInt8], encrypted: inout [UInt8],
                            nonce: [UInt8], tag: inout [UInt8]) -> Bool {
        let bs = Self.blockSize
        var delta = [UInt8](repeating: 0, count: bs)
        var checksum = [UInt8](repeating: 0, count: bs)
        var tmp = [UInt8](repeating: 0, count: bs)
        var pad = [UInt8](repeating: 0, count: bs)

        nonce.withUnsafeBufferPointer { n in
            delta.withUnsafeMutableBufferPointer { d in
                aesEncryptBlock(n.baseAddress!, d.baseAddress!)
            }
        }

        var offset = 0
        var len = plain.count
        while len > bs {
            // XEX* countermeasure: an all-zero (except final byte)
            // second-to-last block enables the 2019 forgery. Flip one bit —
            // inaudible in PCM/Opus payloads, breaks the attack precondition.
            var flipABit = false
            if len - bs <= bs {
                var sum: UInt8 = 0
                for i in 0..<(bs - 1) { sum |= plain[offset + i] }
                if sum == 0 { flipABit = true }
            }

            Self.times2(&delta)
            for i in 0..<bs { tmp[i] = delta[i] ^ plain[offset + i] }
            if flipABit { tmp[0] ^= 1 }
            tmp.withUnsafeBufferPointer { src in
                var out = [UInt8](repeating: 0, count: bs)
                out.withUnsafeMutableBufferPointer { dst in
                    aesEncryptBlock(src.baseAddress!, dst.baseAddress!)
                }
                tmp = out
            }
            for i in 0..<bs { encrypted[offset + i] = delta[i] ^ tmp[i] }
            for i in 0..<bs { checksum[i] ^= plain[offset + i] }
            if flipABit { checksum[0] ^= 1 }

            len -= bs
            offset += bs
        }

        Self.times2(&delta)
        tmp = [UInt8](repeating: 0, count: bs)
        let bits = UInt32(len * 8)
        tmp[bs - 4] = UInt8((bits >> 24) & 0xFF)
        tmp[bs - 3] = UInt8((bits >> 16) & 0xFF)
        tmp[bs - 2] = UInt8((bits >> 8) & 0xFF)
        tmp[bs - 1] = UInt8(bits & 0xFF)
        for i in 0..<bs { tmp[i] ^= delta[i] }
        tmp.withUnsafeBufferPointer { src in
            pad.withUnsafeMutableBufferPointer { dst in
                aesEncryptBlock(src.baseAddress!, dst.baseAddress!)
            }
        }
        for i in 0..<len { tmp[i] = plain[offset + i] }
        for i in len..<bs { tmp[i] = pad[i] }
        for i in 0..<bs { checksum[i] ^= tmp[i] }
        for i in 0..<bs { tmp[i] ^= pad[i] }
        for i in 0..<len { encrypted[offset + i] = tmp[i] }

        Self.times3(&delta)
        Self.xorInto(&tmp, delta, checksum)
        tmp.withUnsafeBufferPointer { src in
            tag.withUnsafeMutableBufferPointer { dst in
                aesEncryptBlock(src.baseAddress!, dst.baseAddress!)
            }
        }
        return true
    }

    private func ocbDecrypt(encrypted: [UInt8], plain: inout [UInt8],
                            nonce: [UInt8], tag: inout [UInt8]) -> Bool {
        let bs = Self.blockSize
        var delta = [UInt8](repeating: 0, count: bs)
        var checksum = [UInt8](repeating: 0, count: bs)
        var tmp = [UInt8](repeating: 0, count: bs)
        var pad = [UInt8](repeating: 0, count: bs)
        var success = true

        nonce.withUnsafeBufferPointer { n in
            delta.withUnsafeMutableBufferPointer { d in
                aesEncryptBlock(n.baseAddress!, d.baseAddress!)
            }
        }

        var offset = 0
        var len = encrypted.count
        while len > bs {
            Self.times2(&delta)
            for i in 0..<bs { tmp[i] = delta[i] ^ encrypted[offset + i] }
            tmp.withUnsafeBufferPointer { src in
                var out = [UInt8](repeating: 0, count: bs)
                out.withUnsafeMutableBufferPointer { dst in
                    aesDecryptBlock(src.baseAddress!, dst.baseAddress!)
                }
                tmp = out
            }
            for i in 0..<bs { plain[offset + i] = delta[i] ^ tmp[i] }
            for i in 0..<bs { checksum[i] ^= plain[offset + i] }

            // Reject blocks matching the XEX* attack shape (see encrypt side).
            if len - bs <= bs {
                var sum: UInt8 = 0
                for i in 0..<(bs - 1) { sum |= plain[offset + i] }
                if sum == 0 { success = false }
            }

            len -= bs
            offset += bs
        }

        Self.times2(&delta)
        tmp = [UInt8](repeating: 0, count: bs)
        let bits = UInt32(len * 8)
        tmp[bs - 4] = UInt8((bits >> 24) & 0xFF)
        tmp[bs - 3] = UInt8((bits >> 16) & 0xFF)
        tmp[bs - 2] = UInt8((bits >> 8) & 0xFF)
        tmp[bs - 1] = UInt8(bits & 0xFF)
        for i in 0..<bs { tmp[i] ^= delta[i] }
        tmp.withUnsafeBufferPointer { src in
            pad.withUnsafeMutableBufferPointer { dst in
                aesEncryptBlock(src.baseAddress!, dst.baseAddress!)
            }
        }
        tmp = [UInt8](repeating: 0, count: bs)
        for i in 0..<len { tmp[i] = encrypted[offset + i] }
        for i in 0..<bs { tmp[i] ^= pad[i] }
        for i in 0..<bs { checksum[i] ^= tmp[i] }
        for i in 0..<len { plain[offset + i] = tmp[i] }

        Self.times3(&delta)
        var tagIn = [UInt8](repeating: 0, count: bs)
        Self.xorInto(&tagIn, delta, checksum)
        tagIn.withUnsafeBufferPointer { src in
            tag.withUnsafeMutableBufferPointer { dst in
                aesEncryptBlock(src.baseAddress!, dst.baseAddress!)
            }
        }
        return success
    }
}
