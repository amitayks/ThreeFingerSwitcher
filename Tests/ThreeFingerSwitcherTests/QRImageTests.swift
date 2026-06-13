import XCTest
import DeviceLinkProtocol
import DeviceLinkPairing
@testable import ThreeFingerSwitcherCore

/// The Mac QR image generation round-trips (generate → decode), proving the QR path the Hub Show-code
/// surface renders. The cross-device scan is user-verified.
final class QRImageTests: XCTestCase {

    func testQRRoundTripsAPairingPayload() throws {
        let payload = PairingQRPayload(device: DeviceIdentity(id: "mac-1", name: "Mac"),
                                       secret: PairingQRPayload.makeSecret(),
                                       spkiFingerprint: Data((0..<32).map { UInt8($0) }))
        let string = payload.encodedString()

        // The image is generated...
        XCTAssertNotNil(QRImage.image(from: string), "a QR image is produced")
        // ...and decodes back to the same string.
        XCTAssertEqual(QRImage.decode(string), string, "the generated QR decodes to the original payload")

        // And the decoded string parses back to the equal payload.
        let decoded = try PairingQRPayload(string: QRImage.decode(string) ?? "")
        XCTAssertEqual(decoded, payload)
    }

    func testQRRoundTripsAShortString() {
        XCTAssertEqual(QRImage.decode("tfslink:hello"), "tfslink:hello")
    }
}
