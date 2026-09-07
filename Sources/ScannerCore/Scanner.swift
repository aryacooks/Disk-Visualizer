import Darwin
import Foundation

// MARK: - attrlist constants (Swift imports these as Int32; we need attrgroup_t)

private let CMN_RETURNED = attrgroup_t(0x8000_0000 as UInt32)
private let CMN_NAME     = attrgroup_t(0x0000_0001)
private let CMN_DEVID    = attrgroup_t(0x0000_0002)
private let CMN_OBJTYPE  = attrgroup_t(0x0000_0008)
private let CMN_CRTIME   = attrgroup_t(0x0000_0200)
private let CMN_MODTIME  = attrgroup_t(0x0000_0400)
private let CMN_FLAGS    = attrgroup_t(0x0004_0000)
private let CMN_FILEID   = attrgroup_t(0x0200_0000)

private let FILE_LINKCOUNT = attrgroup_t(0x0000_0001)
private let FILE_TOTALSIZE = attrgroup_t(0x0000_0002)
private let FILE_ALLOCSIZE = attrgroup_t(0x0000_0004)

private let VREG: UInt32 = 1
private let VDIR: UInt32 = 2
private let VLNK: UInt32 = 5

private struct AttrRef { var offset: Int32; var length: UInt32 }
private struct AttributeSet { var common: UInt32; var vol: UInt32; var dir: UInt32; var file: UInt32; var fork: UInt32 }

// MARK: - Work queue

private struct DirTask { let path: String; let node: Int32 }

private final class WorkQueue {
    private var items: [DirTask] = []
    private var active = 0
    private let cond = NSCondition()
    private var cancelled = false

    func push(_ t: DirTask) {
        cond.lock()
        guard !cancelled else { cond.unlock(); return }
        items.append(t)
        cond.signal()
        cond.unlock()
    }

    /// Blocks until work is available, or returns nil when the whole tree is done.
    func pop() -> DirTask? {
        cond.lock()
        defer { cond.unlock() }
        while items.isEmpty {
            if cancelled || active == 0 { cond.broadcast(); return nil }
            cond.wait()
        }
        if cancelled { return nil }
        active += 1
        return items.removeLast()   // LIFO: depth-first, keeps the queue small
    }

    func complete(pushing children: [DirTask]) {
        cond.lock()
        if !cancelled {
            items.append(contentsOf: children)
        }
        active -= 1
        if cancelled || (children.isEmpty && items.isEmpty && active == 0) { cond.broadcast() }
        else if !children.isEmpty { cond.broadcast() }
        cond.unlock()
    }

    func cancel() {
        cond.lock()
        cancelled = true
        items.removeAll()
        cond.broadcast()
        cond.unlock()
    }

    func seed(_ t: DirTask) {
        cond.lock()
        items.append(t)
        active = 0
        cancelled = false
        cond.unlock()
    }
}

// MARK: - File Types

public enum FileTypeCategory: String, CaseIterable, Identifiable, Sendable {
    case video = "Video"
    case audio = "Audio"
    case image = "Image"
    case document = "Document"
    case developer = "Developer"
    case archive = "Archive"
    case other = "Other"

    public var id: String { rawValue }

    public static func classify(extension ext: String) -> FileTypeCategory {
        let e = ext.lowercased()
        switch e {
        case "mp4", "mov", "mkv", "avi", "webm", "m4v", "flv", "wmv", "mpg", "mpeg", "ts":
            return .video
        case "mp3", "m4a", "wav", "flac", "aac", "ogg", "aiff", "wma", "alac":
            return .audio
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "svg", "tiff", "tif", "psd", "raw", "cr2", "nef", "bmp", "ico":
            return .image
        case "pdf", "docx", "doc", "xlsx", "xls", "pptx", "ppt", "txt", "rtf", "pages", "numbers", "key", "csv", "epub":
            return .document
        case "swift", "c", "cpp", "cc", "cxx", "h", "hpp", "rs", "go", "py", "js", "tsx", "jsx", "html", "css", "scss",
             "json", "yaml", "yml", "xml", "sh", "zsh", "bash", "java", "kt", "rb", "php", "sql", "m", "mm", "dart", "lua", "toml", "md":
            return .developer
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg":
            return .archive
        default:
            return .other
        }
    }
}

