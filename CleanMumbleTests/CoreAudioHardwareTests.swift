//
//  CoreAudioHardwareTests.swift
//  CleanMumbleTests
//
//  Hardware-in-the-loop tests for CoreAudioInput / CoreAudioOutput / CoreAudioIO.
//
//  Requires BlackHole 2ch virtual audio device:
//      https://existential.audio/blackhole/  (choose the "2ch" variant)
//
//  All tests call requireBlackHole() and skip cleanly when the device is absent
//  so CI without the driver still passes.
//
//  What we test:
//
//   1. Output/Input start + stop lifecycle on BlackHole — isRunning reflects state.
//   2. Output renders silence (zeros) without crashing when ring is empty.
//   3. Input delivers render callbacks within 1.5 s of starting.
//   4. CoreAudioIO façade start/stop and enqueuePlayback.
//   5. LOOPBACK: write a 1 kHz sine to CoreAudioOutput → BlackHole routes it
//      back → CoreAudioInput captures it → assert dominant frequency ≈ 1 kHz
//      and signal is not silence.  This is the test that actually exercises the
//      full hardware path end-to-end.
//

import XCTest
import CoreAudio
import AudioCore
@testable import CleanMumble

// MARK: - BlackHole presence check

/// CoreAudio UID for the BlackHole 2-channel virtual loopback device.
private let kBlackHoleUID = "BlackHole2ch_UID"

/// Returns true when BlackHole 2ch is present in the HAL device list.
/// Uses the same `kAudioHardwarePropertyDeviceForUID` translation as
/// `CoreAudioIO.deviceID(forUID:isInput:)` so any mis-configuration that
/// would affect the AU would also make this return false.
private func blackHoleIsPresent() -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDeviceForUID,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain
    )
    var devID = AudioDeviceID(0)
    var cfUID: CFString = kBlackHoleUID as CFString
    var avt = AudioValueTranslation(
        mInputData:      withUnsafeMutablePointer(to: &cfUID) { UnsafeMutableRawPointer($0) },
        mInputDataSize:  UInt32(MemoryLayout<CFString>.size),
        mOutputData:     withUnsafeMutablePointer(to: &devID) { UnsafeMutableRawPointer($0) },
        mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
    let err = withUnsafeMutablePointer(to: &avt) {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &addr, 0, nil, &size, $0)
    }
    return err == noErr && devID != 0
}

// MARK: - Test suite

final class CoreAudioHardwareTests: XCTestCase {

    // MARK: Helpers

    private func requireBlackHole() throws {
        try XCTSkipUnless(
            blackHoleIsPresent(),
            "BlackHole 2ch not installed — skipping hardware tests. " +
            "Install from https://existential.audio/blackhole/ (2ch variant)."
        )
    }

    // MARK: - Output lifecycle

    func test_output_startsAndStops_onBlackHole() throws {
        try requireBlackHole()
        let output = CoreAudioOutput()
        output.deviceUID = kBlackHoleUID
        output.start()
        XCTAssertTrue(output.isRunning, "CoreAudioOutput.isRunning should be true after start()")
        output.stop()
        XCTAssertFalse(output.isRunning, "CoreAudioOutput.isRunning should be false after stop()")
    }

    func test_output_startStop_isIdempotent() throws {
        try requireBlackHole()
        let output = CoreAudioOutput()
        output.deviceUID = kBlackHoleUID
        // Start/stop three times — should not crash or leave the AU in a bad state.
        for i in 1...3 {
            output.start()
            XCTAssertTrue(output.isRunning, "iteration \(i): output not running after start()")
            output.stop()
            XCTAssertFalse(output.isRunning, "iteration \(i): output still running after stop()")
        }
    }

    func test_output_rendersSilenceWhenRingEmpty() throws {
        try requireBlackHole()
        let output = CoreAudioOutput()
        output.deviceUID = kBlackHoleUID
        output.start()
        XCTAssertTrue(output.isRunning)
        // Let the AU run for 300 ms with an empty ring — render callback should
        // pad with zeros and not crash.
        Thread.sleep(forTimeInterval: 0.3)
        output.stop()
        XCTAssertFalse(output.isRunning)
    }

    // MARK: - Input lifecycle

    func test_input_startsAndStops_onBlackHole() throws {
        try requireBlackHole()
        let input = CoreAudioInput()
        input.deviceUID = kBlackHoleUID
        input.start()
        XCTAssertTrue(input.isRunning, "CoreAudioInput.isRunning should be true after start()")
        input.stop()
        XCTAssertFalse(input.isRunning, "CoreAudioInput.isRunning should be false after stop()")
    }

    /// The AUHAL watchdog in CoreAudioInput logs loudly if no callbacks arrive
    /// within 1.2 s of start. This test is the automated version: we assert that
    /// at least one onSamples call arrives within 1.5 s.
    func test_input_deliversCallbacksWithin1500ms() throws {
        try requireBlackHole()
        let input = CoreAudioInput()
        input.deviceUID = kBlackHoleUID

        let callbackFired = expectation(description: "onSamples called at least once")
        callbackFired.assertForOverFulfill = false
        input.onSamples = { _, _ in callbackFired.fulfill() }

        input.start()
        XCTAssertTrue(input.isRunning)
        defer { input.stop() }

        wait(for: [callbackFired], timeout: 1.5)
    }

    // MARK: - Façade (CoreAudioIO)

