import CryptoKit
import Darwin
import Foundation

public struct DuplicateFile: Identifiable, Sendable {
    public var id: Int { nodeIndex }
    public let nodeIndex: Int
    public let path: String
    public let name: String
    public let size: Int64
    public let mtime: Date
    /// APFS clone of another file in the same group: byte-identical, but the
    /// blocks are shared, so deleting it frees nothing.
    public let isClone: Bool
}

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String            // content digest
    public let size: Int64           // size of ONE copy
    public let files: [DuplicateFile]
    /// Index into `files` of the copy we suggest keeping.
    public let keepIndex: Int
    /// Bytes actually recoverable — excludes the keeper and every clone.
    public let reclaimable: Int64

    /// Name of the copy we suggest keeping — not an arbitrary group member,
    /// whose identity depends on non-deterministic scan order.
    public var name: String {
        files.indices.contains(keepIndex) ? files[keepIndex].name : (files.first?.name ?? "")
    }
    public var cloneCount: Int { files.filter { $0.isClone }.count }
}

public struct DuplicateProgress: Sendable {
    public var stage: String = ""
    public var done: Int = 0
    public var total: Int = 0
    public var bytesHashed: Int64 = 0

    public init(stage: String = "", done: Int = 0, total: Int = 0, bytesHashed: Int64 = 0) {
        self.stage = stage; self.done = done; self.total = total; self.bytesHashed = bytesHashed
    }
}

public struct DuplicateResult: Sendable {
    public var groups: [DuplicateGroup] = []
    public var candidatesBySize = 0
    public var survivedPrefixHash = 0
    public var bytesHashed: Int64 = 0
    public var elapsed: TimeInterval = 0

    public init() {}

    public var totalReclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }
    public var totalExtraCopies: Int { groups.reduce(0) { $0 + $1.files.count - 1 } }
}

/// Finds byte-identical files with a three-stage funnel.
///
/// Hashing everything is the naive failure mode: it takes hours and thrashes
/// the disk. Instead:
///   1. group by exact size — free, we already have every size from the scan,
///      and it eliminates ~99% of files;
///   2. hash the first and last 4 KB of the survivors — one read each;
///   3. hash full contents only for groups that still collide.
///
/// Then the part that separates a useful duplicate finder from a misleading
/// one: APFS clones are byte-identical but share their blocks, so removing one
/// frees nothing. They are detected and excluded from the reclaimable figure.
public enum DuplicateFinder {

    public static func find(store: NodeStore,
                            minSize: Int64 = 4096,
                            isCancelled: (@Sendable () -> Bool)? = nil,
                            progress: (@Sendable (DuplicateProgress) -> Void)? = nil) -> DuplicateResult {
        let t0 = DispatchTime.now()
        var result = DuplicateResult()

        // ---- Stage 1: group by exact size ----
        progress?(DuplicateProgress(stage: "Grouping by size"))
        var bySize: [Int64: [Int]] = [:]
        for i in 0..<store.count {
            guard !store.isDir(i) else { continue }
            let f = store.flags[i]
            if f & NodeStore.isLink != 0 { continue }
            // A hardlink is the same bytes on disk, not a second copy.
            if f & NodeStore.isHardlinkDup != 0 { continue }
            let size = store.logical[i]
            guard size >= minSize else { continue }
            bySize[size, default: []].append(i)
        }
        if isCancelled?() == true { result.elapsed = elapsedSince(t0); return result }
        var candidates: [[Int]] = bySize.values.filter { $0.count > 1 }
        result.candidatesBySize = candidates.reduce(0) { $0 + $1.count }
        guard !candidates.isEmpty else {
            result.elapsed = elapsedSince(t0)
            return result
        }

        // ---- Stage 2: head+tail signature ----
        //
        // Parallelise across ALL candidates at once, not per group. Most groups
        // hold 2-3 files, so a concurrentPerform per group spends more time in
        // thread-pool setup than in reading, across hundreds of thousands of
        // groups. One flat pass is dramatically faster.
        progress?(DuplicateProgress(stage: "Reading file heads", total: result.candidatesBySize))
        var flat: [Int] = []
        var owner: [Int] = []          // index into `candidates` for each entry
        flat.reserveCapacity(result.candidatesBySize)
        owner.reserveCapacity(result.candidatesBySize)
        for (gi, g) in candidates.enumerated() {
            for n in g { flat.append(n); owner.append(gi) }
        }

        let done2 = Counter()
        var sigs = [UInt64](repeating: 0, count: flat.count)
        sigs.withUnsafeMutableBufferPointer { buf in
            let ptr = buf
            let chunk = 512
            let chunks = (flat.count + chunk - 1) / chunk
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                if isCancelled?() == true { return }
                let lo = c * chunk, hi = min(flat.count, lo + chunk)
                for k in lo..<hi {
                    let node = flat[k]
                    ptr[k] = edgeSignature(store.path(node), size: store.logical[node])
                }
                done2.add(hi - lo)
                progress?(DuplicateProgress(stage: "Reading file heads",
                                            done: done2.value,
                                            total: flat.count))
            }
        }

