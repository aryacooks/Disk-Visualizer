import AppKit
import Foundation
import ScannerCore

public struct CleanupItem: Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let size: Int64
    public let isDir: Bool
    public let origin: String        // where it was staged from
}

/// The staged cleanup queue.
///
/// Nothing is ever removed at the moment it is added. Items accumulate here,
/// the user reviews the whole list with a running total, and only then is
/// anything moved — to the Trash, never unlinked. Sizes are re-measured
/// immediately before the move, so the "freed" figure is what actually left.
@MainActor
public final class CleanupQueue: ObservableObject {
    @Published public private(set) var items: [CleanupItem] = []
    @Published public var showReview = false
    @Published public var outcome: String?

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    public var count: Int { items.count }

    /// Locations we refuse to stage at all.
    private static let denyPrefixes = [
        "/System", "/bin", "/sbin", "/Library/Apple", "/private/var/db", "/usr/bin", "/usr/lib"
    ]

    public static func isProtected(_ path: String) -> Bool {
        if denyPrefixes.contains(where: { path.hasPrefix($0) }) { return true }
        if path.hasPrefix("/usr") && !path.hasPrefix("/usr/local") { return true }
        // Never stage the whole home folder or a volume root.
        if path == NSHomeDirectory() || path == "/" { return true }
        return false
    }

    public func contains(_ path: String) -> Bool { items.contains { $0.path == path } }

    @discardableResult
    public func add(path: String, name: String, size: Int64, isDir: Bool, origin: String) -> Bool {
        guard !CleanupQueue.isProtected(path), !contains(path) else { return false }
        // Adding a folder supersedes anything already staged inside it.
        items.removeAll { $0.path.hasPrefix(path + "/") }
        guard !items.contains(where: { path.hasPrefix($0.path + "/") }) else { return false }
        items.append(CleanupItem(path: path, name: name, size: size, isDir: isDir, origin: origin))
        return true
    }

    public func add(store: NodeStore, nodeIndex: Int, origin: String) -> Bool {
        let isDir = store.isDir(nodeIndex)
        return add(path: store.path(nodeIndex),
                   name: store.name(nodeIndex),
                   size: isDir ? store.subtree[nodeIndex] : store.allocated[nodeIndex],
                   isDir: isDir, origin: origin)
    }

    public func remove(_ path: String) { items.removeAll { $0.path == path } }
    public func clear() { items.removeAll() }

    /// Moves everything staged to the Trash.
    public func emptyToTrash() {
        var freed: Int64 = 0
        var moved = 0
        var skipped: [String] = []

        for item in items {
            guard !CleanupQueue.isProtected(item.path) else {
                skipped.append("\(item.name) (protected)"); continue
            }
            guard FileManager.default.fileExists(atPath: item.path) else {
                skipped.append("\(item.name) (already gone)"); continue
            }
            if isInsideRunningApp(item.path) {
                skipped.append("\(item.name) (app is running)"); continue
            }
            // Re-measure so the reported figure is the real one.
            let sizeNow = AppInventory.directorySize(item.path)
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path),
                                                  resultingItemURL: nil)
                freed += sizeNow
                moved += 1
            } catch {
                skipped.append("\(item.name) (\(error.localizedDescription))")
            }
        }

        var msg = "Moved \(moved) item\(moved == 1 ? "" : "s") to the Trash, freeing \(Fmt.bytes(freed))."
        if !skipped.isEmpty {
            msg += " Skipped \(skipped.count): " + skipped.prefix(3).joined(separator: "; ")
        }
        msg += " Everything is recoverable from the Trash."
        outcome = msg
        items.removeAll()
        showReview = false
    }

    private func isInsideRunningApp(_ path: String) -> Bool {
        for app in NSWorkspace.shared.runningApplications {
            guard let url = app.bundleURL else { continue }
            if path == url.path || path.hasPrefix(url.path + "/") { return true }
        }
        return false
    }
}
