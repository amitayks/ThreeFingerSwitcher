import Foundation
import Network
import DeviceLinkProtocol

/// The Mac's always-on receive anchor: advertises a Bonjour service (peer-to-peer enabled so it can
/// use peer-to-peer Wi-Fi/AWDL for high-bandwidth transfer), accepts incoming connections, and surfaces
/// reassembled `LinkItem`s. The app wires `onItem` to the inbound adapter + `ClipboardStore` (done in
/// the hub change). Connection state is confined to the serial `queue`; `onItem` is delivered on the
/// main queue so the app can touch its `@MainActor` store directly.
///
/// v1 is **unauthenticated TCP** — security (a pinned TLS identity + the pairing handshake) lands in
/// `device-link-pairing`, and the feature opt-in must not enable until then. Nothing constructs this
/// service yet (the hub change wires it to the opt-in).
final class DeviceLinkService {
    static let serviceType = "_tfslink._tcp"

    /// A reassembled item from a peer, delivered on the **main** queue.
    var onItem: ((LinkItem) -> Void)?

    private let localIdentity: DeviceIdentity
    private let queue = DispatchQueue(label: "com.threefingerswitcher.devicelink")
    private var listener: NWListener?
    private var connections: [LinkConnection] = [] // queue-confined

    init(localIdentity: DeviceIdentity) {
        self.localIdentity = localIdentity
    }

    /// Begin advertising + accepting. Call from the main thread.
    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let listener = try NWListener(using: params)
        listener.service = NWListener.Service(name: localIdentity.name, type: Self.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async { self?.accept(connection) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Send an item to all currently-connected peers (v1 has effectively one — the paired phone).
    /// Per-device targeting + the user trigger are the Hub change. Dispatched on the serial queue.
    func send(_ item: LinkItem) {
        queue.async { [weak self] in
            self?.connections.forEach { $0.send(item) }
        }
    }

    /// Stop advertising and close all connections.
    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            self?.connections.forEach { $0.close() }
            self?.connections.removeAll()
        }
    }

    // Runs on `queue`.
    private func accept(_ nwConnection: NWConnection) {
        let transport = NWByteTransport(connection: nwConnection, queue: queue)
        let connection = LinkConnection(transport: transport, localIdentity: localIdentity)
        connection.onItem = { [weak self] item in
            DispatchQueue.main.async { self?.onItem?(item) }
        }
        connections.append(connection)
        transport.start()
        connection.start()
    }
}
