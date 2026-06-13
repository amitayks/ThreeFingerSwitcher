import Foundation
import DeviceLinkProtocol

/// Drives a `LinkPump` over a `LinkByteTransport`: performs the `hello` version handshake, sends
/// `LinkItem`s as pump-encoded buffers, and surfaces received items. Transport-agnostic, so it is
/// unit-tested with a mock loopback. Driven from a single serial context (the transport's queue);
/// it is not internally synchronized.
final class LinkConnection {
    /// A fully-received item from the peer.
    var onItem: ((LinkItem) -> Void)?
    /// The peer's identity, learned from its `hello`.
    var onHandshake: ((DeviceIdentity) -> Void)?
    /// A protocol/transport error (after which the connection is closed).
    var onError: ((Error) -> Void)?

    private(set) var peer: DeviceIdentity?

    private let localIdentity: DeviceIdentity
    private let transport: LinkByteTransport
    private var pump: LinkPump
    private var closed = false

    init(transport: LinkByteTransport, localIdentity: DeviceIdentity,
         chunkByteBound: Int = LinkProtocol.defaultChunkByteBound) {
        self.transport = transport
        self.localIdentity = localIdentity
        self.pump = LinkPump(chunkByteBound: chunkByteBound)
        transport.onReceive = { [weak self] data in self?.handle(data) }
        transport.onClose = { [weak self] error in self?.handleClose(error) }
    }

    /// Begin the session: announce ourselves with a `hello`.
    func start() {
        sendControl(.hello(localIdentity, LinkProtocol.version))
    }

    /// Send an item to the peer (after the handshake; ordering with the hello is preserved by the channel).
    func send(_ item: LinkItem) {
        guard !closed else { return }
        do {
            for buffer in try pump.outbound(item) { transport.send(buffer) }
        } catch {
            fail(error)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        transport.close()
    }

    // MARK: - Inbound

    private func handle(_ data: Data) {
        guard !closed else { return }
        do {
            for inbound in try pump.ingest(data) {
                switch inbound {
                case .item(let item):
                    onItem?(item)
                case .control(let frame):
                    handleControl(frame)
                }
            }
        } catch {
            fail(error)
        }
    }

    private func handleControl(_ frame: Frame) {
        switch frame {
        case let .hello(identity, version):
            guard LinkProtocol.version.isCompatible(with: version) else {
                fail(LinkProtocolError(.unsupportedVersion))
                return
            }
            peer = identity
            onHandshake?(identity)
        case .ack, .error:
            break // v1: acks are advisory; a peer-reported error is left to a later change to surface
        default:
            break // item-bearing frames are handled by the pump, not here
        }
    }

    private func sendControl(_ frame: Frame) {
        guard !closed else { return }
        do {
            transport.send(try pump.outbound(control: frame))
        } catch {
            fail(error)
        }
    }

    private func handleClose(_ error: Error?) {
        guard !closed else { return }
        closed = true
        if let error { onError?(error) }
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        onError?(error)
        close()
    }
}