// MARK: - Scanner Stats & Progress

public struct ScanStats: Sendable {
    public var files = 0
    public var dirs = 0
    public var logical: Int64 = 0
    public var allocated: Int64 = 0
    public var compressedSaved: Int64 = 0
    public var skipped = 0            // EPERM / EACCES — usually missing Full Disk Access
    public var hardlinkDupBytes: Int64 = 0
    /// mtime histogram: bucket 0=<7d, 1=<30d, 2=<90d, 3=<365d, 4=<2y, 5=older
    public var ageBytes = [Int64](repeating: 0, count: 6)
    public var categoryBytes: [FileTypeCategory: Int64] = [:]

    public init() {
        for cat in FileTypeCategory.allCases {
            categoryBytes[cat] = 0
        }
    }
}

public struct ScanProgress: Sendable {
    public var files: Int
    public var dirs: Int
    public var allocated: Int64
    public var logical: Int64
    public var currentPath: String
    public var isComplete: Bool
    public var elapsed: TimeInterval

    public init(files: Int = 0, dirs: Int = 0, allocated: Int64 = 0, logical: Int64 = 0, currentPath: String = "", isComplete: Bool = false, elapsed: TimeInterval = 0) {
        self.files = files
        self.dirs = dirs
        self.allocated = allocated
        self.logical = logical
        self.currentPath = currentPath
        self.isComplete = isComplete
        self.elapsed = elapsed
    }
}

// MARK: - Scanner

public final class Scanner: @unchecked Sendable {
    public let store = NodeStore()
    public private(set) var stats = ScanStats()

    private let queue = WorkQueue()
    private let statsLock = NSLock()
    private let seenLock = NSLock()
    private var seenInodes = Set<UInt64>()      // only for linkcount > 1
    private var rootDev: Int32 = 0
    private var crossMounts = false
    private var isCancelled = false
    private var currentScanningPath = ""
    private var startTime: DispatchTime = .now()

    /// Directories that hang or are meaningless to scan. See DESIGN.md §1.3.
    private static let skipNames: Set<String> = [
        ".fseventsd", ".Spotlight-V100", ".DocumentRevisions-V100", ".TemporaryItems"
    ]
    private static let skipAbsolute: Set<String> = [
        "/dev", "/net", "/home", "/Volumes", "/System/Volumes/Data",
        "/System/Volumes/VM", "/System/Volumes/Preboot", "/System/Volumes/Recovery"
    ]

    public init() {}

    public func cancel() {
        isCancelled = true
        queue.cancel()
    }

    public func currentProgress() -> ScanProgress {
        statsLock.lock()
        defer { statsLock.unlock() }
        let now = DispatchTime.now()
        let el = Double(now.uptimeNanoseconds - startTime.uptimeNanoseconds) / 1e9
        return ScanProgress(
            files: stats.files,
            dirs: stats.dirs,
            allocated: stats.allocated,
            logical: stats.logical,
            currentPath: currentScanningPath,
            isComplete: false,
            elapsed: el
        )
    }

    public func scan(root: String, threads: Int = ProcessInfo.processInfo.activeProcessorCount, crossMounts: Bool = false, onProgress: (@Sendable (ScanProgress) -> Void)? = nil) {
        self.crossMounts = crossMounts
        self.isCancelled = false
        self.startTime = DispatchTime.now()

        var sb = stat()
        guard lstat(root, &sb) == 0 else {
            FileHandle.standardError.write("cannot stat \(root)\n".data(using: .utf8)!)
            return
        }
        rootDev = sb.st_dev

        let rootIdx = store.appendRoot(name: Array(root.utf8))
        store.setRootMetadata(mtime: Int32(truncatingIfNeeded: sb.st_mtimespec.tv_sec),
                              crtime: Int32(truncatingIfNeeded: sb.st_birthtimespec.tv_sec))
        queue.seed(DirTask(path: root, node: rootIdx))

        let group = DispatchGroup()
        for _ in 0..<threads {
            DispatchQueue.global(qos: .userInitiated).async(group: group) { [weak self] in
                self?.workerLoop(onProgress: onProgress)
            }
        }
        group.wait()
        if !isCancelled {
            store.rollUp()
            if let onProgress = onProgress {
                var finalProgress = currentProgress()
                finalProgress.isComplete = true
                onProgress(finalProgress)
            }
        }
    }

