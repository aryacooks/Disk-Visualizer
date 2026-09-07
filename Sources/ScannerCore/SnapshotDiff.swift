import Foundation

public enum ChangeKind: String, Sendable {
    case grew, shrank, added, removed
}

public struct SnapshotChange: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let kind: ChangeKind
    public let oldSize: Int64
    public let newSize: Int64
    public let isDir: Bool

    public var delta: Int64 { newSize - oldSize }
    public var magnitude: Int64 { abs(delta) }
}

public struct SnapshotDiffResult: Sendable {
    public var changes: [SnapshotChange] = []
    public var oldTotal: Int64 = 0
    public var newTotal: Int64 = 0
    public var comparedPaths = 0
    public var elapsed: TimeInterval = 0

    public var netChange: Int64 { newTotal - oldTotal }
    public var grew: [SnapshotChange] { changes.filter { $0.kind == .grew || $0.kind == .added } }
    public var shrank: [SnapshotChange] { changes.filter { $0.kind == .shrank || $0.kind == .removed } }
    public var totalGrowth: Int64 { grew.reduce(0) { $0 + $1.magnitude } }
    public var totalShrink: Int64 { shrank.reduce(0) { $0 + $1.magnitude } }
}

/// Compares two saved scans by path.
///
/// Comparing every node would mean building 2.3M path strings twice. Instead we
/// index only what a person can act on: every directory, plus files above a size
/// floor. A directory's parent is always a directory and always has a lower
/// index, so paths can be built in one forward pass with no recursion.
public enum SnapshotDiffEngine {

    public static func diff(old: NodeStore, new: NodeStore,
                            fileFloor: Int64 = 8 * 1024 * 1024,
                            minDelta: Int64 = 1024 * 1024) -> SnapshotDiffResult {
        let t0 = DispatchTime.now()
        var out = SnapshotDiffResult()
        out.oldTotal = old.subtree.first ?? 0
        out.newTotal = new.subtree.first ?? 0

        let oldMap = index(old, fileFloor: fileFloor)
        let newMap = index(new, fileFloor: fileFloor)
        out.comparedPaths = max(oldMap.count, newMap.count)

        var changes: [SnapshotChange] = []

        for (path, entry) in newMap {
            if let before = oldMap[path] {
                let delta = entry.size - before.size
                if abs(delta) >= minDelta {
                    changes.append(SnapshotChange(path: path, name: entry.name,
                                                  kind: delta > 0 ? .grew : .shrank,
                                                  oldSize: before.size, newSize: entry.size,
                                                  isDir: entry.isDir))
                }
            } else if entry.size >= minDelta {
                changes.append(SnapshotChange(path: path, name: entry.name, kind: .added,
                                              oldSize: 0, newSize: entry.size, isDir: entry.isDir))
            }
        }
        for (path, before) in oldMap where newMap[path] == nil {
            if before.size >= minDelta {
                changes.append(SnapshotChange(path: path, name: before.name, kind: .removed,
                                              oldSize: before.size, newSize: 0, isDir: before.isDir))
            }
        }

        // A folder that grew because one child grew shouldn't be listed twice at
        // every level; keep the deepest attribution by dropping ancestors whose
        // delta is fully explained by a listed descendant.
        changes.sort { $0.magnitude > $1.magnitude }
        var kept: [SnapshotChange] = []
        var claimed: [String: Int64] = [:]
        for c in changes {
            let explained = claimed[c.path] ?? 0
            if abs(c.delta - explained) < minDelta && c.isDir { continue }
            kept.append(c)
            // Credit this change to every ancestor path.
            var p = (c.path as NSString).deletingLastPathComponent
            while p.count > 1 {
                claimed[p, default: 0] += c.delta
                p = (p as NSString).deletingLastPathComponent
            }
        }

        out.changes = kept.sorted { $0.magnitude > $1.magnitude }
        out.elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
        return out
    }

    private struct Entry { let name: String; let size: Int64; let isDir: Bool }

    private static func index(_ store: NodeStore, fileFloor: Int64) -> [String: Entry] {
        var map: [String: Entry] = [:]
        map.reserveCapacity(store.count / 4)
        var dirPath = [String?](repeating: nil, count: store.count)
        guard store.count > 0 else { return map }

        dirPath[0] = store.name(0)
        map[store.name(0)] = Entry(name: store.name(0), size: store.subtree[0], isDir: true)

        for i in 1..<store.count {
            let p = Int(store.parent[i])
            guard p >= 0, let base = dirPath[p] else { continue }
            let isDir = store.isDir(i)
            let size = isDir ? store.subtree[i] : store.allocated[i]
            if !isDir && size < fileFloor { continue }
            let full = base + "/" + store.name(i)
            if isDir { dirPath[i] = full }
            map[full] = Entry(name: store.name(i), size: size, isDir: isDir)
        }
        return map
    }
}
