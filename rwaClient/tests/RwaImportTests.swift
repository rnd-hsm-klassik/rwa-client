//
//  RwaImportTests.swift
//  rwaclientTests
//
//  The .rwa importer must read element text the way the Creator's
//  QXmlStreamReader::readElementText() does: fully decoded, in one piece.
//  Foundation's XMLParser splits character data at every entity reference,
//  so "A&amp;B_performance" arrives as "A", "&", "B_performance"; applying
//  those chunks directly stored three required states and a truncated hint
//  state, which locked the state forever (see CHANGELOG.md).
//

import XCTest
@testable import rwa_client

final class RwaImportTests: XCTestCase {

    private var gameFile: URL!

    override func setUpWithError() throws {
        let rwa = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE rwa>
        <rwa version="1.0">
            <game currentscene="Scene 0"/>
            <scene currentstate="FALLBACK" name="Scene 0" lon="7.58652896" lat="47.55512934" zoom="16" numberofstates="3" areatype="1" radius="200" width="200" height="200" level="-1" exitoffset="0" fallbackdisabled="0" minstaytime="4">
                <corners/>
                <exitoffsetcorners/>
                <state name="FALLBACK" type="1" areatype="1" zoom="18" assetsfollowstate="1" defaultplaybacktype="3" lockposition="0" statewithinstate="0" leaveafterassetsfinish="0" leaveonlyafterassetsfinish="0" enteronlyonce="0" timeout="0" minstaytime="0">
                    <enterconditions>
                        <gps isgps="0" lon="7.58652896" lat="47.55512934" radius="10" width="-1" height="-1" exitoffset="0"/>
                        <requiredstates/>
                        <corners/>
                        <exitoffsetcorners/>
                    </enterconditions>
                    <actions/>
                    <assets/>
                </state>
                <state name="A&amp;B_Lorenz B_composition" type="3" areatype="4" zoom="20" assetsfollowstate="1" defaultplaybacktype="8" lockposition="0" statewithinstate="0" leaveafterassetsfinish="0" leaveonlyafterassetsfinish="0" enteronlyonce="0" timeout="0" minstaytime="4">
                    <enterconditions>
                        <gps isgps="1" lon="7.58652896" lat="47.55512934" radius="4" width="100" height="100" exitoffset="0"/>
                        <requiredstates>
                            <requiredstate>A&amp;B_performance</requiredstate>
                            <requiredstate>A&amp;B_research</requiredstate>
                            <requiredstate>A&amp;B_production</requiredstate>
                        </requiredstates>
                        <corners>
                            <lon>7.58659333</lon>
                            <lat>47.55513296</lat>
                            <lon>7.58649006</lon>
                            <lat>47.55518093</lat>
                        </corners>
                        <exitoffsetcorners>
                            <lon>7.58648604</lon>
                            <lat>47.55508228</lat>
                        </exitoffsetcorners>
                    </enterconditions>
                    <actions>
                        <hintstate>A&amp;B_hint_The Hint</hintstate>
                        <nextstate>Tom &amp; Jerry</nextstate>
                        <nextscene>Scene &lt;2&gt;</nextscene>
                    </actions>
                    <assets/>
                </state>
                <state name="A&amp;B_hint_The Hint" type="7" areatype="4" zoom="18" assetsfollowstate="1" defaultplaybacktype="8" lockposition="0" statewithinstate="0" leaveafterassetsfinish="1" leaveonlyafterassetsfinish="0" enteronlyonce="0" timeout="0" minstaytime="4">
                    <enterconditions>
                        <gps isgps="1" lon="7.58652762" lat="47.55509133" radius="7" width="100" height="100" exitoffset="0"/>
                        <requiredstates/>
                        <corners/>
                        <exitoffsetcorners/>
                    </enterconditions>
                    <actions/>
                    <assets/>
                </state>
            </scene>
        </rwa>
        """
        gameFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("RwaImportTests-\(UUID().uuidString).rwa")
        try rwa.write(to: gameFile, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: gameFile)
        scenes.removeAll()
        hero.loadGameScript()
    }

    private func importedState(_ name: String) throws -> RwaState {
        RwaImport().readRwa(gameFile.path)
        let scene = try XCTUnwrap(scenes.first, "no scene imported")
        return try XCTUnwrap(scene.getState(name), "state '\(name)' not imported")
    }

    func testElementTextWithEntitiesIsDecodedInOnePiece() throws {
        let state = try importedState("A&B_Lorenz B_composition")

        XCTAssertEqual(state.requiredStates,
                       ["A&B_performance", "A&B_research", "A&B_production"])
        XCTAssertEqual(state.hintState, "A&B_hint_The Hint")
        XCTAssertEqual(state.nextState, "Tom & Jerry")
        XCTAssertEqual(state.nextScene, "Scene <2>")
    }

    func testHintStateNameResolvesInTheImportedScene() throws {
        let state = try importedState("A&B_Lorenz B_composition")
        let hint = try XCTUnwrap(scenes.first?.getState(state.hintState))

        XCTAssertEqual(hint.stateName, "A&B_hint_The Hint")
        XCTAssertEqual(Int(hint.type), RWASTATETYPE_HINT)
    }

    func testCornersStillImportWithBufferedText() throws {
        let state = try importedState("A&B_Lorenz B_composition")
        let corners = try XCTUnwrap(state.corners)
        let exitCorners = try XCTUnwrap(state.exitOffsetCorners)

        XCTAssertEqual(corners.count, 2)
        XCTAssertEqual(corners[0].longitude, 7.58659333, accuracy: 1e-9)
        XCTAssertEqual(corners[0].latitude, 47.55513296, accuracy: 1e-9)
        XCTAssertEqual(corners[1].longitude, 7.58649006, accuracy: 1e-9)
        XCTAssertEqual(corners[1].latitude, 47.55518093, accuracy: 1e-9)
        XCTAssertEqual(exitCorners.count, 1)
        XCTAssertEqual(exitCorners[0].longitude, 7.58648604, accuracy: 1e-9)
        XCTAssertEqual(exitCorners[0].latitude, 47.55508228, accuracy: 1e-9)
    }

    func testEmptyActionElementsLeaveDefaults() throws {
        let state = try importedState("A&B_hint_The Hint")

        XCTAssertEqual(state.requiredStates, [])
        XCTAssertEqual(state.hintState, "")
        XCTAssertEqual(state.nextState, "")
        XCTAssertEqual(state.nextScene, "")
        XCTAssertEqual(state.corners?.count ?? 0, 0)
    }
}
