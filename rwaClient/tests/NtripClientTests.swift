//
//  NtripClientTests.swift
//  rwaclientTests
//
//  The pure pieces of the NTRIP client (ADR-001, PROJECT-PLAN.md §5.6):
//  the request bytes, the caster response classification, and the GGA
//  seed built from a phone fix. The session itself (NWConnection, timers,
//  backoff) is exercised against the caster on a device.
//

import XCTest
@testable import rwa_client

final class NtripRequestTests: XCTestCase {

    private var settings: CasterSettings {
        var s = CasterSettings()
        s.host = "caster.example.net"
        s.port = 2101
        s.mount = "VRS_3_4G_CH"
        s.user = "rwa-hs-1"
        s.pass = "secret"
        return s
    }

    /// NTRIP 1.0 style: GET line, a User-Agent starting with "NTRIP", Basic
    /// auth, blank line. Nothing else; the old firmware's request shape.
    func testRequestBytes() {
        let request = Ntrip.request(settings: settings, appVersion: "1.4.0")
        let text = String(decoding: request, as: UTF8.self)
        XCTAssertEqual(text,
                       "GET /VRS_3_4G_CH HTTP/1.0\r\n"
                       + "User-Agent: NTRIP RWA Player/1.4.0\r\n"
                       + "Authorization: Basic cndhLWhzLTE6c2VjcmV0\r\n"   // rwa-hs-1:secret
                       + "\r\n")
    }

    /// The Settings/provisioning reader: default port, leading slash on the
    /// mount point dropped, whitespace trimmed, completeness.
    func testSettingsNormalisation() {
        XCTAssertEqual(CasterSettings.parsePort(nil), 2101)
        XCTAssertEqual(CasterSettings.parsePort(" "), 2101)
        XCTAssertEqual(CasterSettings.parsePort("2102"), 2102)
        XCTAssertEqual(CasterSettings.parsePort("abc"), 0)
        XCTAssertEqual(CasterSettings.mountPoint(" /MOUNT "), "MOUNT")

        var s = settings
        XCTAssertTrue(s.isComplete)
        XCTAssertEqual(s.endpointDescription, "caster.example.net:2101/VRS_3_4G_CH")
        s.pass = ""
        XCTAssertTrue(s.isComplete, "an empty password is allowed")
        s.user = ""
        XCTAssertFalse(s.isComplete)
    }
}

final class NtripResponseTests: XCTestCase {

    private func parse(_ text: String) -> (response: Ntrip.Response, headerLength: Int)? {
        return Ntrip.parseResponse(Data(text.utf8))
    }

    func testIcy200OpensTheStream() throws {
        let r = try XCTUnwrap(parse("ICY 200 OK\r\n\r\n\u{D3}\u{00}"))
        XCTAssertEqual(r.response, .streamOpen)
        XCTAssertEqual(r.headerLength, 14, "status line plus the blank line")
    }

    /// An ICY reply is complete with its status line: waiting for a blank
    /// line would deadlock against a VRS that streams nothing before GGA.
    func testIcy200WithoutBlankLineIsComplete() throws {
        let r = try XCTUnwrap(parse("ICY 200 OK\r\n"))
        XCTAssertEqual(r.response, .streamOpen)
        XCTAssertEqual(r.headerLength, 12)
    }

    func testHttp200OpensTheStreamAfterTheHeaderBlock() throws {
        let header = "HTTP/1.1 200 OK\r\nNtrip-Version: Ntrip/2.0\r\nContent-Type: gnss/data\r\n\r\n"
        let r = try XCTUnwrap(parse(header + "\u{D3}"))
        XCTAssertEqual(r.response, .streamOpen)
        XCTAssertEqual(r.headerLength, header.utf8.count)
    }

    func testHttpHeaderBlockIncompleteReturnsNil() {
        XCTAssertNil(parse("HTTP/1.1 200 OK\r\nContent-Type: gnss/data\r\n"))
        XCTAssertNil(parse("ICY 200 O"))
    }

    /// "200" alone must not open the stream: a source table means the mount
    /// point is unknown (the old firmware matched the substring and then
    /// pushed the table into the receiver).
    func testSourceTableIsAConfigError() throws {
        XCTAssertEqual(try XCTUnwrap(parse("SOURCETABLE 200 OK\r\nContent-Type: text/plain\r\n\r\nSTR;...")).response,
                       .sourceTable)
        XCTAssertEqual(try XCTUnwrap(parse("HTTP/1.1 200 OK\r\nContent-Type: gnss/sourcetable\r\n\r\n")).response,
                       .sourceTable)
    }

    func testUnauthorized() throws {
        XCTAssertEqual(try XCTUnwrap(parse("HTTP/1.1 401 Unauthorized\r\n\r\n")).response, .unauthorized)
        XCTAssertEqual(try XCTUnwrap(parse("HTTP/1.0 401 Unauthorized\r\nWWW-Authenticate: Basic\r\n\r\n")).response,
                       .unauthorized)
    }

    func testOtherStatusCarriesTheLine() throws {
        XCTAssertEqual(try XCTUnwrap(parse("HTTP/1.1 404 Not Found\r\n\r\n")).response,
                       .other("HTTP/1.1 404 Not Found"))
        XCTAssertEqual(try XCTUnwrap(parse("ERROR - Bad Password\r\n")).response,
                       .other("ERROR - Bad Password"))
    }
}

final class NtripGgaTests: XCTestCase {

    /// A sentence captured on the bench from the receiver (rwa-hs-1).
    func testChecksumOfAKnownSentence() {
        let bench = "$GPGGA,214104.30,4733.3177986,N,00735.2118902,E,2,12,0.65,284.398,M,47.259,M,41.3,0285*4E"
        XCTAssertEqual(Ntrip.checksum("GPGGA,214104.30,4733.3177986,N,00735.2118902,E,2,12,0.65,284.398,M,47.259,M,41.3,0285"),
                       "4E")
        XCTAssertTrue(Ntrip.hasValidChecksum(bench))
        XCTAssertFalse(Ntrip.hasValidChecksum(bench.dropLast() + "F"))
        XCTAssertFalse(Ntrip.hasValidChecksum("GPGGA,no dollar*00"))
    }

    /// The CoreLocation seed: fixed layout, quality 1, placeholders for
    /// satellites and HDOP, a valid checksum.
    func testSeedFromAPhoneFix() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 12
        components.hour = 21; components.minute = 41; components.second = 4
        components.nanosecond = 300_000_000
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components)!

        let gga = Ntrip.gga(latitude: 47.5552966, longitude: 7.5868648, altitude: 284.4, at: date)
        XCTAssertEqual(gga, "$GPGGA,214104.30,4733.31780,N,00735.21189,E,1,08,1.0,284.4,M,0.0,M,,*52")
        XCTAssertTrue(Ntrip.hasValidChecksum(gga))
    }

    func testSouthernWesternHemispheres() {
        let gga = Ntrip.gga(latitude: -33.8688, longitude: -151.2093, altitude: 0, at: Date())
        XCTAssertTrue(gga.contains(",3352.12800,S,15112.55800,W,"))
        XCTAssertTrue(Ntrip.hasValidChecksum(gga))
    }

    /// Minutes are computed in 1e-5-minute units, so 59.999999' rounds to
    /// the next degree instead of printing "60.00000".
    func testMinutesNeverRoundToSixty() {
        XCTAssertEqual(Ntrip.degreesMinutes(47.99999999, degreeDigits: 2), "4800.00000")
        XCTAssertEqual(Ntrip.degreesMinutes(7.5, degreeDigits: 3), "00730.00000")
    }
}
