# Engine parity tests (Phase C of the cross-platform sync plan)

The Swift game engine in this app (`RwaGameLoop.swift`) is a hand-mirrored
port of the Creator's C++ runtime (`rwa-creator/src/rwaruntime.cpp`). Keeping
the two in sync is done behaviorally, by **golden-trace differential
testing**: the same scenario script is replayed against both engines and the
resulting event traces are diffed.

- Phase A (engine walkthrough, known divergences):
  `rwa-creator/docs/engine-runtime-investigation.md`
- Phase B (headless C++ harness `rwatrace`): `rwa-creator/tools/trace/`
- **Phase C (this repo): the Swift side of the trace pipeline** — an XCTest
  target that replays the shared scenarios against the real `RwaGameLoop` and
  emits a trace in the same JSONL format as `rwatrace`.

## Layout

```
rwaClient/tests/
├── PdBaseRecorder.swift        # link-time-fake analogue: swizzles PdBase sends
├── ScenarioRunner.swift        # scenario replay + JSONL trace writer
├── EngineParityTests.swift     # XCTest entry points
├── rwaclientTests-Bridging-Header.h
└── scenarios/
    └── smoke-background.scenario.json   # mirror of rwa-creator/tools/trace/scenarios/
```

The `rwaclientTests` unit-test target is **hosted in rwa-client.app** (the
engine is not a framework; it lives in the app module and is reached via
`@testable import rwa_client`). The host app fully launches before tests run —
that is wanted: the `rwagameloop` global needs the real libpd patcher pools,
which need `PdAudioController` and the bundled `.pd` patches.

## How it works

### PdBaseRecorder — the fake_libpd analogue

`rwatrace` replaces libpd at link time (`fake_libpd.cpp`): every
`libpd_float/bang/symbol` is recorded, nothing real plays, and scenarios
inject `playfinished` bangs. The app can't do link-time replacement (the
engine and libpd live in the same binary as the tests' host), so the recorder
swizzles instead. `RwaGameLoop` reaches Pd through exactly four `PdBase`
class methods:

| selector | note |
|---|---|
| `sendFloat:toReceiver:` | |
| `sendDouble:toReceiver:` | app-local category (`PdBase_Extension.m`) that forwards to `libpd_float`, i.e. **truncates to float** — the recorder reproduces the truncation so values match the C++ trace |
| `sendBangToReceiver:` | |
| `sendSymbol:toReceiver:` | |

While a scenario runs, these four are replaced with record-only
implementations (restored afterwards). Consequences, mirroring the C++ fake:

- no message reaches Pd → no patch starts playing → **no real
  `-playfinished` can ever fire**; scenarios inject them deterministically;
- everything else stays real: `PdBase.openFile` / `dollarZeroForFile` still
  run, so patcher tags are genuine Pd `$0` values (canonicalized away when
  diffing, via the tag→asset mapping learned from the `"<tag>-play"` symbol).

### ScenarioRunner — the rwatracemain analogue

Replays a `rwa-scenario/1` JSON (same schema as Phase B, see
`rwa-creator/tools/trace/README.md`) at the Player's **native 10 ms tick**:

1. Setup mirrors the app's load path plus `rwatracemain`'s order: reset the
   shared `hero` globals, `RwaImport().readRwa(game)`,
   `rwagameloop.resetGame()`, `initDynamicPatchers()`, start recording, then
   `setScene(startScene)` (whose background-state asset init is the first
   recorded traffic, exactly like the C++ harness).
