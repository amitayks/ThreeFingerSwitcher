import Foundation
import Network

/// A `LinkByteTransport` backed by an `NWConnection`. A continuous receive loop forwards bytes to
/// `onReceive`; `send` writes to the connection; failure/cancellation reports `onClose`. All callbacks
/// run on the connection's `queue` (the device-link serial queue), which is where `LinkConnection` is
/// driven. Compile-verified; runtime behavior is user-verified on devices.
final class NWByteTransport: LinkByteTransport {
    var onReceive: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var started = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Start the connection and the receive loop. Call once.
    func start() {
        guard !started else { return }
        started = true
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error): self?.onClose?(error)
            case .cancelled:         self?.onClose?(nil)
            default:                 break
            }
        }
        connection.start(queue: queue)
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onReceive?(data) }
            if let error { self.onClose?(error); return }
            if isComplete { self.onClose?(nil); return }
            self.receiveLoop()
        }
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }
}
