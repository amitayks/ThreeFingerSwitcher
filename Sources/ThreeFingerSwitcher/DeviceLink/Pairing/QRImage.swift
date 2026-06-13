import Foundation
import AppKit
import CoreImage

/// QR generation + decoding (CoreImage). Generation feeds the Hub "Show pairing code" surface; decoding
/// backs the unit-tested round-trip (the actual phone scan uses the iOS camera).
enum QRImage {
    /// A crisp QR `NSImage` for `string`, or nil.
    static func image(from string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    /// Decode the first QR message in a generated CIImage (for the round-trip test).
    static func decode(_ string: String) -> String? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: scaled) ?? []
        return (features.first as? CIQRCodeFeature)?.messageString
    }
}
