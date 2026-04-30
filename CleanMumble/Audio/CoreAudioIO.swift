//
//  CoreAudioIO.swift
//  CleanMumble
//
//  Native CoreAudio (AUHAL) capture + render. Replaces the AVAudioEngine path
//  to fix the device-switch / format-renegotiation / two-engine-conflict bugs
//  that plague the AVAudioEngine implementation.
//
//  Structure and approach are a faithful Swift port of Mumble's
//  src/mumble/CoreAudio.mm (BSD-3-Clause, © The Mumble Developers,
//  https://www.mumble.info/LICENSE) — same AU components, same property
//  listeners, same restart-on-stream-format / default-device change strategy.
//  The Qt/threading scaffolding has been replaced with plain Swift +
//  GCD + os_unfair_lock.
//

import Foundation
import CoreAudio
import AudioToolbox
import AudioUnit
import os.lock
import AudioCore

// MARK: - Stream formats

/// Mumble fixes capture/playback at 48 kHz mono Float32. The AUHAL handles
/// any required device-side sample rate conversion for us when we set this
/// ASBD on the output scope of the input element (or the input scope of the
/// output element, respectively).
private let kSampleRate: Float64 = 48_000
private let kBytesPerSample: UInt32 = 4 // Float32

/// Window after a successful `start()` during which AU property-change
/// notifications are ignored. The system commonly republishes the stream
/// format right after the AU starts, which would otherwise create an
/// infinite restart loop.
private let kHotswapSuppressionSeconds: CFAbsoluteTime = 1.0

/// Two formats are considered equal for hot-swap purposes when these key
/// fields match. Avoids restarting on cosmetic flag changes.
private func formatsMatch(_ a: AudioStreamBasicDescription,
                          _ b: AudioStreamBasicDescription) -> Bool {
    return a.mSampleRate       == b.mSampleRate
        && a.mChannelsPerFrame == b.mChannelsPerFrame
        && a.mBitsPerChannel   == b.mBitsPerChannel
        && a.mFormatID         == b.mFormatID
        && a.mFormatFlags      == b.mFormatFlags
        && a.mBytesPerFrame    == b.mBytesPerFrame
}

private func makeFloat32Mono() -> AudioStreamBasicDescription {
    var f = AudioStreamBasicDescription()
    f.mSampleRate       = kSampleRate
    f.mFormatID         = kAudioFormatLinearPCM
    f.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    f.mBitsPerChannel   = 32
    f.mChannelsPerFrame = 1
    f.mBytesPerFrame    = kBytesPerSample
    f.mFramesPerPacket  = 1
    f.mBytesPerPacket   = kBytesPerSample
    return f
}

private func makeFloat32Interleaved(channels: UInt32) -> AudioStreamBasicDescription {
    var f = AudioStreamBasicDescription()
    f.mSampleRate       = kSampleRate
    f.mFormatID         = kAudioFormatLinearPCM
    f.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    f.mBitsPerChannel   = 32
    f.mChannelsPerFrame = channels
    f.mBytesPerFrame    = kBytesPerSample * channels
    f.mFramesPerPacket  = 1
    f.mBytesPerPacket   = kBytesPerSample * channels
    return f
}

// MARK: - Device helpers

private func deviceID(forUID uid: String, isInput: Bool) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDeviceForUID,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain
    )
    var devID = AudioDeviceID(0)
    var cfUID: CFString = uid as CFString
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
    return (err == noErr && devID != 0) ? devID : nil
}

private func defaultDeviceID(isInput: Bool) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: isInput ? kAudioHardwarePropertyDefaultInputDevice
                           : kAudioHardwarePropertyDefaultOutputDevice,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain
    )
    var devID = AudioDeviceID(0)
    var size  = UInt32(MemoryLayout<AudioDeviceID>.size)
    let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &devID)
    return (err == noErr && devID != 0) ? devID : nil
}

private func resolveDeviceID(uid: String, isInput: Bool) -> AudioDeviceID? {
    if uid.isEmpty || uid == "Default" {
        return defaultDeviceID(isInput: isInput)
    }
    return deviceID(forUID: uid, isInput: isInput) ?? defaultDeviceID(isInput: isInput)
}

private func findHALOutputComponent() -> AudioComponent? {
    var desc = AudioComponentDescription(
        componentType:         kAudioUnitType_Output,
        componentSubType:      kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags:        0,
        componentFlagsMask:    0
    )
    return AudioComponentFindNext(nil, &desc)
}

