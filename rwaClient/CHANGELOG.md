# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.11] - 2026-08-19

### Added

- `<tag>-seed` init value (parity with RWA Creator): every asset activation now
  sends a fresh random seed right before `-play`
  (`RwaGameLoop.sendInitValues2Pd`), so Pd asset patches can reseed `[random]`
  and friends. Value is a `UInt32.random` draw kept in `1..2^24-1` (exact in
  float32); patches that don't bind the receiver are unaffected.
  
  Intentionally not identical (more simple) RNG with the Creator: each engine
  draws its own. The source is injectable (`seedSource`) and
  `ScenarioTraceRunner` pins it so parity traces show `-seed 1`.

## [1.3.10] - 2026-08-18

### Added

- Hierarchical gain (parity with RWA Creator): scenes and states carry a `gain`
  of their own (optional `gain="..."` attribute on `<scene>`/`<state>`, linear,
  default 1, older files load unchanged). Sending it once at activation is
  enough (Creator streams it every tick for live mixing, planned divergence #3
  in the Creator's `docs/engine-runtime-investigation.md`).

### Changed

- `startBackgroundState()` no longer sends `<tag>-gain` a second time right
  before `sendInitValues2Pd()` (which sends it anyway). Same cleanup as in
  the Creator, so background-asset init blocks stay comparable in the parity
  traces (`docs/engine-parity-tests.md`).

- `ITSAppUsesNonExemptEncryption = false` in the app Info.plist, so App Store Connect
  stops asking for an export-compliance answer on every TestFlight build (the app only
  uses HTTPS/system crypto, which is exempt).

## [1.3.9] - 2026-08-18

### Changed

- Integrated the rewritten pooled playback patches from RWA Creator (parity).

## [1.3.8] - 2026-08-14

### Added

- USB deployment of games to kiosk phones: `tools/deploy_games.sh` pushes game
  folders into the app's Documents container on every USB-connected paired
  iPhone. iOS 17+ phones go over `xcrun devicectl` (phone unlocked); iOS 16
  phones are invisible to `devicectl` and go over classic lockdown/AFC
  (house_arrest) instead, via `deploy_games_afc.py` run with an installed
  `pymobiledevice3` (`pipx install pymobiledevice3`). The AFC path emulates
  devicectl's skip-unmodified behaviour with a `.deploy-manifest.json` (relpath
  → size+mtime) kept in each pushed game folder. Games are staged via APFS clone
  with the Creator's working files stripped (`tilecache/`, `tmp/`, `undo/`,
  `layouts.ini`) plus macOS junk.

  The script deliberately has no mirror/delete mode: devicectl's
  `--remove-existing-content` was found to wipe the entire app container (all
  games, `Library/Preferences` (i.e. the app's UserDefaults) and pending
  telemetry in `Library/Application Support`), not just the destination folder.
  Stale games are removed via the iOS Files app or Finder file sharing.

- Per-phone settings provisioning: `ProvisioningLoader.swift` applies
  `Documents/player-settings.plist` to UserDefaults at launch, before the
  AppDelegate reads them. The file is pushed by `deploy_games.sh -s <plist>`
  from a single laptop-side plist keyed by hardware UDID (one settings dict per
  phone; format in `provisioning.example.plist`, the real file is not tracked in
  this repo). Applied once per file content, so settings changed on the phone
  afterwards survive relaunches until a changed file is pushed.

## [1.3.7] - 2026-08-13

### Added

- Register the `vas_reverb~` Pd external with the runtime, mirroring the Creator
  (`rwa-creator` commit `46d7855`). The source comes from the shared
  `vas_library` submodule (`examples/PureData/vas_reverb~.c`), which already
  contained it at the pinned commit `7368810`; its convolution engine is the
  existing `vas_fir_binaural` code (`vas_fir_reverb_*` are aliases), so no
  further sources were needed. Registered in `RwaGameLoop.init` alongside
  `rwa_binauralsimple~`, in the Creator's registration order.

## [1.3.6] - 2026-08-13

### Added

- **Two-phase stop/start** (port of the Creator's unreleased two-phase stop;
  reference: `rwa-creator` `rwasimulator.{h,cpp}`). Stopping a walk is now phase
  A (game loop off, audible 800 ms master fade via the new `rwamasterfade`
  receiver in `stereoout.pd`) followed ~100 ms after the fade by phase B1
  (release protocol `-free`/`-fadeouttime 0`/`-end` completed for the whole
  patcher pool) and, after a 60 ms settle window, phase B2 (receive queue
  drained immediately, never on a delayed timer, asset maps cleared, and only
  then may a new start fire). Without this, pooled patchers' pending `[delay]`
  clocks survive a stop (`pd_systime` is continuous), and a fade-out mid-flight
  could fire into the next run and silently switch off a patch a fresh asset
  owns; stale `activeAssets`/`backgroundAssets` entries also leaked across game
  switches.

  Starts open silent: the master fade jumps to 0, then ramps to 1.0 over 300 ms.
  A start requested while stopping is queued and fired when the reset completes;
  a stop while a start is queued cancels the start; loading a game while a walk
  runs waits for the new "Game Stopped" notification before parsing.

  App termination uses a synchronous variant (no fade, no settle; Pd's
  state dies with the process), a scheduled timer never fires once the run
  loop winds down. Backgrounding deliberately does *not* stop the walk
  (background audio is a feature).

  **Engine parity**: intentional mirror of the Creator's design, with two
  deliberate divergences:

  1. The Player never closes the audio stream: the always-on stream matures the
     pending zero-length fades in real time during the settle window, where the
     Creator closes the stream and hand-advances the scheduler with silent
     buffers; safe because the Player's libpd serializes every API call *and*
     the render callback with `sys_lock`, so there is no unlocked teardown to
     protect (the Creator's original motivation).

  2. The Creator closes its dynamic (creator-authored) Pd patchers on every
     stop, the Player keeps them open across start/stop of a loaded game and
     sweeps them with the same release protocol instead. New `TeardownTests`
     asserts the protocol fan-out over every pool.

### Changed

- **Control tab: the Start button is disabled (grayed) while no game is loaded**
  (`scenes` empty); it enables on "Game Loaded". Previously a tap started an
  empty game loop.

- **vas_library bumped `89f3d97` → `7368810`** (fork branch `rwa-player-fixes`):
  engines now deregister from the shared IRs cache in `vas_fir_binaural_free()`.
  Before this, closing a game's dynamic Pd patch containing binaural externals
  left a dangling engine in the cache (use-after-free candidate on the next game
  load); also guards for the array-IR path, the garray double-free fix
  (externals the Player does not compile), and self-identifying filter-loading
  log output.

- **Pd patches deliberately synced with `rwa-creator/puredata/`**:
  `stereoout.pd` replaced by the Creator's version; debug `[print]`s removed
  from shipped patchers; the `r $0-samplerate` receiver the Creator's ogg
  patches have (feeds the `/ 48000` playhead-seconds conversion in `pd
  generatestartmessage`) added to the three Player ogg patches that lacked it
  (the engine already sends `<tag>-samplerate` on every activation). Residual
  patch divergence vs the Creator is now cosmetic only (canvas geometry/fonts),
  plus a few Creator-side debug number boxes.

### Removed

- **Dead diverged DSP copies at `rwaClient/` level** (`rwa_reverb~.c`,
  `rwa_binauralsimple~.c`, `rwa_binauralrir~.c`, `rwa_firobject.c`, `vas_*.c`):
  the Xcode project compiles the `vas_library` submodule sources (and
  `rwaClient/oggread~.c`, which stays in the codebase, identical to the
  Creator's copy); these copies were not referenced by the project and had
  drifted from the fixed fork sources. Those are checked separately.

## [1.3.5] - 2026-08-07

### Fixed

- **Engine parity: multichannel spatial data for Pd-patch assets** (mirrors the
  Creator's changes, see rwa-creator `CHANGELOG.md` [v1.4.3]). The Playback Mode
  of a patch asset now determines how many channels of spatial data it receives
  per tick; previously the game loop ignored the mode for patch assets and
  always sent one data set (`$0-distance1`/`azimuth1`/ `elevation1`). The
  per-playback-type fan-out in `RwaGameLoop.sendData2Asset` is now one loop over
  new `RwaAsset.playbackChannelCount()` (patches: minimum 1; with "headtracker
  relative to source" off always 1 raw-head data set, as before). Two
  divergences from the Creator's Pd branch were aligned in the process: a
  patch's channel-1 distance now folds in the asset altitude
  (`calculateDistanceWithAltitude`) and its elevation is the computed
  source-relative elevation (`calculateElevationEasy`) instead of the raw asset
  altitude — same formulas the audio branch already used.

- **Engine parity: 7-channel offsets**: `getOffsetForChannel` had no case for
  `RWAPLAYBACKTYPE_BINAURAL7CHANNEL_FABIAN`, so all seven channels of a
  7-channel asset were placed at the same angular offset (the same gap just
  fixed in the Creator). The per-mode tables are replaced by
  `RwaAsset.channelCountForPlaybackType` / `channelOffsetForPlaybackType`,
  hand-mirrored from `RwaAsset1` in the Creator (7-ch spread
  −40/0/40/−80/80/−120/120°). The Custom IR-Set modes (14–16) now send one data
  channel like in the Creator; the missing playback-type constants 13–16
  (`BINAURALSPACE`, `CUSTOM1-3`) were added to `RwaAsset.swift`.

### Added

- **Engine parity: `$0-numchannels` init value**: every asset activation sends
  the number of `azimuthN`/`distanceN`/`elevationN` channels the engine will
  actually stream (from `playbackChannelCount()`), alongside `$0-samplerate`, so
  patches can adapt their receiver wiring. The Creator side went in with the
  same change; the Creator's `tools/trace/pdmodes/` fixture and scenario are
  mirrored into `rwaGames/pdmodes/` + `rwaClient/tests/scenarios/`, and a new
  `EngineParityTests.testPdModesScenario` asserts the expected fan-out per
  patch (numchannels and `azimuthN` receivers: 2/1/1/7, the raw head azimuth
  arriving verbatim, and distinct 7-channel bearings).

## [1.3.4] - 2026-08-07

### Changed

- Elevation is no longer inverted by default: the `inverseElevation` default
  flips to *off*, both the in-memory default and the launch fallback. The key
  migration in `c6f59ff9` no longer seeds `inverseElevation` from the legacy
  shared key either: that value recorded whichever colliding setting was written
  last (usually the heading source) and is meaningless for elevation. Devices
  that already ran an interim build with the old seeding keep a stored value;
  toggle the switch once in Settings to write an explicit choice.
- The "set default game" switches are gone from the Games list;
  the default game is chosen in Settings > Soundwalk > Default game. The
  list now marks the current default with a checkmark, and the
  storyboard's leftover "Default Game" caption is hidden. The Settings
  picker also stores the Documents-relative name now, matching the earlier
  path fix: it previously wrote the absolute container path, which
  would have re-introduced the stale-default-game bug through the
  Settings door.
- The Games list no longer displays the absolute Documents path under each entry
  (same container path on every row). The subtitle line stays populated but
  hidden, reserved for game metadata; row selection now reads the game from the
  model instead of scraping the cell labels, so a future metadata line cannot
  break loading.

### Fixed

- The default game loads again after an app update. The "default game" switch
  stored the game's **absolute** path, which embeds the app container UUID, and
  iOS assigns a new container on every update or reinstall. On the next launch
  the stored path pointed into the old, deleted container: the XML import failed
  silently, and the Control tab showed the game title but Start did nothing
  (Scene/State "—", no sound). The setting is now stored Documents-relative and
  resolved against the current container at launch; legacy absolute values are
  migrated in place. When the file is genuinely missing the app now stays on the
  Games list and logs an error instead of showing a phantom title, and
  `RwaImport.readRwa` logs import failures (missing file, parser error) instead
  of ignoring them.

- Internal (device-orientation) heading no longer dies after a relaunch. The
  "Inverse elevation" and "Heading source" settings were both persisted under
  the same literal UserDefaults key `"true"`, so writing either setting
  clobbered the other: after setting Heading = Internal and touching Inverse
  elevation, the next launch silently flipped the heading source back to the
  headtracker and CoreMotion never started, turning the phone had no effect,
  audibly or in the Control readout. The two settings now use distinct keys
  (`inverseElevation`, `useHeadtracker`) with a one-time migration that seeds
  both from the legacy shared key.
- With Heading = Internal, heading/step frames from a connected headtracker
  (kept connected for RTK positioning) no longer overwrite the CoreMotion
  heading and no longer double-count steps. Position (`l`) frames are
  unaffected.
- Internal heading now reaches Pd on the non-headtracker-relative asset path.
  `RwaGameLoop.sendData2Asset` sends the raw `azimuth`/`elevation` globals to
  the `<tag>-azimuth1`/`<tag>-elevation1` receivers, but only the BLE tracker
  parser ever wrote those globals — with Heading = Internal, CoreMotion updated
  `hero.azimuth`/`hero.elevation` (readout, bearing calculation) while Pd kept
  getting the last tracker value or 0. The CoreMotion handler now fills the
  globals too, mirroring the tracker path. Player-only input plumbing; the
  values sent to Pd match what the Creator engine sends from its own heading
  source, no parity impact.

- Loading a game no longer freezes the UI and no longer races app launch. The
  default game now auto-loads on the first `didBecomeActive` instead of inside
  `viewDidLoad`, so view setup and audio-session activation finish first; the
  `.rwa` XML parse runs on a background queue (libpd patcher work stays on the
  main thread, the only thread that issues Pd calls); a running game is stopped
  before a new one loads (the 10 ms tick must not read `scenes` mid-parse); a
  spinner shows over the games list during the load and the jump to the Control
  tab happens after the load completes instead of before it starts.
- The Control tab's connect button now shows "Connecting..." while the BLE
  central is scanning for the tracker (new volatile `headTrackerConnecting`
  state set by the scan/connect callbacks), so an absent or switched-off tracker
  is visible as such instead of looking idle.
- The OSC `/register` message now advertises the Player address that actually
  routes to the Creator. The old code scanned interfaces by name (en0, then
  cellular pdp_ip0) and on hotspot topologies advertised the public-facing
  cellular IP, so the Creator sent OSC to the wrong address while file transfer
  (which uses the manually entered Creator IP) kept working. The address is now
  derived by UDP-connecting a socket toward the configured Creator IP and
  reading the kernel's chosen source address back (`getsockname`; no packets
  sent); the interface scan remains as fallback for non-numeric hosts.
- Registering with the Creator should works on the first tap of an app run.
  `F53OSCClient` defaults its host to "localhost" and the Creator address was
  only applied *after* the `/register` send — so a fresh run sent `/dummy` and
  `/register` to the phone itself and the Creator never learned the Player's
  address. The old Control Data tab masked this by re-applying the host on every
  tab appearance combined with operators toggling register twice. The client is
  now pointed at the Creator before anything is sent, and editing the Creator IP
  in Settings updates an already-configured client immediately. The two `/dummy`
  "warm-up" messages that preceded `/register` are removed: the Creator has no
  `/dummy` handler, UDP needs no warm-up, and their only real effect was a
  redundant `stopUpdatingLocation()` side effect.
- Settings: the RWA Creator "IP address" field can now be dismissed, so the
  entered value is stored. The field now uses `.numbersAndPunctuation`
  (a real return key, and a locale-independent `.` instead of the decimal
  pad's locale separator).
- Fix missing audio input (regression of changes to the audioController setup
  to allow bluetooth headphones).

## [1.3.3] - 2026-07-30

### Fixed

- Games no longer have to ship the FABIAN HRTF set. `[rwa_binauralsimple~ 256
  fabian_dir256.txt]` in a game's own Pd patcher resolved its IR file only from
  the game folder, so the 38 MB `fabian_dir256.txt` had to be copied into every
  game that used a dynamic patcher — even though the app bundle already contains
  it. `RwaGameLoop.init` now adds `Bundle.main.resourcePath` to Pd's search path,
  and `vas_library` (`vas_pdmaxobject_read`) resolves IRs via `open_via_path`
  (absolute path → patch directory → search path) instead of always prefixing the
  canvas directory. Games that carry their own copy are unaffected — the game
  folder is still searched first. Mirrored from the same change in RWA Creator;
  both apps compile the same `vas_library` sources.

## [1.3.2] - 2026-07-30

### Added

- Decode the heartbeat's battery voltage (`batt_mv`, §5.3 key 16), added
  in rtk-rover 0.44.0. The field was already on the wire and silently
  ignored by the additive-evolution rule; it now reaches the SQLite store,
  the upload batches, and the Diagnostics tab.

### Changed

- Diagnostics "Battery" row shows the real pack voltage (e.g. `3.90 V
  (3900 mV)`) instead of the "pending firmware" placeholder. No percentage
  is shown: the firmware ships no discharge curve, and a linear mV -> %
  mapping would be invented precision.
- `DeviceHealth` drops the speculative `batt_pct` field (never existed on
  the wire) and treats `batt_mv == 0` as "device could not read the pack",
  keeping the last known voltage rather than displaying a flat battery.

## [1.3.1] - 2026-07-29

### Added

Decode device telemetry from BLE (PROJECT-PLAN §5)

Receive path for the rtk-rover CBOR telemetry feed: subscribe to the
telemetry GATT service (713D0100/0101), reassemble the TX byte stream by
length prefix, decode frames with the §5.3 integer key table, and hand
events to `TelemetryService.recordDeviceEvent`, from here they flow into
the existing SQLite store, uploader, and Diagnostics tab. Heartbeats now
feed `updateFwVersion()`, so the device firmware version reaches the batch
envelope.

- `TelemetryKeys.swift`: §5.3/§5.4 contract mirror of the firmware's
  `telemetry_keys.h` (same key numbers, type ids, CTRL command ids)
- `DeviceTelemetryDecoder.swift`: frame reassembly (frames may span or
  share notifications; desync flushes the buffer, recovers on
  reconnect), minimal RFC 8949 subset decoder, int-key -> field-name
  mapping (unknown types dropped, unknown keys ignored per the additive
  rule), receiver singleton
- `SecondViewController`: discover/subscribe telemetry TX, route its
  binary payloads before the UTF-8 text guard, reset the stream on
  disconnect
- Tests: byte-exact fixtures mirroring the firmware AUnit encoder tests,
  so both ends of the contract pin the same bytes (9 tests)

### Changed

- Restrict GNSS fix updates to device-origin sources to prevent display
  inconsistencies.
- Increase freshness window for RTK coordinates to 9 seconds, relaxing
  the cutoff when experiencing NTRIP connection problems.
- Allow Map to display both RTK and internal location.

## [1.3.0] - 2026-07-27

### Added

- Use modern loggers and separate log messages for triage in debugger
- Added infrastructure/tests for engine parity investigations (see [../docs/engine-parity-tests.md](../docs/engine-parity-tests.md) for details).

### Changed

- Improve/refactor audioController setup to allow bluetooth headphones
- Set the OSC listener port of RWA Player to 8001.
- Internal cleanups: refactored FileManager extension (error handling, access
  modifiers), compacted GameManager, streamlined position assignment.

### Fixed

Engine parity:

- `sendInitValues2Pd`: Reorder the sequence of pd messages and add assetlon,
  assetlat, samplerate, same as in RWA Creator.
- `processAssets()`: Asset activation now follows order of execution in RWA Creator.
- **major**: Allow background assets to update when there are no active assets
  (`sendData2ActiveAssets`). this now works properly in RWA Player, as at
  game-start, FALLBACK state is active.
- `RwaGameLoop.setScene` implementation synchronised with RWA Creator.
- **major**: Behavior change: active assets of the previous state
  are no longer unconditionally ended on every scene transition, they are
  only ended when the new scene activates a fallback state that contains
  assets. Entering a scene with fallback disabled, or with a silent
  (asset-less) fallback, lets running assets play out until a new state is
  triggered. Existing games that rely on cutting audio at scene
  boundaries will sound different.
- The fallback decision is now based on the *new* scene's `fallbackDisabled`
  flag.
- `timeInCurrentState` is reset only when a fallback state is actually
  entered (no-op difference, aligned with the Creator's structure).
- The re-entry latch (`blockUntilRadiusHasBeenLeft`) is now released on the
  state the hero actually occupied, before the scene switch. Previously a
  state left during a scene change could stay latched and never re-trigger,
  since the per-tick geographic unblock only scans the current scene.
- Entering a scene with fallback enabled but no states now logs a warning
  and leaves the hero without a current state, instead of crashing on
  `states[0]`.

Entry conditions:

- Reduced hard-coded enter offset for circular and rectangular scenes and states
  from 6 m to 2 m.
- Fix missing import for scene boundaries: `radius`, `width`, `height`. this
  enables RWA Player to enter circular and rectangular scenes at all (beyond the
  default scene). Also `exitOffset` (hysteresis) is now imported.

## [1.2.0] - 2026-07-24

### Added

Replace the Control Data tab with an actions-only Control tab

- The Control Data tab mixed three unrelated things: settings that the
  Settings tab already duplicated, live operator actions, and read-only
  sensor dumps. It is split along those lines and retired.
- New Control tab (`ControlViewController`, laid out in code and installed
  programmatically like Diagnostics and Settings) keeps only what acts on
  the running app: start/stop, connect headtracker, calibrate north, and
  the output volume — plus a compact scene/state and azimuth readout so the
  operator does not have to switch tabs mid-walk. It takes over the OSC
  receiver duty (/step, /lon, /lat, /currentscene) from
  ControlDataViewController.
- The loaded RWA project's filename titles the status card ("No project
  loaded" until one is picked).
- The status card also shows the WGS84 coordinates driving the walk,
  tagged "(RTK)" while the tracker's RTK fix is the active source, with a
  dot that flashes green each time a fix arrives from the active source
  (RTK timestamp, CoreLocation timestamp, or OSC coordinate change).
- The duplicated settings (Creator IP, headtracker name, heading source,
  inverse elevation, calibrate on start) are gone from the tab; Settings is
  now their only home. "Send GPS to Creator" moved to Settings under RWA
  Creator; it is deliberately session-only and starts off on every launch
  (not persisted). rwaCreator register/unregister is also a
  Settings row now (directly under the Creator IP); the register/OSC-listen
  logic and `getWiFiAddress` moved to a shared `UIViewController` extension
  (RwaUtilities) so the Settings button and the Control tab's resume path
  share one implementation.
- The read-only displays were dropped rather than migrated: azimuth,
  elevation, steps and position are already in Diagnostics, and scene/state
  are on the Map tab.
- The volume slider now starts from the actual `pdGainVal` instead of a
  hardcoded 0.5 that did not match it and jumped the volume on first touch.
- The Control tab is installed at tab index 1, the slot Control Data held,
  so FirstViewController's jump after loading a game still lands on the
  Start button. The storyboard's Control Data scene is dropped at runtime
  (like the Current Scene tab) and left behind as unreachable scaffolding;
  Main.storyboard is not edited.

Add Settings tab, RTK positioning and device identity

- New Settings tab (grouped table, installed programmatically like
  Diagnostics): device ID, headtracker name, GPS source, heading source,
  inverse elevation, calibrate on start, RWA Creator IP, and a default-game
  picker. Values live in the existing UserDefaults keys, so the legacy
  Control Data tab keeps working while its controls migrate over.
- GPS source "RTK tracker" now actually routes the headtracker's RTK
  coordinates into the walk positioning (previously parsed but unused).
  Internal GPS stands by and takes over automatically when the tracker
  delivers no coordinates for 3 s; the switch is visible in Diagnostics
  and in the telemetry "source" field.
- Heading source selection (internal / headtracker) moves to Settings and
  reconnects the tracker (or starts device motion) immediately on change.
- Telemetry device_id is now resolved at upload time: Telemetry.plist
  override (dev) → Settings "Device ID" → headtracker name. DeviceId in
  Telemetry.plist is optional and should be omitted on real devices.

Add live telemetry source: GPS/heading/heartbeat with source attribution

- Sample the app's positioning state at 1 Hz into gnss_fix and heading
  events, plus an app-side heartbeat every 15 s. Events carry an additive
  "source" field (rtk_tracker / ios_gps / osc_sim, headtracker_rtk /
  headtracker / ios_motion) so the backend can tell sensors apart; all
  use the app seq range. Fixes are only emitted on fresh data, so
  dropouts appear as gaps.
- Set soundwalk_id on game load, emit walk_started/walk_stopped, and
  show the active position/heading sources in Diagnostics.

Add prototype RWA Player App icon, as a companion to the RWA Creator icon

### Fixed

Make the Games and Map tabs follow light/dark appearance

- Both storyboard scenes baked in literal white backgrounds (Games also on
  its table view, plus 80% alpha and a near-black caption color). Static
  colors do not adapt, so in dark mode the areas behind the navigation bar
  and the tab bar stayed white while the rest of the app went dark — the
  code-built Control, Diagnostics and Settings tabs were already correct.
- Swapped for adaptive system colors in code (systemBackground /
  secondaryLabel), matching the other tabs. Main.storyboard is left
  untouched.

Fix the Map tab's bottom edge sliding under the tab bar

- The storyboard pinned the map to the deprecated top/bottomLayoutGuides
  *and* to the superview's centerY simultaneously — mutually unsatisfiable,
  so Auto Layout broke one at runtime and centred the map against the full
  view (tab bar included), pushing its lower edge behind the tab bar. The
  bottom constraint was also present twice, and Interface Builder had
  already flagged the frame as misplaced.
- The map is now anchored to the safe area in code (same approach as
  `layoutStatusFields`), so it ends exactly where the tab bar begins and the
  map's own attribution stays visible. Main.storyboard is left untouched.

Make the Map tab's scene/state fields read-only status displays

- The two fields used to open an undismissable keyboard, and typing had no
  effect (they were never wired to anything). Scene and state are driven
  by GPS, so there is nothing to edit: the fields no longer accept
  interaction and are styled with adaptive system colors (translucent
  rounded pills, centered text) that work in light and dark mode.
- Their layout moves from the storyboard into MapViewController: the old
  constraints anchored them to the deprecated topLayoutGuide and made
  their width proportional to the superview's *height*, which oversized
  them on tall devices. They are now two equal-width pills pinned to the
  safe area, so position and appearance live in one place.

### Removed

Remove the synthetic telemetry source

- Drop SyntheticTelemetrySource and the SyntheticSourceEnabled flag from
  Telemetry.plist; the live source now always runs. The synthetic source
  had served to validate the store→batch→upload→dedup pipeline before any
  real producer existed; synthetic dashboard traffic is rwa-backend's
  scripts/fake_data.py's job. Removing the flag also eliminates the risk
  of shipping a device that silently reports fake data.

## [1.1.0] - 2026-07-23

- Fix buffer overflow crash
- Switch vas_library to a maintained fork and migrate it to current upstream
  (ca13905, 582a5b2)
- Adapt the Xcode project to the refactored vas_library (50303d9, e797927,
  569d891, dfc9f10)
- Add consistent versioning, with documentation and script for updating the app version.

### Changed

- vas_library now points at a
  [fork](https://github.com/rnd-hsm-klassik/vas_library) (branch
  `rwa-player-fixes`) instead of upstream. The fork carries the upstream history
  forward from ef59475 (2020-01-23, to which the vas_library subomdule was
  pinned up until now), to 0658616 (2022-07-20, the version pinned by RWA
  Creator); commit by commit - each one build-tested against the app - with
  fixes applied to the commits that introduced them (see Fixed below). This
  should avoid inconsistencies between the app and creator.
- Upstream vas_library now defaults its FFT backend to pffft on non-Apple
  platforms and adds a lock-free threadpool for partitioned convolution; both
  are new nested submodules (`pffft`, `C-Thread-Pool`). The iOS app is
  unaffected: on Apple platforms vas_util.h still selects vDSP/Accelerate
  (the app defines no `VAS_USE_*` override), so pffft.c/pffft_common.c are
  compiled into the target but unused.
- Add the new/refactored vas_library sources to the app target:
  vas_pdmaxobject.c, vas_fir_read.c, vas_thpool_noMalloc.c, vas_threads.c,
  pffft.c, pffft_common.c.
- Drop `PDINSTANCE` from the app's preprocessor defines: the linked libpd-ios.a
  is single-instance and the app uses no multi-instance API. With the newer Pd
  headers the define would make externals reference the non-existent `pd_this`
  symbol.
- Set `ALWAYS_SEARCH_USER_PATHS = NO` so angle-bracket includes no longer search
  user header paths. Previously libmysofa's bundled Windows compat `time.h`
  shadowed the SDK header, breaking `clock_gettime`.
- Read `CFBundleShortVersionString` from the `MARKETING_VERSION`
  build setting instead of a hardcoded value in Info.plist.

### Fixed (in the vas_library fork)

- Fixed null terminator overflow bug in vas_fir_read.c, vas_fir.c, and
  vas_firobject.c (4edef437).
- Replace calls to the removed Pd logging function `error()` with `pd_error()`
  (removed from the Pd API, undefined at link time).
- Remove the bundled `m_pd.h` copies (Pd 0.43/0.51) so all externals compile
  against libpd's own Pd 0.52 header, matching the linked core exactly.
- Add missing `#include <time.h>` for `clock_gettime` / `CLOCK_MONOTONIC` in
  vas_util.c.
- Guard the unused sofa reader (`vas_fir_read_sofa_0Degrees`) and its `mysofa.h`
  include behind `VAS_USE_LIBMYSOFA`; the app loads HRTFs from text files and
  does not link libmysofa.
- Define the previously undeclared `MIN` macro in vas_firobject.c.

## [1.0.4] - 2026-07-22

- Implement game download workflow (10ce2b42)
- Add build and deploy instructions (8da5a501)

### Added

- Introduce ZipExtractor to inflate game archives (stored/deflated, no zip64).
- Add NSAllowsLocalNetworking for HTTP access to RWA Creator.

### Changed

- Wire Fetch Games UI and integrate extractor into DownloadManager.
- Use per-download filenames, a serial delegate queue, and safer
  file handling (zip-slip protection).