        if isCancelled?() == true { result.elapsed = elapsedSince(t0); return result }
        var stage2Map: [Int: [UInt64: [Int]]] = [:]
        for k in flat.indices where sigs[k] != 0 {
            stage2Map[owner[k], default: [:]][sigs[k], default: []].append(flat[k])
        }
        var stage2: [[Int]] = []
        for (_, byPrefix) in stage2Map {
            for g in byPrefix.values where g.count > 1 { stage2.append(g) }
        }
        candidates = stage2
        result.survivedPrefixHash = candidates.reduce(0) { $0 + $1.count }
        guard !candidates.isEmpty else {
            result.elapsed = elapsedSince(t0)
            return result
        }

        // ---- Stage 3: full content hash ----
        progress?(DuplicateProgress(stage: "Hashing contents", total: result.survivedPrefixHash))
        var flat3: [Int] = []
        var owner3: [Int] = []
        for (gi, g) in candidates.enumerated() {
            for n in g { flat3.append(n); owner3.append(gi) }
        }

        let done = Counter()
        let bytes = Counter()
        var digests = [String](repeating: "", count: flat3.count)
        digests.withUnsafeMutableBufferPointer { buf in
            let ptr = buf
            let chunk = 32
            let chunks = (flat3.count + chunk - 1) / chunk
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                if isCancelled?() == true { return }
                let lo = c * chunk, hi = min(flat3.count, lo + chunk)
                for k in lo..<hi {
                    ptr[k] = fullDigest(store.path(flat3[k]), counter: bytes)
                }
                done.add(hi - lo)
                progress?(DuplicateProgress(stage: "Hashing contents",
                                            done: done.value,
                                            total: flat3.count,
                                            bytesHashed: bytes.value64))
            }
        }

        if isCancelled?() == true { result.elapsed = elapsedSince(t0); return result }
        var byDigestAll: [String: [Int]] = [:]
        for k in flat3.indices where !digests[k].isEmpty {
            byDigestAll[digests[k], default: []].append(flat3[k])
        }

        // ---- Stage 4: clone detection and group assembly ----
        //
        // This stage used to report nothing, and it is not cheap: every member
        // of every group costs an `fcntl(F_LOG2PHYS_EXT)` to find its first
        // physical block. On a real home folder that is ~340,000 syscalls, and
        // with the UI still showing "Hashing contents — 396,449 of 396,449" the
        // whole app looked hung for minutes. The work was always fine; only the
        // reporting was missing.
        let dupDigests = byDigestAll.filter { $0.value.count > 1 }
        progress?(DuplicateProgress(stage: "Checking for clones", total: dupDigests.count))
        var groups: [DuplicateGroup] = []
        groups.reserveCapacity(dupDigests.count)
        var assembled = 0
        for (digest, members) in dupDigests {
            if isCancelled?() == true { result.elapsed = elapsedSince(t0); return result }
            groups.append(makeGroup(store: store, digest: digest, members: members))
            assembled += 1
            if assembled % 256 == 0 {
                progress?(DuplicateProgress(stage: "Checking for clones",
                                            done: assembled,
                                            total: dupDigests.count,
                                            bytesHashed: bytes.value64))
            }
        }

        result.bytesHashed = bytes.value64
        result.groups = groups.sorted { $0.reclaimable > $1.reclaimable }
        result.elapsed = elapsedSince(t0)
        return result
    }

    // MARK: Group assembly

    private static func makeGroup(store: NodeStore, digest: String, members: [Int]) -> DuplicateGroup {
        let paths = members.map { store.path($0) }
        let physical = paths.map { firstPhysicalBlock($0) }

        // Clones share their first physical extent with an earlier copy.
        var seenBlocks = Set<Int64>()
        var isClone = [Bool](repeating: false, count: members.count)
        for k in members.indices {
            let p = physical[k]
            if p != 0 {
                if seenBlocks.contains(p) { isClone[k] = true } else { seenBlocks.insert(p) }
            }
        }

        let files = members.indices.map { k in
            DuplicateFile(nodeIndex: members[k], path: paths[k],
                          name: store.name(members[k]),
                          size: store.logical[members[k]],
                          mtime: store.modifiedDate(members[k]),
                          isClone: isClone[k])
        }

        let keep = suggestKeeper(files)
        // Only non-clone, non-keeper copies actually free space.
        let reclaimable = files.indices
            .filter { $0 != keep && !files[$0].isClone }
            .reduce(Int64(0)) { $0 + files[$1].size }

        return DuplicateGroup(id: digest, size: files.first?.size ?? 0,
                              files: files, keepIndex: keep, reclaimable: reclaimable)
    }

    /// Which copy is most likely to be the "real" one. Lower score wins.
    static func suggestKeeper(_ files: [DuplicateFile]) -> Int {
        var best = 0
        var bestScore = Int.max
        for (i, f) in files.enumerated() {
            var score = 0
            let lower = f.path.lowercased()
            if lower.contains("/downloads/") { score += 40 }
            if lower.contains("/.trash/") { score += 80 }
            if lower.contains("/caches/") || lower.contains("/cache/") { score += 30 }
            if lower.contains(".app/") { score += 25 }
            if lower.contains("/node_modules/") { score += 20 }
            if f.name.contains(" copy") || f.name.contains("(1)") || f.name.contains("(2)") { score += 15 }
            // Prefer the original: shallower path, older file.
            score += f.path.components(separatedBy: "/").count
            score += Int(f.mtime.timeIntervalSince1970 / 86_400_000)
            if score < bestScore { bestScore = score; best = i }
        }
        return best
    }

    // MARK: Hashing

    /// First and last 4 KB, mixed with the size. Cheap and highly selective.
    static func edgeSignature(_ path: String, size: Int64) -> UInt64 {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }

        let chunk = 4096
        var buf = [UInt8](repeating: 0, count: chunk)
        var h: UInt64 = 0xcbf2_9ce4_8422_2325

        func mix(_ bytes: ArraySlice<UInt8>) {
            for b in bytes { h = (h ^ UInt64(b)) &* 0x1000_0000_01b3 }
        }

        let head = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, chunk, 0) }
        if head > 0 { mix(buf[0..<head]) }

        if size > Int64(chunk) {
            let off = max(0, size - Int64(chunk))
            let tail = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, chunk, off) }
            if tail > 0 { mix(buf[0..<tail]) }
        }
        h = (h ^ UInt64(bitPattern: size)) &* 0x1000_0000_01b3
        return h == 0 ? 1 : h    // 0 is our "unreadable" sentinel
    }

    /// SHA-256 of the whole file, streamed. Hardware-accelerated on Apple silicon.
    static func fullDigest(_ path: String, counter: Counter) -> String {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return "" }
        defer { close(fd) }

        var hasher = SHA256()
        let chunk = 1 << 20
        var buf = [UInt8](repeating: 0, count: chunk)
        var total: Int64 = 0

        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunk) }
            if n <= 0 { break }
            buf.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[0..<n]))
            }
            total += Int64(n)
        }
        counter.add64(total)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Physical device offset of a file's first extent, or 0 if unavailable.
    /// Two files reporting the same offset share blocks — an APFS clone.
    static func firstPhysicalBlock(_ path: String) -> Int64 {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var l2p = log2phys()
        l2p.l2p_contigbytes = 0
        l2p.l2p_devoffset = 0
        guard fcntl(fd, F_LOG2PHYS_EXT, &l2p) == 0 else { return 0 }
        return Int64(l2p.l2p_devoffset)
    }

    private static func elapsedSince(_ t0: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
    }
}

/// Tiny thread-safe counter for cross-thread progress.
public final class Counter: @unchecked Sendable {
    private var n = 0
    private var n64: Int64 = 0
    private let lock = NSLock()

    public init() {}
    public func add(_ k: Int) { lock.lock(); n += k; lock.unlock() }
    public func add64(_ k: Int64) { lock.lock(); n64 += k; lock.unlock() }
    public var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    public var value64: Int64 { lock.lock(); defer { lock.unlock() }; return n64 }

    func publish(_ cb: (@Sendable (DuplicateProgress) -> Void)?, stage: String, done: Int, total: Int) {
        cb?(DuplicateProgress(stage: stage, done: done, total: total, bytesHashed: value64))
    }
}
