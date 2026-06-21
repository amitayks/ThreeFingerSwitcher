import Foundation

/// The shipped library of ready-to-use AI commands, grouped into browsable categories (the Hub's "AI
/// Command" source mirrors this the way `ActionBrowser` mirrors `SystemAction`). Each `Entry` pairs a
/// `Category` with a fully-formed `AICommand`; adding a preset to a band copies it with a fresh id
/// (`copy(of:)`) so the same preset can be added twice and edits never mutate the catalog.
///
/// Construction mirrors `AIBand.seeded()`: an `.sfSymbol` icon, a per-category `ItemColor` tint (one
/// consistent hue per category so a band reads at a glance), and an `OutputTarget` chosen so the verb
/// lands in the right place. Side-effecting commands (task / send-to) inherit `confirmBeforeRun = true`
/// from `AICommand.init` — it is never passed explicitly here.
enum AICommandCatalog {
    // MARK: - Categories

    /// A browsable grouping of presets. The `rawValue` is the user-facing `title`; `sfSymbol` is the
    /// section glyph shown in the source browser.
    enum Category: String, CaseIterable, Identifiable {
        case writing = "Writing"
        case tone = "Tone"
        case understand = "Understand"
        case translate = "Translate"
        case developer = "Developer"
        case reply = "Reply"
        case capture = "Capture"
        case vision = "Vision"
        case format = "Format"

        var id: String { rawValue }

        /// The user-facing section title (identical to the `rawValue`).
        var title: String { rawValue }

        /// A representative SF Symbol for the category's section header.
        var sfSymbol: String {
            switch self {
            case .writing:    return "pencil"
            case .tone:       return "theatermasks"
            case .understand: return "brain"
            case .translate:  return "character.bubble"
            case .developer:  return "chevron.left.forwardslash.chevron.right"
            case .reply:      return "arrowshape.turn.up.left"
            case .capture:    return "tray.and.arrow.down"
            case .vision:     return "eye"
            case .format:     return "tablecells"
            }
        }

        /// The shared tint for every command in this category, so a band of presets reads as a coherent
        /// palette (one hue per category, mirroring `AIBand.seeded()`'s per-command tints).
        var tint: ItemColor {
            switch self {
            case .writing:    return ItemColor(red: 0.25, green: 0.72, blue: 0.40)  // green
            case .tone:       return ItemColor(red: 0.95, green: 0.55, blue: 0.30)  // orange
            case .understand: return ItemColor(red: 0.95, green: 0.70, blue: 0.20)  // amber
            case .translate:  return ItemColor(red: 0.66, green: 0.36, blue: 0.86)  // purple
            case .developer:  return ItemColor(red: 0.30, green: 0.62, blue: 0.78)  // teal
            case .reply:      return ItemColor(red: 0.20, green: 0.48, blue: 0.93)  // blue
            case .capture:    return ItemColor(red: 0.90, green: 0.30, blue: 0.30)  // red
            case .vision:     return ItemColor(red: 0.40, green: 0.50, blue: 0.92)  // indigo
            case .format:     return ItemColor(red: 0.50, green: 0.55, blue: 0.60)  // slate
            }
        }
    }

    // MARK: - Entries

    /// One catalog row: a `Category` paired with its preset command.
    struct Entry {
        let category: Category
        let command: AICommand
    }

    /// All shipped presets, in category order. The catalog is the single source of truth; the Hub
    /// source browser groups these by `category`, and `seeded()` curates a subset for a fresh install.
    static let entries: [Entry] = writing + tone + understand + translate + developer + reply + capture + vision + format

    // MARK: - Queries

    /// The preset commands in a category, in catalog order (used by the source browser's sections).
    static func commands(in category: Category) -> [AICommand] {
        entries.filter { $0.category == category }.map(\.command)
    }

    /// A value copy of a command with a FRESHLY minted id, so the same preset can be added to a band
    /// twice without an id collision and later edits never mutate the catalog's stored command.
    static func copy(of command: AICommand) -> AICommand {
        var c = command
        c.id = UUID()
        return c
    }

    /// A curated, one-band subset shipped on a fresh install: the handful of verbs that cover the most
    /// common cases, in launcher order. (The full catalog is browsable from the Hub.)
    static func seeded() -> [AICommand] {
        let names = ["Fix Grammar", "Make Concise", "Improve Writing", "Translate",
                     "Explain", "Summarize", "Draft a Reply", "Add to Calendar"]
        // Map by name, then emit in the curated order so the seeded band reads deliberately.
        let byName = Dictionary(entries.map { ($0.command.name, $0.command) }, uniquingKeysWith: { first, _ in first })
        return names.compactMap { byName[$0] }.map(copy(of:))
    }
}

