#!/bin/bash
# Regenerate the menu-bar brand mark (template PNGs) from the committed logo SVG.
#
#   ./scripts/make-icon-assets.sh
#   ./scripts/make-icon-assets.sh path/to/logo.svg
#
# The status item is a TEMPLATE image: macOS uses only the alpha channel and recolours the
# shape for light/dark menu bars. We fit the logo (aspect-preserving) onto a SQUARE canvas,
# trimmed to its content, producing 18/36/54 px assets for @1x/@2x/@3x at an 18 pt mark.
#
# Why QuickLook + luminance→alpha: the source is a potrace-style SVG (a <g transform> with
# sub-paths). AppKit's NSImage mis-parses it (fills it solid), but QuickLook's WebKit renderer
# is correct — it just flattens onto white. So we render a BLACK-on-white copy via qlmanage,
# then convert each pixel to alpha = 1 − luminance (ink → opaque, white background →
# transparent), trimming the surrounding whitespace.
#
# IMPORTANT — square the viewBox first: qlmanage's thumbnail is square and aspect-FILL CROPS a
# landscape logo, slicing off edge elements (e.g. the third bar of a three-bar mark). We pad
# the SVG's viewBox to a square (content centred) so nothing is cropped.
#
# Dependency-free: qlmanage + swift only (no Homebrew). The generated PNGs are committed; the
# app build only copies them.
set -euo pipefail

cd "$(dirname "$0")/.."
SVG="${1:-Resources/Branding/z96ck01.svg}"
OUT_DIR="Resources/Branding"
[ -f "$SVG" ] || { echo "✗ source logo not found: $SVG" >&2; exit 1; }

TMP="$(mktemp -d -t makeicon)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ squaring viewBox + forcing black fill → QuickLook master"
# Read the SVG's own viewBox "minx miny w h" and pad the short side to a centred square.
VB="$(grep -oE 'viewBox="[^"]+"' "$SVG" | head -1 | sed -E 's/viewBox="([^"]+)"/\1/')"
# Let awk field-split the "minx miny w h" string itself (portable across bash/zsh); the
# trailing newline matters so `read` returns success under `set -e`.
read -r NMINX NMINY SIDE < <(printf '%s\n' "$VB" | awk \
    '{ s=($3>$4?$3:$4); printf "%g %g %g\n", $1-(s-$3)/2, $2-(s-$4)/2, s }')
[ -n "$SIDE" ] || { echo "✗ could not parse viewBox from $SVG" >&2; exit 3; }
sed -E "s/fill=\"#[fF]{6}\"/fill=\"#000000\"/; \
        s/viewBox=\"[^\"]+\"/viewBox=\"$NMINX $NMINY $SIDE $SIDE\"/; \
        s/width=\"[^\"]+\"/width=\"${SIDE}pt\"/; \
        s/height=\"[^\"]+\"/height=\"${SIDE}pt\"/" "$SVG" > "$TMP/master.svg"
qlmanage -t -s 1024 "$TMP/master.svg" -o "$TMP" >/dev/null 2>&1
MASTER="$TMP/master.svg.png"
[ -f "$MASTER" ] || { echo "✗ QuickLook produced no render (SVG QL generator unavailable?)" >&2; exit 2; }

echo "▸ trimming to content + writing template PNGs → $OUT_DIR/MenuBarIcon{,@2x,@3x}.png"
RENDER_SWIFT="$TMP/render.swift"
cat > "$RENDER_SWIFT" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write(Data("usage: render <master.png> <outDir>\n".utf8)); exit(2) }
let masterPath = args[1], outDir = args[2]
guard let nsimg = NSImage(contentsOfFile: masterPath),
      let master = nsimg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("could not load \(masterPath)\n".utf8)); exit(3)
}

