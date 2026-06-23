import Foundation
import os

private let memoryLog = Logger(subsystem: "ThreeFingerSwitcher", category: "MemoryStore")

/// The scope a write/forget targets.
enum MemoryScope: String, Equatable, Sendable { case fact, subfile }

/// The result of a memory write/update/promote — what landed, and whether eviction ran.
struct MemoryWriteOutcome: Equatable, Sendable {
    /// A short, redacted human description for the audit `argumentsSummary` / the tool `summary`.
    var summary: String
    /// Facts evicted to a subfile to keep core under the cap (informational; may be empty).
    var evictedToSubfile: String?
}

/// The result of a forget — how many entries it touched and whether the op classifies dangerous.
struct MemoryForgetOutcome: Equatable, Sendable {
    var removedCount: Int
    var dangerous: Bool
    var summary: String
}

/// The two-tier on-disk memory store (design §5, MLX-free Core). Parallels `DiskProjectStore`: an
/// Application-Support directory under `ThreeFingerSwitcher/memory`, a sanitized deterministic subfile
/// filename, every `FileManager`/`FileHandle` throw mapped into `MemoryError` AT THE IO BOUNDARY (raw OS
/// error to the log only). The pure `MemoryDocument`/`MemorySubfile`/reconcile logic never touches
/// `FileManager`; this store bridges IO and produces the `[IndexedDoc]` snapshot the SHARED
/// `InMemoryDocIndex` answers over (NO second retriever). Containment is structural: every write is
/// rooted at `directory` via the `DiskProjectStore` sanitizer, so a write can never escape the memory
/// folder — which is what makes auto-when-parked safe (design §4).
final class MemoryStore: @unchecked Sendable {
    private let directory: URL
    /// Where evicted core facts are bundled (design §2/§3).
    static let evictionSubfileName = "evicted-from-core"

    /// Test/seam initializer: inject an isolated directory (e.g. a temp dir).
    init(directory: URL = MemoryStore.defaultDirectory()) {
        self.directory = directory
    }

