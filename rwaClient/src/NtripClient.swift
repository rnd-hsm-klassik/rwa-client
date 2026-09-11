//
//  NtripClient.swift
//  RWA Player
//
//  NTRIP client (ADR-001, PROJECT-PLAN.md §5.6 / §6 item 6). Since rtk-rover
//  0.48.0 the assembly has no radio but BLE, so the app holds the caster
//  session over cellular and proxies the correction loop: RTCM from the
//  caster goes down to the assembly (HeadtrackerManager's RTCM writer,
//  713D0006), the assembly's own GGA goes up to the caster (713D0007,
//  forwarded every 10 s), seeded from CoreLocation until the receiver has
//  a fix.
//
//  Raw TCP on NWConnection: casters answer `ICY 200 OK`, which is not HTTP,
//  and stream forever, so URLSession is out. The session logic mirrors the
//  ≤ 0.47 firmware's task_rtk_get_corrrection_data, which ran against this
//  caster for weeks: one request per connection (re-sending with wrong
//  settings gets the account banned), a bounded response wait, a 30 s
//  no-RTCM grace after connect (VRS spin-up) that tightens to 10 s once
//  data flows, and a 5 s → 60 s doubling backoff on failed or dataless
//  attempts that received data resets. `ntrip_status` is reported on
//  transitions only, never per retry.
//
//  Threading: all state is confined to the client's own serial queue; the
//  callbacks are invoked there and must hop themselves (the RTCM sink goes
//  to the BLE queue, DeviceHealth locks, TelemetryService dispatches).
//

import Foundation
import Network
import os

// MARK: - Protocol pieces (pure; NtripClientTests)

enum Ntrip {

    /// The one request of a session: NTRIP 1.0 style GET with Basic auth.
    /// The User-Agent must start with "NTRIP" (caster requirement).
    static func request(settings: CasterSettings, appVersion: String) -> Data {
        let credentials = Data("\(settings.user):\(settings.pass)".utf8).base64EncodedString()
        let text = "GET /\(settings.mount) HTTP/1.0\r\n"
            + "User-Agent: NTRIP RWA Player/\(appVersion)\r\n"
            + "Authorization: Basic \(credentials)\r\n"
            + "\r\n"
        return Data(text.utf8)
    }

    enum Response: Equatable {
        /// `ICY 200 OK` or `HTTP/1.x 200`: the bytes after the header are RTCM.
        case streamOpen
        /// `SOURCETABLE 200 OK` (or an HTTP 200 carrying a source table):
        /// the mount point is unknown to the caster. A "200" substring match
        /// is not enough; the old firmware had exactly that bug.
        case sourceTable
        /// 401: bad credentials or a ban.
        case unauthorized
        /// Anything else; carries the status line.
        case other(String)
    }

    static let crlf = Data("\r\n".utf8)
    static let blankLine = Data("\r\n\r\n".utf8)

    /// Parses the response header block at the start of `buffer`; nil while
    /// it is incomplete. `headerLength` is what to strip before the stream.
    /// An HTTP-style reply (`HTTP/…`, `SOURCETABLE …`) ends at its first
    /// blank line. An ICY reply is its status line alone: some casters
    /// append the blank line, some don't, and waiting for it would deadlock
    /// against a VRS that streams nothing before our GGA. A blank line
    /// already in the buffer right after the status line is consumed here;
    /// one that arrives later is stripped from the stream's first bytes by
    /// the client. Any other first line (`ERROR - Bad Password`) has no
    /// header block either and is complete as is.
    static func parseResponse(_ buffer: Data) -> (response: Response, headerLength: Int)? {
        guard let lineEnd = buffer.range(of: crlf) else { return nil }
        let statusLine = String(decoding: buffer[buffer.startIndex..<lineEnd.lowerBound], as: UTF8.self)
        if statusLine.hasPrefix("HTTP/") || statusLine.hasPrefix("SOURCETABLE ") {
            guard let blank = buffer.range(of: blankLine) else { return nil }
            let header = String(decoding: buffer[buffer.startIndex..<blank.lowerBound], as: UTF8.self)
            return (classify(statusLine: statusLine, header: header),
                    buffer.distance(from: buffer.startIndex, to: blank.upperBound))
        }
        var end = lineEnd.upperBound
        if buffer.distance(from: end, to: buffer.endIndex) >= 2,
           buffer[end..<buffer.index(end, offsetBy: 2)] == crlf {
            end = buffer.index(end, offsetBy: 2)
        }
        return (classify(statusLine: statusLine, header: statusLine),
                buffer.distance(from: buffer.startIndex, to: end))
    }