// Rasterize a CGImage into a known RGBA8 buffer (white background).
func rgba(_ w: Int, _ h: Int, white: Bool = true, _ draw: (CGContext) -> Void) -> [UInt8] {
    var buf = [UInt8](repeating: white ? 255 : 0, count: w*h*4)
    let cs = CGColorSpaceCreateDeviceRGB()
    buf.withUnsafeMutableBytes { ptr in
        let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if white { ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        ctx.interpolationQuality = .high
        draw(ctx)
    }
    return buf
}

// 1) Render master at a working resolution and find the content bounding box (dark pixels).
let mw = master.width, mh = master.height
let mbuf = rgba(mw, mh) { $0.draw(master, in: CGRect(x: 0, y: 0, width: mw, height: mh)) }
func luma(_ b: [UInt8], _ i: Int) -> Int { (Int(b[i])*299 + Int(b[i+1])*587 + Int(b[i+2])*114) / 1000 }
var minX = mw, minY = mh, maxX = 0, maxY = 0
for y in 0..<mh { for x in 0..<mw {
    if luma(mbuf, (y*mw+x)*4) < 200 { if x < minX {minX=x}; if x > maxX {maxX=x}; if y < minY {minY=y}; if y > maxY {maxY=y} }
}}
guard maxX >= minX, maxY >= minY else { FileHandle.standardError.write(Data("no content found in master\n".utf8)); exit(4) }
let cropW = maxX - minX + 1, cropH = maxY - minY + 1

// 2) For each target: white canvas, draw the cropped content aspect-fit + padded, then
//    rewrite as a template mask (alpha = 1 − luminance, rgb = white).
let targets: [(String, Int)] = [("", 18), ("@2x", 36), ("@3x", 54)]
for (suffix, px) in targets {
    let pad = CGFloat(px) * 0.08
    let avail = CGFloat(px) - 2*pad
    let scale = min(avail / CGFloat(cropW), avail / CGFloat(cropH))
    let w = CGFloat(cropW) * scale, h = CGFloat(cropH) * scale
    let ox = (CGFloat(px) - w) / 2, oy = (CGFloat(px) - h) / 2
    // CoreGraphics origin is bottom-left; crop in image (top-left) coords → flip Y.
    var buf = rgba(px, px) { ctx in
        ctx.saveGState()
        ctx.clip(to: CGRect(x: ox, y: oy, width: w, height: h))
        // place the full master so that the crop region lands in the dst rect
        let fullW = CGFloat(mw) * scale, fullH = CGFloat(mh) * scale
        let dx = ox - CGFloat(minX) * scale
        let dy = oy - CGFloat(mh - maxY - 1) * scale
        ctx.draw(master, in: CGRect(x: dx, y: dy, width: fullW, height: fullH))
        ctx.restoreGState()
    }
    // alpha = 1 − luminance, with a modest gain so the thin outline holds at menu-bar size
    // (scaling a hairline stroke down yields only partial-coverage pixels; the gain firms it
    // up without altering the shape). rgb = white (template ignores rgb; white also reads on
    // dark backgrounds if ever used non-template).
    let gain = 1.6
    for i in stride(from: 0, to: px*px*4, by: 4) {
        let a = Int((Double(255 - luma(buf, i)) * gain).rounded())
        buf[i] = 255; buf[i+1] = 255; buf[i+2] = 255; buf[i+3] = UInt8(max(0, min(255, a)))
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    let out = buf.withUnsafeMutableBytes { ptr -> CGImage in
        let ctx = CGContext(data: ptr.baseAddress, width: px, height: px, bitsPerComponent: 8,
            bytesPerRow: px*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
    let url = URL(fileURLWithPath: "\(outDir)/MenuBarIcon\(suffix).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
    print("  ✓ \(url.lastPathComponent) (\(px)x\(px))")
}
SWIFT

swift "$RENDER_SWIFT" "$MASTER" "$OUT_DIR"
echo "✓ menu-bar mark regenerated. Commit $OUT_DIR/MenuBarIcon*.png"
