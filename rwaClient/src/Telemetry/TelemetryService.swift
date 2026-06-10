//
//  TelemetryService.swift
//  rwa client
//
//  Telemetry gateway core (PROJECT-PLAN.md §4 + §6): collects device- and
//  app-origin events, stamps wall-clock time and envelope context, and
//  uploads them as JSON batches to POST /v1/batch.
//
//  Current stage: in-memory pending buffer fed by SyntheticTelemetrySource.
//  Next stages: SQLite-backed pending_events store (survives relaunch),
//  background URLSession for uploads across background/foreground cycles,
//  BLE/CBOR producer replacing the synthetic source.
//

import Foundation
import os

class TelemetryService {

    // App-origin events use a seq range disjoint from device events (§4.2)
    // so (device_id, session_id, seq) stays globally unique for dedup.
    static let appSeqOffset: UInt64 = 1 << 32
    static let maxBatchSize = 500
    static let uploadInterval: TimeInterval = 15
    static let maxBackoff: TimeInterval = 300
    // Memory cap until the SQLite store lands; drop-oldest on overflow.
    static let maxPendingEvents = 10000

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

    let config: TelemetryConfig
    let sessionId = UUID().uuidString

    // All mutable state below is confined to this serial queue.
    private let queue = DispatchQueue(label: "ch.rwa.telemetry", qos: .utility)
    private var pending: [[String: Any]] = []
    private var appSeq: UInt64 = TelemetryService.appSeqOffset
    private var soundwalkId = "walk-dev"
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
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + TelemetryService.uploadInterval,
                       repeating: TelemetryService.uploadInterval)
        timer.setEventHandler { [weak self] in
            self?.uploadNextBatch()
        }
        timer.resume()
        uploadTimer = timer
    }

    func setSoundwalkId(_ id: String) {
        queue.async {
            self.soundwalkId = id
        }
    }

    func updateFwVersion(_ version: String) {
        queue.async {
            self.fwVersion = version
        }
    }

    /// Device-origin event: caller supplies seq (device counter as-is),
    /// type, t_dev_ms and the type-specific fields. Wall-clock time is
    /// stamped here, on receipt (§4.2).
    func recordDeviceEvent(_ event: [String: Any]) {
        var stamped = event
        stamped["time"] = TelemetryService.rfc3339.string(from: Date())
        queue.async {
            self.append(stamped)
        }
    }

    /// App-origin event (§4.3 app_event): seq comes from the app counter
    /// in the offset range, no t_dev_ms.
    func recordAppEvent(name: String, data: [String: Any] = [:]) {
        let time = TelemetryService.rfc3339.string(from: Date())
        queue.async {
            self.appSeq += 1
            var event: [String: Any] = [
                "seq": self.appSeq,
                "time": time,
                "type": "app_event",
                "name": name
            ]
            if !data.isEmpty {
                event["data"] = data
            }
            self.append(event)
        }
    }

    // MARK: - Queue-confined

    private func append(_ event: [String: Any]) {
        pending.append(event)
        if pending.count > TelemetryService.maxPendingEvents {
            pending.removeFirst(pending.count - TelemetryService.maxPendingEvents)
        }
    }

    private func uploadNextBatch() {
        if uploading || pending.isEmpty || Date() < nextUploadAllowedAt {
            return
        }

        let events = Array(pending.prefix(TelemetryService.maxBatchSize))
        let envelope: [String: Any] = [
            "schema": 1,
            "device_id": config.deviceId,
            "session_id": sessionId,
            "fw_version": fwVersion,
            "app_version": TelemetryService.appVersion,
            "soundwalk_id": soundwalkId,
            "events": events
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else {
            os_log("telemetry: cannot serialize batch, dropping %d events", type: .error, events.count)
            pending.removeFirst(events.count)
            return
        }

        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/batch"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.ingestToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        uploading = true
        let count = events.count
        let task = urlSession.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }
            self.queue.async {
                self.uploading = false
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if error == nil && (200...299).contains(status) {
                    // Delete only on 2xx; on failure events stay queued and
                    // the re-send is dedup-safe on the backend.
                    self.pending.removeFirst(min(count, self.pending.count))
                    self.consecutiveFailures = 0
                    self.nextUploadAllowedAt = Date.distantPast
                    os_log("telemetry: uploaded %d events, %d still pending", type: .info, count, self.pending.count)
                } else {
                    self.consecutiveFailures += 1
                    let backoff = min(pow(2.0, Double(self.consecutiveFailures - 1)) * TelemetryService.uploadInterval,
                                      TelemetryService.maxBackoff)
                    self.nextUploadAllowedAt = Date(timeIntervalSinceNow: backoff)
                    os_log("telemetry: upload failed (status %d, failures %d), backing off %.0fs",
                           type: .error, status, self.consecutiveFailures, backoff)
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
