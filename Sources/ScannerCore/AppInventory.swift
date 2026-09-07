import Darwin
import Foundation

public enum LeftoverConfidence: Int, Sendable, Comparable {
    case low = 0, medium = 1, high = 2
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .high: return "Exact bundle ID"
        case .medium: return "App name"
        case .low: return "Name fragment"
        }
    }
}

public struct LeftoverItem: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    /// Human label for where it lives, e.g. "Caches", "Preferences".
    public let kind: String
    public let size: Int64
    public let confidence: LeftoverConfidence
}

public struct InstalledApp: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleID: String
    public let version: String
    public let bundleSize: Int64
    public let lastUsed: Date?
    public var leftovers: [LeftoverItem] = []

    func withBundleSize(_ n: Int64) -> InstalledApp {
        InstalledApp(path: path, name: name, bundleID: bundleID, version: version,
                     bundleSize: n, lastUsed: lastUsed, leftovers: leftovers)
    }

    public var leftoverBytes: Int64 { leftovers.reduce(0) { $0 + $1.size } }
    public var totalFootprint: Int64 { bundleSize + leftoverBytes }
}

/// Finds installed apps and the files they scattered around the Library.
///
/// The cheap ordering matters: we list each Library root one level deep
/// (a plain directory read), match names first, and only walk the ones that
/// actually matched. Scanning all of ~/Library to find Xcode's caches would
/// cost seconds; this costs milliseconds.
public enum AppInventory {

    public static let appRoots = [
        "/Applications",
        "/Applications/Utilities",
        NSHomeDirectory() + "/Applications"
    ]

    /// (directory, human label). Order is the order shown in the UI.
    public static var leftoverRoots: [(String, String)] {
        let h = NSHomeDirectory()
        return [
            (h + "/Library/Application Support", "Application Support"),
            (h + "/Library/Caches", "Caches"),
            (h + "/Library/Preferences", "Preferences"),
            (h + "/Library/Containers", "Containers"),
            (h + "/Library/Group Containers", "Group Containers"),
            (h + "/Library/Saved Application State", "Saved State"),
            (h + "/Library/Logs", "Logs"),
            (h + "/Library/HTTPStorages", "HTTP Storage"),
            (h + "/Library/WebKit", "WebKit Data"),
            (h + "/Library/Cookies", "Cookies"),
            (h + "/Library/LaunchAgents", "Launch Agents"),
            ("/Library/Application Support", "Application Support (System)"),
            ("/Library/Caches", "Caches (System)"),
            ("/Library/Preferences", "Preferences (System)"),
            ("/Library/Logs", "Logs (System)"),
            ("/Library/LaunchAgents", "Launch Agents (System)"),
            ("/Library/LaunchDaemons", "Launch Daemons (System)")
        ]
    }

    public static func installedApps() -> [InstalledApp] {
        let fm = FileManager.default
        var apps: [InstalledApp] = []

        for root in appRoots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = root + "/" + entry
                let name = String(entry.dropLast(4))
                let plist = path + "/Contents/Info.plist"
                var bundleID = ""
                var version = ""
                if let d = NSDictionary(contentsOfFile: plist) {
                    bundleID = d["CFBundleIdentifier"] as? String ?? ""
                    version = (d["CFBundleShortVersionString"] as? String)
                           ?? (d["CFBundleVersion"] as? String) ?? ""
                }
                let url = URL(fileURLWithPath: path)
                let used = (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate

                apps.append(InstalledApp(path: path, name: name, bundleID: bundleID,
                                         version: version,
                                         bundleSize: 0,
                                         lastUsed: used))
            }
        }
        // Size every bundle in parallel — they are independent subtrees.
        var sizes = [Int64](repeating: 0, count: apps.count)
        sizes.withUnsafeMutableBufferPointer { bufPtr in
            let ptr = bufPtr
            DispatchQueue.concurrentPerform(iterations: apps.count) { i in
                ptr[i] = directorySize(apps[i].path)
            }
        }
        for i in apps.indices { apps[i] = apps[i].withBundleSize(sizes[i]) }

