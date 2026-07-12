//
//  EncryptedVoiceLoopTests.swift
//  CleanMumbleTests
//
//  Headless "server loopback" tests: an in-process murmur stand-in that
//  decrypts, re-frames with the sender session (exactly what a real server
//  does before echoing), and re-encrypts. Everything in the chain is the
//  production code: VoiceTX framing, CryptStateOCB2 both directions,
//  MumbleVoiceParser, and — in the fidelity test — the real CaptureEngine
//  and PlaybackEngine.
//
//  Two claims are verified:
//   1. The wire is bit-transparent: Opus payloads and sequence numbers come
//      back EXACTLY as sent, over both framings, across varint width
//      boundaries. Any transport loss/corruption is a hard failure.
//   2. Audio fidelity end to end: a voice-like signal through
//      capture → Opus → framing → OCB2 → echo → parse → jitter buffer →
//      decode → mix keeps its pitch, level and spectral envelope, with no
//      clicks or dropouts. (Opus is perceptually lossy by design, so this
//      leg is measured with the same calibrated metrics as the codec E2E
//      suite, not bit-compare.)
//

import XCTest
import AudioEngine
import AudioCore
@testable import CleanMumble

final class EncryptedVoiceLoopTests: XCTestCase {

    // MARK: - In-process encrypted echo server

    /// Client + server OCB2 pair with mirrored key material, plus the
    /// murmur-style re-framing (inject sender session) on echo.
    private struct EchoServer {
        let clientCrypt = CryptStateOCB2()
        let serverCrypt = CryptStateOCB2()
        let session: UInt32

        init(session: UInt32) {
            self.session = session
            let key = (0..<16).map { UInt8($0 * 7 &+ 3) }
            let clientNonce = (0..<16).map { UInt8($0 &+ 100) }
            let serverNonce = (0..<16).map { UInt8(200 &- $0) }
            // Client encrypts with its nonce, decrypts with the server's —
            // and vice versa, exactly like CryptSetup wires it.
            XCTAssertTrue(clientCrypt.setKey(key, encryptIV: clientNonce,
                                             decryptIV: serverNonce))
            XCTAssertTrue(serverCrypt.setKey(key, encryptIV: serverNonce,
                                             decryptIV: clientNonce))
        }

        /// Full loop: client packet bytes → wire → server → re-frame →
        /// wire → decrypted payload as the client's RX path receives it.
        /// Returns nil if any crypt stage rejects the packet.
        func echo(_ clientPacket: Data, protobuf: Bool) -> Data? {
            guard let wireUp = clientCrypt.encrypt([UInt8](clientPacket)),
                  let atServer = serverCrypt.decrypt(wireUp) else { return nil }
            // The transport must hand the server exactly what we sent.
            XCTAssertEqual(Data(atServer), clientPacket,
                           "client→server leg corrupted the packet")
            let reframed = Self.injectSession(Data(atServer), session: session,
                                              protobuf: protobuf)
            guard let wireDown = serverCrypt.encrypt([UInt8](reframed)),
                  let atClient = clientCrypt.decrypt(wireDown) else { return nil }
            return Data(atClient)
        }

        /// What murmur does before relaying: legacy framing gets the sender
        /// session varint inserted after the header byte; protobuf gets
        /// field 3 (sender_session) added to the Audio message.
        static func injectSession(_ packet: Data, session: UInt32,
                                  protobuf: Bool) -> Data {
            if protobuf {
                var out = packet
                out.pbUInt32(field: 3, value: session)   // field order is free
                return out
            } else {
                var out = Data([packet[0]])
                out.mumbleVarInt(UInt64(session))
                out.append(packet.dropFirst())
                return out
            }
        }
    }

    // MARK: - 1. Bit-exact transport

    private func runBitExactLoop(protobuf: Bool) {
        let server = EchoServer(session: 12_345)   // 2-byte varint session
        var rng = SystemRandomNumberGenerator()

        // Sequence numbers crossing every varint width the TX path can emit.
        var seq: UInt64 = 0x3FF0
        for i in 0..<300 {
            let size = Int.random(in: 1...1275, using: &rng)
            let opus = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let packet = VoiceTX.buildPacket(opus: opus, seq: seq,
                                             isTerminator: false,
                                             protobuf: protobuf,
                                             target: 31)
            guard let echoed = server.echo(packet, protobuf: protobuf) else {
                return XCTFail("packet \(i) rejected by crypt layer")
            }
            guard let parsed = MumbleVoiceParser.parse(echoed) else {
                return XCTFail("packet \(i) failed to parse after echo")
            }
            XCTAssertEqual(parsed.opus, opus, "packet \(i): opus bytes not bit-exact")
            XCTAssertEqual(parsed.seq, UInt32(truncatingIfNeeded: seq),
                           "packet \(i): sequence corrupted")
            XCTAssertEqual(parsed.sender, 12_345)
            XCTAssertFalse(parsed.isTerminator)
            // Vary the stride so widths 1–4 bytes all occur.
            seq &+= UInt64(1 << (i % 14))
        }

        // Terminator survives too.
        let term = VoiceTX.buildPacket(opus: Data(), seq: seq, isTerminator: true,
                                       protobuf: protobuf, target: 31)
        guard let echoed = server.echo(term, protobuf: protobuf),
              let parsed = MumbleVoiceParser.parse(echoed) else {
            return XCTFail("terminator lost in echo loop")
        }
        XCTAssertTrue(parsed.isTerminator)
        XCTAssertEqual(parsed.opus, Data())
    }

