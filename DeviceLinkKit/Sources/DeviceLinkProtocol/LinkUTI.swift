import Foundation

/// Shared UTI string constants so both ends label representations identically (the manifest keys in an
/// `ItemHeader` and the `uti` in a `ChunkFrame` must match across devices). Deliberately mirrors the
/// Mac's `ClipboardUTI` values; kept as plain strings so this package stays AppKit/UIKit-free.
public enum LinkUTI {
    public static let plainText = "public.utf8-plain-text"
    public static let rtf = "public.rtf"
    public static let png = "public.png"
    public static let tiff = "public.tiff"
    public static let fileURL = "public.file-url"
    public static let url = "public.url"
    public static let color = "com.apple.cocoa.pasteboard.color"
}
