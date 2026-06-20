import Foundation
import CryptoKit
import DeviceLinkPairing

/// A `LinkByteTransport` decorator that wraps an inner transport (the real `NWByteTransport`) in the
/// `SealedRecord` confidential layer once the link handshake has derived a session key. Every outbound
/// pump buffer is sealed into a length-prefixed `ChaChaPoly` record; every inbound buffer is reassembled
/// into whole records and opened in order. This sits *below* `LinkConnection`/`LinkPump`, so the tested
/// framing is unchanged — the pump only ever sees plaintext item bytes.
///
/// **Ordering / nonce discipline:** the `Opener` uses an implicit per-direction monotonic counter, so
/// records MUST be opened in the exact order the peer sealed them. `NWByteTransport` may deliver a record
/// split across receives or several records coalesced into one; we buffer and frame on the 4-byte BE
/// length prefix and open each complete record. Any AEAD failure (tamper / reorder / wrong key) throws —
/// we drop the connection (no partial item is surfaced), matching the fail-closed contract.
final class SealingByteTransport: LinkByteTransport {
    var onReceive: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let inner: LinkByteTransport
    private var sealer: SealedRecord.Sealer
    private var opener: SealedRecord.Opener
    private var inboundBuffer = Data()
    private var closed = false

    init(inner: LinkByteTransport, sealKey: SymmetricKey, openKey: SymmetricKey) {
        self.inner = inner
        // Distinct per-direction keys (sealKey == the peer's openKey) so the two stream directions never
        // reuse a (key, counter-nonce) pair under the role-independent session key.
        self.sealer = SealedRecord.Sealer(key: sealKey)
        self.opener = SealedRecord.Opener(key: openKey)
        inner.onReceive = { [weak self] data in self?.handleInbound(data) }
        inner.onClose = { [weak self] error in self?.onClose?(error) }
    }

    /// Replay bytes that the handshake layer read past `authConfirm` (a coalesced TCP segment) so the
    /// first sealed record(s) are not lost when the transport is swapped in. Call once, right after init,
    /// before `LinkConnection.start`.
    func feed(residual: Data) {
        guard !residual.isEmpty else { return }
        handleInbound(residual)
    }

    func send(_ data: Data) {
        guard !closed else { return }
        do {
            inner.send(try sealer.seal(data))
        } catch {
            fail(error)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        inner.close()
    }

    // MARK: - Inbound

    /// Accumulate bytes and open every complete sealed record in order. Surfaces each record's plaintext
    /// to `onReceive` (the pump). A `.truncated` open means we need more bytes — wait; any other error is
    /// fatal (fail closed).
    private func handleInbound(_ data: Data) {
        guard !closed else { return }
        inboundBuffer.append(data)
        while !inboundBuffer.isEmpty {
            do {
                let (plaintext, consumed) = try opener.open(inboundBuffer)
                inboundBuffer.removeFirst(consumed)
                onReceive?(plaintext)
            } catch SealedRecord.Error.truncated {
                return // incomplete record: keep buffering
            } catch {
                fail(error)
                return
            }
        }
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        closed = true
        inner.close()
        onClose?(error)
    }
}
