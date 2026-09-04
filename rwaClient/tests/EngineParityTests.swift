//
//  EngineParityTests.swift
//  rwaclientTests
//
//  Phase C of the cross-platform engine-sync plan: replay the shared trace
//  scenarios (tools/trace/scenarios in rwa-creator) against the Swift engine
//  and emit a JSONL trace in the same format as the C++ `rwatrace` harness.
//
//  These tests assert structural invariants of the Swift trace only; the
//  actual parity check is diffing the emitted trace against the rwatrace
//  golden for the same scenario (with the known-divergence allowlist — see
//  docs/ENGINE-PARITY-TESTS.md). Traces are attached to the test result and,
//  when the RWA_TRACE_DIR environment variable is set (pass it from the CLI
//  as TEST_RUNNER_RWA_TRACE_DIR), also written to that directory.
//

import XCTest
@testable import rwa_client

final class EngineParityTests: XCTestCase {

    private func loadScenario(named name: String) throws -> RwaScenario {
        let bundle = Bundle(for: EngineParityTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"),
                                "scenario \(name).json missing from test bundle")
        return try RwaScenario(contentsOf: url)
    }

    /// Fixture games live in the TEST bundle, not the app bundle: the
    /// rwaclientTests "Copy game fixtures" build phase copies each one
    /// nested into Resources/games/<name>/ (keeping its own assets/ folder,
    /// unlike the app's flat rwaGames rsync, so basenames cannot collide
    /// between fixtures). A game directory is named after its .rwa.
    private func gameFixture(named name: String) throws -> (game: String, assets: String) {
        let bundle = Bundle(for: EngineParityTests.self)
        let dir = try XCTUnwrap(bundle.resourcePath, "test bundle has no resources")
            + "/games/" + name
        let game = dir + "/" + name + ".rwa"
        XCTAssertTrue(FileManager.default.fileExists(atPath: game),
                      "game fixture \(name) missing from test bundle")
        return (game, dir + "/assets")
    }

