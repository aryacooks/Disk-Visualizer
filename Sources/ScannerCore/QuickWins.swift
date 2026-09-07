import Darwin
import Foundation

public enum QuickWinDetectorType: String, CaseIterable, Identifiable, Sendable {
    case downloads      = "Downloads"
    case cachesAndLogs  = "Caches & Logs"
    case simulators     = "iOS Simulators"
    case nodeModules    = "node_modules"
    case buildArtifacts = "Build Artifacts"
    case derivedData    = "Xcode DerivedData"
    case largeMedia     = "Large Media"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .downloads:       return "arrow.down.circle"
        case .cachesAndLogs:   return "trash"
        case .simulators:      return "iphone.gen3"
        case .nodeModules:     return "shippingbox"
        case .buildArtifacts:  return "hammer"
        case .derivedData:     return "laptopcomputer"
        case .largeMedia:      return "film"
        }
    }

    public var subtitle: String {
        switch self {
        case .downloads:      return "Files in ~/Downloads untouched > 30 days"
        case .cachesAndLogs:  return "Application caches and system log folders"
        case .simulators:     return "Downloaded iOS simulator runtimes & device state"
        case .nodeModules:    return "Node.js dependencies (safe to re-install via npm/pnpm/yarn)"
        case .buildArtifacts: return "Build outputs (target/, build/, dist/, .next/, .gradle/)"
        case .derivedData:    return "Xcode build cache and indexes (safe to delete)"
        case .largeMedia:     return "Video and audio files larger than 100 MB"
        }
    }
}

public struct QuickWinItem: Identifiable, Sendable {
    public var id: Int { nodeIndex }
    public let nodeIndex: Int
    public let name: String
    public let path: String
    public let size: Int64
    public let isDir: Bool
    public let mtime: Date

    public init(nodeIndex: Int, name: String, path: String, size: Int64, isDir: Bool, mtime: Date) {
        self.nodeIndex = nodeIndex
        self.name = name
        self.path = path
        self.size = size
        self.isDir = isDir
        self.mtime = mtime
    }
}

public struct QuickWinResult: Identifiable, Sendable {
    public var id: String { detector.rawValue }
    public let detector: QuickWinDetectorType
    public let title: String
    public let description: String
    public let totalBytes: Int64
    public let itemCount: Int
    public let items: [QuickWinItem]

    public init(detector: QuickWinDetectorType, title: String, description: String, totalBytes: Int64, itemCount: Int, items: [QuickWinItem]) {
        self.detector = detector
        self.title = title
        self.description = description
        self.totalBytes = totalBytes
        self.itemCount = itemCount
        self.items = items
    }
}

