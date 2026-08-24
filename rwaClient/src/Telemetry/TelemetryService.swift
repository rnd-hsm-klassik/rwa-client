//
//  TelemetryService.swift
//  rwa client
//
//  Telemetry gateway core (PROJECT-PLAN.md §4 + §6): collects events created
//  by the RTK headtracker firmware (CBOR frames) and events created by the
//  app, stamps wall-clock time and envelope context, persists them to the
//  SQLite pending_events store, and uploads them as JSON batches to
//  POST /v1/batch. Rows are deleted only on HTTP 2xx, so events survive app
//  relaunches; re-sends are dedup-safe on the backend.
//
//  The gateway owns the dedup key: every event's `seq` is its SQLite row id
//  (§4.2), assigned when the batch is built. The firmware's per-boot frame
//  counter travels as `dev_seq` and is never a key — it restarts at 1 on
//  every reboot of the assembly.
//

import Foundation
import os

class TelemetryService {

    static let maxBatchSize = 500
    static let uploadInterval: TimeInterval = 15
    static let maxBackoff: TimeInterval = 300

    static var shared: TelemetryService?

    static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }()

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RWA Player", category: "Telemetry Service")
    let config: TelemetryConfig
    let sessionId = UUID().uuidString

    // All mutable state below is confined to this serial queue.
    private let queue = DispatchQueue(label: "ch.rwa.telemetry", qos: .utility)
    private var store: TelemetryStore?
    private var storeFailureLogged = false
    // "none" until a soundwalk loads (gameLoaded -> setSoundwalkId)
    private var soundwalkId = "none"
    private var fwVersion = "unknown"
    private var uploadTimer: DispatchSourceTimer?
    private var uploading = false
    private var consecutiveFailures = 0
    private var nextUploadAllowedAt = Date.distantPast
    private let urlSession: URLSession

    init(config: TelemetryConfig) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: sessionConfig)
    }

    func start() {
        queue.async {
            let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            if let dir = baseDir?.appendingPathComponent("Telemetry", isDirectory: true) {
                self.store = TelemetryStore(directory: dir)
            }
            if self.store == nil {
                self.logger.error("telemetry: cannot open event store - events will be dropped")
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + TelemetryService.uploadInterval,
                       repeating: TelemetryService.uploadInterval)
        timer.setEventHandler { [weak self] in
            self?.uploadNextBatch()
        }
        timer.resume()
        uploadTimer = timer

        DeviceHealth.shared.setTelemetrySession(sessionId: sessionId, soundwalkId: soundwalkId)
    }

    func setSoundwalkId(_ id: String) {
        DeviceHealth.shared.setSoundwalkId(id)
        queue.async {
            self.soundwalkId = id
        }
    }

    func updateFwVersion(_ version: String) {
        queue.async {
            self.fwVersion = version
        }
    }

    /// Event created by the RTK headtracker firmware: the decoder supplies
    /// type, source, dev_seq, t_dev_ms and the type-specific fields.
    /// Wall-clock time is stamped here, on receipt (§4.2); `seq` is assigned
    /// at upload from the row id.
    func recordDeviceEvent(_ event: [String: Any]) {
        // Cache latest values for the Diagnostics tab (read-only side channel).
        DeviceHealth.shared.ingestDeviceEvent(event)
        var stamped = event
        stamped["time"] = TelemetryService.rfc3339.string(from: Date())
        queue.async {
            self.append(stamped)
        }
    }

    /// Event created by the app (gnss_fix / heading / heartbeat sampled from
    /// the app's positioning state, or app_event): no dev_seq / t_dev_ms.
    /// Callers set the "source" field (TelemetrySource) to say where the
    /// data stems from; `seq` is assigned at upload from the row id.
    func recordAppOriginEvent(type: String, fields: [String: Any] = [:]) {
        let time = TelemetryService.rfc3339.string(from: Date())
        queue.async {
            var event = fields
            event["time"] = time
            event["type"] = type
            self.append(event)
        }
    }

    /// App lifecycle event (§4.3 app_event).
    func recordAppEvent(name: String, data: [String: Any] = [:]) {
        var fields: [String: Any] = ["name": name,
                                     TelemetrySource.fieldName: TelemetrySource.phone.rawValue]
        if !data.isEmpty {
            fields["data"] = data
        }
        recordAppOriginEvent(type: "app_event", fields: fields)
    }

    /// The unit label for the envelope (`device_id`, §1.1), resolved at
    /// upload time so a Settings change takes effect without reinstalling:
    /// Telemetry.plist override (dev) -> Settings "Unit ID" -> "unknown".
    /// Deliberately no fallback to the assembly BLE name any more: a
    /// missing unit label should be visible in the backend, not papered
    /// over with the name of whatever assembly happened to be configured.
    static func resolveDeviceId(configOverride: String?) -> String {
        if let id = configOverride, !id.isEmpty {
            return id
        }
        return deviceId.isEmpty ? "unknown" : deviceId
    }

    /// Wire events for one batch: each stored row's JSON with `seq` set to
    /// the row id (§4.2). Undecodable rows are skipped. Pure, so it can be
    /// tested without a store or a network.
    static func batchEvents(_ rows: [TelemetryStore.Row]) -> [[String: Any]] {
        var events: [[String: Any]] = []
        for row in rows {
            if let data = row.json.data(using: .utf8),
               var event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                event["seq"] = row.id
                events.append(event)
            }
        }
        return events
    }

    // MARK: - Queue-confined

    private func append(_ event: [String: Any]) {
        // If the store is unavailable, drop telemetry rather than buffer
        // unboundedly or touch playback (CLAUDE.md constraint).
        guard let store = store else { return }

        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8)
        else {
            self.logger.error("telemetry: dropping non-serializable event")
            return
        }

        let ok = store.append(sessionId: sessionId,
                              soundwalkId: soundwalkId,
                              fwVersion: fwVersion,
                              appVersion: TelemetryService.appVersion,
                              eventJSON: json)
        if !ok && !storeFailureLogged {
            storeFailureLogged = true
            self.logger.error("telemetry: event store insert failed - dropping events")
        }
    }

    private func uploadNextBatch() {
        guard let store = store else { return }
        if uploading || Date() < nextUploadAllowedAt {
            return
        }
        guard let batch = store.fetchOldestBatch(limit: TelemetryService.maxBatchSize) else {
            return
        }

        let events = TelemetryService.batchEvents(batch.rows)
        if events.isEmpty {
            // Nothing decodable in this range; clear it so we don't spin.
            store.deleteThrough(id: batch.lastId)
            return
        }

        // Envelope comes from the stored rows, not current state: leftover
        // events from a previous run upload under their original session.
        let envelope: [String: Any] = [
            "schema": 1,
            "device_id": TelemetryService.resolveDeviceId(configOverride: config.unitIdOverride),
            "session_id": batch.sessionId,
            "fw_version": batch.fwVersion,
            "app_version": batch.appVersion,
            "soundwalk_id": batch.soundwalkId,
            "events": events
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else {
            self.logger.error("telemetry: cannot serialize batch, dropping \(events.count) events")
            store.deleteThrough(id: batch.lastId)
            return
        }

        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/batch"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.ingestToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        uploading = true
        let count = events.count
        let lastId = batch.lastId
        let task = urlSession.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }
            self.queue.async {
                self.uploading = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if error == nil && (200...299).contains(status) {
                    // Delete only on 2xx; on failure rows stay in the store
                    // and the re-send is dedup-safe on the backend.
                    store.deleteThrough(id: lastId)
                    self.consecutiveFailures = 0
                    self.nextUploadAllowedAt = Date.distantPast
                    let pending = store.pendingCount()
                    DeviceHealth.shared.setUploadStats(pending: pending, failures: 0, lastStatus: status)
                    self.logger.info("telemetry: uploaded \(count) events, \(pending) still pending")
                } else {
                    self.consecutiveFailures += 1
                    let backoff = min(pow(2.0, Double(self.consecutiveFailures - 1)) * TelemetryService.uploadInterval,
                                      TelemetryService.maxBackoff)
                    self.nextUploadAllowedAt = Date(timeIntervalSinceNow: backoff)
                    DeviceHealth.shared.setUploadStats(pending: store.pendingCount(),
                                                       failures: self.consecutiveFailures,
                                                       lastStatus: status)
                    self.logger.error("telemetry: upload failed (status \(status), failures \(self.consecutiveFailures), backing off \(backoff)s")
                    if self.consecutiveFailures == 1 {
                        // Only on the transition into failure, so an offline
                        // period yields one event instead of one per retry.
                        self.recordAppEvent(name: "upload_failed", data: ["status": status])
                    }
                }
            }
        }
        task.resume()
    }
}
