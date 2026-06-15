import XCTest
import CryptoKit
@testable import DeviceLinkPairing

/// The shared pairing crypto: code format, and the code-authenticated X25519 confirmation including the
/// MITM-resistance property and role independence.
final class PairingTests: XCTestCase {

    // MARK: Code

    func testCodeGenerationFormat() {
        let code = PairingCode.generate()
        XCTAssertEqual(code.count, 8)
        XCTAssertTrue(code.allSatisfy { $0.isNumber })
        XCTAssertTrue(PairingCode.isValid(code))
    }

    func testCodeValidation() {
        XCTAssertTrue(PairingCode.isValid("12345678"))
        XCTAssertFalse(PairingCode.isValid("1234567"))
        XCTAssertFalse(PairingCode.isValid("1234567a"))
        XCTAssertFalse(PairingCode.isValid("123456789"))
    }

    // MARK: Handshake

    func testSameCodeBothSidesAgree() throws {
        let mac = PairingHandshake()
        let phone = PairingHandshake()
        let code = "12345678"
        let kMac = try mac.confirmationKey(peerPublicKey: phone.publicKey, code: code)
        let kPhone = try phone.confirmationKey(peerPublicKey: mac.publicKey, code: code)

        let macConfirm = mac.confirmation(kMac, label: "mac→phone")
        XCTAssertTrue(phone.verify(macConfirm, key: kPhone, label: "mac→phone"))
        let phoneConfirm = phone.confirmation(kPhone, label: "phone→mac")
        XCTAssertTrue(mac.verify(phoneConfirm, key: kMac, label: "phone→mac"))
    }

    func testDifferentCodeDefeatsMITM() throws {
        let mac = PairingHandshake()
        let phone = PairingHandshake()
        let kMac = try mac.confirmationKey(peerPublicKey: phone.publicKey, code: "12345678")
        let kPhoneWrong = try phone.confirmationKey(peerPublicKey: mac.publicKey, code: "87654321")
        let macConfirm = mac.confirmation(kMac, label: "mac→phone")
        XCTAssertFalse(phone.verify(macConfirm, key: kPhoneWrong, label: "mac→phone"),
                       "a different code must fail confirmation — this is the MITM defense")
    }

    func testRoleIndependentDerivation() throws {
        let mac = PairingHandshake()
        let phone = PairingHandshake()
        let code = "55554444"
        let kMac = try mac.confirmationKey(peerPublicKey: phone.publicKey, code: code)
        let kPhone = try phone.confirmationKey(peerPublicKey: mac.publicKey, code: code)
        XCTAssertEqual(mac.confirmation(kMac, label: "x"), phone.confirmation(kPhone, label: "x"))
    }
}
