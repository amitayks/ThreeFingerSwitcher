import Foundation

/// An abstract bidirectional byte channel. `LinkConnection` depends only on this seam (never on
/// `Network.framework`), so its logic is unit-tested with a mock loopback transport while the real
/// `NWConnection`-backed transport is swapped in at runtime.
protocol LinkByteTransport: AnyObject {
    /// Invoked with each received buffer (may hold partial or multiple frames).
    var onReceive: ((Data) -> Void)? { get set }
    /// Invoked once when the channel closes, with an error if it failed.
    var onClose: ((Error?) -> Void)? { get set }
    /// Write a buffer to the channel.
    func send(_ data: Data)
    /// Close the channel.
    func close()
}
