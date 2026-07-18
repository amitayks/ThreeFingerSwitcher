import Foundation

/// Pure sentence chunker (`add-voice-computer-use-agent`, design D3): consumes `.response`-channel
/// token text incrementally and emits speakable chunks at sentence boundaries, so the FIRST sentence
/// can start speaking while the rest of the reply is still generating. Rules:
/// - A chunk closes at a sentence terminator (`.` `!` `?` `…`) followed by whitespace/end, or at a
///   paragraph break (`\n\n`).
/// - A chunk that grows past `maxChunkLength` without a terminator flushes at the last whitespace
///   (never mid-word) so a long unpunctuated stream still speaks.
/// - Fenced code blocks (``` … ```) are NEVER read symbol-by-symbol: the whole fence collapses to a
///   spoken summary ("Code block, N lines."). The VISIBLE transcript keeps the full text — this
///   chunker only feeds the synthesizer.
/// - `flush()` emits whatever remains at stream end.
///
/// Value type, no clocks, no I/O — the full behavior is unit-tested.
public struct SentenceChunker {

    public var maxChunkLength: Int

    private var buffer: String = ""
    private var inFence = false
    private var fenceLineCount = 0

    public init(maxChunkLength: Int = 280) {
        self.maxChunkLength = maxChunkLength
    }

    /// Feed streamed text; returns every chunk that CLOSED as a result (usually zero or one; a large
    /// paste can close several).
    public mutating func consume(_ text: String) -> [String] {
        var closed: [String] = []
        for character in text {
            append(character, into: &closed)
        }
        return closed
    }

    /// Stream end: emit the remainder (and close an unterminated fence honestly).
    public mutating func flush() -> String? {
        if inFence {
            // An unterminated fence still summarizes (the reply was cut off mid-code).
            let summary = fenceSummary()
            inFence = false
            fenceLineCount = 0
            buffer = ""
            return summary
        }
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    // MARK: - Internals

    private mutating func append(_ character: Character, into closed: inout [String]) {
        buffer.append(character)

        // Fence tracking is line-oriented: a line that is exactly ``` (with optional language tag on
        // open) toggles the fence. Detect on newline so partial tokens can't half-toggle.
        if character == "\n" {
            let lastLine = lastCompletedLine()
            if lastLine.hasPrefix("```") {
                if inFence {
                    // CLOSING fence: drop the buffered code, emit the summary chunk.
                    inFence = false
                    let summary = fenceSummary()
                    fenceLineCount = 0
                    buffer = ""
                    closed.append(summary)
                } else {
                    // OPENING fence: whatever preceded it closes as its own chunk first.
                    inFence = true
                    fenceLineCount = 0
                    let before = String(buffer.dropLast(lastLine.count + 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    buffer = ""
                    if !before.isEmpty { closed.append(before) }
                }
                return
            }
            if inFence {
                fenceLineCount += 1
                buffer = ""   // code lines are never spoken; the count is the summary's payload
                return
            }
        }

        guard !inFence else { return }

        // Paragraph break closes a chunk.
        if buffer.hasSuffix("\n\n") {
            let chunk = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            if !chunk.isEmpty { closed.append(chunk) }
            return
        }

        // Sentence terminator + trailing whitespace closes a chunk.
        if character.isWhitespace {
            let trimmedTail = buffer.dropLast()   // the whitespace itself
            if let last = trimmedTail.last, ".!?…".contains(last) {
                let chunk = trimmedTail.trimmingCharacters(in: .whitespacesAndNewlines)
                buffer = ""
                if !chunk.isEmpty { closed.append(chunk) }
                return
            }
        }

        // Length guard: flush at the last whitespace so speech never stalls on an unpunctuated run.
        if buffer.count >= maxChunkLength {
            if let cut = buffer.lastIndex(where: { $0.isWhitespace }), cut != buffer.startIndex {
                let chunk = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
                buffer = String(buffer[buffer.index(after: cut)...])
                if !chunk.isEmpty { closed.append(chunk) }
            } else {
                let chunk = buffer
                buffer = ""
                closed.append(chunk)
            }
        }
    }

    private func lastCompletedLine() -> String {
        // `buffer` ends with "\n"; the last completed line is between the previous newline and it.
        let withoutTrailing = buffer.dropLast()
        if let previous = withoutTrailing.lastIndex(of: "\n") {
            return String(withoutTrailing[withoutTrailing.index(after: previous)...])
        }
        return String(withoutTrailing)
    }

    private func fenceSummary() -> String {
        fenceLineCount == 1 ? "Code block, 1 line." : "Code block, \(fenceLineCount) lines."
    }
}
