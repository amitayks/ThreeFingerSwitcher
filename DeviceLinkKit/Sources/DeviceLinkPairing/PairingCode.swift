import Foundation

/// A short, high-entropy pairing code shown on the Mac and entered on the iPhone. It is a low-entropy
/// secret used only to *authenticate* a strong key agreement — never sent on the wire, never used
/// directly as a key. Generated from the system CSPRNG. Shared by both ends.
public enum PairingCode {
    public static let defaultDigits = 8

    /// A fresh code of `digits` decimal digits (default 8 → ~27 bits).
    public static func generate(digits: Int = defaultDigits) -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<max(1, digits)).map { _ in String(Int.random(in: 0...9, using: &rng)) }.joined()
    }

    /// True iff `code` is exactly `digits` ASCII decimal digits.
    public static func isValid(_ code: String, digits: Int = defaultDigits) -> Bool {
        code.count == digits && code.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