    /// Default: `~/Library/Application Support/ThreeFingerSwitcher/memory` (parallels `DiskProjectStore`).
    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ThreeFingerSwitcher/memory", isDirectory: true)
    }

    private var coreURL: URL { directory.appendingPathComponent("core.md") }
    private var subfilesDir: URL { directory.appendingPathComponent("subfiles", isDirectory: true) }

    /// A safe, deterministic subfile filename — REUSES `DiskProjectStore.fileName(for:)` (alphanumerics
    /// + `-_ `, never empty, traversal/slashes collapsed to `-`), so a hostile `name` (`../`, slashes)
    /// stays rooted inside the memory folder (containment).
    private func subfileURL(for name: String) -> URL {
        subfilesDir.appendingPathComponent(DiskProjectStore.fileName(for: name))
    }

    // MARK: - Load + index (design §5, task §4.2)

    /// Read `core.md` off disk into a `MemoryDocument`, list + parse subfiles, run reconcile. Bounded:
    /// a malformed subfile is excluded (a logged problem), the rest load; an absent folder is an empty
    /// (valid) document. A genuinely unreadable core (present but undecodable) is `.unreadableCore`.
    func loadCore() throws -> MemoryDocument {
        let (doc, subfiles, _) = try loadAll()
        return doc.reconciled(withSubfiles: subfiles)
    }

    /// Load + reconcile + produce the memory `IndexedDoc`s — one `.memoryCore` (facts) + one
    /// `.memorySubfile` per subfile — plus the bodies map, for merging into the SHARED snapshot.
    func indexedDocs() throws -> (docs: [IndexedDoc], bodies: [String: String]) {
        let (doc, subfiles, _) = try loadAll()
        let reconciled = doc.reconciled(withSubfiles: subfiles)

        var docs: [IndexedDoc] = []
        var bodies: [String: String] = [:]

        let coreID = MemoryStore.coreDocID
        docs.append(IndexedDoc(id: coreID, title: "Core memory",
                               summary: "Ground-truth facts about the user.",
                               keywords: ["memory", "facts", "core", "about", "me"],
                               kind: .memoryCore, bodyPath: coreURL,
                               updatedAt: (try? coreURL.modifiedDate()) ?? Date(timeIntervalSince1970: 0)))
        bodies[coreID] = reconciled.factsBody()

        for sub in subfiles {
            let id = MemorySubfile.docID(for: sub.name)
            docs.append(sub.indexedDoc(bodyPath: subfileURL(for: sub.name)))
            bodies[id] = sub.body
        }
        return (docs, bodies)
    }

    static let coreDocID = "memory/core"

    /// A subfile body / the CORE facts text, for the shared index (cached at the file layer by the OS).
    func body(of id: String) throws -> String {
        if id == MemoryStore.coreDocID { return try loadCore().factsBody() }
        let (_, subfiles, _) = try loadAll()
        guard let sub = subfiles.first(where: { MemorySubfile.docID(for: $0.name) == id }) else {
            throw MemoryError.subfileNotFound(name: id)
        }
        return sub.body
    }

    // MARK: - Writes (design §3/§4, task §4.3)

    /// Write/update a fact or a subfile. A fact write applies the cap + eviction (evicted facts become a
    /// subfile + TOC entry); a subfile write adds/refreshes its TOC entry. Atomic, then reconciled.
    func write(scope: MemoryScope, name: String?, summary: String?, content: String,
               cap: MemoryCap = .default) throws -> MemoryWriteOutcome {
        switch scope {
        case .fact:
            return try addFact(content, cap: cap, forcePromote: false)
        case .subfile:
            let n = (name?.isEmpty == false) ? name! : Self.derivedSubfileName(from: content)
            try writeSubfile(name: n, summary: summary ?? Self.derivedSummary(from: content), body: content)
            return MemoryWriteOutcome(summary: "Saved note “\(n)” (\(content.utf8.count) bytes).",
                                      evictedToSubfile: nil)
        }
    }

    /// Replace a named subfile's body/summary. Missing subfile → `.subfileNotFound`.
    func update(name: String, content: String, summary: String?) throws -> MemoryWriteOutcome {
        let (_, subfiles, _) = try loadAll()
        guard let existing = subfiles.first(where: { $0.name == name }) else {
            throw MemoryError.subfileNotFound(name: name)
        }
        try writeSubfile(name: name, summary: summary ?? existing.summary, body: content)
        return MemoryWriteOutcome(summary: "Updated note “\(name)” (\(content.utf8.count) bytes).",
                                  evictedToSubfile: nil)
    }

    /// Propose a CORE fact (design §3). The cap is the structural backstop: an approved promotion that
    /// would breach the cap evicts to a subfile. A single fact larger than the whole cap is `.capExceeded`.
    func promote(content: String, cap: MemoryCap = .default) throws -> MemoryWriteOutcome {
        try addFact(content, cap: cap, forcePromote: true)
    }

    /// Remove a fact / a subfile (+ its TOC entry), or a `match` across either tier. A `match` hitting
    /// MANY entries (or a core-wide clear) classifies dangerous (returned so the tool sets `.dangerous`).
    /// A no-match forget is a clean no-op, never a throw.
    func forget(scope: MemoryScope?, name: String?, match: String?) throws -> MemoryForgetOutcome {
        var (doc, subfiles, _) = try loadAll()
        doc = doc.reconciled(withSubfiles: subfiles)
        var removed = 0

        if let name, scope == .subfile {
            if subfiles.contains(where: { $0.name == name }) {
                try deleteSubfileFile(name: name)
                subfiles.removeAll { $0.name == name }
                removed += 1
            }
        } else if let match, !match.isEmpty {
            let needle = match.lowercased()
            // Facts matching the needle.
            let factsBefore = doc.facts.count
            doc.facts.removeAll { $0.text.lowercased().contains(needle) }
            removed += factsBefore - doc.facts.count
            // Subfiles whose name/summary match.
            for sub in subfiles where sub.name.lowercased().contains(needle)
                || sub.summary.lowercased().contains(needle) {
                try deleteSubfileFile(name: sub.name)
                removed += 1
            }
            subfiles.removeAll { $0.name.lowercased().contains(needle) || $0.summary.lowercased().contains(needle) }
        } else if scope == .fact, let name {
            // Forget a fact by exact text.
            let before = doc.facts.count
            doc.facts.removeAll { $0.text == name }
            removed += before - doc.facts.count
        }

        let reconciled = doc.reconciled(withSubfiles: subfiles)
        try writeCore(reconciled)
        let dangerous = Self.isDangerousForget(removedCount: removed, match: match)
        return MemoryForgetOutcome(removedCount: removed, dangerous: dangerous,
                                   summary: removed == 0 ? "Nothing matched — nothing removed."
                                                         : "Removed \(removed) memory item(s).")
    }

    /// A bulk forget (a `match` removing many entries) or a core-wide clear is dangerous (design §4).
    static func isDangerousForget(removedCount: Int, match: String?) -> Bool {
        // A `match`-driven forget that hit more than one entry escalates; a targeted single forget does not.
        (match != nil && removedCount > 1)
    }

    // MARK: - Fact write + eviction core

    private func addFact(_ content: String, cap: MemoryCap, forcePromote: Bool) throws -> MemoryWriteOutcome {
        let (rawDoc, subfiles, _) = try loadAll()
        var doc = rawDoc.reconciled(withSubfiles: subfiles)
        let fact = MemoryFact(content)

        // A single fact larger than the whole cap can never fit. If forced (promote), it's a clean
        // `.capExceeded`; for a plain fact write it is routed to a subfile (it is detail, not a fact).
        let soloByteCount = MemoryDocument(facts: [fact]).serialized().utf8.count
        if soloByteCount > cap.maxBytes {
            if forcePromote { throw MemoryError.capExceeded }
            let n = Self.derivedSubfileName(from: content)
            try writeSubfile(name: n, summary: Self.derivedSummary(from: content), body: content)
            return MemoryWriteOutcome(summary: "Too long for core — saved as note “\(n)”.",
                                      evictedToSubfile: n)
        }

        doc.facts.append(fact)
        var evictedName: String?
        if doc.exceeds(cap) {
            let (kept, evicted) = doc.evicting(toFit: cap)
            doc = kept
            if !evicted.isEmpty {
                evictedName = try appendEviction(evicted)
                // Re-list subfiles so the eviction subfile's TOC entry reconciles in.
                let (_, freshSubfiles, _) = try loadAll()
                doc = doc.reconciled(withSubfiles: freshSubfiles)
            }
        }
        try writeCore(doc)
        return MemoryWriteOutcome(
            summary: evictedName == nil ? "Kept in core (\(content.utf8.count) bytes)."
                                        : "Kept in core; evicted older facts to note “\(evictedName!)”.",
            evictedToSubfile: evictedName)
    }

    /// Bundle evicted facts into the eviction subfile (appending to its body if it already exists).
    private func appendEviction(_ facts: [MemoryFact]) throws -> String {
        let name = Self.evictionSubfileName
        let (_, subfiles, _) = try loadAll()
        let existingBody = subfiles.first(where: { $0.name == name })?.body
        let appended = facts.map { "- \($0.text)" }.joined(separator: "\n")
        let body = [existingBody, appended].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n")
        try writeSubfile(name: name, summary: "Detail facts evicted from core to stay within the cap.",
                         body: body)
        return name
    }

    // MARK: - IO boundary (every throw maps to MemoryError here; raw text to the log only)

    /// Read core + all subfiles + the bounded problems. An absent folder is an empty doc.
    private func loadAll() throws -> (MemoryDocument, [MemorySubfile], [MemoryError]) {
        let fm = FileManager.default
        var doc = MemoryDocument()
        if fm.fileExists(atPath: coreURL.path) {
            do {
                doc = MemoryDocument.parse(try String(contentsOf: coreURL, encoding: .utf8))
            } catch {
                memoryLog.error("core read failed: \(String(describing: error), privacy: .public)")
                throw MemoryError.unreadableCore(detail: String(describing: error))
            }
        }
        var subfiles: [MemorySubfile] = []
        var problems: [MemoryError] = []
        if let entries = try? fm.contentsOfDirectory(at: subfilesDir, includingPropertiesForKeys: nil) {
            for file in entries.filter({ $0.pathExtension == "md" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let stem = file.deletingPathExtension().lastPathComponent
                switch MemorySubfile.parse(text, fallbackName: stem) {
                case let .success(s): subfiles.append(s)
                case let .failure(e):
                    problems.append(e)
                    memoryLog.error("subfile parse failed: \(String(describing: e), privacy: .public)")
                }
            }
        }
        return (doc, subfiles, problems)
    }

    private func writeCore(_ doc: MemoryDocument) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(doc.serialized().utf8).write(to: coreURL, options: .atomic)
        } catch {
            memoryLog.error("core write failed: \(String(describing: error), privacy: .public)")
            throw MemoryError.writeFailed(detail: String(describing: error))
        }
    }

    private func writeSubfile(name: String, summary: String, body: String) throws {
        let sub = MemorySubfile(name: name, summary: summary, body: body, updatedAt: Date())
        do {
            try FileManager.default.createDirectory(at: subfilesDir, withIntermediateDirectories: true)
            try Data(sub.serialized().utf8).write(to: subfileURL(for: name), options: .atomic)
            // Keep the core TOC honest after a subfile write (reconcile against the fresh folder).
            let (doc, subfiles, _) = try loadAll()
            try writeCore(doc.reconciled(withSubfiles: subfiles))
        } catch let e as MemoryError {
            throw e
        } catch {
            memoryLog.error("subfile write failed: \(String(describing: error), privacy: .public)")
            throw MemoryError.writeFailed(detail: String(describing: error))
        }
    }

    private func deleteSubfileFile(name: String) throws {
        do {
            let url = subfileURL(for: name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            memoryLog.error("subfile delete failed: \(String(describing: error), privacy: .public)")
            throw MemoryError.writeFailed(detail: String(describing: error))
        }
    }

    // MARK: - Derivations

    static func derivedSubfileName(from content: String) -> String {
        let firstLine = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? "note"
        let slug = SkillStore.slug(firstLine)
        return slug.isEmpty ? "note" : String(slug.prefix(48))
    }

    static func derivedSummary(from content: String) -> String {
        let firstLine = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? content
        return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
    }
}

private extension URL {
    func modifiedDate() throws -> Date {
        try resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
    }
}
