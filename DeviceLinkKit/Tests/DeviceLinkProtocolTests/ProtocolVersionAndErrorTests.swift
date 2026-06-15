import XCTest
@testable import DeviceLinkProtocol

/// Version compatibility + the error taxonomy's clean messages.
final class ProtocolVersionAndErrorTests: XCTestCase {

    func testMajorMatchIsCompatible() {
        XCTAssertTrue(ProtocolVersion(major: 1, minor: 0).isCompatible(with: ProtocolVersion(major: 1, minor: 0)))
    }

    func testNewerMinorIsCompatible() {
        // A receiver on 1.0 tolerates a peer on 1.7 (additive minor).
        XCTAssertTrue(ProtocolVersion(major: 1, minor: 0).isCompatible(with: ProtocolVersion(major: 1, minor: 7)))
    }

    func testMajorMismatchIsIncompatible() {
        XCTAssertFalse(ProtocolVersion(major: 1, minor: 0).isCompatible(with: ProtocolVersion(major: 2, minor: 0)))
    }

    func testEveryErrorCodeHasACleanMessage() {
        let codes: [LinkProtocolError.Code] = [
            .badMagic, .unsupportedVersion, .unknownFrameType, .oversizeLength, .truncatedFrame,
            .malformedPayload, .manifestMismatch, .unknownMessage, .duplicateMessage, .badSequence, .cancelled,
        ]
        for code in codes {
            let message = LinkProtocolError(code).errorDescription
            XCTAssertNotNil(message, "\(code) has no message")
            XCTAssertFalse(message!.isEmpty, "\(code) has an empty message")
        }
    }

    func testProtocolVersionConstantIsV1() {
        XCTAssertEqual(LinkProtocol.version, ProtocolVersion(major: 1, minor: 0))
    }
}
