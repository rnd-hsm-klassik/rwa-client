# CLAUDE.md — rwa-client

iOS app for an audio augmented reality (AAR) installation: loads "soundwalks"
(virtual audio scenes placed on a map), performs binaural mixing driven by RTK GNSS
position and head-tracking data received over BLE from a headset-mounted ESP32 unit
("rtk-rover"). The app is also the **telemetry gateway**: it forwards structured
debug/quality events from the device to our backend.

Read `PROJECT-PLAN.md` (repo root) first — it defines the architecture and the
telemetry event schema (§4–6). The schema is a cross-repo contract shared with
`rtk-rover` (BLE/CBOR side) and `rwa-backend` (HTTPS/JSON side).

## Naming

Several names are used here, for directories, project, App titles etc.
The following names all refer to the same project:

- rwa-client
- rwaclient-ios
- rwaClient

Eventually, the App should be named "RWA Player", with a repo slug `rwa-player`.

## Responsibilities (telemetry gateway, PROJECT-PLAN.md §6)

1. BLE central: subscribe to the rtk-rover telemetry characteristic; decode
   length-prefixed CBOR frames (short-integer-key mapping mirrors the firmware).
2. Stamp each event with wall-clock `time` and envelope context (device_id,
   session_id, soundwalk_id, app_version, fw_version); persist to SQLite
   (`pending_events` table) immediately on receipt.
3. Emit app-origin `app_event`s (walk_started, audio_zone_entered, ble_disconnected,
   upload_failed, …) into the same store, using the app seq counter (offset 2^32 —
   see PROJECT-PLAN.md §4.2).
4. Background uploader: every 15–30 s POST the oldest ≤ 500 events as one gzipped
   JSON batch to `https://<backend>/v1/batch` with the bearer token. Delete rows
   only on HTTP 2xx; exponential backoff on failure; duplicates are safe (backend
   dedupes).
5. Session lifecycle: new `session_id` (UUID) per walk session.

## Project facts

- Language/UI: Swift, UIKit
- Min iOS: 16.2
- Build: open `rwaClient/rwaclient.xcodeproj` / `xcodebuild -scheme rwaclient build`
- Tests: No tests, (start with `xcodebuild test -scheme rwaclient -destination 'platform=iOS Simulator,name=iPhone 15'`)
- Local setup: copy `rwaClient/src/Telemetry/Telemetry.example.plist` to
  `Telemetry.plist` (same directory) and fill in device_id, backend URL and
  ingest token. `Telemetry.plist` is gitignored (contains the token); the build
  fails on a fresh clone until it exists.

## Conventions & constraints

- Audio rendering is real-time sensitive: telemetry persistence and uploads run on
  background queues; never touch the audio or BLE callback threads with I/O.
- BLE delegate callbacks → lightweight decode → async write to SQLite. If the store
  is unavailable, drop telemetry rather than degrade playback.
- Uploads must survive app background/foreground cycles (BGTaskScheduler or
  URLSession background configuration — match existing app patterns).
- The devices are kiosk-style (we own them): device_id and backend token come from
  a local config (plist / managed settings), not user input.
- Soundwalk content: treat as versioned asset bundles addressed by a manifest
  (OTA-content groundwork, PROJECT-PLAN.md §8.2). Avoid hardcoding bundle paths.

## Legacy view-controller structure (read before touching tabs/BLE)

Assessed 2026-07 — explains why the code and Main.storyboard disagree; this
state is intentional and stable, don't "fix" it casually.

- `SecondViewController` is the original 2015 "Current Scene" developer screen.
  It is **not really a view controller but the app's service layer**: it owns the
  BLE central (headtracker connection + text-protocol parsing), CoreMotion
  heading/steps, the 10 ms game-loop timer, and north calibration.
- Its tab is hidden at runtime (`hideCurrentSceneTab()` in AppDelegate), but the
  controller must stay alive: `loadViewIfNeeded()` forces its BLE setup without
  the tab ever appearing, and a strong reference keeps its notification
  observers ("Start Game", "Connect Headtracker", …) from dying. Fragile by
  design — killing or lazily loading it kills BLE and the game loop.
- `ControlDataViewController` is the later operator-facing "Control Data" tab
  (OSC/rwaCreator registration, volume) and duplicates some of the same
  readouts/controls via shared globals. Settings migration is shrinking it.
- Diagnostics and Settings tabs are installed **programmatically** in
  AppDelegate; "Current Scene" exists only in the storyboard. This asymmetry is
  fine: do NOT re-sync the storyboard (rabbit hole, zero user value; storyboard
  XML diffs badly). Treat Main.storyboard as legacy scaffolding.
- Planned cleanup, folded into the CBOR/BLE work-queue item (touch the BLE layer
  once, not twice): extract `HeadtrackerManager` (BLE + parsing),
  `MotionHeadingSource` (CoreMotion + steps), and `GameLoopController`
  (timer + start/stop) as plain objects owned by the AppDelegate, then delete
  `SecondViewController` and its storyboard scene.
- Legacy quirk to be aware of: `defaultsKeys` values are the UserDefaults *key
  strings*, and some are misleading (the headtracker name is stored under the
  literal key `"rwaht01"`; the default-game key is `""`).

## Current work queue

1. SQLite event store + envelope stamping
2. CBOR frame decoder (shared key table with rtk-rover) — start with the
   SecondViewController service extraction (see above)
3. Batch uploader with backoff + dedup-safe retry
4. app_event instrumentation at key lifecycle points
5. Debug screen: last fix quality, carrier solution, NTRIP state, upload backlog
