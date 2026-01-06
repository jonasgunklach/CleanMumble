//
//  CleanMumbleApp.swift
//  CleanMumble
//
//  Created by Jonas Gunklach on 24.09.25.
//

import SwiftUI

@main
struct CleanMumbleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .windowResizability(.contentSize)
        
        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(MumbleViewModel())
        }
        #endif
    }
}