        return apps.sorted { $0.totalFootprint > $1.totalFootprint }
    }

    /// Finds the files belonging to one app. Cheap enough to call on selection.
    public static func leftovers(for app: InstalledApp) -> [LeftoverItem] {
        let fm = FileManager.default
        var out: [LeftoverItem] = []
        let bid = app.bundleID.lowercased()
        let appName = app.name.lowercased()
        // A two-character app name would match half the Library.
        let nameUsable = appName.count >= 4

        for (root, label) in leftoverRoots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries {
                let lower = entry.lowercased()
                var confidence: LeftoverConfidence? = nil

                if !bid.isEmpty {
                    let stem = lower.hasSuffix(".plist") ? String(lower.dropLast(6)) : lower
                    if stem == bid || stem.hasPrefix(bid + ".") || stem.hasPrefix(bid + "-") {
                        confidence = .high
                    } else if lower.contains(bid) {
                        confidence = .high
                    }
                }
                if confidence == nil, nameUsable {
                    let stem = (entry as NSString).deletingPathExtension.lowercased()
                    if stem == appName { confidence = .medium }
                    else if lower.contains(appName) { confidence = .low }
                }

                guard let c = confidence else { continue }
                let path = root + "/" + entry
                out.append(LeftoverItem(path: path, name: entry, kind: label,
                                        size: directorySize(path), confidence: c))
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    /// Recursive size of a file or directory, in allocated bytes.
    ///
    /// Uses `getattrlistbulk` for the same reason the main scanner does:
    /// `FileManager.enumerator` costs several syscalls per file, and measuring
    /// 51 app bundles that way took ~40s cold. This does it in a fraction.
    public static func directorySize(_ path: String) -> Int64 {
        var sb = stat()
        guard lstat(path, &sb) == 0 else { return 0 }
        if (sb.st_mode & S_IFMT) != S_IFDIR { return Int64(sb.st_blocks) * 512 }

        var total: Int64 = 0
        var stack = [path]
        let bufSize = 64 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }

        while let dir = stack.popLast() {
            let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if fd < 0 { continue }

            var alist = attrlist()
            alist.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            alist.commonattr = attrgroup_t(0x8000_0000 as UInt32) | attrgroup_t(0x0000_0001)
                             | attrgroup_t(0x0000_0008)
            alist.fileattr = attrgroup_t(0x0000_0004)   // ATTR_FILE_ALLOCSIZE

            while true {
                let n = withUnsafeMutablePointer(to: &alist) { ap -> Int32 in
                    getattrlistbulk(fd, ap, buf, bufSize, 0)
                }
                if n <= 0 { break }
                var cursor = buf
                for _ in 0..<n {
                    let entryLen = Int(cursor.loadUnaligned(as: UInt32.self))
                    var p = cursor + 4
                    let ret = p.loadUnaligned(as: AttrSet.self); p += 20

                    var name = ""
                    var objType: UInt32 = 0
                    var alloc: Int64 = 0
                    if ret.common & 0x0000_0001 != 0 {
                        let off = p.loadUnaligned(as: Int32.self)
                        let len = p.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                        let start = p + Int(off)
                        name = String(decoding: UnsafeRawBufferPointer(start: start,
                                                                      count: max(0, Int(len) - 1)),
                                      as: UTF8.self)
                        p += 8
                    }
                    if ret.common & 0x0000_0008 != 0 { objType = p.loadUnaligned(as: UInt32.self); p += 4 }
                    if ret.file & 0x0000_0004 != 0 { alloc = p.loadUnaligned(as: Int64.self); p += 8 }

                    cursor += entryLen
                    if name.isEmpty || name == "." || name == ".." { continue }
                    if objType == 2 {                       // VDIR
                        stack.append(dir + "/" + name)
                    } else if objType == 1 {                // VREG
                        total += alloc
                    }
                }
            }
            close(fd)
        }
        return total
    }
}

private struct AttrSet {
    var common: UInt32; var vol: UInt32; var dir: UInt32; var file: UInt32; var fork: UInt32
}
