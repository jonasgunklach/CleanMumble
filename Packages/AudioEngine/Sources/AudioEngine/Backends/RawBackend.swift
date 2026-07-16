//
//  RawBackend.swift
//  AudioEngine
//
//  Studio mode: an AUHAL input + output pair with no processing. For pro
//  interfaces and users who explicitly opt out of voice processing.
//
//  Ported from the proven parts of CoreAudioIO.swift, minus everything the
//  control plane now owns (no property listeners, no restart logic, no
//  suppression windows) and minus the input-side resampler (the capture
//  worker owns SRC — the AU captures at the device's NATIVE rate, which is
//  also the only mode Bluetooth HFP devices reliably deliver buffers in).
//

#if os(macOS)

import Foundation
import CoreAudio
import AudioToolbox

final class RawBackend: IOBackend {

    private var inputAU: AudioUnit?
    private var outputAU: AudioUnit?
    private var capture: CaptureEngine?
    private var playback: PlaybackEngine?

    private var inputScratch: UnsafeMutablePointer<Float>?
    private let inputScratchCap = 4_096
    private var inputBufList = AudioBufferList()
    private var outputChannels: Int = 2

    // MARK: - IOBackend

    func start(route: ResolvedRoute,
               capture: CaptureEngine,
               captureFormat: CaptureFormat,
               playback: PlaybackEngine,
               agcEnabled: Bool) throws {
        stop()
        self.capture = capture
        self.playback = playback
        do {
            let inputRate = try startInput(device: route.inputID)
            let band = inputRate <= 16_000 ? "wideband(8k)"
                     : inputRate <= 24_000 ? "superwideband(12k)" : "fullband"
            print(String(format: "[Audio] Raw backend: mic native %.0f Hz → Opus cap %@",
                         inputRate, band))
            capture.start(sourceRate: inputRate, format: captureFormat)
            try startOutput(device: route.outputID)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let au = inputAU {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            inputAU = nil
        }
        if let au = outputAU {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            outputAU = nil
        }
        capture?.stop()
        capture = nil
        playback = nil
        if let s = inputScratch {
            s.deinitialize(count: inputScratchCap)
            s.deallocate()
            inputScratch = nil
        }
    }

    // MARK: - Input (AUHAL capture at device-native rate, mono Float32)

    private func startInput(device: AudioDeviceID) throws -> Double {
        let unit = try makeHALUnit()
        // Enable input on bus 1, disable output on bus 0.
        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &enable, 4),
                  "enable input", unit)
        var disable: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0, &disable, 4),
                  "disable output", unit)
        var dev = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &dev,
                                       UInt32(MemoryLayout<AudioDeviceID>.size)),
                  "bind input device", unit)

        // Native rate, mono, Float32 — never ask the AU to SRC (BT HFP
        // devices "start" and then deliver nothing).
        var devFmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 1, &devFmt, &size),
                  "read device format", unit)
        let nativeRate = devFmt.mSampleRate > 0 ? devFmt.mSampleRate : 48_000

        var fmt = monoFloat32(rate: nativeRate)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1, &fmt,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "set capture format", unit)

        var maxFrames: UInt32 = 4_096
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &maxFrames, 4)

        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: inputScratchCap)
        scratch.initialize(repeating: 0, count: inputScratchCap)
        inputScratch = scratch
        inputBufList.mNumberBuffers = 1
        inputBufList.mBuffers.mNumberChannels = 1
        inputBufList.mBuffers.mDataByteSize = UInt32(inputScratchCap * 4)
        inputBufList.mBuffers.mData = UnsafeMutableRawPointer(scratch)

        try check(AudioUnitInitialize(unit), "initialize input AU", unit)

        var cb = AURenderCallbackStruct(
            inputProc: rawInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global, 0, &cb,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "set input callback", unit)

        try startWithRetry(unit, stage: "start input AU")
        inputAU = unit
        return nativeRate
    }

    // MARK: - Output (AUHAL render, 48 kHz interleaved; AUHAL does SRC)

    private func startOutput(device: AudioDeviceID) throws {
        let unit = try makeHALUnit()
        var dev = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &dev,
                                       UInt32(MemoryLayout<AudioDeviceID>.size)),
                  "bind output device", unit)

        var devFmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 0, &devFmt, &size)
        let channels = (err == noErr && devFmt.mChannelsPerFrame > 0)
            ? Int(devFmt.mChannelsPerFrame) : 2
        outputChannels = channels

        var fmt = interleavedFloat32(rate: 48_000, channels: UInt32(channels))
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0, &fmt,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "set render format", unit)

        var cb = AURenderCallbackStruct(
            inputProc: rawOutputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Global, 0, &cb,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "set render callback", unit)

        try check(AudioUnitInitialize(unit), "initialize output AU", unit)
        try startWithRetry(unit, stage: "start output AU")
        outputAU = unit
    }

    // MARK: - Render paths (REALTIME)

    fileprivate func renderInput(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                 timeStamp: UnsafePointer<AudioTimeStamp>,
                                 busNumber: UInt32,
                                 frames: UInt32) -> OSStatus {
        guard let unit = inputAU, let scratch = inputScratch,
              frames <= UInt32(inputScratchCap) else { return noErr }
        inputBufList.mBuffers.mDataByteSize = frames * 4
        inputBufList.mBuffers.mData = UnsafeMutableRawPointer(scratch)
        let err = withUnsafeMutablePointer(to: &inputBufList) {
            AudioUnitRender(unit, actionFlags, timeStamp, busNumber, frames, $0)
        }
        if err == noErr {
            capture?.ingest(scratch, count: Int(frames))
        }
        return err
    }

    fileprivate func renderOutput(_ ioData: UnsafeMutablePointer<AudioBufferList>?,
                                  frames: UInt32) -> OSStatus {
        guard let ioData else { return noErr }
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        guard let ab = abl.first,
              let dst = ab.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        playback?.pullInterleaved(into: dst, frames: Int(frames), channels: outputChannels)
        return noErr
    }

    // MARK: - Helpers

    private func makeHALUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw BackendError("find AUHAL component")
        }
        var au: AudioUnit?
        let err = AudioComponentInstanceNew(comp, &au)
        guard err == noErr, let unit = au else {
            throw BackendError("instantiate AUHAL", err)
        }
        return unit
    }

    private func check(_ status: OSStatus, _ stage: String, _ unit: AudioUnit) throws {
        if status != noErr {
            AudioComponentInstanceDispose(unit)
            throw BackendError(stage, status)
        }
    }

    /// HAL error 35 (EAGAIN) at start = device still held by a unit that
    /// hasn't fully released. A short bounded retry is a start-time race fix,
    /// not policy — anything persistent still throws to the controller.
    private func startWithRetry(_ unit: AudioUnit, stage: String) throws {
        var err = AudioOutputUnitStart(unit)
        var attempts = 1
        while err != noErr && attempts < 5 {
            usleep(50_000)
            err = AudioOutputUnitStart(unit)
            attempts += 1
        }
        if err != noErr {
            AudioComponentInstanceDispose(unit)
            throw BackendError(stage, err)
        }
    }

    private func monoFloat32(rate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    }

    private func interleavedFloat32(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }
}

// MARK: - C trampolines

private func rawInputCallback(inRefCon: UnsafeMutableRawPointer,
                              ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                              inTimeStamp: UnsafePointer<AudioTimeStamp>,
                              inBusNumber: UInt32,
                              inNumberFrames: UInt32,
                              ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<RawBackend>.fromOpaque(inRefCon).takeUnretainedValue()
        .renderInput(actionFlags: ioActionFlags, timeStamp: inTimeStamp,
                     busNumber: inBusNumber, frames: inNumberFrames)
}

private func rawOutputCallback(inRefCon: UnsafeMutableRawPointer,
                               ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                               inTimeStamp: UnsafePointer<AudioTimeStamp>,
                               inBusNumber: UInt32,
                               inNumberFrames: UInt32,
                               ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<RawBackend>.fromOpaque(inRefCon).takeUnretainedValue()
        .renderOutput(ioData, frames: inNumberFrames)
}

#endif