    func test_coreAudioIO_startsAndStops() throws {
        try requireBlackHole()
        let io = CoreAudioIO()
        io.inputDeviceUID  = kBlackHoleUID
        io.outputDeviceUID = kBlackHoleUID
        io.start()
        XCTAssertTrue(io.isRunning, "CoreAudioIO.isRunning should be true after start()")
        io.stop()
        XCTAssertFalse(io.isRunning, "CoreAudioIO.isRunning should be false after stop()")
    }

    func test_coreAudioIO_enqueuePlayback_doesNotCrash() throws {
        try requireBlackHole()
        let io = CoreAudioIO()
        io.inputDeviceUID  = kBlackHoleUID
        io.outputDeviceUID = kBlackHoleUID
        io.start()
        defer { io.stop() }

        let sine = SignalGenerator.sine(frequency: 440, amplitude: 0.1,
                                        durationSeconds: 0.5, sampleRate: 48_000)
        sine.withUnsafeBufferPointer { buf in
            io.enqueuePlayback(buf.baseAddress!, count: buf.count)
        }
        Thread.sleep(forTimeInterval: 0.6)
        // No assertion needed beyond "didn't crash".
    }

    // MARK: - Full hardware loopback

    /// THE KEY TEST.
    ///
    /// Audio path:
    ///
    ///   SignalGenerator.sine(1 kHz)
    ///     → output.ring.write        (main thread)
    ///     → CoreAudioOutput render callback reads ring
    ///     → AUHAL sends Float32 PCM to BlackHole 2ch output
    ///     → BlackHole routes audio to its input side
    ///     → AUHAL captures from BlackHole 2ch input
    ///     → CoreAudioInput.onSamples callback fires
    ///     → we accumulate samples in `captured`
    ///     → assert dominant freq ≈ 1 kHz and RMS > silence threshold
    ///
    /// Assertions are intentionally lenient to tolerate the AUHAL buffer size
    /// (typically 256–512 frames) and any BlackHole startup latency:
    ///   • At least half the target samples must arrive (confirms loopback runs).
    ///   • RMS > 0.02 (original amplitude 0.3 — we're looking for non-silence).
    ///   • Dominant frequency within ±50 Hz of 1 kHz.
    func test_blackhole_loopback_sine1kHz_signalPreserved() throws {
        try requireBlackHole()

        let sampleRate    = 48_000.0
        let captureSecs   = 3.0
        let targetSamples = Int(sampleRate * captureSecs)

        // ── Set up output ─────────────────────────────────────────────────────
        let output = CoreAudioOutput()
        output.deviceUID = kBlackHoleUID

        // ── Set up input + sample accumulator ─────────────────────────────────
        let input = CoreAudioInput()
        input.deviceUID = kBlackHoleUID

        var captured = [Float]()
        captured.reserveCapacity(targetSamples + 1024)
        let captureLock  = NSLock()
        let capturedEnough = expectation(description: "Captured \(targetSamples) samples")
        capturedEnough.assertForOverFulfill = false

        input.onSamples = { ptr, count in
            captureLock.lock()
            let already = captured.count
            if already < targetSamples {
                let take = min(count, targetSamples - already)
                captured.append(contentsOf: UnsafeBufferPointer(start: ptr, count: take))
                if captured.count >= targetSamples { capturedEnough.fulfill() }
            }
            captureLock.unlock()
        }

        // ── Start both AUs ────────────────────────────────────────────────────
        output.start()
        input.start()
        defer {
            input.stop()
            output.stop()
        }

        XCTAssertTrue(output.isRunning, "Output did not start on BlackHole")
        XCTAssertTrue(input.isRunning,  "Input did not start on BlackHole")

        // ── Fill the output ring with a 1 kHz sine (+1 s extra headroom) ──────
        let source = SignalGenerator.sine(frequency: 1_000,
                                          amplitude: 0.3,
                                          durationSeconds: captureSecs + 1.0,
                                          sampleRate: sampleRate)
        source.withUnsafeBufferPointer { buf in
            output.ring.write(buf.baseAddress!, count: buf.count)
        }

        wait(for: [capturedEnough], timeout: 10.0)

        // ── Collect final snapshot ─────────────────────────────────────────────
        captureLock.lock()
        let samples = Array(captured.prefix(targetSamples))
        captureLock.unlock()

        // ── Assert ─────────────────────────────────────────────────────────────

        // Must have received at least half the expected sample count.
        XCTAssertGreaterThanOrEqual(
            samples.count, targetSamples / 2,
            "Too few samples captured (\(samples.count)) — input callbacks may not be running"
        )

        guard !samples.isEmpty else { return }

        // Must not be silence — RMS well above noise floor.
        let rms = AudioAnalysis.rms(samples)
        XCTAssertGreaterThan(
            rms, 0.02,
            "Captured signal is near silence (RMS=\(rms)) — loopback may not be routing"
        )

        // Dominant frequency must be 1 kHz ± 50 Hz.
        let (freq, _) = AudioAnalysis.dominantFrequency(samples, sampleRate: sampleRate)
        XCTAssertEqual(
            freq, 1_000, accuracy: 50,
            "Dominant frequency \(String(format: "%.1f", freq)) Hz is not near 1 kHz"
        )

        print("""
        [BlackHole loopback] \
        samples=\(samples.count)  \
        RMS=\(String(format: "%.4f", rms))  \
        dominantHz=\(String(format: "%.1f", freq))
        """)
    }
}
