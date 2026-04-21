//
//  SettingsView.swift
//  CleanMumble
//
//  Created by Jonas Gunklach on 24.09.25.
//

import SwiftUI
import CoreAudio
import AVFoundation
import Combine

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: MumbleViewModel
    @State private var audioSettings  = AudioSettings()
    @State private var inputDevices:  [AudioDeviceInfo] = []
    @State private var outputDevices: [AudioDeviceInfo] = []
    @StateObject private var audioMonitor = AudioMonitor()
    
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $viewModel.userPreferences.theme) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    }
                    Toggle("Show Notifications", isOn: $viewModel.userPreferences.showNotifications)
                    Toggle("Minimize to Menu Bar", isOn: $viewModel.userPreferences.minimizeToTray)
                    Toggle("Launch at Login", isOn: $viewModel.userPreferences.startWithSystem)
                }

                Section("Audio") {
                    Picker("Microphone", selection: $audioSettings.inputDevice) {
                        Text("System Default").tag("Default")
                        ForEach(inputDevices) { d in Text(d.name).tag(d.uid) }
                    }
                    LabeledContent("Mic Level") {
                        MicLevelMeterView(level: audioMonitor.micLevel)
                            .frame(width: 200, height: 10)
                    }
                    Picker("Output Device", selection: $audioSettings.outputDevice) {
                        Text("System Default").tag("Default")
                        ForEach(outputDevices) { d in Text(d.name).tag(d.uid) }
                    }
                    LabeledContent("Test Output") {
                        Button(audioMonitor.isPlayingTest ? "Playing…" : "Play Test Tone") {
                            audioMonitor.playTestTone()
                        }
                        .disabled(audioMonitor.isPlayingTest)
                    }
                    LabeledContent("Input Volume") {
                        HStack(spacing: 8) {
                            Slider(value: $audioSettings.inputVolume, in: 0...1).frame(width: 160)
                            Text("\(Int(audioSettings.inputVolume * 100))%")
                                .foregroundColor(.secondary).monospacedDigit().frame(width: 38, alignment: .trailing)
                        }
                    }
                    LabeledContent("Output Volume") {
                        HStack(spacing: 8) {
                            Slider(value: $audioSettings.outputVolume, in: 0...1).frame(width: 160)
                            Text("\(Int(audioSettings.outputVolume * 100))%")
                                .foregroundColor(.secondary).monospacedDigit().frame(width: 38, alignment: .trailing)
                        }
                    }
                    Toggle("Echo Cancellation", isOn: $audioSettings.enableEchoCancellation)
                    Toggle("Noise Suppression", isOn: $audioSettings.enableNoiseSuppression)
                    Toggle("Automatic Gain Control", isOn: $audioSettings.enableAutomaticGainControl)
                    LabeledContent("Outgoing Quality") {
                        Picker("", selection: $audioSettings.quality) {
                            ForEach(AudioQuality.allCases) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Mumble Protocol", value: "1.4.287")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    viewModel.updateAudioSettings(audioSettings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460)
        .navigationTitle("Settings")
        .onAppear {
            audioSettings  = viewModel.userPreferences.audioSettings
            inputDevices   = listAudioDevices(input: true)
            outputDevices  = listAudioDevices(input: false)
            audioMonitor.startMonitoring()
        }
        .onDisappear {
            audioMonitor.stopMonitoring()
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(MumbleViewModel())
}

// MARK: - Mic Level Meter

struct MicLevelMeterView: View {
    let level: Float   // 0...1

    private var meterColor: Color {
        switch level {
        case ..<0.60: return .green
        case ..<0.85: return .yellow
        default:      return .red
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(meterColor)
                    .frame(width: max(geo.size.width * CGFloat(level), 0))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }
}

// MARK: - Audio Monitor

class AudioMonitor: ObservableObject {
    @Published var micLevel: Float = 0.0
    @Published var isPlayingTest: Bool = false

    private var monitorEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var isMonitoring = false

    // MARK: Microphone Level

    func startMonitoring() {
        guard !isMonitoring else { return }
        let engine = AVAudioEngine()
        monitorEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let rms = AudioMonitor.rms(buffer: buffer)
            DispatchQueue.main.async { self?.micLevel = rms }
        }
        do {
            try engine.start()
            isMonitoring = true
        } catch {
            inputNode.removeTap(onBus: 0)
            monitorEngine = nil
        }
    }

    func stopMonitoring() {
        monitorEngine?.inputNode.removeTap(onBus: 0)
        monitorEngine?.stop()
        monitorEngine = nil
        isMonitoring = false
        micLevel = 0
    }

    private static func rms(buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        let ptr = data[0]
        var sum: Float = 0
        for i in 0..<n { sum += ptr[i] * ptr[i] }
        // Scale: quiet speech sits around 0.03–0.10 RMS; map to useful 0…1 range
        return min(sqrt(sum / Float(n)) * 10, 1.0)
    }

    // MARK: Output Test Tone

    func playTestTone() {
        guard !isPlayingTest else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let sampleRate = 44100.0
        let duration   = 0.8
        let frequency  = 440.0
        let numSamples = Int(sampleRate * duration)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples))
        else { return }

        buffer.frameLength = AVAudioFrameCount(numSamples)
        let fadeIn  = Int(sampleRate * 0.02)
        let fadeOut = Int(sampleRate * 0.08)
        for i in 0..<numSamples {
            let env: Double
            if i < fadeIn {
                env = Double(i) / Double(fadeIn)
            } else if i > numSamples - fadeOut {
                env = Double(numSamples - i) / Double(fadeOut)
            } else {
                env = 1.0
            }
            let v = Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate) * env * 0.45)
            buffer.floatChannelData?[0][i] = v
            buffer.floatChannelData?[1][i] = v
        }

        engine.connect(player, to: engine.mainMixerNode, format: format)

        isPlayingTest = true
        playbackEngine = engine

        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                self?.isPlayingTest = false
                self?.playbackEngine?.stop()
                self?.playbackEngine = nil
            }
        }

        do {
            try engine.start()
            player.play()
        } catch {
            isPlayingTest = false
            playbackEngine = nil
        }
    }
}