import Darwin
import Foundation

/// Flat struct-of-arrays arena. One entry per filesystem object.
/// ~60 bytes/node, contiguous, freed in one shot. See docs/DESIGN.md §2.
public final class NodeStore: @unchecked Sendable {
    public private(set) var parent: [Int32] = []
    public private(set) var childStart: [Int32] = []
    public private(set) var childCount: [Int32] = []
    public private(set) var nameOff: [UInt32] = []
    public private(set) var nameLen: [UInt16] = []
    public private(set) var logical: [Int64] = []
    public private(set) var allocated: [Int64] = []
    public private(set) var subtree: [Int64] = []          // filled by rollUp()
    public private(set) var subtreeLogical: [Int64] = []   // filled by rollUp()
    public private(set) var subtreeCompressed: [Int64] = []// filled by rollUp()
    public private(set) var subtreeFiles: [Int32] = []     // filled by rollUp()
    public private(set) var subtreeDirs: [Int32] = []      // filled by rollUp()
    public private(set) var mtime: [Int32] = []
    public private(set) var crtime: [Int32] = []
    public private(set) var flags: [UInt8] = []
    public private(set) var names: [UInt8] = []            // one contiguous UTF-8 blob

    public static let isDir: UInt8 = 1 << 0
    public static let isLink: UInt8 = 1 << 1
    public static let isCompressed: UInt8 = 1 << 2   // UF_COMPRESSED
    public static let isSparse: UInt8 = 1 << 3
    public static let isHardlinkDup: UInt8 = 1 << 4  // seen this inode already

    private let lock = NSLock()

    /// Rebuild a store from serialized arrays (see `SnapshotStore`).
    public init(parent: [Int32], childStart: [Int32], childCount: [Int32],
                nameOff: [UInt32], nameLen: [UInt16],
                logical: [Int64], allocated: [Int64], subtree: [Int64],
                subtreeLogical: [Int64], subtreeCompressed: [Int64],
                subtreeFiles: [Int32], subtreeDirs: [Int32],
                mtime: [Int32], crtime: [Int32], flags: [UInt8], names: [UInt8]) {
        self.parent = parent; self.childStart = childStart; self.childCount = childCount
        self.nameOff = nameOff; self.nameLen = nameLen
        self.logical = logical; self.allocated = allocated; self.subtree = subtree
        self.subtreeLogical = subtreeLogical; self.subtreeCompressed = subtreeCompressed
        self.subtreeFiles = subtreeFiles; self.subtreeDirs = subtreeDirs
        self.mtime = mtime; self.crtime = crtime; self.flags = flags; self.names = names
    }

    public init(capacityHint: Int = 1 << 20) {
        reserveCapacity(capacityHint)
    }

    private func reserveCapacity(_ n: Int) {
        parent.reserveCapacity(n)
        childStart.reserveCapacity(n)
        childCount.reserveCapacity(n)
        nameOff.reserveCapacity(n)
        nameLen.reserveCapacity(n)
        logical.reserveCapacity(n)
        allocated.reserveCapacity(n)
        subtree.reserveCapacity(n)
        subtreeLogical.reserveCapacity(n)
        subtreeCompressed.reserveCapacity(n)
        subtreeFiles.reserveCapacity(n)
        subtreeDirs.reserveCapacity(n)
        mtime.reserveCapacity(n)
        crtime.reserveCapacity(n)
        flags.reserveCapacity(n)
        names.reserveCapacity(n * 16)
    }

    public var count: Int { parent.count }

