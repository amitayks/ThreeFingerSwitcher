import Foundation
import DeviceLinkProtocol
import DeviceLinkPairing

/// Runs the authenticated `LinkSession` handshake on a freshly-accepted connection, *before* any item or
/// control traffic is allowed (D6: fail-closed gate). The handshake's `authHello`/`authConfirm` frames are
/// exchanged in the clear over the raw `NWByteTransport` (they carry only public keys + a MAC), framed with
/// the same `LinkCodec` envelope as the pump but driven directly here so the `LinkPump` never sees them.
///
/// On mutual confirm it reports the derived `Established` session (session key + verified peer identity +
/// pinned fingerprint); the caller then wraps the transport in `SealingByteTransport` and drives a normal
/// `LinkConnection` over it. Any failure — malformed key, an unpinned static (not in `pinnedFingerprints`),
/// or a confirmation mismatch — closes the connection and surfaces nothing.
final class LinkHandshake {
    /// Fired once on mutual confirm with the established session, plus any post-confirm bytes already
    /// read (to be replayed into the sealing layer). Delivered on the transport's queue.
    var onEstablished: ((LinkSession.Established, _ residual: Data) -> Void)?
    /// Fired once if the handshake fails / the transport closes first. The connection is dropped.
    var onFailure: ((Error) -> Void)?

    private let transport: LinkByteTransport
    private let session: LinkSession
    private let pinnedFingerprints: Set<Data>
    private var decoder = FrameDecoder()
    /// Every byte received during the handshake; lets us recover the post-confirm tail (the peer may
    /// coalesce its `authConfirm` with the first sealed bytes into one TCP read) and hand it to the
    /// sealing layer rather than dropping it.
    private var rawReceived = Data()

    private var established: LinkSession.Established?
    private var sentConfirm = false
    private var done = false

    init(transport: LinkByteTransport, session: LinkSession, pinnedFingerprints: Set<Data>) {
        self.transport = transport
        self.session = session
        self.pinnedFingerprints = pinnedFingerprints
        transport.onReceive = { [weak self] data in self?.handle(data) }
        transport.onClose = { [weak self] error in self?.fail(error ?? LinkSession.Failure.confirmationFailed) }
    }

    /// Send our `authHello` to open the handshake. Both ends do this symmetrically (no caller-supplied role).
    func start() {
        sendFrame(session.hello())
    }

    // MARK: - Inbound

    private func handle(_ data: Data) {
        guard !done else { return }
        rawReceived.append(data)
        decoder.push(data)
        do {
            while let frame = try decoder.next() {
                try consume(frame)
                if done { return }
            }
        } catch {
            fail(error)
        }
    }

    /// Process one handshake frame. The two ends are symmetric: each consumes the peer's `authHello` to
    /// derive the session + send its own `authConfirm`, then verifies the peer's `authConfirm`.
    private func consume(_ frame: Frame) throws {
        switch frame {
        case .authHello:
            guard established == nil else { return } // ignore a duplicate hello
            let est = try session.accept(peerHello: frame, pinnedFingerprints: pinnedFingerprints)
            established = est
            if !sentConfirm {
                sentConfirm = true
                sendFrame(est.confirm())
            }
        case .authConfirm:
            guard let est = established else {
                // A confirm before we have a session (no peer hello yet) can't verify → fail closed.
                throw LinkSession.Failure.confirmationFailed
            }
            guard est.verify(peerConfirm: frame) else {
                throw LinkSession.Failure.confirmationFailed
            }
            finish(est)
        default:
            // No other frame may precede mutual confirm (D6) — treat as a protocol violation.
            throw LinkSession.Failure.confirmationFailed
        }
    }

    private func sendFrame(_ frame: Frame) {
        guard !done else { return }
        do {
            transport.send(try LinkCodec.encode(frame))
        } catch {
            fail(error)
        }
    }

    private func finish(_ established: LinkSession.Established) {
        guard !done else { return }
        done = true
        transport.onReceive = nil
        transport.onClose = nil
        // Bytes pushed but not yet framed are the post-confirm tail (sealed item bytes); replay them.
        let residual = decoder.bufferedByteCount > 0
            ? Data(rawReceived.suffix(decoder.bufferedByteCount)) : Data()
        onEstablished?(established, residual)
    }

    private func fail(_ error: Error) {
        guard !done else { return }
        done = true
        transport.onReceive = nil
        transport.onClose = nil
        transport.close()
        onFailure?(error)
    }
}