public enum QuickWinsEngine {
    public static func detect(store: NodeStore, rootPath: String) -> [QuickWinDetectorType: QuickWinResult] {
        let count = store.count
        guard count > 0 else { return [:] }

        let now = Int32(Date().timeIntervalSince1970)
        let thirtyDaysSecs: Int32 = 30 * 86400
        let hundredMBSecs: Int64 = 100 * 1024 * 1024

        let home = NSHomeDirectory()
        let downloadsPrefix = home + "/Downloads"
        let cachesPrefix = home + "/Library/Caches"
        let logsPrefix = home + "/Library/Logs"
        let simulatorsPrefix = home + "/Library/Developer/CoreSimulator/Devices"
        let derivedDataPrefix = home + "/Library/Developer/Xcode/DerivedData"

        var downloadsItems: [QuickWinItem] = []
        var cachesLogsItems: [QuickWinItem] = []
        var simulatorsItems: [QuickWinItem] = []
        var nodeModulesItems: [QuickWinItem] = []
        var buildArtifactsItems: [QuickWinItem] = []
        var derivedDataItems: [QuickWinItem] = []
        var largeMediaItems: [QuickWinItem] = []

        let buildNames: Set<String> = ["target", "build", "dist", ".next", ".gradle"]

        // Track seen ancestors for non-nesting
        // Since indices are contiguous, we can check ancestor chain
        func hasAncestorNamed(_ node: Int, _ name: String) -> Bool {
            var cur = Int(store.parent[node])
            while cur >= 0 {
                if store.name(cur) == name { return true }
                cur = Int(store.parent[cur])
            }
            return false
        }

        func hasBuildAncestor(_ node: Int) -> Bool {
            var cur = Int(store.parent[node])
            while cur >= 0 {
                let n = store.name(cur)
                if buildNames.contains(n) || n == "node_modules" { return true }
                cur = Int(store.parent[cur])
            }
            return false
        }

        for i in 1..<count {
            let isDir = store.isDir(i)
            let name = store.name(i)
            let size = isDir ? store.subtree[i] : store.allocated[i]
            let mtimeSec = store.mtime[i]
            let mtimeDate = Date(timeIntervalSince1970: TimeInterval(mtimeSec))

            // 1. node_modules (non-nested)
            if isDir && name == "node_modules" {
                if !hasAncestorNamed(i, "node_modules") {
                    let path = store.path(i)
                    nodeModulesItems.append(QuickWinItem(nodeIndex: i, name: name, path: path, size: size, isDir: true, mtime: mtimeDate))
                }
                continue // Skip inspecting inside node_modules for other rules
            }

            // 2. Build artifacts (target, build, dist, .next, .gradle - non-nested)
            if isDir && buildNames.contains(name) {
                if !hasBuildAncestor(i) {
                    let path = store.path(i)
                    buildArtifactsItems.append(QuickWinItem(nodeIndex: i, name: name, path: path, size: size, isDir: true, mtime: mtimeDate))
                }
                continue // Skip children of this build artifact
            }

            // 3. Large media (> 100 MB video/audio)
            if !isDir && size >= hundredMBSecs {
                let ext = (name as NSString).pathExtension
                let cat = FileTypeCategory.classify(extension: ext)
                if cat == .video || cat == .audio {
                    let path = store.path(i)
                    largeMediaItems.append(QuickWinItem(nodeIndex: i, name: name, path: path, size: size, isDir: false, mtime: mtimeDate))
                }
            }

            // Path-based rules
            let parentIdx = Int(store.parent[i])
            if parentIdx >= 0 {
                let parentPath = store.path(parentIdx)

                // 4. Downloads (> 30 days)
                if !isDir && (now - mtimeSec > thirtyDaysSecs) {
                    if parentPath == downloadsPrefix || parentPath.hasPrefix(downloadsPrefix + "/") {
                        let path = store.path(i)
                        downloadsItems.append(QuickWinItem(nodeIndex: i, name: name, path: path, size: size, isDir: false, mtime: mtimeDate))
                    }
                }

                // 5. Caches & logs (direct top-level folders in ~/Library/Caches or ~/Library/Logs)
                if isDir {
                    if parentPath == cachesPrefix || parentPath == logsPrefix {
                        let path = store.path(i)
                        cachesLogsItems.append(QuickWinItem(nodeIndex: i, name: name, path: path, size: size, isDir: true, mtime: mtimeDate))
                    }
                }

                // 6. iOS Simulators (direct folders in ~/Library/Developer/CoreSimulator/Devices/*)
                if isDir && parentPath == simulatorsPrefix {
                    let path = store.path(i)
                    simulatorsItems.append(QuickWinItem(nodeIndex: i, name: name, path: path, size: size, isDir: true, mtime: mtimeDate))
                }

                // 7. Xcode DerivedData (direct folders in ~/Library/Developer/Xcode/DerivedData/*)
                if isDir && parentPath == derivedDataPrefix {
                    let path = store.path(i)
                    derivedDataItems.append(QuickWinItem(nodeIndex: i, name: name, path: path, size: size, isDir: true, mtime: mtimeDate))
                }
            }
        }

        // Sort each detector's items biggest first
        func makeResult(_ detector: QuickWinDetectorType, _ items: [QuickWinItem]) -> QuickWinResult {
            let sorted = items.sorted { $0.size > $1.size }
            let total = sorted.reduce(Int64(0)) { $0 + $1.size }
            return QuickWinResult(
                detector: detector,
                title: detector.rawValue,
                description: detector.subtitle,
                totalBytes: total,
                itemCount: sorted.count,
                items: sorted
            )
        }

        var results: [QuickWinDetectorType: QuickWinResult] = [:]
        results[.downloads] = makeResult(.downloads, downloadsItems)
        results[.cachesAndLogs] = makeResult(.cachesAndLogs, cachesLogsItems)
        results[.simulators] = makeResult(.simulators, simulatorsItems)
        results[.nodeModules] = makeResult(.nodeModules, nodeModulesItems)
        results[.buildArtifacts] = makeResult(.buildArtifacts, buildArtifactsItems)
        results[.derivedData] = makeResult(.derivedData, derivedDataItems)
        results[.largeMedia] = makeResult(.largeMedia, largeMediaItems)

        return results
    }
}
