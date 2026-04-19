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
                // Input volume
                HStack {
                    Image(systemName: "mic")
                        .foregroundColor(.secondary)
                        .frame(width: 20)
                    
                    Slider(value: $viewModel.inputVolume, in: 0...1)
                        .accentColor(.blue)
                    
                    Text("\(Int(viewModel.inputVolume * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 35, alignment: .trailing)
                }
                
                // Output volume
                HStack {
                    Image(systemName: "speaker.2")
                        .foregroundColor(.secondary)
                        .frame(width: 20)
                    
                    Slider(value: $viewModel.outputVolume, in: 0...1)
                        .accentColor(.green)
                    
                    Text("\(Int(viewModel.outputVolume * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 35, alignment: .trailing)
                }
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



