# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- vas_library switches its FFT backend from Apple vDSP to pffft and adds a
  lock-free threadpool for partitioned convolution; both are new nested
  submodules (`pffft`, `C-Thread-Pool`).
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
