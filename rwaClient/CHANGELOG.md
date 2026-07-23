# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Add live telemetry source: GPS/heading/heartbeat with source attribution

- Sample the app's positioning state at 1 Hz into gnss_fix and heading
  events, plus an app-side heartbeat every 15 s. Events carry an additive
  "source" field (rtk_tracker / ios_gps / osc_sim, headtracker_rtk /
  headtracker / ios_motion) so the backend can tell sensors apart; all
  use the app seq range. Fixes are only emitted on fresh data, so
  dropouts appear as gaps.
- Set soundwalk_id on game load, emit walk_started/walk_stopped, and
  show the active position/heading sources in Diagnostics.

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
