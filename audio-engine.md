# CleanMumble Audio Engine — Design Document

Status: **implemented** (`Packages/AudioEngine`, 2026-07) · Scope: macOS (iOS notes where relevant) · Replaced: `CoreAudioIO.swift`, `VPIOEngineInput.swift`, `JitterBuffer.swift`, `AudioDeviceTransport.swift`, the audio half of `RealMumbleClient.swift`, and the TCP-only voice path

> Implementation notes: all five migration phases (§12) landed in one pass.
> The package ships with 30 unit tests (SPSC ring torture, OCB2 round-trip /
> tamper / replay / IV-wraparound, jitter-buffer FEC/PLC/runaway-cap, capture
> VAD + SRC + mute-privacy, playback mix / deafen / per-sender gain / render
> safety). The §11.2 hardware matrix — AirPods studio-path verification in
> particular — still needs a human with the devices.

---

## 1. Why a redesign

The current stack is three half-architectures welded together — a raw AUHAL input, an
independent raw AUHAL output, and an AVAudioEngine/VPIO backend — coordinated by timing
heuristics (2.5 s suppression windows, 0.3 s debounces, retry loops, log-only watchdogs)
instead of an owned lifecycle. Every historical bug fix added another band-aid. The
observable symptoms all trace back to a small set of structural decisions:

| Symptom | Root cause in current code |
|---|---|
| AirPods sound bad while mic is open | VPIO is explicitly disabled on Bluetooth (`AudioDeviceTransport.recommendVoiceProcessing = false`), so the system never negotiates Apple's high-quality voice link; the headset collapses to 16 kHz HFP |
| Voice breaks up when a game / YouTube runs | Mic DSP + VAD + Opus encode run on **MainActor**; the render callback allocates a Swift `Array` per callback and hops through `Task {}` |
| Crackle / robotic audio after device or format changes | Restart-the-world recovery gated by wall-clock suppression windows; legitimate events inside the window are silently swallowed |
| Random dead audio after connect | "Started but no callbacks" watchdog only logs; two independent AUs race for the same Bluetooth device (`EAGAIN` retry loop) |
| Occasional stutter with several talkers | Push-model jitter buffer on a 10 ms GCD wall-clock timer, drifting against the device clock; hacks (`maxConsecutivePLC`, 200 ms ring caps) mask it |
| Audio dies on flaky Wi-Fi | Voice is tunneled over **TCP** — one lost segment stalls every audio packet behind it for ≥ 1 RTT (head-of-line blocking) |

The redesign is one engine, one owner, one state machine, two strictly separated planes
(control vs. realtime data), and native UDP transport.

---

## 2. Goals and non-goals

### Goals (each is an acceptance criterion, not a vibe)

1. **Device universality.** Built-in, USB, Bluetooth Classic, AirPods (H1/H2), LE Audio,
   aggregate, virtual devices — all work with the *same* code path and policy table.
2. **Live switching.** Any device switch (user-initiated or system default change) while
   connected to a server resumes audio in **< 500 ms**, without dropping the server
   connection, without a stuck state, ever.
3. **Coexistence.** Another app starting (game, browser video) that changes the device
   sample rate, grabs exclusive hog mode, or saturates the CPU must never crash, deadlock,
   or permanently silence us. Worst case: one clean < 500 ms rebuild.
4. **AirPods first-class.** On H2 AirPods (Pro 2 / 4) + macOS Tahoe 26, the mic runs the
   48 kHz studio-quality path and output stays music-grade while the mic is open. On
   older AirPods/macOS we degrade predictably and *tell the user* via the quality badge.
5. **Crisp mic.** Voice-processed capture (AEC + NS + AGC) by default, pro-audio raw mode
   as an explicit opt-in. No processing done twice.
6. **Volume everywhere.** Mic gain, per-remote-user volume, master output volume — all
   adjustable live from any thread, click-free (ramped), no engine restart.
7. **Realtime-safe by construction.** Zero allocations, locks, or runtime calls on the
   audio render thread. Enforced by a rule checklist (§9) and a debug-build assertion
   harness, not by hope.
8. **Network resilience.** Native encrypted UDP with automatic TCP fallback; loss/jitter
   feedback drives Opus FEC/bitrate; mouth-to-ear latency ≤ 150 ms P50 on LAN.

### Non-goals

- Spatial/positional audio, stereo capture, music streaming (design leaves room, no code).
- Windows/Linux portability. AudioCore (DSP) stays platform-neutral; the IO layer is
  deliberately Apple-native.
- Replacing Opus or the Mumble protocol.

---

## 3. Platform ground truth