    @discardableResult
    private func runAndExport(scenarioName: String, gameFixture name: String) throws -> [String] {
        let scenario = try loadScenario(named: scenarioName)
        XCTAssertEqual(scenario.schema, "rwa-scenario/1", "unknown scenario schema")

        let fixture = try gameFixture(named: name)
        let runner = ScenarioTraceRunner()
        let trace = runner.run(gamePath: fixture.game,
                               assetPath: fixture.assets,
                               scenario: scenario)

        let text = trace.joined(separator: "\n") + "\n"
        let fileName = scenarioName.replacingOccurrences(of: ".scenario", with: "")
            + ".player.trace.jsonl"

        let outDir = ProcessInfo.processInfo.environment["RWA_TRACE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let outURL = outDir.appendingPathComponent(fileName)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try text.write(to: outURL, atomically: true, encoding: .utf8)
        print("trace written to \(outURL.path)")

        let attachment = XCTAttachment(string: text)
        attachment.name = fileName
        attachment.lifetime = .keepAlways
        add(attachment)

        return trace
    }

    func testSmokeBackgroundScenario() throws {
        let trace = try runAndExport(scenarioName: "smoke-background.scenario",
                                     gameFixture: "rwatest")

        // Initial state event (after the setScene init messages): start scene
        // with its front (fallback) state.
        let firstState = try XCTUnwrap(trace.first { $0.contains("\"ev\":\"state\"") },
                                       "trace contains no state event")
        XCTAssertTrue(firstState.contains("\"scene\":\"Scene 0\""))

        // The background state's asset must have been started...
        XCTAssertTrue(trace.contains { $0.contains("-play\"") && $0.contains("forest.ogg") },
                      "background asset forest.ogg was never started")

        // ...and released again by the injected playfinished at t=8000.
        XCTAssertTrue(trace.contains { $0.contains("\"kind\":\"playFinished\"") && $0.contains("\"tag\":") },
                      "playfinished injection did not resolve a playing tag")
        XCTAssertTrue(hero.backgroundAssets.isEmpty && hero.activeAssets.isEmpty,
                      "assets still active after playfinished")

        // Ticks are the Player's native 10 ms: the injected playfinished lands
        // at t=8000 (tick 800), and no event lies beyond durationMs (tick 1000).
        // Like rwatrace, the file simply ends at the last event.
        XCTAssertTrue(trace.contains { $0.contains("\"kind\":\"playFinished\"") && $0.contains("\"t\":8000") })
        let maxTick = trace.compactMap { line -> Int? in
            guard let range = line.range(of: #""tick":(\d+)"#, options: .regularExpression) else { return nil }
            return Int(line[range].dropFirst(7))
        }.max() ?? 0
        XCTAssertLessThanOrEqual(maxTick, 1000, "event beyond scenario duration")
    }

    /// Playback-mode-dependent spatial data for Pd-patch assets (the
    /// multichannel-patch change, mirrored from the Creator). Expectations
    /// per patch are documented in rwa-creator/tools/trace/README.md:
    /// binaural stereo → 2 channels, binaural mono → 1, binaural stereo with
    /// "headtracker relative to source" off → 1 (raw head data), binaural
    /// 7 channel → 7 at distinct angular offsets.
    /// Float distance / azimuth / elevation chain (mirrored from the Creator's
    /// `calculateRelativeDirection` change). Fixture and expectations:
    /// rwa-creator/tools/trace/spatial/README.md; the C++ trace is checked by
    /// tools/trace/spatial/check_trace.py, this test asserts the same
    /// invariants on the Swift trace.
    func testSpatialEdgeScenario() throws {
        let trace = try runAndExport(scenarioName: "spatial-edge.scenario",
                                     gameFixture: "spatial")

        func tagFor(_ asset: String) throws -> Int {
            let playLine = try XCTUnwrap(trace.first { $0.contains("-play\"") && $0.contains(asset) },
                                         "\(asset) was never started")
            return try XCTUnwrap(tag(ofLine: playLine), "no tag in: \(playLine)")
        }
        /// (t, value) of every `<tag>-<param>` float event; nil value = JSON null (NaN/inf).
        func values(_ tag: Int, _ param: String) -> [(t: Int, val: Double?)] {
            trace.compactMap { line in
                guard line.contains("\"recv\":\"\(tag)-\(param)\""),
                      let tRange = line.range(of: #""t":(\d+)"#, options: .regularExpression),
                      let t = Int(line[tRange].dropFirst(4)) else { return nil }
                guard let vRange = line.range(of: #""val":(null|-?[\d.eE+-]+)"#, options: .regularExpression) else { return nil }
                let raw = String(line[vRange].dropFirst(6))
                return (t, raw == "null" ? nil : Double(raw))
            }
        }
        func wrap(_ x: Double) -> Double { let r = fmod(x, 360); return r < 0 ? r + 360 : r }

        let relative = ["horizon.pd", "elevated.pd", "onspot0.pd", "onspot5.pd",
                        "mindist.pd", "fixedazi.pd", "fixeddist.pd"]
        for asset in relative + ["rawhead.pd"] {
            let tag = try tagFor(asset)
            for param in ["distance1", "azimuth1", "elevation1"] {
                let vals = values(tag, param)
                XCTAssertFalse(vals.isEmpty, "\(asset): \(param) never sent")
                XCTAssertFalse(vals.contains { $0.val == nil || !$0.val!.isFinite },
                               "\(asset): non-finite \(param) on the wire")
            }
            XCTAssertTrue(values(tag, "azimuth1").allSatisfy { $0.val! >= 0 && $0.val! < 360 },
                          "\(asset): azimuth outside [0, 360)")
            XCTAssertTrue(values(tag, "distance1").allSatisfy { $0.val! >= 0 }, "\(asset): negative distance")
        }
        for asset in relative {
            XCTAssertTrue(values(try tagFor(asset), "elevation1").allSatisfy { abs($0.val!) <= 90 },
                          "\(asset): relative elevation outside [-90, 90]")
        }

        // Raw-head patch echoes the wrapped yaw (12.5, -45 -> 315, 725 -> 5) and the
        // unclamped, wrapped pitch (90, -95, 120, -150).
        let raw = try tagFor("rawhead.pd")
        for expected in [12.5, 315.0, 5.0] {
            XCTAssertTrue(values(raw, "azimuth1").contains { abs($0.val! - expected) < 1e-3 },
                          "rawhead.pd: head yaw \(expected) never echoed")
        }
        for expected in [90.0, -95.0, 120.0, -150.0] {
            XCTAssertTrue(values(raw, "elevation1").contains { abs($0.val! - expected) < 1e-3 },
                          "rawhead.pd: head pitch \(expected) never echoed")
        }

        // Horizon source dead ahead: azimuth 180 at pitch 0 (t < 1000), flipped by
        // 180 at pitch 120 (6000 <= t < 7000) and -150 (7000 <= t < 8000).
        let horizon = try tagFor("horizon.pd")
        let ahead = try XCTUnwrap(values(horizon, "azimuth1").first { $0.t < 1000 }?.val)
        XCTAssertEqual(ahead, 180, accuracy: 1e-3)
        for (lo, hi) in [(6000, 7000), (7000, 8000)] {
            let flipped = try XCTUnwrap(values(horizon, "azimuth1").first { $0.t >= lo && $0.t < hi }?.val)
            XCTAssertEqual(wrap(flipped - ahead), 180, accuracy: 1e-3, "horizon.pd: no 180 flip past vertical")
        }
        XCTAssertEqual(try XCTUnwrap(values(horizon, "elevation1").first { $0.t >= 6000 && $0.t < 7000 }?.val),
                       -60, accuracy: 1e-3)

        // Sub-metre distance after the 0.5 m move at t=8000, and the fixed / min values.
        XCTAssertEqual(try XCTUnwrap(values(try tagFor("onspot0.pd"), "distance1").last?.val), 0.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(values(try tagFor("mindist.pd"), "distance1").first?.val), 3, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(values(try tagFor("fixeddist.pd"), "distance1").first?.val), 2.5, accuracy: 1e-3)
        XCTAssertTrue(values(try tagFor("fixedazi.pd"), "azimuth1").allSatisfy { abs($0.val! - 45.5) < 1e-3 },
                      "fixedazi.pd: fixed orientation must ignore the head")
        XCTAssertEqual(try XCTUnwrap(values(try tagFor("onspot5.pd"), "elevation1").first?.val), 90, accuracy: 1e-3)
    }

    func testPdModesScenario() throws {
        let trace = try runAndExport(scenarioName: "pdmodes.scenario",
                                     gameFixture: "pdmodes")

        let expectations: [(asset: String, channels: Int)] = [
            ("stereopatch.pd", 2),
            ("monopatch.pd", 1),
            ("rawpatch.pd", 1),
            ("sevenpatch.pd", 7),
        ]

        for (asset, channels) in expectations {
            // The "<tag>-play" init symbol binds tag to asset.
            let playLine = try XCTUnwrap(
                trace.first { $0.contains("-play\"") && $0.contains(asset) },
                "\(asset) was never started")
            let tag = try XCTUnwrap(tag(ofLine: playLine), "no tag in: \(playLine)")

            // numchannels init value (sent before -play, so match by tag).
            XCTAssertTrue(trace.contains {
                $0.contains("\"recv\":\"\(tag)-numchannels\"") && $0.contains("\"val\":\(channels)")
            }, "\(asset): expected numchannels \(channels)")

            // Per-tick fan-out streams channels 1...N and nothing beyond.
            for channel in 1...channels {
                XCTAssertTrue(trace.contains { $0.contains("\"recv\":\"\(tag)-azimuth\(channel)\"") },
                              "\(asset): azimuth\(channel) never sent")
            }
            XCTAssertFalse(trace.contains { $0.contains("\"recv\":\"\(tag)-azimuth\(channels + 1)\"") },
                           "\(asset): unexpected azimuth\(channels + 1)")
        }

        // The raw-head patch gets the head azimuth verbatim: 90 after the
        // t=1000 azimuth input.
        let rawPlayLine = try XCTUnwrap(trace.first { $0.contains("-play\"") && $0.contains("rawpatch.pd") })
        let rawTag = try XCTUnwrap(tag(ofLine: rawPlayLine))
        XCTAssertTrue(trace.contains {
            $0.contains("\"recv\":\"\(rawTag)-azimuth1\"") && $0.contains("\"val\":90")
        }, "rawpatch.pd: head azimuth 90 never sent verbatim")

        // The 7-channel patch's channels sit at distinct angular offsets:
        // their bearings must not all coincide within one tick.
        let sevenPlayLine = try XCTUnwrap(trace.first { $0.contains("-play\"") && $0.contains("sevenpatch.pd") })
        let sevenTag = try XCTUnwrap(tag(ofLine: sevenPlayLine))
        let firstAzimuths: [String] = (1...7).compactMap { channel in
            trace.first { $0.contains("\"recv\":\"\(sevenTag)-azimuth\(channel)\"") }
                 .flatMap { line in
                     line.range(of: #""val":-?\d+(\.\d+)?"#, options: .regularExpression)
                         .map { String(line[$0]) }
                 }
        }
        XCTAssertEqual(firstAzimuths.count, 7)
        XCTAssertGreaterThan(Set(firstAzimuths).count, 1,
                             "7-channel offsets collapsed: all channels share one bearing")
    }

    /// Leading "<tag>-" of the line's receiver field.
    private func tag(ofLine line: String) -> Int? {
        guard let start = line.range(of: #""recv":""#)?.upperBound else {
            return nil
        }
        let digits = line[start...].prefix(while: { $0.isNumber })
        return digits.isEmpty ? nil : Int(digits)
    }

    /// The harness itself must be deterministic: two in-process replays of the
    /// same scenario produce byte-identical traces. (Patcher $0 tags advance
    /// between runs, so compare with tags canonicalized away via the asset
    /// column and receiver suffix.)
    func testScenarioReplayIsDeterministic() throws {
        let scenario = try loadScenario(named: "smoke-background.scenario")
        let fixture = try gameFixture(named: "rwatest")

        let first = ScenarioTraceRunner().run(gamePath: fixture.game,
                                              assetPath: fixture.assets,
                                              scenario: scenario)
        let second = ScenarioTraceRunner().run(gamePath: fixture.game,
                                               assetPath: fixture.assets,
                                               scenario: scenario)

        XCTAssertEqual(first.map(canonicalized), second.map(canonicalized))
    }

    /// Replace "<tag>-suffix" receivers with "#-suffix" and drop the tag field
    /// of playFinished echoes, so traces from different pool states compare.
    private func canonicalized(_ line: String) -> String {
        var result = line.replacingOccurrences(of: #""recv":"\d+-"#,
                                               with: ##""recv":"#-"##,
                                               options: .regularExpression)
        result = result.replacingOccurrences(of: #""tag":\d+"#,
                                             with: #""tag":0"#,
                                             options: .regularExpression)
        return result
    }
}