    /// Append a whole directory's worth of children in ONE lock acquisition.
    /// This is why the lock isn't a bottleneck: ~1 acquire per directory, not per file.
    public func appendBatch(_ batch: [RawEntry], parentIndex: Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let base = Int32(parent.count)
        if parentIndex >= 0 && Int(parentIndex) < childStart.count {
            childStart[Int(parentIndex)] = base
            childCount[Int(parentIndex)] = Int32(batch.count)
        }
        for e in batch {
            parent.append(parentIndex)
            childStart.append(-1)
            childCount.append(0)
            nameOff.append(UInt32(names.count))
            nameLen.append(UInt16(min(e.name.count, Int(UInt16.max))))
            names.append(contentsOf: e.name)
            logical.append(e.logical)
            allocated.append(e.allocated)
            subtree.append(e.allocated)
            subtreeLogical.append(e.logical)
            let comp = (e.flags & NodeStore.isCompressed != 0 && e.logical > e.allocated) ? (e.logical - e.allocated) : 0
            subtreeCompressed.append(comp)
            mtime.append(e.mtime)
            crtime.append(e.crtime)
            flags.append(e.flags)
            if e.isDir {
                subtreeDirs.append(1)
                subtreeFiles.append(0)
            } else {
                subtreeDirs.append(0)
                subtreeFiles.append(1)
            }
        }
        return base
    }