    static func classify(statusLine: String, header: String) -> Response {
        let words = statusLine.split(separator: " ").map(String.init)
        guard words.count >= 2, let code = Int(words[1]) else { return .other(statusLine) }
        if words[0] == "SOURCETABLE" { return .sourceTable }
        if code == 401 { return .unauthorized }
        if code == 200 && (words[0] == "ICY" || words[0].hasPrefix("HTTP/")) {
            // NTRIP 2.0 casters answer an unknown mount point with a plain
            // HTTP 200 whose body is the source table.
            if header.lowercased().contains("gnss/sourcetable") { return .sourceTable }
            return .streamOpen
        }
        return .other(statusLine)
    }

    // MARK: GGA

    /// A GGA sentence from a phone (CoreLocation) fix: the seed the caster
    /// gets until the assembly delivers its own (ADR-001 §2). Quality 1,
    /// 8 satellites and HDOP 1.0 are placeholders; the VRS only needs the
    /// position to within a few km. No trailing CRLF (added on the wire,
    /// like for the assembly's sentence).
    static func gga(latitude: Double, longitude: Double, altitude: Double, at date: Date) -> String {
        let body = "GPGGA,\(ggaTimeFormatter.string(from: date)),"
            + "\(degreesMinutes(abs(latitude), degreeDigits: 2)),\(latitude >= 0 ? "N" : "S"),"
            + "\(degreesMinutes(abs(longitude), degreeDigits: 3)),\(longitude >= 0 ? "E" : "W"),"
            + "1,08,1.0,\(String(format: "%.1f", altitude)),M,0.0,M,,"
        return "$\(body)*\(checksum(body))"
    }

    /// NMEA checksum: XOR of every byte between `$` and `*`, two uppercase
    /// hex digits.
    static func checksum(_ body: String) -> String {
        var c: UInt8 = 0
        for byte in body.utf8 { c ^= byte }
        return String(format: "%02X", c)
    }

    /// True for a `$…*hh` sentence whose checksum matches its body.
    static func hasValidChecksum(_ sentence: String) -> Bool {
        guard sentence.hasPrefix("$"),
              let star = sentence.lastIndex(of: "*") else { return false }
        let body = String(sentence[sentence.index(after: sentence.startIndex)..<star])
        let given = String(sentence[sentence.index(after: star)...])
        return given.uppercased() == checksum(body)
    }

    /// "ddmm.mmmmm" / "dddmm.mmmmm". Computed in 1e-5-minute units so the
    /// minutes can never round up to 60.00000.
    static func degreesMinutes(_ degrees: Double, degreeDigits: Int) -> String {
        let unitsPerMinute = 100_000
        let unitsPerDegree = 60 * unitsPerMinute
        let units = Int((degrees * Double(unitsPerDegree)).rounded())
        let whole = units / unitsPerDegree
        let minuteUnits = units % unitsPerDegree
        return String(format: "%0\(degreeDigits)d%02d.%05d",
                      whole, minuteUnits / unitsPerMinute, minuteUnits % unitsPerMinute)
    }

    private static let ggaTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HHmmss.SS"
        return f
    }()
}

// MARK: - Client

final class NtripClient {

    /// The §4.3 `ntrip_status` states. `reconnecting` is reported once per
    /// outage, only after a previous successful connect: the initial
    /// connect is not a "reconnecting" transition.
    enum State: String {
        case disconnected, connected, reconnecting
    }

    struct Status {
        let state: State
        let reconnects: Int   // successful connects − 1
        let bytesRx: Int      // RTCM bytes received from the caster, cumulative
    }

    // Tunables, mirrored from the ≤ 0.47 firmware (RTKRoverConfig.h).
    static let connectTimeout: TimeInterval = 15
    static let responseTimeout: TimeInterval = 10   // CONNECTION_TIMEOUT_MS
    static let connectGrace: TimeInterval = 30      // NTRIP_CONNECT_GRACE_MS
    static let rtcmTimeout: TimeInterval = 10       // NTRIP_RTCM_TIMEOUT_MS
    static let backoffStart: TimeInterval = 5       // NTRIP_BACKOFF_START_MS
    static let backoffMax: TimeInterval = 60        // NTRIP_BACKOFF_MAX_MS
    static let ggaInterval: TimeInterval = 10
    static let maxHeaderLength = 4096

    let settings: CasterSettings

    /// RTCM as it arrives, in order. Invoked on the client's queue.
    var onRtcm: ((Data) -> Void)?
    /// A GGA seed (no CRLF) while the assembly has delivered none, or nil.
    var ggaSeed: (() -> String?)?
    /// State transitions only.
    var onStatus: ((Status) -> Void)?
    /// The cumulative RTCM byte count, once per second while streaming and
    /// only when it moved: for Diagnostics, which would otherwise show the
    /// zero snapshotted at the `connected` transition until the next one.
    /// Not for telemetry (`ntrip_status` stays transition-only).
    var onProgress: ((Int) -> Void)?
    /// The reason for every failed or dropped session, for Diagnostics.
    var onError: ((String) -> Void)?