    private func workerLoop(onProgress: (@Sendable (ScanProgress) -> Void)?) {
        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }

        var local = ScanStats()
        var flushCountdown = 64

        while !isCancelled, let task = queue.pop() {
            let children = processDirectory(task, buf: buf, bufSize: bufSize, stats: &local)
            queue.complete(pushing: children)

            flushCountdown -= 1
            if flushCountdown == 0 {
                flush(&local, lastPath: task.path)
                flushCountdown = 64
                if let onProgress = onProgress {
                    let prog = currentProgress()
                    onProgress(prog)
                }
            }
        }
        flush(&local, lastPath: "")
    }

    private func flush(_ local: inout ScanStats, lastPath: String) {
        statsLock.lock()
        stats.files += local.files
        stats.dirs += local.dirs
        stats.logical += local.logical
        stats.allocated += local.allocated
        stats.compressedSaved += local.compressedSaved
        stats.skipped += local.skipped
        stats.hardlinkDupBytes += local.hardlinkDupBytes
        for i in 0..<6 { stats.ageBytes[i] += local.ageBytes[i] }
        for (k, v) in local.categoryBytes {
            stats.categoryBytes[k, default: 0] += v
        }
        if !lastPath.isEmpty {
            currentScanningPath = lastPath
        }
        statsLock.unlock()
        local = ScanStats()
    }

    private func processDirectory(_ task: DirTask, buf: UnsafeMutableRawPointer,
                                  bufSize: Int, stats local: inout ScanStats) -> [DirTask] {
        let fd = open(task.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd < 0 { local.skipped += 1; return [] }
        defer { close(fd) }

        var alist = attrlist()
        alist.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        alist.commonattr = CMN_RETURNED | CMN_NAME | CMN_DEVID | CMN_OBJTYPE
                         | CMN_CRTIME | CMN_MODTIME | CMN_FLAGS | CMN_FILEID
        alist.fileattr = FILE_LINKCOUNT | FILE_TOTALSIZE | FILE_ALLOCSIZE

        var entries: [RawEntry] = []
        entries.reserveCapacity(256)
        let now = Int32(Date().timeIntervalSince1970)

        while !isCancelled {
            let n = withUnsafeMutablePointer(to: &alist) { ap -> Int32 in
                getattrlistbulk(fd, ap, buf, bufSize, 0)
            }
            if n <= 0 { break }

            var cursor = buf
            for _ in 0..<n {
                let entryLen = Int(cursor.loadUnaligned(as: UInt32.self))
                var p = cursor + 4
                let ret = p.loadUnaligned(as: AttributeSet.self); p += 20

                var name: [UInt8] = []
                var devid: Int32 = rootDev
                var objType: UInt32 = 0
                var crtime: Int32 = 0
                var mtime: Int32 = 0
                var fflags: UInt32 = 0
                var fileID: UInt64 = 0
                var linkCount: UInt32 = 1
                var logical: Int64 = 0
                var alloc: Int64 = 0

                if ret.common & CMN_NAME != 0 {
                    let r = p.loadUnaligned(as: AttrRef.self)
                    let start = p + Int(r.offset)
                    let len = max(0, Int(r.length) - 1)   // length includes the NUL
                    name = [UInt8](UnsafeRawBufferPointer(start: start, count: len))
                    p += 8
                }
                if ret.common & CMN_DEVID   != 0 { devid = p.loadUnaligned(as: Int32.self); p += 4 }
                if ret.common & CMN_OBJTYPE != 0 { objType = p.loadUnaligned(as: UInt32.self); p += 4 }
                if ret.common & CMN_CRTIME  != 0 {
                    crtime = Int32(truncatingIfNeeded: p.loadUnaligned(as: Int.self)); p += 16
                }
                if ret.common & CMN_MODTIME != 0 {
                    mtime = Int32(truncatingIfNeeded: p.loadUnaligned(as: Int.self)); p += 16
                }
                if ret.common & CMN_FLAGS   != 0 { fflags = p.loadUnaligned(as: UInt32.self); p += 4 }
                if ret.common & CMN_FILEID  != 0 { fileID = p.loadUnaligned(as: UInt64.self); p += 8 }
                if ret.file   & FILE_LINKCOUNT != 0 { linkCount = p.loadUnaligned(as: UInt32.self); p += 4 }
                if ret.file   & FILE_TOTALSIZE != 0 { logical = p.loadUnaligned(as: Int64.self); p += 8 }
                if ret.file   & FILE_ALLOCSIZE != 0 { alloc = p.loadUnaligned(as: Int64.self); p += 8 }

                cursor += entryLen

                if name.isEmpty || name == [0x2E] || name == [0x2E, 0x2E] { continue }

                let isDir = objType == VDIR
                let isLink = objType == VLNK
                var flags: UInt8 = 0
                if isDir { flags |= NodeStore.isDir }
                if isLink { flags |= NodeStore.isLink }

                // UF_COMPRESSED (0x20): decmpfs. alloc << logical, real savings.
                let compressed = (fflags & 0x20) != 0
                if compressed { flags |= NodeStore.isCompressed }
                else if !isDir && !isLink && alloc < logical / 2 && logical > 65536 {
                    flags |= NodeStore.isSparse
                }

                // Hardlink dedup: charge the bytes once. Only touch the shared set
                // when linkcount > 1, which is rare, so contention stays near zero.
                var chargeable = true
                if !isDir && linkCount > 1 {
                    seenLock.lock()
                    chargeable = seenInodes.insert(fileID).inserted
                    seenLock.unlock()
                    if !chargeable {
                        flags |= NodeStore.isHardlinkDup
                        local.hardlinkDupBytes += alloc
                    }
                }

                entries.append(RawEntry(name: name, logical: logical,
                                        allocated: chargeable ? alloc : 0,
                                        mtime: mtime, crtime: crtime, flags: flags,
                                        fileID: fileID, isDir: isDir, dev: devid))

                if isDir { local.dirs += 1 } else {
                    local.files += 1
                    local.logical += logical
                    if chargeable {
                        local.allocated += alloc
                        if compressed && logical > alloc { local.compressedSaved += logical - alloc }
                        let age = now - mtime
                        let b: Int
                        switch age {
                        case ..<604_800:     b = 0
                        case ..<2_592_000:   b = 1
                        case ..<7_776_000:   b = 2
                        case ..<31_536_000:  b = 3
                        case ..<63_072_000:  b = 4
                        default:             b = 5
                        }
                        local.ageBytes[b] += alloc

                        // File type category:
                        let ext = Self.extractExtension(name: name)
                        let cat = FileTypeCategory.classify(extension: ext)
                        local.categoryBytes[cat, default: 0] += alloc
                    }
                }

            }
        }

        if entries.isEmpty { return [] }
        let base = store.appendBatch(entries, parentIndex: task.node)

        var children: [DirTask] = []
        for (i, e) in entries.enumerated() where e.isDir {
            if !crossMounts && e.dev != rootDev { continue }   // don't descend into another volume
            let nm = String(decoding: e.name, as: UTF8.self)
            if Scanner.skipNames.contains(nm) { continue }
            let childPath = task.path == "/" ? "/\(nm)" : "\(task.path)/\(nm)"
            if Scanner.skipAbsolute.contains(childPath) { continue }
            children.append(DirTask(path: childPath, node: base + Int32(i)))
        }
        return children
    }

    private static func extractExtension(name: [UInt8]) -> String {
        guard let dotIdx = name.lastIndex(of: 0x2E), dotIdx < name.count - 1 else { return "" }
        return String(decoding: name[(dotIdx + 1)...], as: UTF8.self)
    }
}