// MARK: - Preset definitions
//
// One `Entry` array per category. Each command is built the same way as `AIBand.seeded()`: an
// `.sfSymbol` icon, the category's shared tint, an input source, a prompt template (templates that
// must yield only the result say so), and an output target.

private extension AICommandCatalog {
    /// Sugar for a preset: applies the category's tint so call sites stay terse and consistent.
    static func preset(_ category: Category, _ name: String, icon: String, input: InputSource,
                       output: OutputTarget, template: String,
                       runtimeParameter: RuntimeParameter? = nil) -> Entry {
        Entry(category: category,
              command: AICommand(name: name, icon: .sfSymbol(icon), tint: category.tint,
                                  input: input, promptTemplate: template, output: output,
                                  runtimeParameter: runtimeParameter))
    }

    // MARK: Writing

    static let writing: [Entry] = [
        preset(.writing, "Fix Grammar", icon: "text.badge.checkmark", input: .selection, output: .replaceSelection,
               template: "Fix the spelling and grammar of the following text. Return only the corrected text, with no commentary:\n\n{input}"),
        preset(.writing, "Improve Writing", icon: "wand.and.stars", input: .selection, output: .replaceSelection,
               template: "Improve the clarity and flow of the following while preserving its meaning and voice. Return only the rewritten text:\n\n{input}"),
        preset(.writing, "Make Concise", icon: "scissors", input: .selection, output: .replaceSelection,
               template: "Rewrite the following to be as concise as possible while preserving its meaning. Return only the rewritten text:\n\n{input}"),
        preset(.writing, "Expand", icon: "arrow.up.left.and.arrow.down.right", input: .selection, output: .replaceSelection,
               template: "Expand the following terse note into clear, complete prose. Return only the rewritten text:\n\n{input}"),
        preset(.writing, "Simplify", icon: "text.append", input: .selection, output: .replaceSelection,
               template: "Rewrite the following in plain language a non-expert can follow. Return only the rewritten text:\n\n{input}"),
        preset(.writing, "Proofread", icon: "checklist", input: .selection, output: .previewOnly,
               template: "List the spelling, grammar, and clarity issues in the following as a short bulleted list:\n\n{input}"),
        preset(.writing, "Bulletize", icon: "list.bullet", input: .selection, output: .replaceSelection,
               template: "Rewrite the following as a concise bulleted list. Return only the list:\n\n{input}"),
        preset(.writing, "Active Voice", icon: "bolt.fill", input: .selection, output: .replaceSelection,
               template: "Rewrite the following in the active voice. Return only the rewritten text:\n\n{input}"),
    ]

    // MARK: Tone

    static let tone: [Entry] = [
        preset(.tone, "Make Professional", icon: "briefcase.fill", input: .selection, output: .replaceSelection,
               template: "Rewrite the following in a professional, workplace-appropriate tone. Return only the rewritten text:\n\n{input}"),
        preset(.tone, "Make Friendly", icon: "face.smiling", input: .selection, output: .replaceSelection,
               template: "Rewrite the following in a warmer, friendlier tone. Return only the rewritten text:\n\n{input}"),
        preset(.tone, "Make Confident", icon: "hand.thumbsup.fill", input: .selection, output: .replaceSelection,
               template: "Rewrite the following to remove hedging and sound confident. Return only the rewritten text:\n\n{input}"),
        preset(.tone, "De-escalate", icon: "wind", input: .selection, output: .replaceSelection,
               template: "Rewrite the following to be calm, neutral, and professional, removing any anger or snark while keeping the substance. Return only the rewritten text:\n\n{input}"),
        preset(.tone, "Make Funnier", icon: "face.dashed", input: .selection, output: .replaceSelection,
               template: "Rewrite the following to be a bit funnier without changing the meaning. Return only the rewritten text:\n\n{input}"),
    ]

    // MARK: Understand

