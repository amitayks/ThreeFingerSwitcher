import AppKit
import OpenDirectory
import QuartzCore

/// The unlock card shown behind the curtain after an unrecognized finger (`keep-awake-silent-touch-id`).
/// Styled after the macOS login window: a dark frosted card with the user's picture, full name, a
/// pill "Enter Password" field, and the live Touch ID glyph — so a finger or the password both work.
/// The field holds keyboard focus from the first moment (the screen may be dimmed to black).
@MainActor
final class CurtainPasswordCard: NSVisualEffectView {
    static let size = CGSize(width: 320, height: 284)

    let field = NSSecureTextField()
    /// Host for the `LAAuthenticationView` (the listener installs it).
    let touchIDSlot = NSView()

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        appearance = NSAppearance(named: .darkAqua)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        // A dark tint so the card reads as the login window over a bright screen too.
        let tint = NSView(frame: bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        addSubview(tint)

        let w = Self.size.width

        // The user's picture (login-window style), or a person glyph.
        let avatar = NSImageView(frame: NSRect(x: (w - 76) / 2, y: 184, width: 76, height: 76))
        avatar.image = Self.userPicture()
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.contentTintColor = .white.withAlphaComponent(0.85)
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 38
        avatar.layer?.masksToBounds = true
        addSubview(avatar)

        let name = Self.label(NSFullUserName(), size: 17, weight: .semibold, color: .white)
        name.frame = NSRect(x: 16, y: 152, width: w - 32, height: 22)
        addSubview(name)

        let hint = Self.label("Touch ID or Enter Password", size: 12, weight: .regular,
                              color: NSColor.white.withAlphaComponent(0.6))
        hint.frame = NSRect(x: 16, y: 132, width: w - 32, height: 16)
        addSubview(hint)

        // The pill password field.
        let pill = NSView(frame: NSRect(x: (w - 220) / 2, y: 84, width: 220, height: 32))
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 16
        pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        pill.layer?.borderWidth = 0.5
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        addSubview(pill)
        field.frame = NSRect(x: 14, y: 6, width: 192, height: 20)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .white
        field.alignment = .left
        field.placeholderAttributedString = NSAttributedString(
            string: "Enter Password",
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.5),
                         .font: NSFont.systemFont(ofSize: 13)])
        (field.cell as? NSSecureTextFieldCell)?.echosBullets = true
        pill.addSubview(field)

        // The live Touch ID glyph.
        // Clipped: the embedded Touch ID view draws larger than its frame at bigger control sizes.
        touchIDSlot.frame = NSRect(x: (w - 40) / 2, y: 28, width: 40, height: 40)
        touchIDSlot.wantsLayer = true
        touchIDSlot.layer?.masksToBounds = true
        addSubview(touchIDSlot)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The macOS wrong-password shake.
    func shake() {
        guard let layer else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -14, 12, -10, 8, -5, 3, 0]
        a.duration = 0.45
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "shake")
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = .center
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    /// The login picture from the local user record; a person glyph when there is none.
    private static func userPicture() -> NSImage? {
        if let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes)),
           let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(),
                                         attributes: [kODAttributeTypeJPEGPhoto]),
           let values = try? record.values(forAttribute: kODAttributeTypeJPEGPhoto),
           let data = values.first as? Data, let image = NSImage(data: data) {
            return image
        }
        let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
        return NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}
