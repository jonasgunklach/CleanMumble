//
//  EngineController.swift
//  AudioEngine
//
//  The one owner of audio lifecycle. All transitions run on a private serial
//  queue; UI, network and HAL listeners only post events. Generations replace
//  the old wall-clock suppression windows: every (re)build increments the
//  generation, and anything spawned under an older generation is ignored —
//  no legitimate event can be swallowed, no storm can loop.
//
//      idle ── start ─► starting ──ok──► running
//        ▲                 │fail            │ invalidation
//        └── stop ◄────────┴─────────► recovering (backoff 0.1→0.4→1.6→3 s)
//                                           │ 6 consecutive failures
//                                           ▼
//                                       degraded (retry on next event)
//

#if os(macOS)

import Foundation
import Synchronization

public final class EngineController: @unchecked Sendable {

    // ---- Data plane (stable identity across rebuilds) -----------------------
    public let capture = CaptureEngine()
    public let playback = PlaybackEngine()

    // ---- Observability -------------------------------------------------------
    /// Delivered on the main queue.
    public var onStateChange: ((EngineState) -> Void)?
    /// Route info for the UI (badge, device names). Main queue.
    public var onRouteChange: ((ResolvedRoute?) -> Void)?

    public private(set) var state: EngineState = .idle {
        didSet {
            guard state != oldValue else { return }
            let s = state
            DispatchQueue.main.async { [onStateChange] in onStateChange?(s) }
        }
    }
    public private(set) var currentRoute: ResolvedRoute? {
        didSet {
            let r = currentRoute
            DispatchQueue.main.async { [onRouteChange] in onRouteChange?(r) }
        }
    }

    // ---- Internals -----------------------------------------------------------
    private let queue = DispatchQueue(label: "audio.engine.control", qos: .userInitiated)
    private var deviceManager: DeviceManager?
    private var backend: IOBackend?
    private var config = AudioConfig()
    private var desiredRunning = false
    private var generation = 0
    private var consecutiveFailures = 0
    private var rebuildPending = false
    private var watchdog: DispatchSourceTimer?
    private var lastIngestBeat = 0
    private var lastRenderBeat = 0
    private var stalledSamples = 0
    /// Stall-fallback tier: consecutive builds that reached `.running` but
    /// never streamed. After 2, the route is demoted to the raw backend
    /// until the config or the physical route actually changes.
    private var stallStrikes = 0
    private var forceRawFallback = false

    private let backoffLadder: [Double] = [0.1, 0.4, 1.6, 3.0]

    public init() {}

    // MARK: - Public API (any thread)

    public func start(config: AudioConfig) {
        queue.async {
            self.config = config
            self.desiredRunning = true
            self.consecutiveFailures = 0
            self.stallStrikes = 0
            self.forceRawFallback = false
            self.rebuild(reason: "start")
        }
    }

    public func stop() {
        queue.async {
            self.desiredRunning = false
            self.generation += 1
            self.teardown()
            self.state = .idle
            self.currentRoute = nil
        }
    }

    /// Diff desired vs current; rebuild only when a rebuild-class field changed.
    public func apply(config newConfig: AudioConfig) {
        queue.async {
            let changed = newConfig != self.config
            self.config = newConfig
            guard self.desiredRunning, changed else { return }
            self.consecutiveFailures = 0
            self.stallStrikes = 0
            self.forceRawFallback = false
            self.rebuild(reason: InvalidationReason.configChanged.rawValue)
        }
    }

    // MARK: - Event intake (control queue)

