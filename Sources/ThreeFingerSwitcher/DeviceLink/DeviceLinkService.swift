import Foundation
import CryptoKit
import Network
import DeviceLinkProtocol
import DeviceLinkPairing

/// The Mac's always-on receive anchor: advertises a Bonjour service (peer-to-peer enabled so it can
/// use peer-to-peer Wi-Fi/AWDL for high-bandwidth transfer), accepts incoming connections, and surfaces
/// reassembled `LinkItem`s. The app wires `onItem` to the inbound adapter + `ClipboardStore`. Connection
/// state is confined to the serial `queue`; `onItem`/`onOnlineChange` are delivered on the main queue so
/// the app can touch its `@MainActor` store directly.
///
/// Every accepted connection runs the authenticated `LinkSession` handshake first (this Mac's long-lived
/// key + the pinned-fingerprint set): an unpinned or unconfirmed peer is dropped and surfaces nothing
/// (fail closed, D6). After mutual confirm the byte channel is wrapped in `SealingByteTransport` so all
/// item traffic is encrypted (`ChaChaPoly`), below the unchanged `LinkPump`. Authenticated connections are
/// held in a per-peer registry keyed by the pinned identity id, so sends can target a chosen paired peer
/// and per-device online state is observable.
final class DeviceLinkService {
    static let serviceType = "_tfslink._tcp"

    /// A reassembled item from a peer, delivered on the **main** queue.
    var onItem: ((LinkItem) -> Void)?
    /// Per-paired-device online state changed (peer id → connected). Delivered on the **main** queue.
    var onOnlineChange: ((_ peerID: String, _ online: Bool) -> Void)?

    private let localIdentity: DeviceIdentity
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    /// Supplies the current pinned-fingerprint set (`SHA256(peer staticPub)`); read per accept so a
    /// freshly-paired or "forgotten" device is reflected without restarting the service.
    private let pinnedFingerprints: () -> Set<Data>
    /// Maps a verified peer fingerprint back to its stable pinned id/name for the registry.
    private let device: (Data) -> PairedDevice?

    private let queue = DispatchQueue(label: "com.threefingerswitcher.devicelink")
    private var listener: NWListener?
    /// In-flight handshakes (not yet authenticated) — retained so they aren't deallocated mid-handshake.
    private var pending: [ObjectIdentifier: LinkHandshake] = [:] // queue-confined
    /// Authenticated connections keyed by the pinned peer id (D4/D5). One entry per online paired device.
    private var peers: [String: LinkConnection] = [:] // queue-confined

    init(localIdentity: DeviceIdentity,
         staticKey: Curve25519.KeyAgreement.PrivateKey,
         pinnedFingerprints: @escaping () -> Set<Data>,
         device: @escaping (Data) -> PairedDevice?) {
        self.localIdentity = localIdentity
        self.staticKey = staticKey
        self.pinnedFingerprints = pinnedFingerprints
        self.device = device
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

    /// Send an item to a specific paired peer by its pinned id. No-op if that peer is not online.
    func send(_ item: LinkItem, to peerID: String) {
        queue.async { [weak self] in
            self?.peers[peerID]?.send(item)
        }
    }

    /// Send an item to every currently-online paired peer (a thin convenience over the per-peer send).
    func sendToAll(_ item: LinkItem) {
        queue.async { [weak self] in
            self?.peers.values.forEach { $0.send(item) }
        }
    }

    /// The pinned ids of currently-online (authenticated) peers.
    func onlinePeerIDs() -> Set<String> {
        queue.sync { Set(peers.keys) }
    }

    /// Stop advertising and close all connections.
    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.pending.removeAll()
            // Detach the registry first so each close()'s `onClose` → `drop` is a no-op (=== fails), then
            // close + notify offline exactly once per peer.
            let closing = self.peers
            self.peers.removeAll()
            for (peerID, connection) in closing {
                connection.close()
                self.notifyOnline(peerID, false)
            }
        }
    }

    // MARK: - Accept + handshake (runs on `queue`)

    private func accept(_ nwConnection: NWConnection) {
        let transport = NWByteTransport(connection: nwConnection, queue: queue)
        let session = LinkSession(identity: localIdentity, staticKey: staticKey)
        let handshake = LinkHandshake(transport: transport,
                                      session: session,
                                      pinnedFingerprints: pinnedFingerprints())
        let token = ObjectIdentifier(handshake)
        handshake.onEstablished = { [weak self] established, residual in
            self?.adopt(established, transport: transport, residual: residual, token: token)
        }
        handshake.onFailure = { [weak self] _ in
            self?.pending[token] = nil // connection already closed by the handshake; just drop the holder
        }
        pending[token] = handshake
        transport.start()
        handshake.start()
    }

    /// A handshake completed: wrap the transport in the sealing layer, register the authenticated peer by
    /// its pinned id (replacing any stale connection for the same device), and start the sealed pump.
    private func adopt(_ established: LinkSession.Established,
                       transport: LinkByteTransport,
                       residual: Data,
                       token: ObjectIdentifier) {
        pending[token] = nil
        // The verified peer fingerprint resolves to the pinned record → stable peer id for the registry.
        guard let paired = device(established.peerStaticFingerprint) else { return }
        let peerID = paired.id

        let sealing = SealingByteTransport(inner: transport, sealKey: established.sealKey, openKey: established.openKey)
        let connection = LinkConnection(transport: sealing, localIdentity: localIdentity)
        connection.onItem = { [weak self] item in
            DispatchQueue.main.async { self?.onItem?(item) }
        }
        // `onClose` fires once on any close (clean disconnect or error), already on `queue`; drop the peer
        // and update online state. Idempotent in `drop` (guards against a superseded connection).
        connection.onClose = { [weak self] in
            self?.drop(peerID: peerID, connection: connection)
        }

        // Replace any prior connection for this device (a reconnect supersedes the stale one). Install the
        // new entry first so the stale close's `onClose` → `drop` is a no-op (=== fails) and doesn't clear
        // the fresh registration or emit a spurious offline.
        let stale = peers[peerID]
        peers[peerID] = connection
        stale?.close()

        connection.start()
        sealing.feed(residual: residual) // replay any post-confirm bytes the handshake read ahead
        notifyOnline(peerID, true)
    }

    /// Remove a peer's connection from the registry iff it is still the registered one, updating online
    /// state. Guards against a late error from a superseded connection clobbering a fresh reconnect.
    private func drop(peerID: String, connection: LinkConnection) {
        guard peers[peerID] === connection else { return }
        connection.close()
        peers[peerID] = nil
        notifyOnline(peerID, false)
    }

    private func notifyOnline(_ peerID: String, _ online: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onOnlineChange?(peerID, online) }
    }
}