    public func appendRoot(name: [UInt8]) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let idx = Int32(parent.count)
        parent.append(-1)
        childStart.append(-1)
        childCount.append(0)
        nameOff.append(UInt32(names.count))
        nameLen.append(UInt16(name.count))
        names.append(contentsOf: name)
        logical.append(0)
        allocated.append(0)
        subtree.append(0)
        subtreeLogical.append(0)
        subtreeCompressed.append(0)
        subtreeDirs.append(1)
        subtreeFiles.append(0)
        mtime.append(0)
        crtime.append(0)
        flags.append(NodeStore.isDir)
        return idx
    }

    /// The root is created before we have its own metadata, so fill it in afterwards.
    /// Without this the inspector reports the root as modified in 1970 ("56 years ago").
    public func setRootMetadata(mtime m: Int32, crtime c: Int32) {
        guard !parent.isEmpty else { return }
        mtime[0] = m
        crtime[0] = c
    }

    /// Post-order rollup. Children are always allocated AFTER their parent,
    /// so a single reverse pass is a valid post-order traversal. O(n), no recursion.
    public func rollUp() {
        var i = parent.count - 1
        while i > 0 {
            let p = parent[i]
            if p >= 0 {
                let pi = Int(p)
                subtree[pi] &+= subtree[i]
                subtreeLogical[pi] &+= subtreeLogical[i]
                subtreeCompressed[pi] &+= subtreeCompressed[i]
                subtreeFiles[pi] &+= subtreeFiles[i]
                subtreeDirs[pi] &+= subtreeDirs[i]
            }
            i -= 1
        }
    }

    public func isDir(_ i: Int) -> Bool {
        guard i >= 0 && i < flags.count else { return false }
        return (flags[i] & NodeStore.isDir) != 0
    }

    public func isCompressed(_ i: Int) -> Bool {
        guard i >= 0 && i < flags.count else { return false }
        return (flags[i] & NodeStore.isCompressed) != 0
    }

    public func isSparse(_ i: Int) -> Bool {
        guard i >= 0 && i < flags.count else { return false }
        return (flags[i] & NodeStore.isSparse) != 0
    }

    public func name(_ i: Int) -> String {
        guard i >= 0 && i < nameOff.count else { return "" }
        let off = Int(nameOff[i]), len = Int(nameLen[i])
        return names.withUnsafeBufferPointer { buf in
            String(decoding: UnsafeBufferPointer(rebasing: buf[off..<off+len]), as: UTF8.self)
        }
    }

    public func path(_ i: Int) -> String {
        var parts: [String] = []
        var cur = i
        while cur >= 0 && cur < parent.count {
            parts.append(name(cur))
            cur = Int(parent[cur])
        }
        return parts.reversed().joined(separator: "/")
    }

    public func children(of i: Int) -> Range<Int>? {
        guard i >= 0 && i < childCount.count else { return nil }
        let count = Int(childCount[i])
        guard count > 0 else { return nil }
        let start = Int(childStart[i])
        guard start >= 0 && start + count <= parent.count else { return nil }
        return start..<(start + count)
    }

    /// Sorted direct children (biggest first)
    public func sortedChildren(of index: Int, directoriesOnly: Bool = false) -> [Int] {
        guard let range = children(of: index) else { return [] }
        var result: [Int] = []
        result.reserveCapacity(range.count)
        for i in range {
            if directoriesOnly {
                if isDir(i) { result.append(i) }
            } else {
                result.append(i)
            }
        }
        result.sort { a, b in
            let sa = isDir(a) ? subtree[a] : allocated[a]
            let sb = isDir(b) ? subtree[b] : allocated[b]
            return sa > sb
        }
        return result
    }

    /// Top N largest direct children (for Inspector)
    public func largestChildren(of index: Int, limit: Int = 10) -> [Int] {
        guard let range = children(of: index) else { return [] }
        var result = Array(range)
        result.sort { a, b in
            let sa = isDir(a) ? subtree[a] : allocated[a]
            let sb = isDir(b) ? subtree[b] : allocated[b]
            return sa > sb
        }
        if result.count > limit {
            return Array(result.prefix(limit))
        }
        return result
    }

    public func percentOfParent(_ index: Int) -> Double {
        guard index > 0 && index < parent.count else { return 100.0 }
        let p = Int(parent[index])
        guard p >= 0 && p < subtree.count else { return 100.0 }
        let parentSize = subtree[p]
        guard parentSize > 0 else { return 0.0 }
        let mySize = isDir(index) ? subtree[index] : allocated[index]
        return min(100.0, (Double(mySize) / Double(parentSize)) * 100.0)
    }

    public func modifiedDate(_ index: Int) -> Date {
        guard index >= 0 && index < mtime.count else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(mtime[index]))
    }

    public func creationDate(_ index: Int) -> Date {
        guard index >= 0 && index < crtime.count else { return Date() }
        let t = crtime[index]
        if t > 0 {
            return Date(timeIntervalSince1970: TimeInterval(t))
        }
        return modifiedDate(index)
    }

    public func topNodes(scope: TopSizesScope, folderIndex: Int = 0, limit: Int = 100) -> [Int] {
        switch scope {
        case .inThisFolder:
            guard let range = children(of: folderIndex) else { return [] }
            var result = Array(range)
            result.sort { a, b in
                let sa = isDir(a) ? subtree[a] : allocated[a]
                let sb = isDir(b) ? subtree[b] : allocated[b]
                return sa > sb
            }
            return Array(result.prefix(limit))

        case .biggestFiles:
            var fileIndices: [Int] = []
            fileIndices.reserveCapacity(min(count, 50000))
            for i in 1..<count {
                if !isDir(i) {
                    fileIndices.append(i)
                }
            }
            fileIndices.sort { allocated[$0] > allocated[$1] }
            return Array(fileIndices.prefix(limit))

        case .biggestFolders:
            var dirIndices: [Int] = []
            dirIndices.reserveCapacity(min(count / 8, 20000))
            for i in 1..<count {
                if isDir(i) {
                    dirIndices.append(i)
                }
            }
            dirIndices.sort { subtree[$0] > subtree[$1] }
            return Array(dirIndices.prefix(limit))
        }
    }
}

public enum TopSizesScope: String, CaseIterable, Identifiable, Sendable {
    case inThisFolder   = "In This Folder"
    case biggestFiles   = "Biggest Files Anywhere"
    case biggestFolders = "Biggest Folders Anywhere"

    public var id: String { rawValue }
}

public struct RawEntry: Sendable {
    public var name: [UInt8]
    public var logical: Int64
    public var allocated: Int64
    public var mtime: Int32
    public var crtime: Int32
    public var flags: UInt8
    public var fileID: UInt64
    public var isDir: Bool
    public var dev: Int32

    public init(name: [UInt8], logical: Int64, allocated: Int64, mtime: Int32, crtime: Int32, flags: UInt8, fileID: UInt64, isDir: Bool, dev: Int32) {
        self.name = name
        self.logical = logical
        self.allocated = allocated
        self.mtime = mtime
        self.crtime = crtime
        self.flags = flags
        self.fileID = fileID
        self.isDir = isDir
        self.dev = dev
    }
}
