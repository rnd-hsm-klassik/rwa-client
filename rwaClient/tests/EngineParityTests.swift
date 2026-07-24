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

    /// The .rwa games ship flat in the app bundle (the rwaGames rsync build
    /// phase); resolve a scenario's "rwatest/rwatest.rwa" style reference by
    /// basename, like the Player itself does.
    private func gamePath(forBasename basename: String) throws -> String {
        let name = (basename as NSString).deletingPathExtension
        return try XCTUnwrap(Bundle.main.path(forResource: name, ofType: "rwa"),
                             "game \(basename) missing from host app bundle")
    }

    @discardableResult
    private func runAndExport(scenarioName: String, gameBasename: String) throws -> [String] {
        let scenario = try loadScenario(named: scenarioName)
        XCTAssertEqual(scenario.schema, "rwa-scenario/1", "unknown scenario schema")

        let runner = ScenarioTraceRunner()
        let trace = runner.run(gamePath: try gamePath(forBasename: gameBasename),
                               assetPath: Bundle.main.resourcePath!,
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
                                     gameBasename: "rwatest.rwa")

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

    /// The harness itself must be deterministic: two in-process replays of the
    /// same scenario produce byte-identical traces. (Patcher $0 tags advance
    /// between runs, so compare with tags canonicalized away via the asset
    /// column and receiver suffix.)
    func testScenarioReplayIsDeterministic() throws {
        let scenario = try loadScenario(named: "smoke-background.scenario")
        let game = try gamePath(forBasename: "rwatest.rwa")
        let assetPath = Bundle.main.resourcePath!

        let first = ScenarioTraceRunner().run(gamePath: game, assetPath: assetPath, scenario: scenario)
        let second = ScenarioTraceRunner().run(gamePath: game, assetPath: assetPath, scenario: scenario)

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
