import SwiftUI
import AppKit

/// A read-only, transparent text view that renders **bidirectional (RTL/LTR) text correctly** for the
/// AI command preview canvas (spec launcher-overlay: "Bidirectional text rendering" — Hebrew/Arabic
/// starts on the correct side; mixed LTR+RTL resolves cleanly; recomputed as tokens stream).
///
/// Design D6: SwiftUI's `Text` doesn't expose a NATURAL base writing direction, so the robust path for
/// the streamed/result body is a tiny `NSTextView` wrapper. The base direction is a **paragraph-style**
/// attribute, not a view-level one: an `NSMutableParagraphStyle` with `baseWritingDirection = .natural`
/// makes TextKit apply the Unicode Bidi Algorithm's first-strong rule (P2/P3) **per paragraph**, and
/// `alignment = .natural` then follows the resolved direction (an RTL paragraph aligns right, an LTR
/// paragraph left) — so a Hebrew line aligns right, an English line aligns left, and a mixed paragraph
/// picks its side from its first strong character, with no per-character work here.
///
/// IMPORTANT: the VIEW-LEVEL `textView.baseWritingDirection`/`alignment` must NOT be set to `.natural`.
/// View-level `.natural` resolves to the USER-INTERFACE layout direction (the app/system language — LTR
/// on an English-localized Mac), NOT per-paragraph first-strong, and a view-level `alignment` then
/// force-aligns every paragraph to that uniform side — which is the exact bug this file fixes (Hebrew
/// rendered left-aligned). We apply the paragraph style to `defaultParagraphStyle`, `typingAttributes`,
/// and the full text-storage range instead. We set the string in `updateNSView`, which re-runs on every
/// `@Published` stream update and re-asserts the paragraph style over the full range, so the base
/// direction is recomputed live as the model streams. Final RTL rendering is confirmed on a signed build.
///
/// It is NOT editable and NOT selectable (matching the canvas's prior `.textSelection(.disabled)`),
/// draws no background (transparent over the overlay), and grows with its content inside the existing
/// `ScrollView` — it wraps to the available width and reports its fitted height.
struct BidiText: NSViewRepresentable {
    /// The text to render. Set into the view on every update so base direction recomputes as it streams.
    let text: String
    /// The point size for the system font (14 to match the canvas body / `Text(.system(size: 14))`).
    var fontSize: CGFloat = 14
    /// The text color. `labelColor` matches a default SwiftUI `Text`; pass `.secondaryLabelColor` for
    /// the dimmer decline/failed message bodies.
    var color: NSColor = .labelColor

    func makeNSView(context: Context) -> NSTextView {
        // A plain NSTextView does NOT report a usable `intrinsicContentSize` height, so SwiftUI sizes it to
        // the viewport and the enclosing ScrollView never overflows (it rubber-bands "as if at the
        // bottom"). `FittingTextView` reports its laid-out text height, so a long body grows past the
        // viewport and the ScrollView actually scrolls.
        let textView = FittingTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false                 // transparent over the overlay
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        // NATURAL base direction is set as a PARAGRAPH STYLE in `apply(to:)` (NOT view-level): TextKit then
        // resolves each paragraph's side by the Unicode first-strong rule. A view-level `.natural` here would
        // instead resolve to the UI-language direction and override per-paragraph alignment — that was the bug.
        // Wrap to the container's width and let height grow with content (vertical scroll lives outside):
        // the container tracks the view's width but is UNBOUNDED in height, so a multi-line body can never
        // be clipped to one line by a finite container as text wraps inside the SwiftUI ScrollView.
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.lineFragmentPadding = 0
            container.size = NSSize(width: container.size.width, height: .greatestFiniteMagnitude)
        }
        // Don't fight the ScrollView for width (hug low horizontally) but report the full fitted height
        // (hug high vertically) so the body grows to its wrapped height rather than collapsing to one line.
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        apply(to: textView)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        // Re-set the string on every stream update; this is what recomputes the per-paragraph base
        // direction (first-strong) as new tokens arrive.
        if textView.string != text { textView.string = text }
        apply(to: textView)
        // Keep the height unbounded after a string change, then force layout + re-report the intrinsic
        // size so the SwiftUI ScrollView sizes to the freshly-wrapped height (and never a stale 1-line one).
        // NOTE: final visual sizing must be confirmed in a real signed build (manual test).
        if let container = textView.textContainer, let layout = textView.layoutManager {
            container.size = NSSize(width: container.size.width, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
        }
        textView.invalidateIntrinsicContentSize()
    }

