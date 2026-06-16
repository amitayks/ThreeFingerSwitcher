import Foundation
import os
import DeviceLinkProtocol
import DeviceLinkPairing

private let coordLog = Logger(subsystem: "com.threefingerswitcher.app", category: "pairing")

/// The Mac host side of QR pairing: generate a secret, expose the QR string, advertise the pairing
/// service, run the host `PairingExchange`, and pin the scanner into `PairedDeviceStore`.
@MainActor
final class MacPairingCoordinator: ObservableObject {
    enum Status: Equatable {
        case idle, waiting, pairing
        case success(String)
        case failed
    }

    @Published var status: Status = .idle
    @Published var qrString: String?

    private let queue = DispatchQueue(label: "com.threefingerswitcher.macpair")
    private let store: PairedDeviceStore
    private let identity: DeviceIdentity

    private var listener: MacPairingListener?
    private var channel: MacPairingChannel?
    private var exchange: PairingExchange?
    private var secret = Data()

    init(store: PairedDeviceStore, identity: DeviceIdentity) {
        self.store = store
        self.identity = identity
    }

    /// Show a QR + advertise the pairing service, waiting to be scanned. Start the listener FIRST so the
    /// QR can carry the listener's bound port + this Mac's reachable address(es) — letting the scanner dial
    /// directly (unicast) without mDNS/Bonjour discovery. The QR is published once the listener is ready.
    func showCode() {
        guard status == .idle else { return }
        coordLog.info("HOST showCode (id \(self.identity.id, privacy: .public))")
        secret = PairingQRPayload.makeSecret()
        status = .waiting

        let listener = MacPairingListener(serviceName: identity.id, queue: queue)
        listener.onReady = { [weak self] port in
            guard let self else { return }
            let addresses = LocalAddresses.current()
            coordLog.info("HOST endpoint [\(addresses.joined(separator: ", "), privacy: .public)]:\(port, privacy: .public)")
            self.qrString = MacLocalIdentity.payload(device: self.identity, secret: self.secret,
                                                     addresses: addresses, port: port).encodedString()
        }
        listener.onChannel = { [weak self] channel in self?.adopt(channel) }
        listener.start()
        self.listener = listener
    }

    func stop() {
        listener?.stop(); channel?.close()
        listener = nil; channel = nil; exchange = nil
        status = .idle; qrString = nil
    }

    // MARK: - Exchange (main queue)

    private func adopt(_ channel: MacPairingChannel) {
        guard self.channel == nil else {   // already pairing on a connection — ignore extras, don't clobber
            coordLog.info("HOST ignoring extra scanner connection")
            channel.close(); return
        }
        self.channel = channel
        exchange = PairingExchange(role: .host, secret: secret,
                                   identity: identity, spkiFingerprint: MacLocalIdentity.fingerprint)
        status = .pairing
        channel.onMessage = { [weak self] message in self?.handle(message) }
    }

    private func handle(_ message: PairingMessage) {
        guard var exch = exchange, let channel else { return }
        do {
            let (reply, result) = try exch.consume(message)
            exchange = exch
            if let reply { channel.send(reply) }
            if let result {
                switch result {
                case let .pinned(peer, fingerprint):
                    coordLog.info("PINNED \(peer.name, privacy: .public) ✅")
                    store.add(PairedDevice(id: peer.id, name: peer.name, pinnedSPKIHash: fingerprint, pairedAt: Date()))
                    status = .success(peer.name)
                case .failed:
                    coordLog.error("exchange FAILED (confirmation mismatch)")
                    status = .failed
                }
            }
        } catch {
            status = .failed
        }
    }
}