// MARK: - Lock-free-ish ring buffer for output PCM (mono Float32)

/// Single-producer / single-consumer ring buffer guarded by os_unfair_lock.
/// Critical sections are O(1) memcpy, fine for audio render callbacks at
/// typical buffer sizes (256–2048 frames).
final class FloatRingBuffer {
    private var storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private var head = 0   // read index  (consumer / RT thread)
    private var tail = 0   // write index (producer / Swift)
    private var lock = os_unfair_lock()

    init(capacity: Int) {
        self.capacity = capacity
        let p = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        p.initialize(repeating: 0, count: capacity)
        self.storage = UnsafeMutableBufferPointer(start: p, count: capacity)
    }

    deinit {
        storage.baseAddress?.deinitialize(count: capacity)
        storage.baseAddress?.deallocate()
    }

    var availableRead: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return (tail &- head + capacity) % capacity
    }

    /// Append samples; drops oldest data on overflow.
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let cap = capacity
        // If buffer would overflow, advance head to drop oldest.
        let used = (tail &- head + cap) % cap
        let free = cap - used - 1
        if count > free {
            // Drop the oldest (count - free) samples.
            head = (head + (count - free)) % cap
        }
        var written = 0
        var t = tail
        while written < count {
            let chunk = min(count - written, cap - t)
            samples.advanced(by: written).withMemoryRebound(to: Float.self, capacity: chunk) { src in
                storage.baseAddress!.advanced(by: t).update(from: src, count: chunk)
            }
            t = (t + chunk) % cap
            written += chunk
        }
        tail = t
    }

    /// Read up to `count` samples. Returns frames actually read; pads remainder
    /// with silence in `dst`.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        os_unfair_lock_lock(&lock)
        let cap = capacity
        let avail = (tail &- head + cap) % cap
        let toCopy = min(avail, count)
        var copied = 0
        var h = head
        while copied < toCopy {
            let chunk = min(toCopy - copied, cap - h)
            dst.advanced(by: copied).update(from: storage.baseAddress!.advanced(by: h),
                                            count: chunk)
            h = (h + chunk) % cap
            copied += chunk
        }
        head = h
        os_unfair_lock_unlock(&lock)
        if copied < count {
            // Pad with silence so the AU always gets a full buffer.
            (dst + copied).update(repeating: 0, count: count - copied)
        }
        return copied
    }

    func clear() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        head = 0; tail = 0
    }
}

// MARK: - Input (AUHAL capture)

/// Captures mic audio at 48 kHz mono Float32 and ships every render-callback
/// chunk to the supplied `onSamples` closure. Restarts itself when the device
/// stream format changes or when the system default device changes.
final class CoreAudioInput {
    private var au: AudioUnit?
    private var deviceID: AudioDeviceID = 0
    private var bufList = AudioBufferList()
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchFrames: Int = 0
    private(set) var isRunning: Bool = false
    /// Mach-time of the most recent successful `start()`. Property-change
    /// notifications fired within `kHotswapSuppressionSeconds` of this point
    /// are ignored — the system commonly republishes the stream format
    /// during AU initialization, which would otherwise trigger an infinite
    /// restart loop.
    private var lastStartedAt: CFAbsoluteTime = 0
    /// Last stream format we observed; used to dedupe no-op change events.
    private var lastFormat = AudioStreamBasicDescription()
    /// Native sample rate of the input device (Hz). The AU is configured to
    /// hand us samples at this rate; we resample to 48 kHz in software.
    private var deviceSampleRate: Float64 = 48_000
    /// AudioConverter that resamples device-rate mono Float32 → 48 kHz mono
    /// Float32. nil when no rate conversion is necessary.
    private var resampler: AudioConverterRef?
    /// Scratch buffer for the resampled output (48 kHz mono Float32).
    private var resampledScratch: UnsafeMutablePointer<Float>?
    private var resampledScratchFrames: Int = 0
    /// Watchdog: counts AudioUnitRender invocations. Main thread checks this
    /// ~1s after start; if still 0 we know the AU started but isn't actually
    /// delivering buffers (the symptom we're fixing).
    private var renderInvocations: Int = 0

    /// Called from the audio render thread with one chunk of mono Float32 PCM.
    /// Implementations MUST be realtime-safe (no allocations / locks / Swift
    /// runtime calls beyond pointer arithmetic and `DispatchQueue.async`).
    var onSamples: ((UnsafePointer<Float>, Int) -> Void)?

