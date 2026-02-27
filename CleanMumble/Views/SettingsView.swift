//
//  SettingsView.swift
//  CleanMumble
//
//  Created by Jonas Gunklach on 24.09.25.
//

import SwiftUI
import CoreAudio

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: MumbleViewModel
    @State private var audioSettings  = AudioSettings()
    @State private var inputDevices:  [AudioDeviceInfo] = []
    @State private var outputDevices: [AudioDeviceInfo] = []
    
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
                    Picker("Output Device", selection: $audioSettings.outputDevice) {
                        Text("System Default").tag("Default")
                        ForEach(outputDevices) { d in Text(d.name).tag(d.uid) }
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
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(MumbleViewModel())
}