    private func invalidated(_ reason: InvalidationReason) {
        guard desiredRunning else { return }
        switch reason {
        // Selection-aware filtering: a default-device change only matters if
        // we're following the default on that side.
        case .defaultInputChanged where config.input != .systemDefault: return
        case .defaultOutputChanged where config.output != .systemDefault: return

        // Route-diff filtering: device events that don't change what we'd
        // actually open are ignored. Crucially, VPIO CREATES an aggregate
        // device on every start — without this check its own
        // `deviceListChanged` echo re-triggers a rebuild, which interrupts
        // the Bluetooth negotiation, which stalls the stream, forever.
        case .defaultInputChanged, .defaultOutputChanged, .deviceListChanged:
            if routeIsUnchanged() { return }
            // The physical route really changed — the stall-fallback state
            // belongs to the old route.
            stallStrikes = 0
            forceRawFallback = false

        case .ioStalled:
            // Repeated "running but silent" on the voice backend → demote to
            // raw AUHAL until the route or config changes. Two strikes: one
            // stall can be a transient BT hiccup.
            stallStrikes += 1
            if stallStrikes >= 2, currentRoute?.backend == .voice, !forceRawFallback {
                forceRawFallback = true
            }

        case .coreAudioServiceRestarted, .startFailed, .configChanged:
            break
        }
        // Coalesce bursts (BT renegotiation fires several events) into one
        // rebuild via a dirty flag — a flag can't lose events the way the old
        // suppression window could.
        guard !rebuildPending else { return }
        rebuildPending = true
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.rebuildPending else { return }
            self.rebuildPending = false
            self.consecutiveFailures = 0
            self.rebuild(reason: reason.rawValue)
        }
    }

    /// True when re-resolving the config yields the same devices and backend
    /// we are already running on.
    private func routeIsUnchanged() -> Bool {
        guard let current = currentRoute,
              let candidate = try? RoutePolicy.resolve(config: config,
                                                       forceRaw: forceRawFallback)
        else { return false }
        return candidate.inputID == current.inputID
            && candidate.outputID == current.outputID
            && candidate.backend == current.backend
    }

    // MARK: - Build / teardown (control queue)

    private func rebuild(reason: String) {
        guard desiredRunning else { return }
        generation += 1
        let gen = generation
        state = (consecutiveFailures == 0) ? .starting : .recovering(reason: reason)
        let hadBackend = backend != nil
        teardown()

        // Listeners live exactly as long as the controller wants them.
        if deviceManager == nil {
            let dm = DeviceManager(queue: queue)
            dm.onInvalidated = { [weak self] r in self?.invalidated(r) }
            deviceManager = dm
        }

        // Settle delay after tearing down a live backend: Bluetooth (HFP)
        // needs a beat to release the device, otherwise the next start races
        // it (HAL error 35 / "there already is a thread").
        let settle: TimeInterval = hadBackend ? 0.25 : 0
        queue.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self, self.generation == gen, self.desiredRunning else { return }
            self.build(generation: gen)
        }
    }

    private func build(generation gen: Int) {
        do {
            let route = try RoutePolicy.resolve(config: config, forceRaw: forceRawFallback)
            let chosen: IOBackend = (route.backend == .voice) ? VoiceBackend() : RawBackend()
            do {
                try chosen.start(route: route, capture: capture,
                                 captureFormat: config.capture,
                                 playback: playback,
                                 agcEnabled: config.agcEnabled)
                backend = chosen
                currentRoute = route
            } catch where route.backend == .voice {
                // Voice processing refused this route (some BT stacks, exotic
                // devices): fall back to raw AUHAL rather than dying.
                let raw = RawBackend()
                let rawRoute = ResolvedRoute(inputID: route.inputID,
                                             outputID: route.outputID,
                                             inputInfo: route.inputInfo,
                                             outputInfo: route.outputInfo,
                                             backend: .raw,
                                             inputPinned: route.inputPinned,
                                             outputPinned: route.outputPinned)
                try raw.start(route: rawRoute, capture: capture,
                              captureFormat: config.capture,
                              playback: playback,
                              agcEnabled: config.agcEnabled)
                backend = raw
                currentRoute = rawRoute
            }

            playback.start()
            consecutiveFailures = 0
            state = .running
            startWatchdog(generation: gen)
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures > backoffLadder.count + 2 {
                state = .degraded(error: "\(error)")
                return   // retry on the next device event or apply()
            }
            let delay = backoffLadder[min(consecutiveFailures - 1, backoffLadder.count - 1)]
            state = .recovering(reason: "\(error)")
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.generation == gen, self.desiredRunning else { return }
                self.rebuild(reason: InvalidationReason.startFailed.rawValue)
            }
        }
    }

    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        backend?.stop()
        backend = nil
        capture.stop()
        playback.stop()
    }

    // MARK: - Watchdog (acts, doesn't log)

    private func startWatchdog(generation gen: Int) {
        lastIngestBeat = capture.ingestHeartbeat
        lastRenderBeat = playback.renderHeartbeat
        stalledSamples = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, self.generation == gen, self.state == .running else { return }
            let ingest = self.capture.ingestHeartbeat
            let render = self.playback.renderHeartbeat
            let stalled = (ingest == self.lastIngestBeat) || (render == self.lastRenderBeat)
            self.lastIngestBeat = ingest
            self.lastRenderBeat = render
            if stalled {
                self.stalledSamples += 1
                if self.stalledSamples >= 2 {
                    self.stalledSamples = 0
                    self.invalidated(.ioStalled)
                }
            } else {
                self.stalledSamples = 0
                // Audio actually flowing on this build → the route is
                // healthy; forget any accumulated stall strikes.
                self.stallStrikes = 0
            }
        }
        t.resume()
        watchdog = t
    }
}

#endif