    static let understand: [Entry] = [
        preset(.understand, "Explain", icon: "lightbulb", input: .selection, output: .previewOnly,
               template: "Explain the following clearly and concisely for a curious non-expert:\n\n{input}"),
        preset(.understand, "Summarize", icon: "text.line.first.and.arrowtriangle.forward", input: .selection, output: .previewOnly,
               template: "Summarize the following in a few short bullet points:\n\n{input}"),
        preset(.understand, "TL;DR", icon: "text.alignleft", input: .selection, output: .previewOnly,
               template: "Give a one-sentence TL;DR of the following:\n\n{input}"),
        preset(.understand, "Key Points & Action Items", icon: "checklist.checked", input: .selection, output: .previewOnly,
               template: "Extract the key points and any action items from the following as two short bulleted lists:\n\n{input}"),
        preset(.understand, "Define", icon: "character.book.closed", input: .selection, output: .previewOnly,
               template: "Define the selected word or phrase in this context, briefly:\n\n{input}"),
        preset(.understand, "Pros & Cons", icon: "arrow.up.arrow.down", input: .selection, output: .previewOnly,
               template: "List the pros and cons of the following as two short bulleted lists:\n\n{input}"),
        preset(.understand, "Counterargument", icon: "arrow.uturn.backward", input: .selection, output: .previewOnly,
               template: "Give the strongest counterargument to the following:\n\n{input}"),
    ]

    // MARK: Translate

    static let translate: [Entry] = [
        preset(.translate, "Translate", icon: "character.bubble", input: .selection, output: .previewOnly,
               template: "Translate the following to {lang}. Return only the translation:\n\n{input}",
               runtimeParameter: .language(default: "English")),
        preset(.translate, "Translate in Place", icon: "character.bubble.fill", input: .selection, output: .replaceSelection,
               template: "Translate the following to {lang}. Return only the translation:\n\n{input}",
               runtimeParameter: .language(default: "English")),
        preset(.translate, "Detect & Translate to English", icon: "globe", input: .selection, output: .previewOnly,
               template: "Detect the language of the following and translate it to English. Return only the translation:\n\n{input}"),
        preset(.translate, "Explain Idiom", icon: "quote.bubble", input: .selection, output: .previewOnly,
               template: "Explain what this idiom or expression means (not a literal translation):\n\n{input}"),
    ]

    // MARK: Developer

    static let developer: [Entry] = [
        preset(.developer, "Explain Code", icon: "curlybraces", input: .selection, output: .previewOnly,
               template: "Explain what this code does, step by step, concisely:\n\n{input}"),
        preset(.developer, "Explain Error", icon: "exclamationmark.triangle", input: .selection, output: .previewOnly,
               template: "Explain this error or stack trace and the most likely fix:\n\n{input}"),
        preset(.developer, "Commit Message", icon: "checkmark.seal", input: .clipboard, output: .pasteAtCursor,
               template: "Write a concise Conventional Commits message for this diff. Return only the message:\n\n{input}"),
        preset(.developer, "Add Docstring", icon: "text.quote", input: .selection, output: .previewOnly,
               template: "Add a clear docstring and comments to this code. Return only the updated code:\n\n{input}"),
        preset(.developer, "Regex from Description", icon: "asterisk", input: .selection, output: .previewOnly,
               template: "Write a regular expression that does the following. Return only the regex:\n\n{input}"),
        preset(.developer, "Explain Regex", icon: "magnifyingglass", input: .selection, output: .previewOnly,
               template: "Explain what this regular expression matches, concisely:\n\n{input}"),
        preset(.developer, "Rewrite in Language", icon: "arrow.triangle.2.circlepath", input: .selection, output: .previewOnly,
               template: "Rewrite this code in {lang}. Return only the code:\n\n{input}",
               runtimeParameter: .codeLanguage(default: "Python")),
        preset(.developer, "Shell Command", icon: "terminal", input: .selection, output: .previewOnly,
               template: "Write a single shell command that does the following. Return only the command:\n\n{input}"),
        preset(.developer, "Name This", icon: "tag", input: .selection, output: .previewOnly,
               template: "Suggest 3 clear, idiomatic names for this. Return only the names, one per line:\n\n{input}"),
    ]

    // MARK: Reply

    static let reply: [Entry] = [
        preset(.reply, "Draft a Reply", icon: "arrowshape.turn.up.left", input: .selection, output: .previewOnly,
               template: "Draft a clear, friendly reply to the following message. Return only the reply:\n\n{input}"),
        preset(.reply, "Polite Decline", icon: "hand.raised", input: .selection, output: .previewOnly,
               template: "Draft a polite, brief decline in response to the following. Return only the reply:\n\n{input}"),
        preset(.reply, "Quick Acknowledge", icon: "checkmark.circle", input: .selection, output: .previewOnly,
               template: "Draft a short acknowledgement reply (e.g. \"Got it, will do\") to the following:\n\n{input}"),
        preset(.reply, "Summarize Thread then Reply", icon: "bubble.left.and.bubble.right", input: .selection, output: .previewOnly,
               template: "Summarize this thread in one line, then draft a suggested reply:\n\n{input}"),
    ]