    /// Called on the main queue when the input device or stream format
    /// changes and the input has restarted (or failed to). Use it to refresh
    /// any cached format info.
    var onRestart: (() -> Void)?

    /// Linear input gain applied AFTER resampling, BEFORE delivery to
    /// `onSamples`. Adjustable from any thread; the render callback reads it
    /// once per frame. 1.0 = unity, 0.0 = silence, hard-clamped to [0, 8].
    let inputGainProcessor = GainProcessor(gain: 1.0)
    var inputGain: Float {
        get { inputGainProcessor.gain }
        set { inputGainProcessor.gain = newValue }
    }
    /// Smoothed RMS / peak level meter — observes the mic samples AFTER
    /// gain. Read via `inputMeter.snapshot()` from a UI timer.
    let inputMeter = LevelMeter()

    /// The UID requested by the user ("Default" / "" → system default).
    var deviceUID: String = "Default"

    func start() {
        stop()
        guard let comp = findHALOutputComponent() else {
            print("[CAInput] AUHAL not found"); return
        }
        guard let dev = resolveDeviceID(uid: deviceUID, isInput: true) else {
            print("[CAInput] Could not resolve input device for UID '\(deviceUID)'")
            return
        }
        deviceID = dev

        var au: AudioUnit?
        var err = AudioComponentInstanceNew(comp, &au)
        guard err == noErr, let unit = au else {
            print("[CAInput] AudioComponentInstanceNew failed: \(err)"); return
        }

        // Enable input on bus 1; disable output on bus 0.
        var enable: UInt32 = 1
        err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        guard err == noErr else { print("[CAInput] enableIO(input) failed: \(err)"); dispose(unit); return }

        var disable: UInt32 = 0
        err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size))
        guard err == noErr else { print("[CAInput] enableIO(output off) failed: \(err)"); dispose(unit); return }

        // Bind the chosen device.
        var devID = dev
        err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &devID,
                                   UInt32(MemoryLayout<AudioDeviceID>.size))
        guard err == noErr else { print("[CAInput] setCurrentDevice failed: \(err)"); dispose(unit); return }

        // ---------------------------------------------------------------
        // Mumble-style format negotiation: query the device's NATIVE format
        // on the input scope of bus 1, force channels=1 + Float32 packed,
        // KEEP the device's sample rate, then set that format on BOTH scopes.
        // We resample to 48 kHz in software (Bluetooth HFP devices in
        // particular refuse to start when the AU is asked to do internal SRC
        // from 16 kHz to 48 kHz — we get "started" with no IO callbacks).
        // ---------------------------------------------------------------
        var devFmt = AudioStreamBasicDescription()
        var devFmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Input, 1, &devFmt, &devFmtSize)
        guard err == noErr else { print("[CAInput] getStreamFormat(device) failed: \(err)"); dispose(unit); return }
        print(String(format: "[CAInput] Device native format: %.0f Hz, %u ch, fmtFlags=0x%08X",
                     devFmt.mSampleRate, devFmt.mChannelsPerFrame, devFmt.mFormatFlags))

        let nativeRate = devFmt.mSampleRate > 0 ? devFmt.mSampleRate : 48_000
        deviceSampleRate = nativeRate

        // Build our chosen AU format: device's native rate, mono, Float32 packed.
        var fmt = AudioStreamBasicDescription()
        fmt.mSampleRate       = nativeRate
        fmt.mFormatID         = kAudioFormatLinearPCM
        fmt.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        fmt.mChannelsPerFrame = 1
        fmt.mBitsPerChannel   = 32
        fmt.mBytesPerFrame    = 4
        fmt.mFramesPerPacket  = 1
        fmt.mBytesPerPacket   = 4

        err = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output, 1, &fmt,
                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard err == noErr else { print("[CAInput] setStreamFormat(out-bus-1) failed: \(err)"); dispose(unit); return }
        // Mumble also sets the same format on input-scope-bus-0 (the disabled
        // output side). Skip if AU rejects (some Bluetooth AUs do).
        let err2 = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                        kAudioUnitScope_Input, 0, &fmt,
                                        UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if err2 != noErr {
            print("[CAInput] setStreamFormat(in-bus-0) returned \(err2) — non-fatal")
        }

        // Cap the maximum frames per slice. Some devices default to a huge
        // value and the AU then refuses to start.
        var maxFrames: UInt32 = 4096
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &maxFrames,
                             UInt32(MemoryLayout<UInt32>.size))

        // Build the resampler if device rate ≠ 48 kHz.
        if Int(nativeRate) != Int(kSampleRate) {
            var srcFmt = fmt
            var dstFmt = makeFloat32Mono()
            var conv: AudioConverterRef?
            let cerr = AudioConverterNew(&srcFmt, &dstFmt, &conv)
            if cerr == noErr, let conv {
                resampler = conv
                print("[CAInput] Resampler installed: \(Int(nativeRate)) Hz → 48000 Hz")
            } else {
                print("[CAInput] AudioConverterNew failed: \(cerr) — passing through native rate")
            }
        }

        // Pre-allocate a generous scratch buffer; AudioUnitRender writes here.
        let scratchCap = 4096
        let p = UnsafeMutablePointer<Float>.allocate(capacity: scratchCap)
        p.initialize(repeating: 0, count: scratchCap)
        scratch = p
        scratchFrames = scratchCap

        // Resampled scratch: even if no resampler, we keep this nil. With a
        // resampler we pick a generous size based on max upsample ratio.
        if resampler != nil {
            let upRatio = max(1.0, kSampleRate / max(deviceSampleRate, 1))
            let resampledCap = max(scratchCap, Int(Double(scratchCap) * upRatio + 256))
            let rp = UnsafeMutablePointer<Float>.allocate(capacity: resampledCap)
            rp.initialize(repeating: 0, count: resampledCap)
            resampledScratch = rp
            resampledScratchFrames = resampledCap
        }

        bufList = AudioBufferList()
        bufList.mNumberBuffers = 1
        bufList.mBuffers.mNumberChannels = 1
        bufList.mBuffers.mDataByteSize   = UInt32(scratchCap) * kBytesPerSample
        bufList.mBuffers.mData           = UnsafeMutableRawPointer(p)

        err = AudioUnitInitialize(unit)
        guard err == noErr else { print("[CAInput] AudioUnitInitialize failed: \(err)"); dispose(unit); return }

        // Install render callback AFTER AudioUnitInitialize — installing it
        // earlier on an uninitialised AU is a known cause of "AU starts but
        // never delivers buffers". Mumble's CoreAudio.mm does it in this order.
        var cb = AURenderCallbackStruct(
            inputProc: caInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                   kAudioUnitScope_Global, 0, &cb,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard err == noErr else { print("[CAInput] setInputCallback failed: \(err)"); dispose(unit); return }

        // Property listeners for hot-swap recovery (AirPods etc.).
        AudioUnitAddPropertyListener(unit, kAudioUnitProperty_StreamFormat,
                                     caInputPropertyChanged,
                                     Unmanaged.passUnretained(self).toOpaque())
        var defaultDevAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                       &defaultDevAddr,
                                       caInputDefaultDeviceChanged,
                                       Unmanaged.passUnretained(self).toOpaque())

        // Stash the AU pointer BEFORE start so the render callback can deref
        // it on its very first invocation.
        self.au = unit

        // Retry start on EAGAIN (HAL error 35 = device temporarily busy,
        // typically because another AU on the same device hasn't fully
        // released yet).
        err = AudioOutputUnitStart(unit)
        var attempts = 1
        while err != noErr && attempts < 5 {
            print("[CAInput] Start attempt \(attempts) failed (err=\(err)); retrying after backoff")
            usleep(50_000) // 50 ms
            err = AudioOutputUnitStart(unit)
            attempts += 1
        }
        guard err == noErr else {
            print("[CAInput] AudioOutputUnitStart failed permanently: \(err)")
            self.au = nil
            dispose(unit)
            return
        }

        self.isRunning = true
        self.lastStartedAt = CFAbsoluteTimeGetCurrent()
        // Cache the post-start format so the listener can dedupe no-op events.
        var postFmt = AudioStreamBasicDescription()
        var postSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                kAudioUnitScope_Output, 1,
                                &postFmt, &postSize) == noErr {
            self.lastFormat = postFmt
        }
        print("[CAInput] Started on device id \(dev) (UID '\(deviceUID)')")

        // Watchdog: ~1s after start, check that the AU is actually delivering
        // buffers. If not, it "started" but the HAL refused IO (the bug we've
        // been chasing). Log it loudly so we can spot it without instrumenting
        // every render.
        renderInvocations = 0
        let startToken = lastStartedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            // If we've been restarted in the meantime, skip.
            guard self.lastStartedAt == startToken else { return }
            if self.renderInvocations == 0 {
                print("[CAInput][WATCHDOG] No render callbacks within 1.2s after Start — HAL silently refused IO. Devices: input=\(self.deviceID)")
            } else {
                print("[CAInput][WATCHDOG] OK — \(self.renderInvocations) render callbacks delivered in 1.2s")
            }
        }
    }

    func stop() {
        guard let unit = au else { return }
        AudioOutputUnitStop(unit)
        AudioUnitRemovePropertyListenerWithUserData(unit, kAudioUnitProperty_StreamFormat,
                                                    caInputPropertyChanged,
                                                    Unmanaged.passUnretained(self).toOpaque())
        var defaultDevAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                          &defaultDevAddr,
                                          caInputDefaultDeviceChanged,
                                          Unmanaged.passUnretained(self).toOpaque())
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        au = nil
        isRunning = false
        if let s = scratch {
            s.deinitialize(count: scratchFrames)
            s.deallocate()
            scratch = nil
            scratchFrames = 0
        }
        if let r = resampledScratch {
            r.deinitialize(count: resampledScratchFrames)
            r.deallocate()
            resampledScratch = nil
            resampledScratchFrames = 0
        }
        if let conv = resampler {
            AudioConverterDispose(conv)
            resampler = nil
        }
        print("[CAInput] Stopped")
    }

    private func dispose(_ unit: AudioUnit) {
        AudioComponentInstanceDispose(unit)
    }

    /// Called from a property listener (off the audio thread). We bounce to
    /// main and restart the unit cleanly.
    fileprivate func handleHotswap(reason: String) {
        // Suppress restart storms during the immediate post-start window.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastStartedAt < kHotswapSuppressionSeconds {
            print("[CAInput] Ignored hotswap (\(reason)) within suppression window")
            return
        }
        // Dedupe by reading the *current* format and comparing to lastFormat.
        if let unit = au {
            var f = AudioStreamBasicDescription()
            var s = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Output, 1,
                                    &f, &s) == noErr,
               formatsMatch(f, lastFormat) {
                print("[CAInput] Ignored hotswap (\(reason)): format unchanged")
                return
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            print("[CAInput] Restart requested: \(reason)")
            self.start()
            self.onRestart?()
        }
    }

    // MARK: Render callback machinery (called from audio thread)

    /// Single-shot input feeder for the AudioConverter: hands the converter
    /// the entire current scratch buffer (one render's worth) and then
    /// signals "no more data" so the converter returns control to render().
    fileprivate func fillResamplerInput(numPackets: UnsafeMutablePointer<UInt32>,
                                        data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard let scratch else { numPackets.pointee = 0; return noErr }
        let avail = bufList.mBuffers.mDataByteSize / kBytesPerSample
        if avail == 0 {
            // No more data this round — must return noErr (NOT an error code)
            // so AudioConverterFillComplexBuffer returns whatever frames it
            // has already produced rather than propagating the error.
            numPackets.pointee = 0
            return noErr
        }
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mNumberChannels = 1
        data.pointee.mBuffers.mDataByteSize = avail * kBytesPerSample
        data.pointee.mBuffers.mData = UnsafeMutableRawPointer(scratch)
        numPackets.pointee = avail
        // Mark the source buffer empty so the next callback returns 0.
        bufList.mBuffers.mDataByteSize = 0
        return noErr
    }

    fileprivate func render(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            timeStamp: UnsafePointer<AudioTimeStamp>,
                            busNumber: UInt32,
                            frames: UInt32) -> OSStatus {
        guard let unit = au, let scratch else { return -1 }
        renderInvocations &+= 1
        // Reset buffer size to what the AU wants this round.
        let bytes = frames * kBytesPerSample
        bufList.mBuffers.mDataByteSize = bytes
        bufList.mBuffers.mData = UnsafeMutableRawPointer(scratch)
        let err = withUnsafeMutablePointer(to: &bufList) { listPtr -> OSStatus in
            AudioUnitRender(unit, actionFlags, timeStamp, busNumber, frames, listPtr)
        }
        if err != noErr { return err }

        if let conv = resampler, let dst = resampledScratch {
            // Convert device-rate mono Float32 → 48 kHz mono Float32.
            let ratio = kSampleRate / deviceSampleRate
            let outCap = UInt32(Double(frames) * ratio + 64)
            var outFrames = outCap
            var outList = AudioBufferList()
            outList.mNumberBuffers = 1
            outList.mBuffers.mNumberChannels = 1
            outList.mBuffers.mDataByteSize = outCap * kBytesPerSample
            outList.mBuffers.mData = UnsafeMutableRawPointer(dst)
            let cerr = withUnsafeMutablePointer(to: &outList) { outListPtr in
                AudioConverterFillComplexBuffer(conv,
                                                caResamplerInputCallback,
                                                Unmanaged.passUnretained(self).toOpaque(),
                                                &outFrames,
                                                outListPtr,
                                                nil)
            }
            // Deliver any frames the converter produced, even if it returned
            // a non-zero status (typical when input ran dry mid-fill).
            if outFrames > 0 {
                inputGainProcessor.applyInPlace(dst, count: Int(outFrames))
                inputMeter.observe(dst, count: Int(outFrames))
                onSamples?(dst, Int(outFrames))
            } else if cerr != noErr {
                // Periodic-but-not-spammy log: only first few failures.
                if renderInvocations < 4 {
                    print("[CAInput] Resampler produced 0 frames (cerr=\(cerr))")
                }
            }
        } else {
            inputGainProcessor.applyInPlace(scratch, count: Int(frames))
            inputMeter.observe(scratch, count: Int(frames))
            onSamples?(scratch, Int(frames))
        }
        return noErr
    }
}

