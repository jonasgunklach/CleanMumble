//
//  AboutView.swift
//  CleanMumble
//
//  Created by Jonas Gunklach on 24.09.25.
//

import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 30) {
            // App Icon
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 100))
                .foregroundColor(.accentColor)
            
            VStack(spacing: 8) {
                Text("CleanMumble")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Version 1.0.0")
                    .font(.title2)
                    .foregroundColor(.secondary)
                
                Text("A beautiful, modern Mumble client for Apple platforms")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 16) {
                Text("Built with ❤️ using SwiftUI")
                    .font(.headline)
                
                Text("CleanMumble is a modern, Apple-style client for the Mumble voice chat protocol. It features a beautiful interface that follows Apple's Human Interface Guidelines and supports automatic dark mode.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            VStack(spacing: 12) {
                Link(destination: URL(string: "https://mumble.info")!) {
                    Label("Visit Mumble Website", systemImage: "globe")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                }
                
                Link(destination: URL(string: "https://github.com/mumble-voip")!) {
                    Label("Mumble on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                }
                
                Link(destination: URL(string: "https://github.com/mumble-voip/mumble")!) {
                    Label("Open Source License", systemImage: "doc.text")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                }
            }
            
            Spacer()
            
            Text("© 2025 CleanMumble. Built on the open-source Mumble protocol.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .navigationTitle("About")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}
