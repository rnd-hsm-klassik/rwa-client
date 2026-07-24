//
//  ScenarioRunner.swift
//  rwaclientTests
//
//  Swift counterpart of rwa-creator's tools/trace/rwatracemain.cpp: replays a
//  shared "rwa-scenario/1" JSON script (GPS positions, head orientation,
//  steps, playfinished events) against the real RwaGameLoop at the Player's
//  native 10 ms tick and produces a JSONL trace of every pd message plus
//  every scene/state transition, in the same format as the C++ harness so the
//  two traces can be diffed.
//
//  Determinism notes:
//  - Time is tick-accumulated (setEntityState adds schedulerRate/1000 per
//    tick); no wall clock is involved.
//  - PdBaseRecorder suppresses all real Pd sends, so nothing plays and no
//    real -playfinished can arrive; scenarios inject them via
//    rwagameloop.receiveBang(fromSource:), the queued-bang path's delegate.
//  - hero.activeAssets / backgroundAssets are Swift Dictionaries keyed by
//    UUID: iteration order (and therefore per-tick message order across
//    multiple simultaneously-active assets) is arbitrary, unlike the C++
//    std::map ordering. Trace diffing must canonicalize order within a tick.
//

import Foundation
import CoreLocation
@testable import rwa_client

/// Parsed "rwa-scenario/1" file. Timeline entries stay dynamically typed
/// (each entry mixes optional keys), matching the C++ reader.
struct RwaScenario {
    let schema: String
    let startScene: String
    let durationMs: Int
    let timeline: [[String: Any]]

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "RwaScenario", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "scenario root is not an object"])
        }
        schema = object["schema"] as? String ?? ""
        startScene = object["startScene"] as? String ?? ""
        durationMs = (object["durationMs"] as? NSNumber)?.intValue ?? 60000
        timeline = object["timeline"] as? [[String: Any]] ?? []
    }
}

final class ScenarioTraceRunner {

    private(set) var traceLines: [String] = []

    private var currentTick = 0
    private var currentTimeMs = 0

    // patcherTag -> asset basename, learned from the "<tag>-play" symbol
    private var tagToAsset: [Int: String] = [:]
    // asset basename -> most recent tag playing it (for playfinished injection)
    private var lastTagForAsset: [String: Int] = [:]

    /// Replays the scenario and returns the trace lines. Must run on the main
    /// thread: with the run loop blocked, no CoreLocation/CoreMotion/BLE
    /// callback can interleave and mutate hero mid-run.
    func run(gamePath: String, assetPath: String, scenario: RwaScenario) -> [String] {
        precondition(Thread.isMainThread, "scenario must run on the main thread")
        traceLines.removeAll()
        tagToAsset.removeAll()
        lastTagForAsset.removeAll()
        currentTick = 0
        currentTimeMs = 0

        setUpEngine(gamePath: gamePath, assetPath: assetPath)

        PdBaseRecorder.shared.start { [weak self] message in
            self?.recordPdMessage(message)
        }
        defer { PdBaseRecorder.shared.stop() }

        // Mirrors rwatracemain: engine setup ends with setScene(startScene),
        // whose background-state asset init is the first recorded traffic.
        let startScene = scenes.first(where: { $0.name == scenario.startScene }) ?? scenes[0]
        rwagameloop.setScene(scene: startScene)

        var lastSceneName = hero.currentScene?.name ?? ""
        var lastStateName = hero.currentState?.stateName ?? ""
        writeEvent(["ev": "state", "scene": lastSceneName, "state": lastStateName])

        let totalTicks = scenario.durationMs / Int(schedulerRate)
        var timelineIndex = 0

        for tick in 1...totalTicks {
            currentTick = tick
            currentTimeMs = tick * Int(schedulerRate)

            while timelineIndex < scenario.timeline.count,
                  ((scenario.timeline[timelineIndex]["t"] as? NSNumber)?.intValue ?? 0) <= currentTimeMs {
                apply(input: scenario.timeline[timelineIndex])
                timelineIndex += 1
            }

            rwagameloop.updateGameState()

            let sceneName = hero.currentScene?.name ?? ""
            let stateName = hero.currentState?.stateName ?? ""
            if sceneName != lastSceneName || stateName != lastStateName {
                writeEvent(["ev": "state", "scene": sceneName, "state": stateName,
                            "prevScene": lastSceneName, "prevState": lastStateName])
                lastSceneName = sceneName
                lastStateName = stateName
            }
        }

        return traceLines
    }

    // MARK: - Engine setup (mirrors rwatracemain.cpp's pre-loop block)