/// AudioConverter input callback: feeds the converter one chunk of native-
/// rate mono Float32 samples (the most recent AudioUnitRender output).
private func caResamplerInputCallback(inAudioConverter: AudioConverterRef,
                                      ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
                                      ioData: UnsafeMutablePointer<AudioBufferList>,
                                      outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                                      inUserData: UnsafeMutableRawPointer?) -> OSStatus
{
    guard let raw = inUserData else { ioNumberDataPackets.pointee = 0; return -1 }
    let me = Unmanaged<CoreAudioInput>.fromOpaque(raw).takeUnretainedValue()
    return me.fillResamplerInput(numPackets: ioNumberDataPackets, data: ioData)
}

// MARK: Input C trampolines

private func caInputCallback(inRefCon: UnsafeMutableRawPointer,
                             ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             inTimeStamp: UnsafePointer<AudioTimeStamp>,
                             inBusNumber: UInt32,
                             inNumberFrames: UInt32,
                             ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus
{
    let me = Unmanaged<CoreAudioInput>.fromOpaque(inRefCon).takeUnretainedValue()
    return me.render(actionFlags: ioActionFlags,
                     timeStamp:   inTimeStamp,
                     busNumber:   inBusNumber,
                     frames:      inNumberFrames)
}

private func caInputPropertyChanged(inRefCon: UnsafeMutableRawPointer,
                                    inUnit: AudioUnit,
                                    inID: AudioUnitPropertyID,
                                    inScope: AudioUnitScope,
                                    inElement: AudioUnitElement)
{
    if inID == kAudioUnitProperty_StreamFormat {
        let me = Unmanaged<CoreAudioInput>.fromOpaque(inRefCon).takeUnretainedValue()
        me.handleHotswap(reason: "input stream format changed")
    }
}

private func caInputDefaultDeviceChanged(inObjectID: AudioObjectID,
                                         inNumberAddresses: UInt32,
                                         inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
                                         inClientData: UnsafeMutableRawPointer?) -> OSStatus
{
    if let p = inClientData {
        let me = Unmanaged<CoreAudioInput>.fromOpaque(p).takeUnretainedValue()
        me.handleHotswap(reason: "default input device changed")
    }
    return noErr
}

// MARK: - Output (AUHAL render)

/// Renders mono Float32 PCM (pulled from a ring buffer the protocol layer
/// fills) to the chosen output device. Restarts on stream-format / default
/// device changes the same way as `CoreAudioInput`.
final class CoreAudioOutput {
    private var au: AudioUnit?
    private var outputChannels: UInt32 = 2
    let ring: FloatRingBuffer
    private var mixScratch: UnsafeMutablePointer<Float>?
    private var mixScratchFrames: Int = 0
    private(set) var isRunning: Bool = false
    /// See `CoreAudioInput.lastStartedAt`.
    private var lastStartedAt: CFAbsoluteTime = 0
    private var lastFormat = AudioStreamBasicDescription()

    /// Output device UID ("Default" / "" → system default).
    var deviceUID: String = "Default"
    /// Linear gain applied in the render callback (0…1). Realtime-safe scalar.
    var gain: Float = 1.0
    /// Smoothed RMS / peak level meter — observes the post-gain output
    /// samples (i.e. what the speaker actually hears).
    let outputMeter = LevelMeter()

    init(ringCapacityFrames: Int = 48_000 /* 1s @ 48kHz mono */) {
        self.ring = FloatRingBuffer(capacity: ringCapacityFrames)
    }

    func start() {
        stop()
        guard let comp = findHALOutputComponent() else {
            print("[CAOutput] AUHAL not found"); return
        }
        guard let dev = resolveDeviceID(uid: deviceUID, isInput: false) else {
            print("[CAOutput] Could not resolve output device for UID '\(deviceUID)'")
            return
        }

        var au: AudioUnit?
        var err = AudioComponentInstanceNew(comp, &au)
        guard err == noErr, let unit = au else {
            print("[CAOutput] AudioComponentInstanceNew failed: \(err)"); return
        }

        // Default for HALOutput is output enabled, input disabled — leave it.

        // Bind the chosen device.
        var devID = dev
        err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &devID,
                                   UInt32(MemoryLayout<AudioDeviceID>.size))
        guard err == noErr else { print("[CAOutput] setCurrentDevice failed: \(err)"); dispose(unit); return }

        // Discover device's native channel count so we can render interleaved
        // Float32 with the right channel count (typical: 2 for headphones,
        // sometimes 1 for AirPods in handsfree, 6+ for surround).
        var devFormat = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output, 0,
                                   &devFormat, &fmtSize)
        let channels: UInt32
        if err == noErr, devFormat.mChannelsPerFrame > 0 {
            channels = devFormat.mChannelsPerFrame
        } else {
            channels = 2
        }
        outputChannels = channels

        // Tell the AU what we will feed it on the input side of bus 0.
        var fmt = makeFloat32Interleaved(channels: channels)
        err = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Input, 0, &fmt,
                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard err == noErr else { print("[CAOutput] setStreamFormat failed: \(err)"); dispose(unit); return }

        var cb = AURenderCallbackStruct(
            inputProc: caOutputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        err = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                   kAudioUnitScope_Global, 0, &cb,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard err == noErr else { print("[CAOutput] setRenderCallback failed: \(err)"); dispose(unit); return }

        err = AudioUnitInitialize(unit)
        guard err == noErr else { print("[CAOutput] AudioUnitInitialize failed: \(err)"); dispose(unit); return }

        // Allocate per-render mono scratch (deinterleaved from ring → fanned out).
        let scratchCap = 8192
        let p = UnsafeMutablePointer<Float>.allocate(capacity: scratchCap)
        p.initialize(repeating: 0, count: scratchCap)
        mixScratch = p
        mixScratchFrames = scratchCap

        // Property listeners.
        AudioUnitAddPropertyListener(unit, kAudioUnitProperty_StreamFormat,
                                     caOutputPropertyChanged,
                                     Unmanaged.passUnretained(self).toOpaque())
        var defaultDevAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                       &defaultDevAddr,
                                       caOutputDefaultDeviceChanged,
                                       Unmanaged.passUnretained(self).toOpaque())

        err = AudioOutputUnitStart(unit)
        guard err == noErr else { print("[CAOutput] AudioOutputUnitStart failed: \(err)"); dispose(unit); return }

        self.au = unit
        self.isRunning = true
        self.lastStartedAt = CFAbsoluteTimeGetCurrent()
        var postFmt = AudioStreamBasicDescription()
        var postSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                kAudioUnitScope_Input, 0,
                                &postFmt, &postSize) == noErr {
            self.lastFormat = postFmt
        }
        print("[CAOutput] Started on device id \(dev) (UID '\(deviceUID)', \(channels) ch)")
    }

    func stop() {
        guard let unit = au else { return }
        AudioOutputUnitStop(unit)
        AudioUnitRemovePropertyListenerWithUserData(unit, kAudioUnitProperty_StreamFormat,
                                                    caOutputPropertyChanged,
                                                    Unmanaged.passUnretained(self).toOpaque())
        var defaultDevAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                          &defaultDevAddr,
                                          caOutputDefaultDeviceChanged,
                                          Unmanaged.passUnretained(self).toOpaque())
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        au = nil
        isRunning = false
        if let s = mixScratch {
            s.deinitialize(count: mixScratchFrames)
            s.deallocate()
            mixScratch = nil
            mixScratchFrames = 0
        }
        ring.clear()
        print("[CAOutput] Stopped")
    }

    private func dispose(_ unit: AudioUnit) {
        AudioComponentInstanceDispose(unit)
    }

    fileprivate func handleHotswap(reason: String) {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastStartedAt < kHotswapSuppressionSeconds {
            print("[CAOutput] Ignored hotswap (\(reason)) within suppression window")
            return
        }
        if let unit = au {
            var f = AudioStreamBasicDescription()
            var s = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Input, 0,
                                    &f, &s) == noErr,
               formatsMatch(f, lastFormat) {
                print("[CAOutput] Ignored hotswap (\(reason)): format unchanged")
                return
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            print("[CAOutput] Restart requested: \(reason)")
            self.start()
        }
    }

    /// Realtime: pull mono PCM from the ring, fan out to `outputChannels` interleaved.
    fileprivate func render(_ ioData: UnsafeMutablePointer<AudioBufferList>?,
                            frames: UInt32) -> OSStatus
    {
        guard let ioData, let mixScratch else { return -1 }
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        guard let ab = abl.first, let dst = ab.mData?.assumingMemoryBound(to: Float.self)
        else { return -1 }

        let n = Int(frames)
        let cap = mixScratchFrames
        if n > cap {
            // Should not happen with cap = 8192; bail to silence rather than crash.
            (dst).update(repeating: 0, count: Int(ab.mDataByteSize) / 4)
            return noErr
        }
        ring.read(into: mixScratch, count: n)
        let g = gain
        let chans = Int(outputChannels)
        // Interleave mono → N channels with gain.
        for i in 0..<n {
            let v = mixScratch[i] * g
            mixScratch[i] = v   // store back so the meter sees post-gain
            for c in 0..<chans {
                dst[i * chans + c] = v
            }
        }
        outputMeter.observe(mixScratch, count: n)
        return noErr
    }
}