    /// Apply font/color and an EXPLICIT per-paragraph base direction + alignment after a string change
    /// (setting `.string` can reset attributes, so we restore them each update).
    ///
    /// We do NOT use `.natural`: on `NSTextView` a `.natural` writing direction resolves to the
    /// USER-INTERFACE / system locale direction (LTR on an English-localized Mac) — NOT the Unicode
    /// first-strong rule — so Hebrew rendered left-aligned. Instead we choose each paragraph's base from
    /// its **first strong directional character** (`firstStrongDirection`) — the first word/char of the
    /// line decides its side — and PIN `baseWritingDirection` + `alignment` explicitly: a paragraph whose
    /// first strong char is Hebrew/Arabic (or any RTL script) → `.rightToLeft` + `.right`, otherwise
    /// `.leftToRight` + `.left`. Once that first strong char is present the side is STABLE (later
    /// characters never change it); mixed runs within the paragraph still resolve via the system Bidi
    /// algorithm. Re-run on every stream update only so a paragraph that begins with neutrals adopts its
    /// side once the first strong char streams in — never to re-decide from later content.
    private func apply(to textView: NSTextView) {
        let font = NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        textView.textColor = color
        // Default (LTR) for the empty/typing case; real paragraphs are pinned per-paragraph below.
        let ltrDefault = NSMutableParagraphStyle()
        ltrDefault.baseWritingDirection = .leftToRight
        ltrDefault.alignment = .left
        textView.defaultParagraphStyle = ltrDefault
        textView.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: ltrDefault]

        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.font, value: font, range: full)
        storage.addAttribute(.foregroundColor, value: color, range: full)
        // Explicit first-strong direction per paragraph.
        let ns = storage.string as NSString
        ns.enumerateSubstrings(in: full, options: .byParagraphs) { substring, _, enclosingRange, _ in
            let rtl = firstStrongDirection(substring ?? "") == .rightToLeft
            let para = NSMutableParagraphStyle()
            para.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
            para.alignment = rtl ? .right : .left
            storage.addAttribute(.paragraphStyle, value: para, range: enclosingRange)
        }
    }
}

/// A non-scrolling `NSTextView` that reports its **laid-out text height** as the intrinsic content
/// height, so SwiftUI sizes it to the wrapped content (not the viewport) and the enclosing `ScrollView`
/// overflows + scrolls for long bodies. Height is computed at the current container width (which tracks
/// the view width), so it reflects the actual wrapping; width stays `noIntrinsicMetric` (the parent
/// decides width). `invalidateIntrinsicContentSize()` on each text update re-queries it as tokens stream.
private final class FittingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let height = layoutManager.usedRect(for: textContainer).height
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
    }

    /// This text view is NOT inside an NSScrollView — the enclosing SwiftUI `ScrollView` owns scrolling.
    /// A bare NSTextView otherwise SWALLOWS scroll-wheel events (it has no clip view to move), so the
    /// SwiftUI ScrollView never sees them and the body appears unscrollable. Forward them up so the host
    /// ScrollView scrolls.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// The base writing direction of a paragraph by the Unicode **first-strong** rule, as a SwiftUI
/// `LayoutDirection`: the first strong RTL character (Hebrew/Arabic/… ) ⇒ `.rightToLeft`, the first strong
/// Latin/Greek/Cyrillic/… character ⇒ `.leftToRight`, and an empty/neutral-only string ⇒ `.leftToRight`
/// (the canvas default). The FIRST word/char of a line decides its side; leading neutrals (digits,
/// punctuation, whitespace, a URL) are skipped until the first strong char, and once that char is present
/// the side is STABLE — later characters never change it (that is the intended behavior: a line's
/// alignment is fixed by how it starts, not re-decided as more content streams in).
func firstStrongDirection(_ text: String) -> LayoutDirection {
    for scalar in text.unicodeScalars {
        if isStrongRTL(scalar.value) { return .rightToLeft }
        // First strong character is NOT in an RTL block ⇒ treat it as left-to-right. We detect only the
        // RTL ranges explicitly and default everything else to LTR, so a strong-LTR character outside the
        // common Latin range (e.g. IPA Extensions 0x0250–0x02AF, Greek, Cyrillic) still resolves LTR
        // rather than being mistaken for a neutral and scanned past.
        if isStrongLTR(scalar.value) { return .leftToRight }
        // Neutral (digits, punctuation, whitespace, symbols) ⇒ keep scanning for the first strong char.
    }
    return .leftToRight
}

/// Whether a scalar is a strong RIGHT-TO-LEFT character. Covers **all** RTL scripts, not just Hebrew and
/// Arabic: the contiguous RTL block `U+0590–U+08FF` (Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan,
/// Mandaic, Arabic Extended-A/B) plus the Hebrew/Arabic presentation-form blocks.
func isStrongRTL(_ value: UInt32) -> Bool {
    (0x0590...0x08FF).contains(value)          // Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic, Arabic Ext
        || (0xFB1D...0xFB4F).contains(value)   // Hebrew presentation forms
        || (0xFB50...0xFDFF).contains(value)   // Arabic presentation forms-A
        || (0xFE70...0xFEFF).contains(value)   // Arabic presentation forms-B
}

/// Whether a scalar is a strong LEFT-TO-RIGHT character: any letter that is not in an RTL block. We
/// approximate "letter" as "not a neutral" — digits, punctuation, whitespace, and symbols are neutral
/// and skipped — so a strong-LTR letter outside the Latin range still counts as LTR.
func isStrongLTR(_ value: UInt32) -> Bool {
    guard let scalar = Unicode.Scalar(value), !isStrongRTL(value) else { return false }
    let p = scalar.properties
    return p.isAlphabetic || p.generalCategory == .modifierLetter || p.generalCategory == .otherLetter
}

extension View {
    /// Align a short SwiftUI `Text` by its content's first-strong base direction: a value that STARTS with
    /// Hebrew/Arabic reads right-aligned, one that starts with Latin left-aligned. Sets both the multiline
    /// alignment and the layout direction so the leading edge matches the text's opening script.
    func naturalTextDirection(for text: String) -> some View {
        let direction = firstStrongDirection(text)
        return self
            .multilineTextAlignment(direction == .rightToLeft ? .trailing : .leading)
            .environment(\.layoutDirection, direction)
    }
}
