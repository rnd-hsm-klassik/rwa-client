//
//  TeardownTests.swift
//  rwaclientTests
//
//  The two-phase stop's silent phase B: resetAllPatchers() must complete the
//  release protocol ("-free" bang, "-fadeouttime 0", "-end" bang) for every
//  pooled patcher and clear its busy flag, so no pending [delay] survives a
//  stop and fires into the next run (see the teardown port in CHANGELOG.md,
//  mirrored from RwaRuntime::resetAllPatchers in the Creator).
//
//  Uses PdBaseRecorder, so no message reaches Pd; the patcher tags are real
//  $0 values from the app-hosted patcher pools.
//

import XCTest
@testable import rwa_client

final class TeardownTests: XCTestCase {

    // Closures because [pdPatcher] is a value type: reading through them
    // observes the live pools, not a copy taken before the reset.
    private let pools: [(name: String, pool: () -> [pdPatcher])] = [
        ("monoPatchers", { rwagameloop.monoPatchers }),
        ("monoPatchersOgg", { rwagameloop.monoPatchersOgg }),
        ("stereoPatchers", { rwagameloop.stereoPatchers }),
        ("stereoPatchersOgg", { rwagameloop.stereoPatchersOgg }),
        ("binauralMonoPatchers_fabian", { rwagameloop.binauralMonoPatchers_fabian }),
        ("binauralMonoPatchersOgg_fabian", { rwagameloop.binauralMonoPatchersOgg_fabian }),
        ("binauralStereoPatchers_fabian", { rwagameloop.binauralStereoPatchers_fabian }),
        ("binauralStereoPatchersOgg_fabian", { rwagameloop.binauralStereoPatchersOgg_fabian }),
        ("binaural5ChannelPatchers_fabian", { rwagameloop.binaural5ChannelPatchers_fabian }),
        ("binaural7ChannelPatchers_fabian", { rwagameloop.binaural7ChannelPatchers_fabian }),
    ]

    func testResetAllPatchersCompletesReleaseProtocolForEveryPool() {
        // Materialize the pools (lazy global) before recording, and mark one
        // patcher busy to prove the sweep clears flags.
        rwagameloop.monoPatchers[0].isBusy = true

        var messages: [PdBaseRecorder.Message] = []
        PdBaseRecorder.shared.start { messages.append($0) }
        rwagameloop.resetAllPatchers()
        PdBaseRecorder.shared.stop()

        var frees = Set<String>(), fades = Set<String>(), ends = Set<String>()
        for m in messages {
            if m.receiver.hasSuffix("-free"), m.kind == .bang { frees.insert(m.receiver) }
            if m.receiver.hasSuffix("-fadeouttime"), m.kind == .float, m.value == 0 { fades.insert(m.receiver) }
            if m.receiver.hasSuffix("-end"), m.kind == .bang { ends.insert(m.receiver) }
        }

        for (name, pool) in pools {
            for patcher in pool() {
                let tag = PdBase.dollarZero(forFile: patcher.patcherTag)
                XCTAssertTrue(frees.contains("\(tag)-free"), "\(name) tag \(tag): no -free bang")
                XCTAssertTrue(fades.contains("\(tag)-fadeouttime"), "\(name) tag \(tag): no zero-length fade")
                XCTAssertTrue(ends.contains("\(tag)-end"), "\(name) tag \(tag): no -end bang")
                XCTAssertFalse(patcher.isBusy, "\(name) tag \(tag): busy flag survived the reset")
            }
        }
    }
}