// MARK: Output C trampolines

private func caOutputCallback(inRefCon: UnsafeMutableRawPointer,
                              ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                              inTimeStamp: UnsafePointer<AudioTimeStamp>,
                              inBusNumber: UInt32,
                              inNumberFrames: UInt32,
                              ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus
{
    let me = Unmanaged<CoreAudioOutput>.fromOpaque(inRefCon).takeUnretainedValue()
    return me.render(ioData, frames: inNumberFrames)
}

private func caOutputPropertyChanged(inRefCon: UnsafeMutableRawPointer,
                                     inUnit: AudioUnit,
                                     inID: AudioUnitPropertyID,
                                     inScope: AudioUnitScope,
                                     inElement: AudioUnitElement)
{
    if inID == kAudioUnitProperty_StreamFormat {
        let me = Unmanaged<CoreAudioOutput>.fromOpaque(inRefCon).takeUnretainedValue()
        me.handleHotswap(reason: "output stream format changed")
    }
}

private func caOutputDefaultDeviceChanged(inObjectID: AudioObjectID,
                                          inNumberAddresses: UInt32,
                                          inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
                                          inClientData: UnsafeMutableRawPointer?) -> OSStatus
{
    if let p = inClientData {
        let me = Unmanaged<CoreAudioOutput>.fromOpaque(p).takeUnretainedValue()
        me.handleHotswap(reason: "default output device changed")
    }
    return noErr
}

// MARK: - Facade

/// Owns an input + output pair. Use this from `RealMumbleClient` instead of
/// `AVAudioEngine`.
final class CoreAudioIO {
    let input  = CoreAudioInput()
    let output = CoreAudioOutput()

    var inputDeviceUID: String {
        get { input.deviceUID }
        set { input.deviceUID = newValue }
    }
    var outputDeviceUID: String {
        get { output.deviceUID }
        set { output.deviceUID = newValue }
    }

    func start() {
        input.start()
        output.start()
    }

    func stop() {
        input.stop()
        output.stop()
    }

    /// Submit decoded mono Float32 PCM @ 48 kHz for playback.
    func enqueuePlayback(_ samples: UnsafePointer<Float>, count: Int) {
        output.ring.write(samples, count: count)
    }

    var isRunning: Bool { input.isRunning || output.isRunning }
}