    private func setUpEngine(gamePath: String, assetPath: String) {
        // Quiesce whatever the hosting app session left behind on the shared
        // globals before re-importing: the runner owns hero for the duration.
        hero.activeAssets.removeAll()
        hero.backgroundAssets.removeAll()
        hero.assets2Unblock.removeAll()
        hero.visitedStates.removeAll()
        hero.coordinates = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        hero.azimuth = 0
        hero.elevation = 0
        hero.timeInCurrentState = 0
        hero.timeInCurrentScene = 0
        hero.timeSinceLastGpsUpdate = 0
        azimuth = 0
        elevation = 0
        step = 0
        lastStep = stepCount   // suppress a spurious -step bang on the first tick

        fullAssetPath = assetPath

        // Force construction of the lazy global before recording: the ctor
        // opens the patcher pools (real PdBase.openFile) and registers the
        // -playfinished dispatcher sources.
        _ = rwagameloop

        RwaImport().readRwa(gamePath)          // fills `scenes`, hero.loadGameScript()
        rwagameloop.resetGame()                // unblock states/assets, reset playheads
        rwagameloop.initDynamicPatchers()      // open per-asset PD patches (asset type PD)
    }

    // MARK: - Scenario inputs

    private func apply(input: [String: Any]) {
        if let pos = input["pos"] as? [String: Any] {
            let lon = (pos["lon"] as? NSNumber)?.doubleValue ?? 0
            let lat = (pos["lat"] as? NSNumber)?.doubleValue ?? 0
            hero.coordinates = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            hero.timeSinceLastGpsUpdate = 0
            writeEvent(["ev": "input", "kind": "pos", "lon": lon, "lat": lat])
        }
        if let value = (input["azimuth"] as? NSNumber)?.intValue {
            hero.azimuth = value
            azimuth = value    // module global, read for non-source-relative PD assets
            writeEvent(["ev": "input", "kind": "azimuth", "value": value])
        }
        if let value = (input["elevation"] as? NSNumber)?.intValue {
            hero.elevation = value
            elevation = value
            writeEvent(["ev": "input", "kind": "elevation", "value": value])
        }
        if (input["step"] as? NSNumber)?.boolValue == true {
            stepCount += 1     // sendData2Asset banks -step when stepCount != lastStep
            hero.stepCount = stepCount
            step = 1
            writeEvent(["ev": "input", "kind": "step"])
        }
        if let playFinished = input["playFinished"] as? [String: Any] {
            let asset = playFinished["asset"] as? String ?? ""
            if let tag = lastTagForAsset[asset] {
                writeEvent(["ev": "input", "kind": "playFinished", "asset": asset, "tag": tag])
                // Production path: Pd's queued "<tag>-playfinished" bang lands in
                // RwaGameLoop.receiveBang via PdDispatcher. Deliver it directly.
                rwagameloop.receiveBang(fromSource: "\(tag)-playfinished")
            } else {
                writeEvent(["ev": "input", "kind": "playFinished", "asset": asset,
                            "error": "asset not playing"])
            }
        }
    }

    // MARK: - Trace recording

    private func recordPdMessage(_ message: PdBaseRecorder.Message) {
        var event: [String: Any] = ["ev": "pd", "recv": message.receiver]

        switch message.kind {
        case .float:
            event["val"] = message.value
        case .bang:
            event["bang"] = true
        case .symbol:
            event["sym"] = message.symbol ?? ""
        }

        if let tag = tagOfReceiver(message.receiver) {
            if message.kind == .symbol, message.receiver.hasSuffix("-play"), let path = message.symbol {
                let asset = (path as NSString).lastPathComponent
                tagToAsset[tag] = asset
                lastTagForAsset[asset] = tag
            }
            if let asset = tagToAsset[tag] {
                event["asset"] = asset
            }
        }

        writeEvent(event)
    }

    private func tagOfReceiver(_ receiver: String) -> Int? {
        guard let dash = receiver.firstIndex(of: "-"), dash != receiver.startIndex else {
            return nil
        }
        guard let tag = Int(receiver[..<dash]), tag > 0 else {
            return nil
        }
        return tag
    }

    // MARK: - JSONL encoding (matches QJsonDocument::Compact: keys sorted
    // alphabetically, no whitespace, integral doubles written without decimals)

    private func writeEvent(_ object: [String: Any]) {
        var event = object
        event["t"] = currentTimeMs
        event["tick"] = currentTick
        let parts = event.keys.sorted().map { key in
            "\"\(escape(key))\":\(encode(event[key]!))"
        }
        traceLines.append("{" + parts.joined(separator: ",") + "}")
    }

    private func encode(_ value: Any) -> String {
        switch value {
        case let flag as Bool where type(of: value) == Bool.self:
            return flag ? "true" : "false"
        case let int as Int:
            return String(int)
        case let double as Double:
            if double.rounded() == double && abs(double) < 1e15 {
                return String(Int64(double))
            }
            return String(double)   // Swift shortest round-trip, like Qt6
        case let string as String:
            return "\"\(escape(string))\""
        default:
            return "\"\(escape(String(describing: value)))\""
        }
    }

    private func escape(_ string: String) -> String {
        var out = ""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