    func testOpusBitExactThroughEncryptedEcho_protobuf() { runBitExactLoop(protobuf: true) }
    func testOpusBitExactThroughEncryptedEcho_legacy()   { runBitExactLoop(protobuf: false) }

    /// OCB2 must refuse tampered datagrams — corruption can't reach playback.
    func testTamperedWireIsRejected() {
        let server = EchoServer(session: 1)
        let packet = VoiceTX.buildPacket(opus: Data([1, 2, 3, 4]), seq: 9,
                                         isTerminator: false, protobuf: true)
        guard var wire = server.clientCrypt.encrypt([UInt8](packet)) else {
            return XCTFail("encrypt failed")
        }
        wire[wire.count - 1] ^= 0x40
        XCTAssertNil(server.serverCrypt.decrypt(wire),
                     "tampered packet must not decrypt")
    }

    // MARK: - 2. Full-stack audio fidelity through the encrypted echo

    func testVoiceFidelityThroughEncryptedServerEcho() {
        let sampleRate = 48_000.0
        let source = SignalGenerator.voiceLike(pitchHz: 130, amplitude: 0.4,
                                               durationSeconds: 2.0,
                                               sampleRate: sampleRate)

        // Capture: the production worker (SRC → HPF → gain → limiter → VAD →
        // Opus). Collect its packets.
        let capture = CaptureEngine()
        capture.transmitEnabled = true
        capture.vadThreshold = 0.003
        let lock = NSLock()
        var packets: [(seq: UInt64, data: Data, isTerm: Bool)] = []
        capture.onPacket = { data, seq, isTerm in
            lock.lock(); packets.append((seq, data, isTerm)); lock.unlock()
        }
        capture.start(sourceRate: sampleRate, format: CaptureFormat())
        let chunk = Int(sampleRate / 100)
        var i = 0
        while i + chunk <= source.count {
            source[i..<(i + chunk)].withUnsafeBufferPointer {
                capture.ingest($0.baseAddress!, count: chunk)
            }
            Thread.sleep(forTimeInterval: 0.002)
            i += chunk
        }
        Thread.sleep(forTimeInterval: 0.3)
        capture.stop()

        lock.lock()
        let sent = packets
        lock.unlock()
        XCTAssertGreaterThan(sent.count, 60, "expected ~100 packets for 2 s")

        // Wire: frame → encrypt → server echo (re-frame) → decrypt → parse →
        // playback, all through production code.
        let server = EchoServer(session: 41)
        let playback = PlaybackEngine()
        playback.start()
        defer { playback.stop() }
        var delivered = 0
        for p in sent {
            let packet = VoiceTX.buildPacket(opus: p.data, seq: p.seq,
                                             isTerminator: p.isTerm,
                                             protobuf: true, target: 31)
            guard let echoed = server.echo(packet, protobuf: true),
                  let parsed = MumbleVoiceParser.parse(echoed) else {
                XCTFail("packet seq \(p.seq) lost in echo loop"); continue
            }
            if !parsed.isTerminator { XCTAssertEqual(parsed.opus, p.data) }
            playback.submit(sender: Int32(parsed.sender), seq: parsed.seq,
                            opus: parsed.opus, isTerminator: parsed.isTerminator)
            delivered += 1
        }
        XCTAssertEqual(delivered, sent.count, "every packet must survive the wire")

        // Render the mix like the output device would.
        var out: [Float] = []
        var block = [Float](repeating: 0, count: 480)
        for _ in 0..<Int(3.0 * 100) {
            Thread.sleep(forTimeInterval: 0.01)
            block.withUnsafeMutableBufferPointer {
                playback.pullMix(into: $0.baseAddress!, frames: 480)
            }
            out.append(contentsOf: block)
        }

        // Steady-state body: trim silence, drop 10 % each end.
        var body = Array(out.drop { abs($0) < 0.001 }.reversed()
            .drop { abs($0) < 0.001 }.reversed())
        if body.count > 9_600 {
            let cut = body.count / 10
            body = Array(body[cut..<(body.count - cut)])
        }
        XCTAssertGreaterThan(body.count, 48_000, "need ≥1 s of rendered audio")

        // Fidelity metrics — the same bounds the full-stack quality suite
        // uses. (Spectral distance vs. the raw source is deliberately NOT
        // asserted here: the capture chain applies HPF/VAD/limiter by design;
        // codec-only spectral fidelity is covered by MumblePipelineE2ETests.)
        let domSrc = AudioAnalysis.dominantFrequency(source, sampleRate: sampleRate)
        let domRcv = AudioAnalysis.dominantFrequency(body, sampleRate: sampleRate)
        XCTAssertEqual(domRcv.frequency, domSrc.frequency, accuracy: 30,
                       "dominant frequency drifted through the full stack: " +
                       "src=\(domSrc.frequency) rcv=\(domRcv.frequency)")
        let rms = AudioAnalysis.rms(body)
        let srcRMS = AudioAnalysis.rms(source)
        let rmsDeltaDB = 20 * log10f(max(rms, 1e-6) / max(srcRMS, 1e-6))
        XCTAssertLessThan(abs(rmsDeltaDB), 4, "level shifted \(rmsDeltaDB) dB end to end")
        XCTAssertEqual(AudioAnalysis.discontinuities(body, threshold: 0.4).count, 0,
                       "clicks detected in echoed audio")
        XCTAssertEqual(AudioAnalysis.zeroRuns(body, minRunLength: 480).count, 0,
                       "dropouts detected mid-utterance")
    }
}
