//
//  TelemetryStore.swift
//  rwa client
//
//  SQLite-backed pending_events store (PROJECT-PLAN.md §6): events are
//  persisted immediately on receipt and deleted only after a 2xx upload,
//  so telemetry survives app relaunches.
//
//  Envelope context (session_id, soundwalk_id, fw/app version) is stored
//  per row because rows can outlive the session that created them; the
//  uploader batches only contiguous rows with identical envelopes (§4.1).
//
//  Not thread-safe by design: the owning TelemetryService confines all
//  calls to its serial queue.
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class TelemetryStore {

    struct Batch {
        let lastId: Int64
        let sessionId: String
        let soundwalkId: String
        let fwVersion: String
        let appVersion: String
        let eventsJSON: [String]
    }

    // Disk cap (~a few days of 1 Hz gnss_fix); drop-oldest beyond this.
    static let maxStoredEvents = 500_000
    private static let trimCheckInterval = 1000

    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?
    private var insertsSinceTrim = 0

    init?(directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        var fileURL = directory.appendingPathComponent("telemetry.sqlite")
        if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 2000)

        let schema = """
            CREATE TABLE IF NOT EXISTS pending_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                soundwalk_id TEXT NOT NULL,
                fw_version TEXT NOT NULL,
                app_version TEXT NOT NULL,
                event_json TEXT NOT NULL
            )
            """
        guard exec("PRAGMA journal_mode=WAL"), exec(schema) else {
            sqlite3_close(db)
            db = nil
            return nil
        }

        let insertSQL = """
            INSERT INTO pending_events (session_id, soundwalk_id, fw_version, app_version, event_json)
            VALUES (?, ?, ?, ?, ?)
            """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return nil
        }

        // Kiosk telemetry buffer: no value in iCloud/iTunes backups
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? fileURL.setResourceValues(resourceValues)
    }

    deinit {
        sqlite3_finalize(insertStmt)
        sqlite3_close(db)
    }

    func append(sessionId: String, soundwalkId: String, fwVersion: String, appVersion: String, eventJSON: String) -> Bool {
        guard let stmt = insertStmt else { return false }
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, soundwalkId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, fwVersion, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, appVersion, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, eventJSON, -1, SQLITE_TRANSIENT)
        let ok = sqlite3_step(stmt) == SQLITE_DONE

        insertsSinceTrim += 1
        if insertsSinceTrim >= TelemetryStore.trimCheckInterval {
            insertsSinceTrim = 0
            // Uploads only ever delete the oldest rows, so ids stay
            // contiguous and id arithmetic is a safe drop-oldest.
            _ = exec("DELETE FROM pending_events WHERE id <= (SELECT MAX(id) FROM pending_events) - \(TelemetryStore.maxStoredEvents)")
        }
        return ok
    }

    /// Oldest rows (≤ limit) sharing one envelope: stops at the first row
    /// whose envelope differs, so one batch never mixes sessions.
    func fetchOldestBatch(limit: Int) -> Batch? {
        let sql = """
            SELECT id, session_id, soundwalk_id, fw_version, app_version, event_json
            FROM pending_events ORDER BY id LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var lastId: Int64 = 0
        var envelope: (String, String, String, String)?
        var events: [String] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sessionC = sqlite3_column_text(stmt, 1),
                  let soundwalkC = sqlite3_column_text(stmt, 2),
                  let fwC = sqlite3_column_text(stmt, 3),
                  let appC = sqlite3_column_text(stmt, 4),
                  let jsonC = sqlite3_column_text(stmt, 5)
            else { continue }

            let row = (String(cString: sessionC), String(cString: soundwalkC),
                       String(cString: fwC), String(cString: appC))
            if envelope == nil {
                envelope = row
            } else if envelope! != row {
                break
            }
            events.append(String(cString: jsonC))
            lastId = sqlite3_column_int64(stmt, 0)
        }

        guard let env = envelope else { return nil }
        return Batch(lastId: lastId, sessionId: env.0, soundwalkId: env.1,
                     fwVersion: env.2, appVersion: env.3, eventsJSON: events)
    }

    func deleteThrough(id: Int64) {
        _ = exec("DELETE FROM pending_events WHERE id <= \(id)")
    }

    func pendingCount() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM pending_events", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    private func exec(_ sql: String) -> Bool {
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}