2. Each tick: apply due timeline inputs (GPS → `hero.coordinates`,
   azimuth/elevation → `hero` + the module globals, step → `stepCount`,
   `playFinished` → `rwagameloop.receiveBang(fromSource: "<tag>-playfinished")`,
   the queued-bang path's delegate), then `rwagameloop.updateGameState()`,
   then poll `hero.currentScene`/`currentState` for transitions.
3. Trace lines use the same event shapes as `rwatrace`
   (`{"ev":"pd"|"state"|"input",…,"t":…,"tick":…}`), with keys sorted
   alphabetically and integral numbers written without decimals to match
   `QJsonDocument::Compact` output.

Time is tick-accumulated in the engine (`setEntityState` adds
`schedulerRate/1000` per call); no wall clock is involved, so replays are
deterministic. The whole scenario runs synchronously on the main thread with
the run loop blocked, so no CoreLocation/CoreMotion/BLE callback from the
hosting app can mutate `hero` mid-run.

## Running

```
cd rwaClient
xcodebuild test -scheme rwaclient \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -resultBundlePath /tmp/parity.xcresult
xcrun xcresulttool export attachments \
    --path /tmp/parity.xcresult --output-path /tmp/rwa-traces
```

Each test attaches its `<scenario>.player.trace.jsonl` to the result bundle
(`lifetime = .keepAlways`); the `xcresulttool export attachments` step dumps
them to plain files (see `manifest.json` there for the human-readable
names). The runner also honors an `RWA_TRACE_DIR` environment variable and
writes traces straight to that directory — but note that
`TEST_RUNNER_RWA_TRACE_DIR=…` on the `xcodebuild` command line did **not**
propagate into the hosted test process on Xcode 16.2 here; set the variable
via the scheme's test action if you want direct file output. The attachment
route always works. The C++ counterpart:

```
./build/cmake-debug/rwatrace --game rwa-client/rwaGames/rwatest/rwatest.rwa \
    --scenario tools/trace/scenarios/smoke-background.scenario.json \
    --out smoke-background.creator.trace.jsonl
```

## Diffing the two traces

Not byte-diffable as-is — canonicalize first, with tolerances:

- **Patcher tags** differ (C++ fake counts from 1001, iOS uses real `$0`s
  that advance across in-process runs): compare via the `asset` column and
  the receiver suffix (`-gain`, `-play`, …), not the numeric tag.
- **Tick rate**: Creator 25 ms vs Player 10 ms — compare on the `t` (ms)
  axis, and expect input-application times to quantize differently.
- **Ordering within a tick**: `hero.activeAssets`/`backgroundAssets` are
  Swift `Dictionary`s (arbitrary iteration order) vs C++ `std::map` (sorted
  by uniqueId); sort per-tick message groups before diffing.
- **Expected content diffs** = the known divergences from Phase A
  (`engine-runtime-investigation.md` §Divergences): per-tick send set
  (`-gain/-lon/-lat` every tick in C++ vs init-only/PD-only on iOS), the ~1 s
  state-evaluation gate on iOS, patcher pool sizes, `-playfinished` handling
  details (iOS also sends `<tag>-gain 0` on release). These get triaged into
  intentional (allowlist) vs bug (fix), then goldens are frozen (Phase D).

## Scenario mirroring

Scenario files are copied verbatim from
`rwa-creator/tools/trace/scenarios/` into `rwaClient/tests/scenarios/`.
Until Phase D adds a checksum guard to CI, keep them in sync by hand:

```
shasum -a 256 rwaClient/tests/scenarios/*.json ../rwa-creator/tools/trace/scenarios/*.json
```

The `.rwa` games referenced by scenarios need no mirroring: the app's rsync
build phase already ships everything under `rwaGames/` **flat** into the app
bundle (`rwatest.rwa` and its assets sit next to each other in
`Resources/`), and the tests resolve games by basename from the host bundle.

## Findings made while building this (Phase C notes)

- The engine's entire Pd surface really is the four send selectors above
  plus `openFile`/`closeFile`/`dollarZeroForFile` and the `PdDispatcher`
  `-playfinished` subscription — no other side channel to audio exists, so
  swizzling those four is a complete seam.
- `sendDouble:toReceiver:` narrows to `float` before hitting libpd, and the
  C++ engine sends `float` throughout; **both engines emit float precision**,
  so traces can be compared with float (not double) tolerance.
- The `rwagameloop` global is lazy: in a plain app session with no default
  game it is first constructed on user action; the runner forces construction
  before recording so the ~200 `PdBase.openFile` pool setups (and their
  dispatcher registrations) don't pollute the trace.
- `RwaGameLoop.setScene` posts `NotificationCenter` notifications
  ("Redraw Map"/"Update Scene"/"Update State") that run synchronously into
  the live UI; harmless on the main thread, but one more reason the runner
  must not run scenarios from a background queue.
- Injected `playFinished` events reuse the production delegate path
  (`receiveBang(fromSource:)`), which on iOS also zeroes the patcher gain and
  releases the pool slot — an extra `<tag>-gain 0` pd event relative to the
  C++ trace (part of the known-divergence allowlist).
- Test isolation caveat: the engine state is all module globals (`hero`,
  `scenes`, `fullAssetPath`, `azimuth`, …). The runner resets what the engine
  reads, but tests must not run in parallel and cannot assume a pristine app
  (the host app has already loaded its UI and may have imported a default
  game before the first test runs — the runner's re-import replaces it).
- **Empirical confirmation of the Phase A "early return" divergence:** in the
  smoke scenario (background asset only, `activeAssets` stays empty) the
  Swift trace contains **zero per-tick pd sends** — only the init block at
  tick 0, input echoes, and the release messages after the injected
  playfinished. `sendData2ActiveAssets` returns before touching
  `backgroundAssets` when `activeAssets.isEmpty`, so background assets get
  no positional updates at all on iOS; the C++ engine streams
  `-gain/-lon/-lat/-distance/-azimuth/-elevation` to them every 25 ms tick.
  For background-heavy walks this is the biggest behavioral gap the diff
  will show.

## Observed smoke trace (excerpt, 2026-07)

```
{"ev":"pd","recv":"1132-gain","t":0,"tick":0,"val":0.5}
{"ev":"pd","recv":"1132-playheadposition","t":0,"tick":0,"val":0}
…full init block (damping, offset, loop, fades, crossfades)…
{"asset":"forest.ogg","ev":"pd","recv":"1132-play","sym":"…/rwa-client.app/forest.ogg","t":0,"tick":0}
{"ev":"state","scene":"Scene 0","state":"FALLBACK","t":0,"tick":0}
{"ev":"input","kind":"pos","lat":47.28877782,"lon":7.94604957,"t":10,"tick":1}
…
{"asset":"forest.ogg","ev":"input","kind":"playFinished","t":8000,"tag":1132,"tick":800}
{"asset":"forest.ogg","ev":"pd","recv":"1132-gain","t":8000,"tick":800,"val":0}
```

Note the trailing `-gain 0`: the iOS release path zeroes the patcher gain on
playfinished (C++ only frees the patcher) — a known, intentional-looking
divergence for the allowlist. Also note the double `-gain` in the init block:
`startBackgroundState` sends gain once itself and once via
`sendInitValues2Pd` — background assets only, worth triaging.
