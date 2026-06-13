import Foundation
import Network
import os
import DeviceLinkPairing

private let pairingLog = Logger(subsystem: "com.threefingerswitcher.app", category: "pairing")

/// A length-prefixed JSON `PairingMessage` channel over one `NWConnection` — the Mac mirror of the iOS
/// `PairingChannel`. Pairing uses `includePeerToPeer = true` (AWDL + Wi-Fi) so discovery works even when
/// the router blocks mDNS between devices (AP/client isolation, mesh). `@unchecked Sendable`.
final class MacPairingChannel: @unchecked Sendable {
    static let serviceType = "_tfspair._tcp"

    var onMessage: ((PairingMessage) -> Void)?  // delivered on main
    var onClosed: (() -> Void)?                  // delivered on main

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    static func parameters() -> NWParameters {
        let params = NWParameters.tcp
        params.includePeerToPeer = true   // AWDL + Wi-Fi — robust across routers that block mDNS bridging
        return params
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:      pairingLog.info("channel READY"); self?.receiveLoop()
            case .waiting(let error): pairingLog.error("channel waiting: \(String(describing: error), privacy: .public)")
            case .failed(let error):  pairingLog.error("channel failed: \(String(describing: error), privacy: .public)"); DispatchQueue.main.async { self?.onClosed?() }
            case .cancelled:  DispatchQueue.main.async { self?.onClosed?() }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ message: PairingMessage) {
        guard let json = try? JSONEncoder().encode(message) else { return }
        pairingLog.info("→ send \(self.label(message), privacy: .public)")
        var framed = Data()
        let length = UInt32(json.count)
        framed.append(UInt8((length >> 24) & 0xff)); framed.append(UInt8((length >> 16) & 0xff))
        framed.append(UInt8((length >> 8) & 0xff));  framed.append(UInt8(length & 0xff))
        framed.append(json)
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    func close() { connection.cancel() }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data); self.drain() }
            if error != nil || isComplete { DispatchQueue.main.async { self.onClosed?() }; return }
            self.receiveLoop()
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let length = (UInt32(buffer[buffer.startIndex]) << 24) | (UInt32(buffer[buffer.startIndex + 1]) << 16)
                       | (UInt32(buffer[buffer.startIndex + 2]) << 8) | UInt32(buffer[buffer.startIndex + 3])
            let total = 4 + Int(length)
            guard buffer.count >= total else { break }
            let json = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + total))
            buffer = Data(buffer[(buffer.startIndex + total)...])
            if let message = try? JSONDecoder().decode(PairingMessage.self, from: json) {
                pairingLog.info("← recv \(self.label(message), privacy: .public)")
                DispatchQueue.main.async { self.onMessage?(message) }
            }
        }
    }

    private func label(_ message: PairingMessage) -> String {
        switch message {
        case .joinerHello:   return "joinerHello"
        case .hostHello:     return "hostHello"
        case .joinerConfirm: return "joinerConfirm"
        }
    }
}

/// Advertises `_tfspair._tcp` under the Mac's id and accepts a scanner.
final class MacPairingListener: @unchecked Sendable {
    var onChannel: ((MacPairingChannel) -> Void)?  // main

    private let serviceName: String
    private let queue: DispatchQueue
    private var listener: NWListener?

    init(serviceName: String, queue: DispatchQueue) {
        self.serviceName = serviceName
        self.queue = queue
    }

    func start() {
        guard let listener = try? NWListener(using: MacPairingChannel.parameters()) else {
            pairingLog.error("listener: failed to create NWListener")
            return
        }
        listener.service = NWListener.Service(name: serviceName, type: MacPairingChannel.serviceType)
        listener.stateUpdateHandler = { state in pairingLog.info("listener state: \(String(describing: state), privacy: .public)") }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            pairingLog.info("listener: scanner CONNECTED")
            let channel = MacPairingChannel(connection: connection, queue: self.queue)
            channel.start()
            DispatchQueue.main.async { self.onChannel?(channel) }
        }
        listener.start(queue: queue)
        pairingLog.info("listener: advertising _tfspair._tcp as \(self.serviceName, privacy: .public)")
    }

    func stop() { listener?.cancel(); listener = nil }
}
