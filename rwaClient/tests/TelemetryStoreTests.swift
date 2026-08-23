//
//  TelemetryStoreTests.swift
//  rwaclientTests
//
//  The gateway owns the telemetry dedup key (PROJECT-PLAN.md §4.2): an
//  event's `seq` is its SQLite row id. These tests pin the two properties
//  that makes this safe — ids are strictly increasing and never reused,
//  even after the rows before them were deleted by an upload — and that the
//  uploader writes the row id over whatever `seq` the stored JSON carried.
//

import XCTest
@testable import rwa_client

final class TelemetryStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelemetryStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() throws -> TelemetryStore {
        return try XCTUnwrap(TelemetryStore(directory: directory))
    }

    private func append(_ store: TelemetryStore, session: String = "S1", json: String = "{\"type\":\"app_event\"}") {
        XCTAssertTrue(store.append(sessionId: session, soundwalkId: "walk", fwVersion: "unknown",
                                   appVersion: "test", eventJSON: json))
    }

    func testRowIdsIncreaseAndAreNeverReused() throws {
        let store = try makeStore()
        append(store); append(store); append(store)

        let first = try XCTUnwrap(store.fetchOldestBatch(limit: 10))
        XCTAssertEqual(first.rows.count, 3)
        let ids = first.rows.map { $0.id }
        XCTAssertEqual(ids, ids.sorted())
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertEqual(first.lastId, ids.last)

        // An upload deletes the batch; the next row must not reuse an id.
        store.deleteThrough(id: first.lastId)
        XCTAssertEqual(store.pendingCount(), 0)
        append(store)
        let second = try XCTUnwrap(store.fetchOldestBatch(limit: 10))
        XCTAssertEqual(second.rows.count, 1)
        XCTAssertGreaterThan(second.rows[0].id, first.lastId)
    }

    func testRowIdsSurviveReopen() throws {
        var lastId: Int64 = 0
        do {
            let store = try makeStore()
            append(store); append(store)
            let batch = try XCTUnwrap(store.fetchOldestBatch(limit: 10))
            lastId = batch.lastId
            store.deleteThrough(id: lastId)
        }
        // Same directory, new instance — like an app relaunch: the counter
        // continues, it does not restart (that only happens on reinstall).
        let reopened = try makeStore()
        append(reopened)
        let batch = try XCTUnwrap(reopened.fetchOldestBatch(limit: 10))
        XCTAssertGreaterThan(batch.rows[0].id, lastId)
    }

    func testBatchStopsAtEnvelopeChange() throws {
        let store = try makeStore()
        append(store, session: "S1"); append(store, session: "S1"); append(store, session: "S2")
        let batch = try XCTUnwrap(store.fetchOldestBatch(limit: 10))
        XCTAssertEqual(batch.sessionId, "S1")
        XCTAssertEqual(batch.rows.count, 2)
    }

    func testBatchEventsUseRowIdAsSeq() {
        // A row whose JSON still carries a seq (firmware counter from an
        // older app build, or anything else) gets it replaced by the row id.
        let rows = [
            TelemetryStore.Row(id: 41, json: "{\"type\":\"gnss_fix\",\"seq\":7,\"dev_seq\":7}"),
            TelemetryStore.Row(id: 42, json: "{\"type\":\"app_event\",\"name\":\"walk_started\"}"),
            TelemetryStore.Row(id: 43, json: "not json"),
        ]
        let events = TelemetryService.batchEvents(rows)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0]["seq"] as? Int64, 41)
        XCTAssertEqual(events[0]["dev_seq"] as? Int, 7)
        XCTAssertEqual(events[1]["seq"] as? Int64, 42)
    }
}
