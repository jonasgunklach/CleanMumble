//
//  AudioViews.swift
//  CleanMumble
//
//  Created by Jonas Gunklach on 24.09.25.
//

import SwiftUI

struct AudioControlsView: View {
    @EnvironmentObject var viewModel: MumbleViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            // Main audio controls
            HStack(spacing: 20) {
                // Mute button
                Button(action: { viewModel.toggleMute() }) {
                    Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.title2)
                        .foregroundColor(viewModel.isMuted ? .red : .primary)
                        .frame(width: 44, height: 44)
                        .background(viewModel.isMuted ? Color.red.opacity(0.2) : Color.secondary.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                
                // Deafen button
                Button(action: { viewModel.toggleDeafen() }) {
                    Image(systemName: viewModel.isDeafened ? "speaker.slash.fill" : "speaker.2.fill")
                        .font(.title2)
                        .foregroundColor(viewModel.isDeafened ? .orange : .primary)
                        .frame(width: 44, height: 44)
                        .background(viewModel.isDeafened ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
                
                // Disconnect button
                Button(action: { viewModel.disconnect() }) {
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                        .foregroundColor(.red)
                        .frame(width: 44, height: 44)
                        .background(Color.red.opacity(0.2))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal)
            
            // Volume controls
            VStack(spacing: 12) {
                // Input volume + live mic level meter
                HStack {
                    Image(systemName: "mic")
                        .foregroundColor(.secondary)
                        .frame(width: 20)

                    Slider(
                        value: Binding(
                            get: { viewModel.inputVolume },
                            set: { viewModel.setInputVolume($0) }
                        ),
                        in: 0...4
                    )
                    .accentColor(.blue)

                    Text("\(Int(viewModel.inputVolume * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 45, alignment: .trailing)
                }
                LevelMeterBar(rms: viewModel.micLevelRMS,
                              peak: viewModel.micLevelPeak,
                              tint: .blue)
                    .frame(height: 6)
                    .padding(.leading, 28)

                // Output volume + live playback level meter
                HStack {
                    Image(systemName: "speaker.2")
                        .foregroundColor(.secondary)
                        .frame(width: 20)

                    Slider(
                        value: Binding(
                            get: { viewModel.outputVolume },
                            set: { viewModel.setOutputVolume($0) }
                        ),
                        in: 0...1
                    )
                        .accentColor(.green)

                    Text("\(Int(viewModel.outputVolume * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 45, alignment: .trailing)
                }
                LevelMeterBar(rms: viewModel.outputLevelRMS,
                              peak: viewModel.outputLevelPeak,
                              tint: .green)
                    .frame(height: 6)
                    .padding(.leading, 28)
            }
            .padding(.horizontal)
            
            // Speaking indicator
            if viewModel.isSpeaking {
                HStack {
                    Image(systemName: "waveform")
                        .foregroundColor(.green)
                    Text("Speaking...")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct VoiceActivityIndicator: View {
    @EnvironmentObject var viewModel: MumbleViewModel
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.green)
                    .frame(width: 4, height: CGFloat.random(in: 4...16))
                    .animation(
                        Animation.easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                        value: isAnimating
                    )
            }
        }
        .onAppear {
            if viewModel.isSpeaking {
                isAnimating = true
            }
        }
        .onChange(of: viewModel.isSpeaking) { speaking in
            isAnimating = speaking
        }
    }
}

struct AudioVisualizer: View {
    let isActive: Bool
    @State private var animationPhase: CGFloat = 0
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: heightForBar(index: index))
                    .animation(
                        Animation.easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.1),
                        value: animationPhase
                    )
            }
        }
        .onAppear {
            if isActive {
                animationPhase = 1
            }
        }
        .onChange(of: isActive) { active in
            animationPhase = active ? 1 : 0
        }
    }
    
    private func heightForBar(index: Int) -> CGFloat {
        if !isActive { return 4 }
        
        let baseHeight: CGFloat = 4
        let maxHeight: CGFloat = 20
        let phase = animationPhase + Double(index) * 0.2
        
        return baseHeight + (maxHeight - baseHeight) * abs(sin(phase * .pi))
    }
}

/// Horizontal VU-style level meter. Maps RMS \u2192 a green/yellow/red filled bar
/// (log-mapped so quiet signals are visible), with a thin held-peak tick.
/// Inputs are linear amplitude in [0, 1].
struct LevelMeterBar: View {
    let rms: Float
    let peak: Float
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let rmsW = CGFloat(scaled(rms)) * w
            let peakX = CGFloat(scaled(peak)) * w
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(barColor)
                    .frame(width: max(2, rmsW))
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: geo.size.height)
                    .offset(x: max(0, peakX - 1))
                    .opacity(peak > 0.001 ? 0.85 : 0)
            }
            .clipShape(Capsule())
        }
    }

    private var barColor: Color {
        switch peak {
        case ..<0.5:  return tint
        case 0.5..<0.85: return .yellow
        default: return .red
        }
    }

    /// Map linear amplitude to a perceptually flatter [0, 1] for the bar.
    /// Floor at -60 dBFS.
    private func scaled(_ x: Float) -> Float {
        guard x > 1e-5 else { return 0 }
        let db = 20 * log10f(x)
        let n = (db + 60) / 60      // -60 dB \u2192 0,  0 dB \u2192 1
        return max(0, min(1, n))
    }
}