    // MARK: Capture (task outputs; `confirmBeforeRun` derives ON automatically — never passed here)

    static let capture: [Entry] = [
        preset(.capture, "Add to Calendar", icon: "calendar.badge.plus", input: .selection, output: .runTask(.addToCalendar),
               template: "Extract a calendar event from the following text. Today is {date}. If the text does not describe an event, decline.\n\n{input}"),
        preset(.capture, "Add to Reminders", icon: "checklist", input: .selection, output: .runTask(.addToReminder),
               template: "Extract a to-do/reminder from the following text. Today is {date}. If it describes no task, decline.\n\n{input}"),
        preset(.capture, "New Contact", icon: "person.crop.circle.badge.plus", input: .selection, output: .runTask(.newContact),
               template: "Extract contact details (name, email, phone, organization) from the following. If there are none, decline.\n\n{input}"),
        preset(.capture, "Save to Project", icon: "tray.and.arrow.down.fill", input: .selection, output: .runTask(.saveToProject(project: "Inbox")),
               template: "Return the following content to save, lightly cleaned up:\n\n{input}"),
        preset(.capture, "Open with Tool…", icon: "arrow.up.forward.app", input: .selection, output: .runTask(.openToolWithPayload(tool: "")),
               template: "{input}"),
        preset(.capture, "Send to Shortcut…", icon: "bolt.fill", input: .selection, output: .sendTo(.shortcut(name: "")),
               template: "{input}"),
    ]

    // MARK: Vision (output `.previewOnly` — these need a vision model). Image comes from a captured
    // screen region (`.screenRegion`) or the live clipboard image (`.clipboardImage`, on-demand).

    static let vision: [Entry] = [
        preset(.vision, "What Is This?", icon: "questionmark.circle", input: .screenRegion, output: .previewOnly,
               template: "What is shown here? Answer concisely."),
        preset(.vision, "Describe Clipboard Image", icon: "photo", input: .clipboardImage, output: .previewOnly,
               template: "What is shown in this image? Answer concisely."),
        preset(.vision, "Clipboard Image → Text (OCR)", icon: "doc.text.viewfinder", input: .clipboardImage, output: .previewOnly,
               template: "Transcribe all the text shown in this image exactly. Return only the text."),
        preset(.vision, "Extract Text (OCR)", icon: "text.viewfinder", input: .screenRegion, output: .previewOnly,
               template: "Transcribe all the text shown here exactly. Return only the text."),
        preset(.vision, "Explain This Chart", icon: "chart.bar", input: .screenRegion, output: .previewOnly,
               template: "Explain what this chart or diagram shows, concisely."),
        preset(.vision, "Solve This", icon: "function", input: .screenRegion, output: .previewOnly,
               template: "Solve the problem shown here and show the key steps."),
        preset(.vision, "Transcribe Handwriting", icon: "hand.draw", input: .screenRegion, output: .previewOnly,
               template: "Transcribe the handwriting shown here. Return only the text."),
        preset(.vision, "Extract Table to Markdown", icon: "tablecells", input: .screenRegion, output: .previewOnly,
               template: "Extract the table shown here as a Markdown table. Return only the table."),
        preset(.vision, "Translate Image Text", icon: "character.bubble", input: .screenRegion, output: .previewOnly,
               template: "Translate the text shown here to {lang}. Return only the translation.",
               runtimeParameter: .language(default: "English")),
    ]

    // MARK: Format

    static let format: [Entry] = [
        preset(.format, "Format as Markdown Table", icon: "tablecells", input: .selection, output: .replaceSelection,
               template: "Convert the following into a Markdown table. Return only the table:\n\n{input}"),
        preset(.format, "Extract Emails", icon: "envelope", input: .selection, output: .previewOnly,
               template: "Extract all email addresses from the following, one per line. Return only the list:\n\n{input}"),
        preset(.format, "Extract URLs", icon: "link", input: .selection, output: .previewOnly,
               template: "Extract all URLs from the following, one per line. Return only the list:\n\n{input}"),
        preset(.format, "Strip Formatting", icon: "textformat", input: .selection, output: .replaceSelection,
               template: "Return the following as clean plain text with consistent spacing. Return only the text:\n\n{input}"),
        preset(.format, "JSON to YAML", icon: "doc.plaintext", input: .selection, output: .previewOnly,
               template: "Convert this JSON to YAML. Return only the YAML:\n\n{input}"),
        preset(.format, "Clean Up Whitespace", icon: "space", input: .selection, output: .replaceSelection,
               template: "Normalize the whitespace in the following (collapse runs, trim lines). Return only the text:\n\n{input}"),
    ]
}
