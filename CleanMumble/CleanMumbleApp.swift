//
//  CleanMumbleApp.swift
//  CleanMumble
//
//  Created by Jonas Gunklach on 24.09.25.
//

import SwiftUI
import AVFoundation

@main
struct CleanMumbleApp: App {

    init() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
        #else
        WindowGroup {
            ContentView()
        }
        #endif


        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(MumbleViewModel())
        }
        #endif
    }
}
