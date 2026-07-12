//
//  VoiceBackend.swift
//  AudioEngine
//
//  Default backend: AVAudioEngine with voice processing enabled — one duplex
//  unit owning both directions (AEC reference for free), the only reliable
//  VPIO entry point on macOS, and the path that lets the system negotiate
//  the high-bandwidth AirPods voice link.
//
//  Hard-won specifics (inherited from VPIOEngineInput.swift):
//   • Pin BOTH nodes' AUAudioUnit.deviceID before enabling voice processing —
//     VPIO needs matching devices to negotiate the Bluetooth link mode.
//   • setVoiceProcessingEnabled reconfigures the graph; query node formats
//     AFTER it, never before.
//   • The mainMixer→output connection must be made at the output node's
//     negotiated duplex format or AudioUnitInitialize fails with -10875.
//   • VPIO sub-properties (AGC) only stick on an initialized AU — set them
//     after engine.start().
//   • Ducking: default VPIO crushes other apps' audio (games, YouTube);
//     duckingLevel = .min keeps it audible. (audio-engine.md §3.2)
//

#if os(macOS)

import Foundation
import AVFAudio
import AudioToolbox

final class VoiceBackend: IOBackend {

    private var engine: AVAudioEngine?
    private var srcNode: AVAudioSourceNode?

    func start(route: ResolvedRoute,
               capture: CaptureEngine,
               captureFormat: CaptureFormat,
               playback: PlaybackEngine,
               agcEnabled: Bool) throws {
        stop()

        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let outputNode = eng.outputNode

        // 1) Pin devices ONLY when the user explicitly chose them. When
        //    following the system default we leave the nodes alone: VPIO
        //    builds its own aggregate around the default devices, and a
        //    manual bind against split Bluetooth devices (AirPods expose
        //    input-only + output-only HAL devices) can wedge that aggregate
        //    ("AUVPAggregate: Timeout waiting for streams").
        if route.inputPinned {
            try? inputNode.auAudioUnit.setDeviceID(route.inputID)
        }
        if route.outputPinned {
            try? outputNode.auAudioUnit.setDeviceID(route.outputID)
        }

        // 2) Voice processing ON — this triggers the BT mode negotiation.
        try inputNode.setVoiceProcessingEnabled(true)

        // 3) Don't crush other apps' audio.
        inputNode.voiceProcessingOtherAudioDuckingConfiguration =
            .init(enableAdvancedDucking: false, duckingLevel: .min)

        // 4) Formats — only valid AFTER step 2.
        let inFormat = inputNode.outputFormat(forBus: 0)
        let outNodeFormat = outputNode.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, outNodeFormat.sampleRate > 0 else {
            throw BackendError("VPIO negotiated zero sample rate")
        }

        // 5) Capture: worker resamples device rate → 48 kHz, so the tap just
        //    forwards mono samples.
        capture.start(sourceRate: inFormat.sampleRate, format: captureFormat)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buf, _ in
            guard let ch0 = buf.floatChannelData?[0] else { return }
            capture.ingest(ch0, count: Int(buf.frameLength))
        }

        // 6) Playback: a source node PULLS the 48 kHz mono mix at the device
        //    clock; mainMixer converts to the duplex format.
        guard let pullFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 48_000, channels: 1,
                                             interleaved: false) else {
            throw BackendError("make pull format")
        }
        let src = AVAudioSourceNode(format: pullFormat) { _, _, frames, ablPtr in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            guard let ab = abl.first,
                  let dst = ab.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            playback.pullMix(into: dst, frames: Int(frames))
            return noErr
        }
        eng.attach(src)
        let mixer = eng.mainMixerNode
        eng.disconnectNodeOutput(mixer)
        eng.connect(mixer, to: outputNode, format: outNodeFormat)
        eng.connect(src, to: mixer, format: pullFormat)
        srcNode = src

        eng.prepare()
        do {
            try eng.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            capture.stop()
            throw error
        }
        engine = eng

        // 7) Sub-properties — valid only on the initialized AU.
        if let au = inputNode.audioUnit {
            var agc: UInt32 = agcEnabled ? 1 : 0
            AudioUnitSetProperty(au, kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                                 kAudioUnitScope_Global, 0,
                                 &agc, UInt32(MemoryLayout<UInt32>.size))
        }
    }

    func stop() {
        guard let eng = engine else { return }
        if eng.isRunning {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        }
        if let s = srcNode { eng.detach(s) }
        try? eng.inputNode.setVoiceProcessingEnabled(false)
        srcNode = nil
        engine = nil
    }
}

#endif
