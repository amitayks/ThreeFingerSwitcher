import XCTest
import DeviceLinkProtocol
@testable import DeviceLinkPairing

/// QR pairing: the payload string codec, and the authenticated exchange ending in mutual pinning
/// (including MITM and tamper resistance).
final class QRPairingTests: XCTestCase {

    private let host = DeviceIdentity(id: "mac-1", name: "Mac")
    private let joiner = DeviceIdentity(id: "phone-1", name: "iPhone")
    private let hostSPKI = Data((0..<32).map { UInt8($0) })
    private let joinerSPKI = Data((0..<32).map { UInt8(255 - $0) })

    // MARK: Payload

    func testPayloadRoundTrips() throws {
        let secret = PairingQRPayload.makeSecret()
        let payload = PairingQRPayload(device: host, secret: secret, spkiFingerprint: hostSPKI)
        let decoded = try PairingQRPayload(string: payload.encodedString())
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.device, host)
        XCTAssertEqual(decoded.secret, secret)
        XCTAssertEqual(decoded.spkiFingerprint, hostSPKI)
    }

    func testSecretIs32Bytes() {
        XCTAssertEqual(PairingQRPayload.makeSecret().count, 32)
        // Two secrets should (overwhelmingly) differ.
        XCTAssertNotEqual(PairingQRPayload.makeSecret(), PairingQRPayload.makeSecret())
    }

    func testBadSchemeRejected() {
        XCTAssertThrowsError(try PairingQRPayload(string: "https://example.com/x")) {
            XCTAssertEqual($0 as? PairingQRError, .badScheme)
        }
    }

    func testBadVersionRejected() throws {
        var payload = PairingQRPayload(device: host, secret: PairingQRPayload.makeSecret(), spkiFingerprint: hostSPKI)
        payload.version = 99
        XCTAssertThrowsError(try PairingQRPayload(string: payload.encodedString())) {
            XCTAssertEqual($0 as? PairingQRError, .unsupportedVersion)
        }
    }

    func testV2EndpointRoundTrips() throws {
        let secret = PairingQRPayload.makeSecret()
        let payload = PairingQRPayload(device: host, secret: secret, spkiFingerprint: hostSPKI,
                                       addresses: ["10.0.0.21", "2a06:c701::1"], port: 52344)
        let decoded = try PairingQRPayload(string: payload.encodedString())
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.version, PairingQRPayload.currentVersion)
        XCTAssertEqual(decoded.addresses, ["10.0.0.21", "2a06:c701::1"])
        XCTAssertEqual(decoded.port, 52344)
        XCTAssertTrue(decoded.hasEndpoint)
    }

    func testV1BackCompatDecodesWithNoEndpoint() throws {
        // A v1 payload (no addresses/port) must still decode — the scanner then falls back to discovery.
        let secret = PairingQRPayload.makeSecret()
        let v1 = PairingQRPayload(device: host, secret: secret, spkiFingerprint: hostSPKI, version: 1)
        let decoded = try PairingQRPayload(string: v1.encodedString())
        XCTAssertEqual(decoded.version, 1)
        XCTAssertTrue(decoded.addresses.isEmpty)
        XCTAssertNil(decoded.port)
        XCTAssertFalse(decoded.hasEndpoint)
        XCTAssertEqual(decoded, v1)
    }

    func testV2WithEmptyAddressesDecodesWithoutEndpoint() throws {
        let payload = PairingQRPayload(device: host, secret: PairingQRPayload.makeSecret(), spkiFingerprint: hostSPKI)
        XCTAssertEqual(payload.version, PairingQRPayload.currentVersion)
        let decoded = try PairingQRPayload(string: payload.encodedString())
        XCTAssertTrue(decoded.addresses.isEmpty)
        XCTAssertNil(decoded.port)
        XCTAssertFalse(decoded.hasEndpoint)
        XCTAssertEqual(decoded, payload)
    }

    func testLocalAddressesAreRoutableAndCapped() {
        let addrs = LocalAddresses.current(limit: 4)
        XCTAssertLessThanOrEqual(addrs.count, 4)
        for a in addrs {
            XCTAssertFalse(a.hasPrefix("169.254."), "link-local IPv4 must be excluded")
            XCTAssertFalse(a.lowercased().hasPrefix("fe80:"), "link-local IPv6 must be excluded")
            XCTAssertNotEqual(a, "127.0.0.1")
            XCTAssertNotEqual(a, "::1")
        }
    }

    // MARK: Exchange

    /// Drive a full host↔joiner exchange and return the two results.
    private func runExchange(hostSecret: Data, joinerSecret: Data) throws -> (joiner: PairingExchange.Result?, host: PairingExchange.Result?) {
        var j = PairingExchange(role: .joiner, secret: joinerSecret, identity: joiner, spkiFingerprint: joinerSPKI)
        var h = PairingExchange(role: .host, secret: hostSecret, identity: host, spkiFingerprint: hostSPKI)
        let m1 = j.start()!
        let (m2, r2) = try h.consume(m1)
        XCTAssertNil(r2)
        let (m3, rJoiner) = try j.consume(m2!)
        let (_, rHost) = m3 != nil ? try h.consume(m3!) : (nil, nil)
        return (rJoiner, rHost)
    }

    func testMatchingSecretMutuallyPins() throws {
        let secret = PairingQRPayload.makeSecret()
        let (rJoiner, rHost) = try runExchange(hostSecret: secret, joinerSecret: secret)

        guard case let .pinned(pinnedHostID, pinnedHostSPKI) = rJoiner else { return XCTFail("joiner not pinned") }
        XCTAssertEqual(pinnedHostID, host)
        XCTAssertEqual(pinnedHostSPKI, hostSPKI)

        guard case let .pinned(pinnedJoinerID, pinnedJoinerSPKI) = rHost else { return XCTFail("host not pinned") }
        XCTAssertEqual(pinnedJoinerID, joiner)
        XCTAssertEqual(pinnedJoinerSPKI, joinerSPKI)
    }

    func testDifferentSecretDefeatsMITM() throws {
        let (rJoiner, _) = try runExchange(hostSecret: PairingQRPayload.makeSecret(),
                                           joinerSecret: PairingQRPayload.makeSecret())
        XCTAssertEqual(rJoiner, .failed, "a different secret must fail confirmation")
    }

    func testTamperedConfirmationFails() throws {
        let secret = PairingQRPayload.makeSecret()
        var j = PairingExchange(role: .joiner, secret: secret, identity: joiner, spkiFingerprint: joinerSPKI)
        var h = PairingExchange(role: .host, secret: secret, identity: host, spkiFingerprint: hostSPKI)
        let m1 = j.start()!
        let (m2, _) = try h.consume(m1)
        guard case let .hostHello(e, i, s, c) = m2! else { return XCTFail("expected hostHello") }
        var bad = c; bad[0] ^= 0xFF
        let tampered = PairingMessage.hostHello(ephemeral: e, identity: i, spki: s, confirm: bad)
        let (_, result) = try j.consume(tampered)
        XCTAssertEqual(result, .failed, "a tampered confirmation must fail")
    }
}
