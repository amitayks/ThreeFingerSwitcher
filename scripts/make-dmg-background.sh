#!/bin/bash
# Regenerate the styled-DMG background image (Resources/Branding/dmg-background.png).
#
#   ./scripts/make-dmg-background.sh
#
# A 660×400 backdrop for the install window: title + a "drag the app onto Applications"
# arrow positioned to sit between the two icon slots that scripts/package-dmg.sh places
# (app centred at 180,190 and the Applications drop-link at 480,190, icon size 144).
# Dependency-free: renders via AppKit. The PNG is committed; package-dmg.sh just uses it.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="Resources/Branding/dmg-background.png"

SWIFT="$(mktemp -t dmgbg).swift"
trap 'rm -f "$SWIFT"' EXIT
cat > "$SWIFT" <<'SWIFT'
import AppKit
import Foundation

let W: CGFloat = 660, H: CGFloat = 400
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx

// Subtle vertical gradient (light, so the colorful app icon + blue Applications folder pop).
let top = NSColor(calibratedRed: 0.972, green: 0.980, blue: 0.992, alpha: 1)
let bot = NSColor(calibratedRed: 0.918, green: 0.933, blue: 0.957, alpha: 1)
NSGradient(starting: bot, ending: top)!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

// Centred text in a horizontal band whose TOP edge is `topY` px from the window top.
func centered(_ s: String, topY: CGFloat, font: NSFont, color: NSColor) {
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
    let lh = ceil(font.ascender - font.descender)
    NSAttributedString(string: s, attributes: attrs)
        .draw(in: NSRect(x: 0, y: H - topY - lh, width: W, height: lh))
}
centered("ThreeFingerSwitcher", topY: 40,
         font: .systemFont(ofSize: 24, weight: .semibold),
         color: NSColor(calibratedWhite: 0.16, alpha: 1))
centered("Drag the app onto the Applications folder to install", topY: 74,
         font: .systemFont(ofSize: 13, weight: .regular),
         color: NSColor(calibratedWhite: 0.45, alpha: 1))

// "Drag →" arrow at the icon row (centres at x=180 and x=480, y=190 from top → cgY=210),
// sitting in the gap between the two 144px icons.
let cgY = H - 190
let arrow = NSColor(calibratedRed: 0.60, green: 0.65, blue: 0.74, alpha: 1)
arrow.set()
let shaft = NSBezierPath()
shaft.lineWidth = 8; shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: 273, y: cgY)); shaft.line(to: NSPoint(x: 372, y: cgY))
shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 394, y: cgY))
head.line(to: NSPoint(x: 369, y: cgY - 15))
head.line(to: NSPoint(x: 369, y: cgY + 15))
head.close(); head.fill()

NSGraphicsContext.current = nil
let url = URL(fileURLWithPath: CommandLine.arguments[1])
try! rep.representation(using: .png, properties: [:])!.write(to: url)
print("wrote \(url.path) (\(Int(W))x\(Int(H)))")
SWIFT

swift "$SWIFT" "$OUT"
echo "✓ DMG background regenerated. Commit $OUT"
