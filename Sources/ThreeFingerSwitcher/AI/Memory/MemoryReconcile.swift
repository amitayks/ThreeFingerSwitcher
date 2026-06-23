import Foundation

/// The pure reconciliation pass (design §6, task §3.1). The subfiles folder is the **existence source of
/// truth**; the CORE's `## Contents` block is a derived view kept honest against it: a subfile with no TOC
/// entry gains one (from its front-matter `summary`); a TOC entry with no backing subfile is dropped.
/// `## Facts` is untouched. Pure — no `FileManager` (the store passes in the parsed subfile front-matters).
extension MemoryDocument {
    /// Return a normalized document whose `## Contents` matches the actual subfiles. Order: existing TOC
    /// entries first (preserving their order, summaries refreshed from the subfile), then any subfiles
    /// missing a TOC entry, appended in the given order.
    func reconciled(withSubfiles subfiles: [MemorySubfile]) -> MemoryDocument {
        let byName = Dictionary(subfiles.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var newContents: [MemoryTOCEntry] = []

        for entry in contents {
            guard let sub = byName[entry.name] else { continue }   // drop stale TOC line (no backing subfile)
            if seen.insert(entry.name).inserted {
                newContents.append(sub.tocEntry)                   // refresh summary from the subfile
            }
        }
        for sub in subfiles where !seen.contains(sub.name) {
            seen.insert(sub.name)
            newContents.append(sub.tocEntry)                       // add missing TOC line from front-matter
        }
        return MemoryDocument(facts: facts, contents: newContents)
    }
}
