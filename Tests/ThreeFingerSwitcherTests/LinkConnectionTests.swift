import XCTest
import DeviceLinkProtocol
@testable import ThreeFingerSwitcherCore

/// `LinkConnection` logic, driven synchronously by a mock loopback transport — handshake, item
/// exchange, version refusal, malformed-stream teardown. No `Network.framework` involved.
final class LinkConnectionTests: XCTestCase {

    /// A synchronous loopback: each `send` delivers straight to the peer's `onReceive`.
    final class MockByteTransport: LinkByteTransport {
        var onReceive: ((Data) -> Void)?
        var onClose: ((Error?) -> Void)?
        weak var peer: MockByteTransport?
        private(set) var closed = false

        func send(_ data: Data) { peer?.onReceive?(data) }
        func close() {
            guard !closed else { return }
            closed = true
            onClose?(nil)
        }

        static func pair() -> (MockByteTransport, MockByteTransport) {
            let a = MockByteTransport(); let b = MockByteTransport()
            a.peer = b; b.peer = a
            return (a, b)
        }
    }

    private let mac = DeviceIdentity(id: "mac", name: "Mac")
    private let phone = DeviceIdentity(id: "phone", name: "iPhone")

    func testHandshakeLearnsPeerIdentities() {
        let (ta, tb) = MockByteTransport.pair()
        let connA = LinkConnection(transport: ta, localIdentity: mac)
        let connB = LinkConnection(transport: tb, localIdentity: phone)
        var aLearned: DeviceIdentity?; connA.onHandshake = { aLearned = $0 }
        var bLearned: DeviceIdentity?; connB.onHandshake = { bLearned = $0 }

        connA.start()
        connB.start()

        XCTAssertEqual(aLearned, phone)
        XCTAssertEqual(bLearned, mac)
        XCTAssertEqual(connA.peer, phone)
    }

    func testItemExchangeBothDirections() {
        let (ta, tb) = MockByteTransport.pair()
        let connA = LinkConnection(transport: ta, localIdentity: mac)
        let connB = LinkConnection(transport: tb, localIdentity: phone)
        var aItems: [LinkItem] = []; connA.onItem = { aItems.append($0) }
        var bItems: [LinkItem] = []; connB.onItem = { bItems.append($0) }
        connA.start(); connB.start()

        let toPhone = LinkItem(messageID: UUID(), kind: .text, representations: [LinkUTI.plainText: Data("to phone".utf8)])
        let toMac = LinkItem(messageID: UUID(), kind: .url, representations: [LinkUTI.url: Data("https://x".utf8)])
        connA.send(toPhone)
        connB.send(toMac)

        XCTAssertEqual(bItems, [toPhone])
        XCTAssertEqual(aItems, [toMac])
    }

    func testIncompatibleVersionIsRefused() throws {
        let (ta, tb) = MockByteTransport.pair()
        let connA = LinkConnection(transport: ta, localIdentity: mac)
        var handshakes = 0; connA.onHandshake = { _ in handshakes += 1 }
        var items = 0; connA.onItem = { _ in items += 1 }
        var error: Error?; connA.onError = { error = $0 }
        connA.start()

        // Inject a hello from a peer on an incompatible major version (2.x vs our 1.x).
        _ = tb // keep the pair alive
        let badHello = try LinkCodec.encode(.hello(phone, ProtocolVersion(major: 2, minor: 0)))
        ta.onReceive?(badHello)

        XCTAssertEqual((error as? LinkProtocolError)?.code, .unsupportedVersion)
        XCTAssertEqual(handshakes, 0)
        XCTAssertEqual(items, 0)
        XCTAssertTrue(ta.closed, "connection should close on version refusal")
    }

    func testMalformedStreamTearsDown() {
        let (ta, _) = MockByteTransport.pair()
        let connA = LinkConnection(transport: ta, localIdentity: mac)
        var error: Error?; connA.onError = { error = $0 }
        connA.start()

        ta.onReceive?(Data([0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 5, 6])) // bad magic
        XCTAssertTrue(error is LinkProtocolError)
        XCTAssertTrue(ta.closed)
    }
}