Everything below is what the design leans on. Items marked **[VERIFY]** are believed
correct from platform experience but are not documented by Apple and must be confirmed on
hardware before being load-bearing (test plan §11 covers them).

### 3.1 Bluetooth audio on macOS

- Classic Bluetooth has two mutually exclusive modes: **A2DP** (output-only, AAC/SBC,
  music quality) and **HFP** (duplex, 8 kHz CVSD or 16 kHz mSBC). Opening the mic on a
  generic BT headset forces HFP → *both* directions drop to ≤ 16 kHz. This is physics of
  the protocol, not a bug; the only mitigations are (a) Apple's proprietary path below,
  (b) LE Audio, or (c) using a different mic than the headset.
- **Apple high-bandwidth voice path (verified 2026-07):** with **iOS 26 / macOS
  Tahoe 26** plus a 2025 firmware update, H2-chip AirPods (AirPods Pro 2, AirPods 4)
  gained **"studio-quality" recording — a 48 kHz mic path that uses the full Bluetooth
  bandwidth instead of collapsing to HFP**, plus "improved call quality" explicitly
  scoped to FaceTime, CallKit apps, and video-conferencing apps
  ([Apple newsroom](https://www.apple.com/newsroom/2025/06/airpods-now-more-versatile-with-studio-quality-audio-recording-and-camera-remote/),
  [SoundGuys measurement — clips now 48 kHz, previously 24 kHz](https://www.soundguys.com/airpods-studio-quality-microphone-recording-139454/),
  [MacRumors firmware note](https://www.macrumors.com/2025/09/15/apple-releases-new-airpods-firmware-ios-26/)).
  On **older macOS (≤ 15)** the community record is unambiguous: opening the AirPods mic
  drops the whole headset to the low-quality call link even on AirPods Pro 2
  ([Apple Communities](https://discussions.apple.com/thread/253692683),
  [MacRumors thread](https://forums.macrumors.com/threads/airpods-pro-2-mic-quality-very-bad.2363763/)).
  Consequence for the design: goal 4 is fully achievable on macOS 26 + H2; on older
  OS/hardware we degrade predictably and say so in the UI badge.
  **[VERIFY]** whether the macOS 26 studio path engages for any app that opens the
  AirPods mic or is gated to voice-processing (VPIO) clients — the "call quality"
  half of Apple's announcement names call frameworks, so VPIO is the safe bet and the
  right default anyway (AEC). Either way, today's
  `recommendVoiceProcessing = false` for Bluetooth actively prevents the best path and
  remains the single most damaging line in the codebase.
- On macOS, AirPods expose a 2-ch output-only device and a 1-ch input-only device (split
  HAL devices), and mismatched aggregate pairings (AirPods mic + MacBook speakers) are a
  known AVAudioEngine failure mode
  ([supermegaultragroovy: AVAudioEngine + AirPods](https://supermegaultragroovy.com/2021/01/28/more-on-avaudioengine-airpods/)) —
  RoutePolicy must warn on cross-device input/output pairs (§5.3).
- Raw `kAudioUnitSubType_VoiceProcessingIO` over AUHAL fails against the split AirPods
  devices (observed `-10875`); `AVAudioEngine.inputNode.setVoiceProcessingEnabled(true)`
  performs the aggregate-device + link-mode dance internally and is the only reliable
  entry point. It is **synchronous and reconfigures the graph** — node formats must be
  re-queried *after* the call, never cached across it. (The existing
  `VPIOEngineInput.swift` already discovered the two hard parts: pin *both* nodes'
  `AUAudioUnit.deviceID`, and connect mainMixer→output at the output node's negotiated
  duplex format to avoid `-10875`.)
- **LE Audio / LC3** presents as `kAudioDeviceTransportTypeBluetoothLE`. Treat identically
  to Classic in policy (voice backend), let the OS pick the link codec. **[VERIFY]** actual
  behavior on macOS 15+.

### 3.2 Voice processing (VPIO)

- `setVoiceProcessingEnabled(true)` on `AVAudioEngine.inputNode` gives AEC + NS + AGC and
  turns the engine's I/O into one duplex unit — input and output share a clock, which is
  also what makes echo cancellation possible at all.
- **Ducking (verified against Apple docs):** by default VPIO *ducks other apps' audio*
  while the voice client runs — for a gaming/hangout client this is hostile; the user's
  game or YouTube gets crushed. macOS 14+ exposes
  [`AVAudioVoiceProcessingOtherAudioDuckingConfiguration`](https://developer.apple.com/documentation/avfaudio/avaudioinputnode/voiceprocessingotheraudioduckingconfiguration);
  `duckingLevel = .min` "minimizes the amount of ducking… other audio as loud as
  possible" ([duckingLevel docs](https://developer.apple.com/documentation/avfaudio/avaudiovoiceprocessingotheraudioduckingconfiguration/duckinglevel),
  [WWDC23 "What's new in voice processing"](https://developer.apple.com/videos/play/wwdc2023/10235/)).
  We set `enableAdvancedDucking = false, duckingLevel = .min`. This directly addresses
  "YT/League sounds weird when I'm connected".
- VPIO exposes AGC toggle (`kAUVoiceIOProperty_VoiceProcessingEnableAGC`), bypass, and
  muted-speech-activity events (`AUVoiceIOMutedSpeechActivityEvent` — "you're talking
  while muted" UI for free). Sub-properties must be set **after** the AU is initialized.
- VPIO output ducks/filters non-voice content on the *voice* stream slightly; for a voice
  chat this is fine and what every competitor ships (Discord/Zoom/Teams/FaceTime all ride
  VPIO on macOS).

### 3.3 CoreAudio lifecycle facts

- Never set device-global properties (nominal sample rate, hog mode). Other apps' changes
  arrive as notifications; fighting back causes oscillation. Always accept the hardware
  format and SRC in-process.
- `kAudioHardwarePropertyServiceRestarted` fires when **coreaudiod itself crashes or
  restarts** (it happens — GPU driver installs, `sudo killall coreaudiod`). Every AU
  handle is garbage afterwards. The current code doesn't listen for this at all; the new
  engine must treat it as a full rebuild trigger.
- `kAudioDevicePropertyDeviceIsAlive` → device unplugged mid-stream.
  `kAudioDeviceProcessorOverload` → we (or the system) missed a deadline; count it,
  surface it in diagnostics.
- `AVAudioEngineConfigurationChange` notification is the engine-level coalescing of most
  raw HAL noise (format changes, route changes). Prefer it over hand-rolled
  property-listener debouncing; keep raw HAL listeners only for what it doesn't cover
  (default-device change when we're pinned, service restart, device-alive).

### 3.4 Realtime scheduling

- The render callback runs on a realtime workgroup thread with a hard deadline. Rules in §9.
- Auxiliary DSP threads (encode, decode-ahead) should join the device's **os_workgroup**
  (`AVAudioEngine` exposes it via the output node's AU) so the scheduler treats them as
  part of the audio deadline chain, instead of best-effort QoS that a game can starve.

---

## 4. Architecture overview

Two planes with a hard boundary:

- **Control plane** — one actor, owns all lifecycle. Slow, careful, serialized. Talks to
  CoreAudio configuration APIs, builds/tears down graphs, holds the state machine.
- **Data plane** — realtime callbacks + two dedicated worker threads (capture-encode,
  network-decode). Lock-free rings and atomics only. Never blocks, never allocates,
  never talks to the control plane except through SPSC queues and atomics.

```
CONTROL PLANE (EngineController actor, serial)
┌─────────────────────────────────────────────────────────────────────┐
│  DeviceManager ── RoutePolicy ── StateMachine(gen N) ── Diagnostics │
└──────────────┬──────────────────────────────────────────────────────┘
               │ builds / tears down (generation-stamped)
               ▼
DATA PLANE (per generation)
  mic ─► VPIO(AEC/NS/AGC) ─► [tap] ─► SPSC ring ─► CaptureWorker thread
                                                      │ HPF → limiter → VAD
                                                      │ → framer(20ms) → Opus enc
                                                      ▼
                                              PacketQueue ─► Network TX (UDP)
  Network RX (UDP) ─► per-sender NetJitterBuffer (decode-ahead worker)
                                                      │ pull-model PCM
                                                      ▼
  render callback ◄─ Mixer ◄─ per-sender ring + gain(ramped) ◄──┘
        │  master gain → soft limiter → device
        ▼
  speaker (same duplex VPIO unit — AEC reference comes for free)
```

**Clock domains.** There are exactly three: (1) the device clock (render callbacks),
(2) each remote sender's clock (packet timestamps), (3) wall clock (control plane only).
Rule: *PCM never crosses a clock boundary except through a jitter buffer or a ring with
explicit drift policy.* The wall clock never paces audio.

---

## 5. Control plane

### 5.1 State machine

```
idle ── start() ──► starting ──ok──► running
  ▲                    │fail             │ invalidation event
  │                    ▼                 ▼
  └── stop() ◄── stopping ◄──────── recovering (backoff: 0.1s→0.4s→1.6s→3s cap)
                                         │ after N=6 consecutive failures
                                         ▼
                                    degraded(error surfaced to UI, retry on
                                             next device event or user action)
```

- All transitions run on the `EngineController` actor. UI, network thread, and HAL
  listeners *post events*; they never mutate engine state directly.
- **Generations replace suppression windows.** Every `starting` increments an atomic
  generation counter. Every callback, listener registration, worker thread, and async
  completion captures the generation it was created under and is ignored if
  `gen != current`. This kills the whole class of "notification storm → restart loop" and
  "event inside the suppression window → swallowed" bugs with zero timing sensitivity.
  A tiny debounce (~100 ms) remains only to coalesce bursts into one rebuild — it can no
  longer *lose* events, because the trigger is a dirty-flag, not the event itself.
- **Config as data.** The desired state is a value struct:

  ```swift
  struct AudioConfig: Equatable {
      var inputSelection:  DeviceSelection   // .systemDefault | .pinned(uid)
      var outputSelection: DeviceSelection
      var processingMode:  ProcessingMode    // .voice | .raw   (.voice is default)
      var agcEnabled: Bool
      var muted: Bool, deafened: Bool
  }
  ```

  `apply(config:)` diffs desired vs. *actual* (queried, not remembered) and rebuilds only
  if a rebuild-class field changed. Gains/mute are not rebuild-class — they apply live.

### 5.2 DeviceManager

- Single source of truth for device enumeration, UIDs, transport types, and the
  listener zoo. Registers **once** for: default input/output changed, device list
  changed, `ServiceRestarted`; per-active-device: `DeviceIsAlive`, stream format,
  `ProcessorOverload` (count only).
- Listener tokens are held in a registration object whose `deinit` unregisters —
  the current leak (listeners re-registered on every failed start, never removed on
  failure paths) becomes structurally impossible.
- Emits one event type to the controller: `.devicesInvalidated(reason)`. The controller
  decides what to do; listeners never restart anything themselves.

### 5.3 RoutePolicy

Pure function `(AudioConfig, [Device]) → ResolvedRoute`. Encodes:

| Situation | Resolution |
|---|---|
| Pinned device present | use it |
| Pinned device missing (unplugged) | fall back to system default, remember the pin, auto-return when it reappears |
| `.systemDefault` | resolve now; a default-change event re-resolves |
| Input is Bluetooth, output is different device | allowed, but warn in UI: AEC quality degrades and AirPods high-quality link won't engage (needs both directions) **[VERIFY]** |
| Transport ∈ {builtIn, bluetooth, bluetoothLE, usb-headset} and mode `.voice` | VoiceBackend (VPIO) |
| Transport ∈ {aggregate, virtual} or mode `.raw` | RawBackend (AUHAL, no processing, software SRC) |

Note the reversal from today: **Bluetooth gets the voice backend.** The existing
`AudioDeviceTransportInfo` quality-badge logic survives as the UI layer of RoutePolicy.

### 5.4 Backends

One protocol, two implementations:

```swift
protocol IOBackend: AnyObject {
    func start(route: ResolvedRoute, gen: Generation,
               capture: CaptureBridge,      // owns the mic-side SPSC ring
               playback: PlaybackSource) throws  // pull-model PCM provider
    func stop()
    var negotiatedInputFormat: AudioFormat { get }
}
```

- **VoiceBackend** (default): `AVAudioEngine`, `setVoiceProcessingEnabled(true)`,
  both nodes pinned via `AUAudioUnit.deviceID`, mixer connected at the negotiated duplex
  format, ducking configured to `.min`, sub-properties applied post-init. Playback is an
  `AVAudioSourceNode` that *pulls* from the Mixer (§7). This is `VPIOEngineInput` grown
  up: same discoveries, but owning both directions and pull-based playback.
- **RawBackend** (studio mode): today's AUHAL pair, kept *only* for pro interfaces —
  no VPIO, no AEC (headphones assumed), software SRC at device-native rate. Its
  format-negotiation code (accept native rate, mono Float32, resample in-process) is
  already correct in `CoreAudioIO.swift` and ports over nearly verbatim.
- Backends are dumb. They do not listen for anything, retry anything, or restart
  anything. All of that lives in the controller. (`start` may retry `EAGAIN` a few times
  internally since it's a start-time race, not a policy decision.)

### 5.5 Recovery matrix

| Event | Source | Response (controller) |
|---|---|---|
| Default in/out device changed | HAL listener | if selection is `.systemDefault`: rebuild; else ignore |
| Pinned device disappeared | DeviceIsAlive / list change | rebuild via RoutePolicy fallback; toast in UI |
| Pinned device reappeared | device list change | rebuild back to pin |
| Stream format changed (game forces 44.1 kHz) | `AVAudioEngineConfigurationChange` / HAL | rebuild (same device, renegotiate formats) |
| coreaudiod restarted | `ServiceRestarted` | full rebuild, fresh device enumeration |
| Engine stopped delivering (watchdog, §8.3) | frame-flow counter | rebuild; if repeated ×3, next RoutePolicy fallback tier |
| Start failure | backend throw | backoff ladder → `degraded` |
| BT link renegotiation burst | multiple of the above | dirty-flag coalescing → exactly one rebuild |
| App nap / sleep-wake | NSWorkspace notifications | proactive stop on sleep, rebuild on wake |

Every rebuild preserves: server connection, mute/deafen state, all gains, jitter-buffer
contents (they just pause draining — generation-stamped pulls resume against the new
device clock).

---

## 6. Capture pipeline (data plane)

```
VPIO tap (device thread, negotiated fmt)
  │  memcpy only → SPSC ring A (float, ~200 ms capacity)
  ▼
CaptureWorker (dedicated thread, joined to audio os_workgroup)
  │  1. SRC to 48 kHz mono if needed (AudioConverter, preallocated)
  │  2. HPF 80 Hz (BiquadFilter — reuse AudioCore)
  │  3. input gain (RampedGain, atomic target)          } order matters:
  │  4. soft limiter −1 dBFS (SoftLimiter — reuse)      } gain before limiter
  │  5. LevelMeter (atomics → UI polls)
  │  6. framer: fixed 960-sample (20 ms) frames
  │  7. VAD gate + 300 ms hangover  (+ PTT override)
  │  8. Opus encode (voip, VBR, FEC on, loss% ← network feedback)
  ▼
PacketQueue (SPSC) ─► network TX thread
```

Rules realized here:

- **The tap does one thing: memcpy into ring A.** Everything else happens on
  CaptureWorker. No `[Float]` allocation, no `Task {}`, no MainActor — the entire current
  `io.input.onSamples` closure body is deleted.
- CaptureWorker is a plain `Thread` (not GCD) with a fixed preallocated arena, parked on
  a `os_unfair_lock`-free semaphore signaled by the tap (or ring occupancy polling at
  10 ms — measured choice). It joins the device workgroup so game load can't starve it.
- When VPIO is active, **no software NS/AGC** (that's VPIO's job — running both fights
  Apple's tuning, today's code already knows this). In `.raw` mode the same worker slots
  in nothing extra by default; a future RNNoise stage has a marked insertion point.
- **Mute** gates at step 7 (send terminator, keep engine hot — instant unmute, and VPIO
  can report "talking while muted"). **Deafen** additionally zeroes playback pull.
- VAD stays RMS-threshold initially (it works), but moves *behind* the limiter, so the
  threshold means the same thing at every input gain; the Opus-side `setDTX` stays off
  (one gate, one owner).

## 7. Playback pipeline (data plane)

**Pull model — the device clock is the only pacemaker.**

```
render callback (device thread), N frames requested:
  for each active sender (lock-free snapshot, max K=32):
      ring.read(N)  ── underrun? JB notes it, returns silence-padded tail
      × senderGain (RampedGain)
      Σ into mix bus
  × masterGain (RampedGain)
  soft-clip (tanh approx — keep existing curve)
  fan out to device channels; LevelMeter.observe (atomics)
```

Per sender, a **NetJitterBuffer** replaces today's timer-driven JitterBuffer:

- Network thread `push(seq, opusBytes)` → same jitter-EMA/σ depth estimator as today
  (that math is good and stays: target = clamp(2·(EMA+σ), 40…200 ms)).
- A **DecodeWorker** (one shared thread for all senders, workgroup-joined) keeps each
  sender's PCM ring topped up 1–2 frames ahead of the render head: decode / FEC-decode /
  PLC exactly as today's `DrainAction` logic — but *demand-driven from ring occupancy*,
  not from a wall-clock 10 ms timer. The `maxConsecutivePLC` trap disappears: when the
  render side stops pulling a sender (no packets, ring drained, hangover elapsed), the
  sender goes inactive; there is no timer to run away.
- **Drift** (sender clock vs device clock, ±100 ppm typical): a PI controller on ring
  occupancy nudges an adjustment of ±1 frame per ~10 s — implemented as Opus PLC-insert
  (falling behind) or drop-one-frame-at-lowest-energy (running ahead). NetEQ-style
  time-stretch (WSOLA) is explicitly *out of scope v1*; frame insert/drop at 20 ms
  granularity is inaudible at these rates.
- Sender lifecycle: created on first packet (control plane allocates, publishes to the
  render snapshot lock-free), retired after 30 s silence or user-left (control plane
  retracts, frees off-thread).

Latency budget (mouth-to-ear, LAN, targets):

| Stage | Budget |
|---|---|
| Mic HW + VPIO | ~15 ms |
| Ring A + framer | ≤ 20 ms (one frame) |
| Opus encode | < 3 ms |
| Network (LAN) | < 5 ms |
| Jitter buffer | 40 ms (floor, adaptive up) |
| Decode + ring + render | ≤ 15 ms |
| Output HW | ~10 ms |
| **Total** | **≈ 110 ms P50 LAN** (≤ 150 ms goal) |

## 8. Cross-cutting data-plane machinery

### 8.1 SPSCRingBuffer (replaces `FloatRingBuffer`)

True lock-free single-producer/single-consumer: atomic head/tail with
acquire/release ordering, power-of-two capacity, no `os_unfair_lock` (today's lock is a
priority-inversion hazard on the render thread when the UI thread holds it). Overflow
policy is per-instance: capture ring drops **newest** (glitch stays local), playback
rings drop **oldest** (latency stays bounded). Unit-test with a torture harness
(2 threads, random burst sizes, checksum the stream).

### 8.2 RampedGain / atomics

`RampedGain`: atomic Float target, per-sample linear ramp over 5–10 ms toward it in the
consumer. Used for input gain, per-sender gain, master gain. Mute/deafen are *states* in
the config, not `gain = 0` hacks — but their audible application is also a ramp (2 ms) to
avoid clicks. UI meters: `LevelMeter` already uses snapshot semantics; keep it, ensure
the fields are actual atomics.

### 8.3 Watchdog (acts, doesn't log)

Per generation, two heartbeat counters bumped by the tap and the render callback. The
controller samples them at 1 s. Running + no ticks for 2 consecutive samples →
`.devicesInvalidated(.stalled)` → rebuild. (Today's watchdog detects exactly this and
then prints.)

### 8.4 Debug-build RT assertions

A `#if DEBUG` shim asserts on the render/tap threads: no allocation (malloc hook), no
locking (unfair-lock wrappers), max duration per callback. Realtime safety is a build
gate, not a review comment.

---

## 9. Realtime rules (the checklist)

On the device render thread and tap:

1. No memory allocation or deallocation (no Array/Data/String construction, no closures
   capturing fresh boxes).
2. No locks, no `os_unfair_lock`, no semaphores that can block, no priority inversion.
3. No Objective-C messaging, no Swift runtime calls that can lock (class init, weak
   loads are borderline — capture unowned raw pointers via `Unmanaged`).
4. No `print`/`os_log`/signposts (signposts allowed on *worker* threads only).
5. No GCD (`DispatchQueue.async` allocates), no `Task`.
6. Bounded work: O(frames × senders), K senders capped.
7. Communication out: SPSC rings, atomics, that's it.

Worker threads (CaptureWorker, DecodeWorker): rules 1–2 relaxed to "preallocated arenas
only, no unbounded waits"; they join the audio workgroup and their per-cycle work is
budgeted < 50 % of a 20 ms frame.

---

## 10. Networking co-design

### 10.1 Transport: native UDP (the big one)

Today all voice rides the TCP control channel (UDPTunnel). TCP retransmission +
head-of-line blocking turns 0.5 % packet loss into repeating multi-frame gaps — no jitter
buffer can hide an in-order-delivery stall. The engine's network contract becomes:

- **UDP first:** implement Mumble's encrypted UDP voice channel — OCB2-AES128 with the
  `CryptSetup` key/nonce exchange, `Resync` handling, and the good/late/lost counters.
  (OCB2 has known theoretical forgery weaknesses; it's what the protocol mandates — note
  it, ship it, don't invent crypto.)
- **Continuous liveness:** UDP ping every 1 s carrying the crypt stats; if no UDP echo
  for 4 s → transparent fallback to the existing TCP tunnel; keep probing UDP and
  upgrade back when it recovers. (This is exactly stock Mumble behavior — users on
  broken NATs still work, everyone else gets real datagrams.)
- Protocol versions: speak protobuf `MumbleUDP` (1.5+) with legacy varint fallback —
  the parsing already exists (`parseProtobufUDPAudio` / `parseLegacyUDPAudio`); it moves
  behind a `VoiceTransport` interface with `.udp`/`.tcpTunnel` states surfaced in UI.

### 10.2 Feedback loop → codec adaptation

One place (`LinkMonitor`, control plane, 2 s cadence) fuses: crypt good/late/lost, ping
RTT/σ, and per-sender JB stats (played/FEC/PLC — the counters already exist). It drives:

| Observation | Action |
|---|---|
| loss < 1 % sustained | Opus `packetLoss = 5 %`, bitrate up-ladder toward 64 kbps VBR |
| loss 1–5 % | `packetLoss = 15 %` (more FEC), hold bitrate |
| loss > 5 % | `packetLoss = 25 %`, bitrate down-ladder (min 24 kbps), consider 40 ms frames (halves packet overhead, +20 ms latency) |
| RTT σ spikes | let JB depth do its job; no codec change |
| UDP dead | TCP fallback (10.1) |

All Opus knob changes go through the existing `OpusControl` shim on the CaptureWorker
(encoder is single-threaded by design; the worker owns it, the monitor posts atomically
read targets).

### 10.3 Packetization

Unchanged from Mumble: 20 ms Opus frames, per-frame sequence numbers, terminator bit ends
an utterance (feeds JB reset — no more PLC-runaway heuristics needed on the far end).
Keep FEC on (the JB already exploits it), keep DTX off (VAD is the single gate).

---

## 11. Test & verification plan

### 11.1 Automated (CI-able, no hardware)

- SPSCRingBuffer torture test (checksummed stream, random bursts, 2 threads).
- NetJitterBuffer: scripted loss/jitter/reorder/burst traces → assert played/FEC/PLC
  ratios and depth adaptation envelope (extend existing `JitterBufferTests`).
- Drift harness: feed 48 000 vs 48 005 Hz clocks for simulated hours → ring occupancy
  stays bounded, insert/drop rate ≈ drift rate.
- Pipeline round-trip at every rate pair {16, 24, 44.1, 48 kHz} (extend
  `PipelineRoundTripTests` / `LoopbackTransport`).
- State machine model test: script event storms (device change during starting, service
  restart during recovering…) → never deadlocks, never double-builds, generation
  monotonic.

### 11.2 Hardware matrix (manual, scripted checklist)

| Scenario | Pass condition |
|---|---|
| AirPods Pro 2 (fw 2025+), macOS 26: join channel, open mic | mic at 48 kHz, output stays music-quality; badge shows studio quality **[VERIFY item 3.1: VPIO-gated or automatic]** |
| AirPods Pro 2, macOS 14/15: same | best-available link engages; degradation matches badge |
| AirPods (H1): same | predictable 16 kHz degradation + correct badge |
| Mid-call: AirPods → built-in → USB → back | audio resumes < 500 ms each hop, no stuck state, gains preserved |
| Launch League/YouTube mid-call (forces 44.1 kHz) | ≤ 1 rebuild, voice continuous within 500 ms, no crash, game audio not ducked |
| `sudo killall coreaudiod` mid-call | rebuild within 2 s |
| Unplug pinned USB mic mid-utterance | fallback to default, toast, auto-return on replug |
| Sleep → wake while connected | audio back without user action |
| 5 % / 15 % simulated loss (Network Link Conditioner) | intelligible voice, UDP→TCP fallback at blackout, upgrade back |
| 2 h idle in channel | 0 glitches, CPU < 3 %, no timer wakeups while silent |

Instrumentation: os_signpost intervals around rebuilds; glitch counter from
`ProcessorOverload` + underrun counts, surfaced in a debug HUD.

---

## 12. Module layout & migration

```
Packages/AudioEngine/Sources/AudioEngine/
  Control/   EngineController.swift  DeviceManager.swift  RoutePolicy.swift
             AudioConfig.swift       Recovery.swift
  Backends/  IOBackend.swift  VoiceBackend.swift  RawBackend.swift
  RT/        SPSCRingBuffer.swift  RampedGain.swift  RTAssert.swift
  Capture/   CaptureWorker.swift  Framer.swift  VADGate.swift
  Playback/  Mixer.swift  NetJitterBuffer.swift  DecodeWorker.swift
  Net/       VoiceTransport.swift  UDPVoice.swift  OCB2.swift  LinkMonitor.swift
  Diag/      Heartbeat.swift  EngineHUDModel.swift
```

**Survives (moves, mostly intact):** AudioCore DSP (Biquad, SoftLimiter, GainProcessor →
RampedGain base, LevelMeter, SignalGenerator, analysis + tests), OpusControl, the JB
depth-estimation math and FEC/PLC decode logic, `AudioDeviceTransportInfo` (as RoutePolicy
input + UI badges), VPIOEngineInput's format/-10875/device-pinning discoveries.

**Dies:** the AUHAL/VPIO dual-path split and its `.auto` contradiction, suppression
windows and debounce heuristics, the timer-driven JB drain, `FloatRingBuffer`'s lock,
MainActor audio processing, log-only watchdogs, the TCP-only voice path (~1 500 lines
net).

**Phases** (each independently shippable, each ends green on §11.1):

1. **Data-plane hygiene** — SPSCRingBuffer + CaptureWorker; mic path off MainActor.
   (Biggest robustness win; zero behavior change otherwise.)
2. **Pull-model playback** — Mixer + NetJitterBuffer + DecodeWorker behind the existing
   `enqueuePlayback` seam, then delete the timer drain.
3. **Control plane** — EngineController/DeviceManager/RoutePolicy; backends become dumb;
   delete suppression windows; add ServiceRestarted/sleep-wake handling.
4. **VoiceBackend as default incl. Bluetooth** — the AirPods quality goal lands here;
   hardware-verify the [VERIFY] items; RawBackend demoted to studio mode.
5. **Native UDP + LinkMonitor** — OCB2, fallback ladder, adaptive Opus.

---

## 13. Open questions / [VERIFY] register

1. Whether the macOS 26 AirPods studio-quality mic path engages for any client that
   opens the AirPods input, or only for voice-processing (VPIO/CallKit-class) clients;
   and what the best-available link is on macOS 14/15 with VPIO active (24 kHz duplex
   suspected). — Phase 4 gate, test on real AirPods Pro 2 across OS versions.
2. LE Audio (LC3) device behavior under VPIO on macOS 15+.
3. Whether `AVAudioEngine` tap buffer sizes are stable enough post-route-change or the
   tap must be reinstalled per configuration change (suspected: reinstall — rebuild does
   this anyway).
4. os_workgroup join from Swift `Thread` — confirm `AudioWorkIntervalCreate` /
   `os_workgroup_join` path and fallback to time-constraint thread policy if the
   workgroup is unavailable (RawBackend case).
5. Whether Opus 40 ms frames are worth the latency on >5 % loss links, or bitrate-only
   adaptation suffices (measure in phase 5).
6. AirPods model identification now reads the paired device's Bluetooth PnP
   record (vendor 0x004C + ProductID) via IOBluetooth instead of guessing
   from the device name (`AirPodsIdentifier.swift`; needs the
   `com.apple.security.device.bluetooth` entitlement + Bluetooth TCC
   consent). PIDs 0x2014/0x2024 (AirPods Pro 2) are community-confirmed;
   0x2019/0x201B (AirPods 4) and 0x201F (Max USB-C) are marked [unverified]
   in the table — confirm against real hardware / theapplewiki.com.

## 14. Sources

- [Apple newsroom — AirPods studio-quality recording (June 2025)](https://www.apple.com/newsroom/2025/06/airpods-now-more-versatile-with-studio-quality-audio-recording-and-camera-remote/)
- [SoundGuys — AirPods "studio-quality" recording measured at 48 kHz](https://www.soundguys.com/airpods-studio-quality-microphone-recording-139454/)
- [MacRumors — AirPods firmware update enabling iOS 26 features (Sept 2025)](https://www.macrumors.com/2025/09/15/apple-releases-new-airpods-firmware-ios-26/)
- [MacRumors — iOS 26 AirPods features, H2 requirement](https://www.macrumors.com/2025/08/08/ios-26-7-new-airpods-features/)
- [Apple docs — voiceProcessingOtherAudioDuckingConfiguration](https://developer.apple.com/documentation/avfaudio/avaudioinputnode/voiceprocessingotheraudioduckingconfiguration)
- [Apple docs — duckingLevel](https://developer.apple.com/documentation/avfaudio/avaudiovoiceprocessingotheraudioduckingconfiguration/duckinglevel)
- [WWDC23 — What's new in voice processing](https://developer.apple.com/videos/play/wwdc2023/10235/)
- [supermegaultragroovy — AVAudioEngine + AirPods split-device behavior](https://supermegaultragroovy.com/2021/01/28/more-on-avaudioengine-airpods/)
- [Apple Communities](https://discussions.apple.com/thread/253692683) / [MacRumors](https://forums.macrumors.com/threads/airpods-pro-2-mic-quality-very-bad.2363763/) — AirPods mic on macOS forcing low-quality link (pre-Tahoe)
- Mumble reference client `CoreAudio.mm` and protocol docs (OCB2-AES128 `CryptSetup`, UDP ping/fallback semantics)
