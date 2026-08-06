# CLAUDE.md — RWA Player

RWA – Real World Audio – is a software ecosystem consisting of RWA Creator, RWA Player (iOS)
and an RTK Headtracker (ESP32 based, for head tracking and positioning).

**RWA Player is the iOS runtime for the games authored in RWA Creator.** It imports an exported
`.rwa` game, tracks the listener's position and head orientation, and renders the placed audio
scene binaurally through libpd. Position comes from the RTK headtracker over BLE, with the
iPhone's internal GPS as automatic fallback; head orientation comes from the headtracker's IMU
(or CoreMotion when no tracker is used). The app is also the **telemetry gateway** of the
installation: it forwards structured device and app events to our backend.

The Player's game engine is a **hand-mirrored Swift port of the Creator's C++ runtime**. Keeping
the two in behavioural lockstep is the standing constraint of this repo — see
[Engine parity](#engine-parity-the-standing-constraint).

## Related repositories

We're currently working on the project "H.E.I. Campus", for which we bugfix / develop the
software further. Some repos therefore default to a base branch specific to this project; those
get merged back into main once the project is complete (out of scope for current discussions).

| Component | Repo | local path | base branch | Role |
| --- | --- | --- | --- | --- |
| rwa-player | `rwa-player` | . (this repo) | h.e.i.-campus | iOS app (previously called rwa-client) |
| rwacreator | `rwa-creator` | ../rwa-creator | h.e.i.-campus-customisation | C++/Qt6 authoring app + simulator |
| rtk-rover | `rtk-rover` | ../RTKRover_mod | main | ESP32 firmware: RTK GNSS + head tracking over BLE |
| rwa-backend | `rwa-backend` | ../rwa-backend | main | telemetry backend: docker-compose stack on AWS EC2 |
| rwa-doc | `rwa-doc` | ../rwa-doc | main | documentation for artists/creators, based on zensical |

Two cross-repo contracts to read before changing anything that crosses a boundary:

- `PROJECT-PLAN.md` (repo root) — telemetry architecture and event schema (§4–6), shared with
  `rtk-rover` (BLE/CBOR side) and `rwa-backend` (HTTPS/JSON side).
- `../rwa-creator/CLAUDE.md` — the domain model and the `.rwa` format. The Player is a consumer
  of both, and of the Creator's engine behaviour.

## Naming

Several names refer to the same thing, in directories, project files and app titles:

- rwa-player, RWA Player — current name (repo slug, app title, in-app strings: done)
- rwa-client, rwaclient-ios, rwaClient — the former name. Directories inside the Xcode project
  still carry `rwaClient` / `rwa client`; renaming those with an Xcode project relying on them
  is dangerous, so they stay.

## Domain model (shared with the Creator)

A **game** (`.rwa` XML + a co-located `assets/` folder) contains **scenes**; a scene contains
**states**; a state contains **assets** plus enter/exit conditions and actions. Scenes and states
are (mostly) geographic areas on the map. The listener is the **hero** (`RwaEntity`).

State types, playback types, area types and the rule that `states[0]` **must** be the fallback
state are defined by the Creator — see `../rwa-creator/CLAUDE.md`. The Swift constants in
`RwaState.swift`, `RwaAsset.swift` and `RwaArea.swift` mirror those numeric values and must not
drift from `rwastate.h` / `rwaasset1.h` / `rwaarea.h`.

Player-specific facts:

- The importer (`RwaImport.swift`, an `XMLParser` delegate) is **stricter** than the Creator's
  exporter: it force-unwraps most attributes, so a `.rwa` missing one traps instead of
  defaulting.
- A scene should have at most one FALLBACK and one BACKGROUND state; the importer keeps the last
  one it sees.
- The Creator exports no `enteroffset`; the Player hardcodes `RwaArea.enterOffset = -2` (you must
  be ~2 m *inside* a boundary to enter it). The exit offset does come from the file.
- Audio is expected at **48 kHz** by both engines.
- The `AUTO`/`NATIVE` playback types dispatch on channel count and are unreliable here — see
  `../rwa-creator/tools/gamefiles/README.md`.

## Code map

`rwaClient/src/` is flat — ~30 Swift files, no subdirectories except `Telemetry/`.

| Area | Files |
| --- | --- |
| Game engine (the important one) | `RwaGameLoop.swift` (~1.7 kloc) — tick, scene/state activation, patcher pools, every Pd message. Mirrors `rwa-creator/rwaruntime.cpp` |
| Game data model | `RwaScene`, `RwaState`, `RwaAsset`, `RwaArea`, `RwaEntity`, `RwaLocation`, `RwaUtilities` (geo math, moving average) |
| Import | `RwaImport.swift` — `.rwa` XML → the model |
| Service layer (a view controller by accident) | `SecondViewController.swift` — BLE central, tracker text protocol, CoreMotion, north calibration, the 10 ms game-loop timer. See [Legacy structure](#legacy-view-controller-structure-read-before-touching-tabsble) |
| Positioning | `CoreLocationController.swift` (internal GPS fallback) + the ublox path in `SecondViewController` + `Device.swift` (GATT UUIDs, raw frame parsing) |
| Telemetry gateway | `Telemetry/` — `TelemetryService` (envelope, seq, uploader), `TelemetryStore` (SQLite), `DeviceTelemetryDecoder` + `TelemetryKeys` (CBOR, §5.3 key table), `LiveTelemetrySource` (app-origin 1 Hz sampler), `TelemetryConfig`; `DeviceHealth.swift` is the shared snapshot the Diagnostics tab reads |
| UI (five tabs) | `FirstViewController` (Games), `ControlViewController` (Control), `MapViewController` (Map), `AboutViewController` (Diagnostics), `SettingsViewController` (Settings) |
| Content delivery | `DownloadManager`, `ZipExtractor`, `GameManager` — HTTP pull of games from the Creator, see `docs/GAME-DOWNLOAD.md` |
| DSP (C, **shared with the Creator**) | repo root: `rwa_binauralsimple~.c`, `rwa_firobject.c`, `vas_fir*.c`, `oggread~.c`, … compiled from `vas_library/` |

Pd patches live in `pd-patches/` (the playback patchers, one per playback type, plus
`fabian_dir256.txt` — the 38 MB FABIAN HRTF set). A build phase rsyncs everything under
`rwaGames/` **flat** into the app bundle, so a game's `.rwa` and its assets end up side by side
in `Resources/`.

**Vendored / submodule directories — do not edit, and exclude them from searches:**
`libpd/`, `vas_library/`, `F53OSC/`, `libogg/`, `vorbis/`, `pd-extra/`. Never run
`git submodule update` in a `.claude/worktrees/*` worktree — build in the main checkout instead.

### How state is held (the thing that makes this codebase hard)

Engine and app state lives in **module-level globals**, not in objects: `hero`, `scenes`,
`rwagameloop`, `fullGamePath`/`fullAssetPath`, `azimuth`/`elevation`, `ubloxLat`/`ubloxLon`,
`useRtkGps`, `useHeadTracker`, `registered`, … declared across `FirstViewController.swift`,
`SecondViewController.swift`, `AppDelegate.swift` and `RwaGameLoop.swift`. Views coordinate
through `NotificationCenter` with stringly-typed names ("Start Game", "Stop Game",
"Connect Headtracker", "Game Loaded", "Redraw Map", "Update Scene", "Update State",
"Update Buttons").

This is the main obstacle to testability (the parity tests have to reset globals by hand and
cannot run in parallel) and the main thing to unpick when improving the structure. Unpick it
deliberately and in whole seams, not opportunistically file by file.

## Input paths (what drives the hero)

Three position sources, in a strict priority order whose single definition is
`LiveTelemetrySource.rtkTrackerActive()`:

1. **OSC from RWA Creator** (`registered == true`) — the Creator's simulator drives
   `hero.coordinates` remotely and overrides everything else. The Player listens on port 8001 and
   sends back to `rwaCreatorIP:8000` (`sendGPS2Creator`, session-only, never persisted).
2. **RTK headtracker** (Settings ▸ GPS source = `rtk`) — ublox coordinates over BLE. Two
   encodings on two characteristics: the legacy text frame `l <lat> <lon>` (1e-7 deg) on
   `TRACKERSERVICETX` (713D0002) and the high-precision raw frame on `TRACKERRAWDATA` (713D0004,
   up to 10 Hz, lat/latHp/lon/lonHp).
3. **Internal GPS** (CoreLocation) — the automatic fallback. `CoreLocationController` stands by
   while tracker fixes are fresher than `LiveTelemetrySource.freshnessWindow` (8 s) and takes
   over as soon as the tracker goes quiet.

Heading: the headtracker's IMU (azimuth / elevation / linear acceleration on the same text
characteristic, with step detection derived from the acceleration) or CoreMotion device
orientation when `useHeadTracker == false`. North calibration is an azimuth offset applied on
receipt; `inverseElevation` flips the elevation sign.

## Telemetry gateway (PROJECT-PLAN.md §6)

Implemented end to end; the pieces are in `rwaClient/src/Telemetry/`.

1. BLE central subscribes to the telemetry characteristic (713D0100/0101), reassembles the TX
   byte stream by its length prefix and decodes length-prefixed CBOR frames with the §5.3
   integer key table (`TelemetryKeys.swift` mirrors the firmware's `telemetry_keys.h`).
2. Each event is stamped with wall-clock `time` and envelope context (device_id, session_id,
   soundwalk_id, app_version, fw_version) and persisted to SQLite (`pending_events`) on receipt.
3. App-origin events (`gnss_fix`, `heading`, `heartbeat` from `LiveTelemetrySource`, plus
   `app_event`s) go into the same store using the app seq counter (offset 2^32, §4.2), so
   `(device_id, session_id, seq)` stays globally unique for dedup.
4. The uploader POSTs the oldest ≤ 500 events as one JSON batch to `<backend>/v1/batch` every
   15 s with the bearer token; rows are deleted only on HTTP 2xx, failures back off
   exponentially to 5 min, and retries are dedup-safe.
5. New `session_id` (UUID) per app run.

Still open here: gzip on the batch body, and surviving background/foreground cycles (the
uploader uses an ephemeral `URLSession` today — no background configuration, no
`BGTaskScheduler`). `app_event` coverage is thin: only `app_launched`, `walk_started`,
`walk_stopped` and `upload_failed` are emitted.

Constraints:

- Audio rendering is real-time sensitive: telemetry persistence and uploads run on background
  queues; never do I/O on the audio or BLE callback threads.
- BLE delegate callback → lightweight decode → async write to SQLite. If the store is
  unavailable, drop telemetry rather than degrade playback.
- `LiveTelemetrySource` is deliberately a *sampler*, not a set of callback hooks: it reads the
  globals the hot paths already maintain, so those paths stay untouched.
- The devices are kiosk-style (we own them): device_id and ingest token come from a local plist,
  not from user input.

## Engine parity (the standing constraint)

The Player does **not** reuse the Creator's C++ engine — `RwaGameLoop.swift` re-implements
`rwaruntime.cpp` by hand. Any behavioural change on either side silently diverges the two
engines unless it is mirrored. When you touch the engine: state the parity impact, check the C++
side in `../rwa-creator/rwaruntime.cpp`, and record it in `rwaClient/CHANGELOG.md`.

**Direction of travel:** the intended end state is for the Player to use the Creator's C++
runtime directly, so the core cannot diverge at all. Nothing depends on that yet, but prefer
changes that move toward it — keep engine logic in `RwaGameLoop` free of UIKit and (where
possible) of the app globals, and treat every new Swift-only engine behaviour as debt you will
later have to port or delete.

**Verification is by golden-trace differential testing**, not by ear: the same scenario script is
replayed against both engines and the resulting JSONL traces are diffed.

- Phase A — engine walkthrough, known divergences:
  `../rwa-creator/docs/engine-runtime-investigation.md`
- Phase B — headless C++ harness `rwatrace`: `../rwa-creator/tools/trace/`
- Phase C — the Swift side: `rwaClient/tests/` (XCTest, hosted in the app), documented in
  `docs/engine-parity-tests.md` (includes the diff canonicalisation rules and the
  `xcresulttool export attachments` step for getting traces out)
- Phase D — **pending**: triage the remaining diffs into intentional (allowlist) vs bug, freeze
  goldens, and add a CI checksum guard on the scenario files mirrored from
  `../rwa-creator/tools/trace/scenarios/`

Known structural divergences (not yet all triaged):

- tick rate 10 ms (Player) vs 25 ms (Creator), and the Player additionally gates scene/state
  evaluation to ~1 Hz via `fmod(hero.timeInCurrentState, 1)` in `setEntityState`
- `sendData2ActiveAssets()` returns early when `activeAssets` is empty, so background assets get
  no per-tick positional updates on iOS while the C++ engine streams them every tick — the
  biggest behavioural gap for background-heavy walks
- per-tick send set, patcher pool sizes, and the extra `<tag>-gain 0` the iOS release path sends
  on `playfinished`
- units differ in places, silently: the Player's global `sampleRate` is 48.0 (samples/**ms**)
  where the Creator uses 48000 (samples/s). Check the unit before mirroring any arithmetic.
- ongoing findings and open questions: `docs/engine-parity-investigations.md`

**The DSP layer is already shared.** Both apps compile the same `vas_library` sources
(submodule branch `rwa-player-fixes`), the same `rwa_binauralsimple~` / `vas_fir*` C files, and
the same `pd-patches/`. A fix there is made once and pulled into both repos. The divergence is in
the game logic, not in the renderer.

## Project facts

- Swift + UIKit, plain Xcode project — no SPM or CocoaPods; dependencies are git submodules.
- Min iOS 16.2; bundle id `com.fhnw.rwa.player`.
- **The app target compiles in Swift 4 language mode** (`SWIFT_VERSION = 4.0`) — hence
  `@UIApplicationMain`, `UIApplicationLaunchOptionsKey`, and no modern concurrency. The test
  target is Swift 5. Migrating the app target is a project of its own, not a drive-by.
- Build: open `rwaClient/rwaclient.xcodeproj`, or `xcodebuild -scheme rwaclient build`.
- Tests: `xcodebuild test -scheme rwaclient -destination 'platform=iOS Simulator,name=iPhone 16'`
  — the `rwaclientTests` target holds the engine parity/trace tests and the CBOR decoder tests.
  It is **hosted in the app** (the engine is not a framework; it is reached via
  `@testable import rwa_client` and needs the real libpd patcher pools).
- Two gitignored files must exist before the project builds (`README.md` has the details):
  `rwaClient/.xcconfig` (`DEVELOPMENT_TEAM`) and `rwaClient/src/Telemetry/Telemetry.plist`
  (copy `Telemetry.example.plist`; device id, backend URL, ingest token — never commit the token).
- Xcode Cloud recreates both from workflow environment variables in
  `ci_scripts/ci_post_clone.sh`. Every submodule tree must clone over plain HTTPS with no
  credentials: Xcode Cloud resolves submodules recursively before any hook runs, so one dead
  nested `git://` or SSH URL fails the whole build.
- Test games live in `rwaGames/` (`rwatest`, `test_moving-asset`). Real authored games are at
  `/Users/cedric.spindler@fhnw.ch/Projects/h.e.i.-campus/shared/examples`, audio material at
  `.../shared/audio/` — outside the repos.

## Verifying changes

There is no general unit-test suite (in either the Player or the Creator). Verification means:

- **engine changes** → the trace pipeline above: replay a scenario, diff against the `rwatrace`
  trace. Never "it sounded right".
- **importer changes** → `../rwa-creator/tools/gamefiles/validate_rwa.py` on the affected files.
- **BLE / telemetry decode** → `DeviceTelemetryDecoderTests`.
- **UI, positioning and interaction** → on a real device, either with the headtracker or driven
  from the Creator's simulator over OSC. The iOS Simulator has no BLE and no useful GPS, so
  anything positioning-related cannot be checked there.

## Legacy view-controller structure (read before touching tabs/BLE)

Assessed 2026-07 — explains why the code and `Main.storyboard` disagree; this state is
intentional and stable, don't "fix" it casually.

- `SecondViewController` is the original 2015 "Current Scene" developer screen. It is **not
  really a view controller but the app's service layer**: it owns the BLE central (headtracker
  connection + text-protocol parsing), CoreMotion heading/steps, the 10 ms game-loop timer, and
  north calibration.
- Its tab is hidden at runtime (`hideCurrentSceneTab()` in AppDelegate), but the controller must
  stay alive: `loadViewIfNeeded()` forces its BLE setup without the tab ever appearing, and a
  strong reference keeps its notification observers ("Start Game", "Connect Headtracker", …)
  from dying. Fragile by design — killing it or making it lazy kills BLE and the game loop.
- `ControlViewController` (the "Control" tab) is the operator-facing replacement for the old
  storyboard "Control Data" tab: start/stop, headtracker connect, calibration, volume, live
  coordinate readout, and the OSC receiver. It is installed in code at index 1 because
  `FirstViewController` jumps to `selectedIndex 1` after loading a game.
- Control, Diagnostics and Settings are installed **programmatically** in AppDelegate; only
  "Current Scene" (hidden) and the legacy "Control Data" (dropped) exist in the storyboard. This
  asymmetry is fine: do NOT re-sync the storyboard (rabbit hole, zero user value; storyboard XML
  diffs badly). Treat `Main.storyboard` as legacy scaffolding.
- Planned cleanup: extract `HeadtrackerManager` (BLE + parsing), `MotionHeadingSource`
  (CoreMotion + steps) and `GameLoopController` (timer + start/stop) as plain objects owned by
  the AppDelegate, then delete `SecondViewController` and its storyboard scene. Do it in one
  pass, together with whatever else needs the BLE layer touched.
- Legacy quirk: `defaultsKeys` values are the UserDefaults *key strings*, and some are
  misleading (the headtracker name is stored under the literal key `"rwaht01"`, the IP under
  `"192.168.178.53"`, and the default-game key is `""`).

## Documenting development

- Short, concise commit messages; the detailed explanation goes into `rwaClient/CHANGELOG.md`
  (Keep a Changelog format, entries under `[Unreleased]`).
- SemVer. The version lives in `MARKETING_VERSION`; releasing means `./update_version.sh x.y.z`
  and moving `[Unreleased]` into a tagged section in the same commit.
- A change that affects the Creator (engine behaviour, `.rwa` format, shared DSP) gets a note on
  both sides.

## Goals

Current focus, roughly in order:

1. **Bug fixing** — the H.E.I. Campus deployment is the driver. Open leads are collected in
   `docs/bugs-and-feature-requests.md`.
3. **User experience** — the app is still shaped like a 2015 developer tool: operator flows
   (load a game, connect, calibrate, start) should be obvious and hard to get wrong, and failure
   states (no tracker, no fix, no game) should say what is wrong.
3. **UI optimisation** merge "Games" and "Control" tab into "Sound Walk" (or something more fitting):
   - remove "set default game", this is done in the Settings tab
   - fetching new games should also move elsewhere, maybe to popover for selecting games or so
   - the list of games becomes a select box triggered somewhere near the title in the current "Control" view
2. **Logical structure, conciseness and code quality** — retire the globals-and-notifications
   coordination, follow best practice architecture, finish the `SecondViewController` extraction,
   and shrink `RwaGameLoop`'s copy-pasted patcher-pool code (eleven near-identical `findFree…`/`get…Index` pairs).
4. **Parity, long term** — use the Creator's C++ engine directly in the Player so the core
   cannot diverge; until then, close Phase D of the trace pipeline.

Open telemetry items: gzip batches, background-safe uploads, wider `app_event` instrumentation.
