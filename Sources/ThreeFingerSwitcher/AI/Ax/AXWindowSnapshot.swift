import Foundation
import CryptoKit

/// The computer-use read layer's PURE half (`add-voice-computer-use-agent`, design D5): value models
/// for a window's semantic snapshot, the bounded tree→snapshot builder, and the per-window epoch
/// store that enforces the constrained-ID rule. The live `AXUIElement` boundary (`AXWindowReader`)
/// only produces `AXNodeData` trees; everything below is deterministic and unit-tested over fakes.

/// One node of a window's accessibility tree, as read at the boundary (or faked in tests).
public struct AXNodeData: Equatable, Sendable {
    public var role: String
    public var label: String
    public var value: String
    /// Whether the node supports AXPress / a settable AXValue / keyboard focus.
    public var isPressable: Bool
    public var isSettable: Bool
    public var isFocusable: Bool
    public var children: [AXNodeData]

    public init(role: String, label: String = "", value: String = "",
                isPressable: Bool = false, isSettable: Bool = false, isFocusable: Bool = false,
                children: [AXNodeData] = []) {
        self.role = role
        self.label = label
        self.value = value
        self.isPressable = isPressable
        self.isSettable = isSettable
        self.isFocusable = isFocusable
        self.children = children
    }
}

/// One enumerated, actionable element with its STABLE ID — the only currency the act tools accept
/// (never coordinates, never free-form names). `path` is the child-index walk from the window root
/// used to re-resolve the live element at act time.
public struct AXElementRef: Equatable, Sendable, Codable {
    public var id: String
    public var role: String
    public var label: String
    public var valuePreview: String
    public var isPressable: Bool
    public var isSettable: Bool
    public var path: [Int]
}

/// A window's semantic snapshot: extracted text + the enumerated element list, bounded and honest
/// (`truncated` reports a depth/count cut — never a silently-partial tree presented as complete).
public struct AXWindowSnapshot: Equatable, Sendable {
    public var pid: pid_t
    public var appName: String
    public var title: String
    public var textBlocks: [String]
    public var elements: [AXElementRef]
    public var truncated: Bool
    /// The constrained-ID epoch: an act must name an element from THIS snapshot generation; a newer
    /// read invalidates older IDs' epoch (see `AXSnapshotStore`).
    public var epoch: Int

    /// All extracted text joined for the tool summary / extraction prompts.
    public var joinedText: String { textBlocks.joined(separator: "\n") }

    /// A cheap content fingerprint (verify-after-act compares before/after).
    public var contentHash: String {
        var hasher = SHA256()
        for block in textBlocks { hasher.update(data: Data(block.utf8)) }
        for element in elements { hasher.update(data: Data("\(element.role)|\(element.label)|\(element.valuePreview)".utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }
}

/// Builds a bounded snapshot from a node tree. Pure — the entire behavior is unit-tested with fakes.
public enum AXSnapshotBuilder {

    public struct Limits: Sendable {
        public var maxDepth: Int
        public var maxNodes: Int
        public var maxTextBlocks: Int
        public var maxValuePreview: Int
        public init(maxDepth: Int = 14, maxNodes: Int = 1200, maxTextBlocks: Int = 400,
                    maxValuePreview: Int = 120) {
            self.maxDepth = maxDepth
            self.maxNodes = maxNodes
            self.maxTextBlocks = maxTextBlocks
            self.maxValuePreview = maxValuePreview
        }
    }

    /// Roles whose value is content worth extracting as text.
    private static let textRoles: Set<String> = [
        "AXStaticText", "AXTextArea", "AXTextField", "AXLink", "AXHeading", "AXCell",
    ]

    public static func build(pid: pid_t, appName: String, title: String,
                             root: AXNodeData, epoch: Int,
                             limits: Limits = Limits()) -> AXWindowSnapshot {
        var textBlocks: [String] = []
        var elements: [AXElementRef] = []
        var visited = 0
        var truncated = false

        func walk(_ node: AXNodeData, path: [Int], depth: Int) {
            visited += 1
            if visited > limits.maxNodes || depth > limits.maxDepth {
                truncated = true
                return
            }
            let trimmedValue = node.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if textRoles.contains(node.role), !trimmedValue.isEmpty,
               textBlocks.count < limits.maxTextBlocks {
                textBlocks.append(trimmedValue)
            } else if textRoles.contains(node.role), !trimmedValue.isEmpty {
                truncated = true
            }
            if node.isPressable || node.isSettable {
                elements.append(AXElementRef(
                    id: stableID(role: node.role, label: node.label, path: path),
                    role: node.role,
                    label: node.label,
                    valuePreview: String(trimmedValue.prefix(limits.maxValuePreview)),
                    isPressable: node.isPressable,
                    isSettable: node.isSettable,
                    path: path))
            }
            for (index, child) in node.children.enumerated() {
                walk(child, path: path + [index], depth: depth + 1)
            }
        }

        walk(root, path: [], depth: 0)
        return AXWindowSnapshot(pid: pid, appName: appName, title: title,
                                textBlocks: textBlocks, elements: elements,
                                truncated: truncated, epoch: epoch)
    }

    /// The stable element ID: role + label + hierarchical path, hashed. Stable across re-reads of an
    /// unchanged window (same walk → same path); a moved/renamed element gets a NEW id, which is
    /// exactly the staleness signal the constrained-ID rule wants.
    public static func stableID(role: String, label: String, path: [Int]) -> String {
        let raw = "\(role)|\(label)|\(path.map(String.init).joined(separator: "."))"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return "el-" + digest.map { String(format: "%02x", $0) }.joined().prefix(10)
    }
}

/// The per-pid latest-snapshot store enforcing the constrained-ID epoch (design D5): an act resolves
/// its element ID against the MOST RECENT snapshot for that window's pid; an ID from an older epoch
/// (or a different window) is `staleElement` — the model must `read_window` again. `@MainActor` like
/// every stateful controller.
@MainActor
public final class AXSnapshotStore {
    private var latest: [pid_t: AXWindowSnapshot] = [:]
    private var nextEpoch = 1

    public init() {}

    /// Register a fresh snapshot, assigning it the next epoch. Returns the stamped snapshot.
    public func register(_ snapshot: AXWindowSnapshot) -> AXWindowSnapshot {
        var stamped = snapshot
        stamped.epoch = nextEpoch
        nextEpoch += 1
        latest[snapshot.pid] = stamped
        return stamped
    }

    public func current(for pid: pid_t) -> AXWindowSnapshot? { latest[pid] }

    /// Resolve an element ID against the CURRENT epoch for `pid`. Throws `staleElement` when the ID
    /// isn't in the latest snapshot — the only recovery is a fresh read.
    public func resolve(_ elementID: String, pid: pid_t) throws -> AXElementRef {
        guard let snapshot = latest[pid],
              let element = snapshot.elements.first(where: { $0.id == elementID }) else {
            throw AXActionError.staleElement
        }
        return element
    }
}
