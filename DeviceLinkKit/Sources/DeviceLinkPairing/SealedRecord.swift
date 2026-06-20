import Foundation
import CryptoKit

/// The confidential-channel layer for an authenticated link: every outbound buffer is wrapped as a
/// length-prefixed `ChaChaPoly` sealed record under the session key, and opened on receive — transparently,
/// *below* the framing pump so the tested `LinkPump` / wire `LinkItem` is unchanged.
///
/// **Nonce discipline (security-critical):** the 96-bit nonce is a strictly-monotonic per-direction
/// counter, NOT carried on the wire. Each direction owns one `Sealer` and the peer owns the matching
/// `Opener`; both start at 0 and advance in lockstep. A fresh session key resets the counters. Because the
/// counter is implicit, records must be opened in the exact order they were sealed — a dropped, reordered,
/// duplicated, or bit-flipped record fails AEAD authentication and `open` throws (the caller closes the
/// connection; no partial item is surfaced).
///
/// Wire record: `length(UInt32 BE) ‖ ChaChaPoly(ciphertext ‖ tag)`. The 16-byte tag is included in the
/// length. Only the long-lived key holders share the session key, so an on-path tap can neither read nor
/// forge records.
public enum SealedRecord {
    /// AEAD overhead per record: the 4-byte length prefix plus ChaChaPoly's 16-byte authentication tag.
    public static let tagSize = 16
    public static let lengthPrefixSize = 4

    public enum Error: Swift.Error, Equatable {
        /// A record was shorter than the length prefix, or its declared length exceeded the buffer.
        case truncated
        /// AEAD authentication failed: a tampered/reordered/duplicated record, or a nonce-counter skew.
        case authenticationFailed
        /// The per-direction counter would overflow 2^64 records (never reached in practice).
        case counterExhausted
    }

    /// Seals outbound buffers for one direction under the session key with a monotonic counter nonce.
    /// One instance per connection-direction; not thread-safe (the transport owns its serial context).
    public struct Sealer {
        private let key: SymmetricKey
        private var counter: UInt64 = 0

        public init(key: SymmetricKey) { self.key = key }

        /// The current (next-to-use) counter value — for tests / diagnostics.
        public var nextCounter: UInt64 { counter }

        /// Seal one buffer into a length-prefixed record and advance the counter. Throws only if the
        /// counter is exhausted (2^64 records).
        public mutating func seal(_ plaintext: Data) throws -> Data {
            guard counter < UInt64.max else { throw Error.counterExhausted }
            let nonce = try ChaChaPoly.Nonce(data: SealedRecord.nonceData(counter))
            let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
            // `box.combined` is nonce(12) ‖ ciphertext ‖ tag(16). The nonce is implicit (the counter), so
            // we transmit only ciphertext ‖ tag — strictly enforcing in-order opening.
            let payload = box.ciphertext + box.tag
            counter &+= 1
            var out = Data()
            SealedRecord.appendU32BE(UInt32(payload.count), to: &out)
            out.append(payload)
            return out
        }
    }

    /// Opens inbound records for one direction. Mirrors a peer `Sealer`: same key, counter starting at 0.
    public struct Opener {
        private let key: SymmetricKey
        private var counter: UInt64 = 0

        public init(key: SymmetricKey) { self.key = key }

        /// The current (next-expected) counter value — for tests / diagnostics.
        public var nextCounter: UInt64 { counter }

        /// Open exactly one length-prefixed record from the front of `record`, returning the plaintext and
        /// the number of bytes consumed. Throws `.truncated` if the buffer is short, `.authenticationFailed`
        /// on any AEAD failure (tamper / reorder / wrong key / counter skew).
        public mutating func open(_ record: Data) throws -> (plaintext: Data, consumed: Int) {
            guard record.count >= SealedRecord.lengthPrefixSize else { throw Error.truncated }
            let s = record.startIndex
            let length = Int(SealedRecord.u32(record, 0))
            guard length >= SealedRecord.tagSize else { throw Error.authenticationFailed }
            let total = SealedRecord.lengthPrefixSize + length
            guard record.count >= total else { throw Error.truncated }
            let payload = record[(s + SealedRecord.lengthPrefixSize)..<(s + total)]
            let cipherEnd = payload.endIndex - SealedRecord.tagSize
            let ciphertext = payload[payload.startIndex..<cipherEnd]
            let tag = payload[cipherEnd..<payload.endIndex]
            guard counter < UInt64.max else { throw Error.counterExhausted }
            let nonce = try ChaChaPoly.Nonce(data: SealedRecord.nonceData(counter))
            do {
                let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
                let plaintext = try ChaChaPoly.open(box, using: key)
                counter &+= 1
                return (plaintext, total)
            } catch {
                throw Error.authenticationFailed
            }
        }
    }

    // MARK: - Nonce + byte helpers

    /// The 12-byte ChaChaPoly nonce for a counter: 4 zero bytes ‖ counter (UInt64 big-endian).
    static func nonceData(_ counter: UInt64) -> Data {
        var d = Data(repeating: 0, count: 4)
        var be = counter.bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        return d
    }

    static func appendU32BE(_ v: UInt32, to data: inout Data) {
        data.append(UInt8((v >> 24) & 0xff))
        data.append(UInt8((v >> 16) & 0xff))
        data.append(UInt8((v >> 8) & 0xff))
        data.append(UInt8(v & 0xff))
    }

    static func u32(_ d: Data, _ offset: Int) -> UInt32 {
        let s = d.startIndex + offset
        return (UInt32(d[s]) << 24) | (UInt32(d[s + 1]) << 16) | (UInt32(d[s + 2]) << 8) | UInt32(d[s + 3])
    }
}