    private let appVersion: String
    private let queue = DispatchQueue(label: "ch.rwa.ntrip", qos: .utility)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RWA Player",
                                category: "NTRIP")

    private enum Phase { case idle, connecting, awaitingResponse, streaming }

    // Queue-confined state
    private var running = false
    private var connection: NWConnection?
    private var phase = Phase.idle
    private var responseBuffer = Data()
    private var stripLeadingBlankLine = false
    private var lastDataAt = Date()
    private var gotDataThisSession = false
    private var reconnectDelay = NtripClient.backoffStart
    private var attemptDelay: TimeInterval = 0
    private var successfulConnects = 0
    private var wasConnected = false
    private var reconnectingReported = false
    private var bytesRx = 0
    private var bytesRxReported = 0
    private var assemblyGga: String?
    private var lastGgaSentAt: Date?
    private var deadline: DispatchSourceTimer?
    private var tick: DispatchSourceTimer?
    private var pendingAttempt: DispatchWorkItem?

    init(settings: CasterSettings, appVersion: String) {
        self.settings = settings
        self.appVersion = appVersion
    }

    // MARK: Control (any thread)

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.logger.info("ntrip: start, caster \(self.settings.endpointDescription)")
            self.openSession()
        }
    }

    /// Ends the session; reports `disconnected` if one was open. The client
    /// is single-use: build a new one to start again.
    func stop() {
        queue.async {
            guard self.running else { return }
            self.running = false
            self.pendingAttempt?.cancel()
            self.pendingAttempt = nil
            self.closeSession()
            self.logger.info("ntrip: stopped")
        }
    }

    /// The assembly's own GGA (713D0007). Sticky: once one exists it is
    /// what the caster gets, even if the receiver later loses its fix
    /// (a stale real position beats a fresh phone one for the VRS).
    func updateAssemblyGga(_ sentence: String) {
        queue.async {
            self.assemblyGga = sentence
        }
    }

    // MARK: Session (queue)

    private func openSession() {
        guard running else { return }
        if successfulConnects > 0 && !reconnectingReported {
            reconnectingReported = true
            report(.reconnecting)
        }
        if attemptDelay > 0 {
            let delay = attemptDelay
            attemptDelay = 0
            logger.info("ntrip: backoff, next attempt in \(Int(delay)) s")
            let attempt = DispatchWorkItem { [weak self] in self?.connect() }
            pendingAttempt = attempt
            queue.asyncAfter(deadline: .now() + delay, execute: attempt)
            return
        }
        connect()
    }

    private func connect() {
        guard running, connection == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: settings.port) else {
            fail("invalid caster port \(settings.port)", backoff: true)
            return
        }
        let parameters = NWParameters.tcp
        parameters.prohibitExpensivePaths = false   // cellular is the expected path
        let conn = NWConnection(host: NWEndpoint.Host(settings.host), port: port, using: parameters)
        connection = conn
        phase = .connecting
        responseBuffer.removeAll()
        gotDataThisSession = false
        conn.stateUpdateHandler = { [weak self] state in
            self?.connectionStateChanged(conn, state)
        }
        armDeadline(NtripClient.connectTimeout, reason: "TCP connect to caster timed out")
        logger.info("ntrip: connecting to \(self.settings.host):\(self.settings.port)")
        conn.start(queue: queue)
    }

    private func connectionStateChanged(_ conn: NWConnection, _ state: NWConnection.State) {
        guard conn === connection else { return }   // a cancelled connection's afterglow
        switch state {
        case .ready:
            sendRequest(conn)
        case .waiting(let error):
            // No usable path (cellular off, airplane mode): Network.framework
            // keeps waiting; the connect deadline turns that into a retry.
            logger.info("ntrip: waiting for a network path (\(error.localizedDescription))")
        case .failed(let error):
            fail("connection failed: \(error.localizedDescription)", backoff: true)
        default:
            break
        }
    }

    private func sendRequest(_ conn: NWConnection) {
        phase = .awaitingResponse
        logger.info("ntrip: requesting /\(self.settings.mount)")
        let request = Ntrip.request(settings: settings, appVersion: appVersion)
        conn.send(content: request, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.fail("request send failed: \(error.localizedDescription)", backoff: true)
            }
        })
        armDeadline(NtripClient.responseTimeout, reason: "caster response timed out")
        receiveNext(conn)
    }

    private func receiveNext(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, conn === self.connection else { return }
            if let data = data, !data.isEmpty {
                self.received(data)
            }
            guard conn === self.connection else { return }   // received() may have failed the session
            if let error = error {
                self.fail("receive failed: \(error.localizedDescription)", backoff: !self.gotDataThisSession)
            } else if isComplete {
                self.fail("caster closed the connection", backoff: !self.gotDataThisSession)
            } else {
                self.receiveNext(conn)
            }
        }
    }

    private func received(_ data: Data) {
        switch phase {
        case .awaitingResponse:
            responseBuffer.append(data)
            guard let (response, headerLength) = Ntrip.parseResponse(responseBuffer) else {
                if responseBuffer.count > NtripClient.maxHeaderLength {
                    fail("caster response header too large", backoff: true)
                }
                return
            }
            let rest = Data(responseBuffer.dropFirst(headerLength))
            responseBuffer.removeAll()
            switch response {
            case .streamOpen:
                streamOpened()
                if !rest.isEmpty { streamBytes(rest) }
            case .sourceTable:
                fail("mount point /\(settings.mount) unknown to the caster (source table)", backoff: true)
            case .unauthorized:
                fail("caster refused the credentials (401)", backoff: true)
            case .other(let line):
                fail("unexpected caster response: \(line)", backoff: true)
            }
        case .streaming:
            streamBytes(data)
        case .idle, .connecting:
            break
        }
    }

    private func streamOpened() {
        cancelDeadline()
        phase = .streaming
        stripLeadingBlankLine = true
        lastDataAt = Date()
        successfulConnects += 1
        reconnectingReported = false
        wasConnected = true
        logger.info("ntrip: stream open (connect #\(self.successfulConnects))")
        report(.connected)
        sendGga(force: true)
        startTick()
    }

    private func streamBytes(_ data: Data) {
        var payload = data
        if stripLeadingBlankLine {
            stripLeadingBlankLine = false
            if payload.count >= 2 && payload.prefix(2) == Ntrip.crlf {
                payload = Data(payload.dropFirst(2))
            }
        }
        guard !payload.isEmpty else { return }
        lastDataAt = Date()
        if !gotDataThisSession {
            gotDataThisSession = true
            reconnectDelay = NtripClient.backoffStart   // received data resets the backoff
        }
        bytesRx += payload.count
        onRtcm?(payload)
    }

    /// Once per second while streaming: the no-RTCM hangup and the GGA push.
    private func tickFired() {
        guard phase == .streaming else { return }
        let timeout = gotDataThisSession ? NtripClient.rtcmTimeout : NtripClient.connectGrace
        if Date().timeIntervalSince(lastDataAt) > timeout {
            // A session that never delivered a byte counts as a failed
            // attempt: back off before hammering the caster again.
            fail("no RTCM for \(Int(timeout)) s, dropping the caster connection",
                 backoff: !gotDataThisSession)
            return
        }
        if bytesRx != bytesRxReported {
            bytesRxReported = bytesRx
            onProgress?(bytesRx)
        }
        sendGga(force: false)
    }

    /// The latest GGA + CRLF, right after the 200 and then every 10 s. Rev2
    /// VRS casters stream nothing until they have one. Without any sentence
    /// (no assembly fix yet, no phone location) nothing is sent and the next
    /// tick retries.
    private func sendGga(force: Bool) {
        guard let conn = connection, phase == .streaming else { return }
        if !force, let at = lastGgaSentAt, Date().timeIntervalSince(at) < NtripClient.ggaInterval {
            return
        }
        guard let sentence = assemblyGga ?? ggaSeed?() else { return }
        lastGgaSentAt = Date()
        conn.send(content: Data((sentence + "\r\n").utf8), completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.fail("GGA send failed: \(error.localizedDescription)", backoff: false)
            }
        })
    }

    /// Ends the current attempt or session and schedules the next one.
    private func fail(_ reason: String, backoff: Bool) {
        logger.error("ntrip: \(reason)")
        onError?(reason)
        if backoff {
            attemptDelay = reconnectDelay
            reconnectDelay = min(reconnectDelay * 2, NtripClient.backoffMax)
        }
        closeSession()
        openSession()
    }

    private func closeSession() {
        cancelDeadline()
        stopTick()
        if let conn = connection {
            connection = nil
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        phase = .idle
        responseBuffer.removeAll()
        lastGgaSentAt = nil
        if wasConnected {
            wasConnected = false
            report(.disconnected)
        }
    }

    private func report(_ state: State) {
        onStatus?(Status(state: state,
                         reconnects: max(0, successfulConnects - 1),
                         bytesRx: bytesRx))
    }

    // MARK: Timers (queue)

    private func armDeadline(_ seconds: TimeInterval, reason: String) {
        cancelDeadline()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            self?.fail(reason, backoff: true)
        }
        timer.resume()
        deadline = timer
    }

    private func cancelDeadline() {
        deadline?.cancel()
        deadline = nil
    }

    private func startTick() {
        stopTick()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.tickFired()
        }
        timer.resume()
        tick = timer
    }

    private func stopTick() {
        tick?.cancel()
        tick = nil
    }
}
