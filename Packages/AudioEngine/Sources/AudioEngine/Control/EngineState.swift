//
//  EngineState.swift
//  AudioEngine
//
//  Engine lifecycle state, shared by the macOS controller (full recovery
//  state machine) and the iOS controller (app-driven rebuilds via
//  AVAudioSession notifications).
//

public enum EngineState: Equatable, Sendable {
    case idle
    case starting
    case running
    case recovering(reason: String)
    case degraded(error: String)
}
