import SwiftUI
import AppKit
import ScannerCore

public struct RecentLocation: Codable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bookmarkData: Data?
}

@MainActor
public final class AppState: ObservableObject {
    @Published public var isScanning: Bool = false
    @Published public var liveProgress: ScanProgress = ScanProgress()
    @Published public var store: NodeStore?
    @Published public var stats: ScanStats?
    @Published public var scanRootPath: String = ""
    @Published public var currentFolderIndex: Int = 0
    @Published public var selectedNodeIndex: Int? = nil
    @Published public var breadcrumbs: [(name: String, index: Int)] = []

    // Disk gauge properties
    @Published public var volumeTotal: Int64 = 0
    @Published public var volumeFree: Int64 = 0
    @Published public var volumeUsed: Int64 = 0

    // View Switching & Scopes (Phase 2)
    public enum ActiveCenterView: Equatable {
        case folders
        case sunburst
        case flame
        case bubbles
        case mindMap
        case treemap
        case topSizes
        case ageMap
        case quickWin(QuickWinDetectorType)

        /// The caption shown beside the view switcher, as in the reference.
        var caption: String {
            switch self {
            case .folders:   return "Browse folder by folder, sized as you go"
            case .sunburst:  return "Rings radiating out from the scan root"
            case .flame:     return "Depth top to bottom, size left to right"
            case .bubbles:   return "Nested bubbles, one per folder"
            case .mindMap:   return "Branches from the root, sized by weight"
            case .treemap:   return "Every file as a rectangle, sized by bytes"
            case .topSizes:  return "The biggest items, ranked"
            case .ageMap:    return "Where your bytes sit on a timeline"
            case .quickWin:  return "Reclaimable items, ready to review"
            }
        }
    }

    /// Top-level tabs across the toolbar.
    public enum MainTab: String, CaseIterable, Identifiable {
        case explore = "Explore"
        case duplicates = "Duplicates"
        case applications = "Applications"
        case monitor = "Monitor"
        case snapshots = "Snapshots"
        public var id: String { rawValue }
        var icon: String {
            switch self {
            case .explore:      return "square.grid.2x2"
            case .duplicates:   return "doc.on.doc"
            case .applications: return "app.badge"
            case .monitor:      return "waveform.path.ecg"
            case .snapshots:    return "clock.arrow.circlepath"
            }
        }
    }

    /// The "By type / By folder / By age" colour mode.
    public enum SizeMode: String, CaseIterable, Identifiable {
        case byType = "By type"
        case byFolder = "By folder"
        case byAge = "By age"
        public var id: String { rawValue }
        var icon: String {
            switch self {
            case .byType:   return "square.on.square"
            case .byFolder: return "folder"
            case .byAge:    return "clock"
            }
        }
    }

    @Published public var mainTab: MainTab = .explore
    @Published public var sizeMode: SizeMode = .byFolder
    @Published public var filterText: String = ""
    @Published public var scanElapsed: TimeInterval = 0
    @Published public var showInspector: Bool = true
    @Published public var sunburstRings: Double = 7
    @Published public var darkMode: Bool = false
    @Published public var showFullPaths: Bool = false
    @Published public var volumes: [(name: String, path: String)] = []
    @Published public var hasFullDiskAccess: Bool = true
    @Published public var loadedFromSnapshot: SnapshotMeta? = nil
    @Published public var snapshots: [SnapshotMeta] = []

    @Published public var activeCenterView: ActiveCenterView = .folders
    @Published public var topSizesScope: TopSizesScope = .inThisFolder
    @Published public var quickWins: [QuickWinDetectorType: QuickWinResult] = [:]
    @Published public var ageMapResult: AgeMapResult? = nil

    // Recent scan locations
    @Published public var recentLocations: [RecentLocation] = []

    private var activeSecurityScopedURL: URL?
    private var currentScanner: ScannerCore.Scanner?
    private var scanTask: Task<Void, Never>?
    private var progressTimer: Timer?

    public init() {
        loadRecentLocations()
        updateVolumeInfo(for: NSHomeDirectory())
        refreshVolumes()
        hasFullDiskAccess = AppState.detectFullDiskAccess()
        snapshots = SnapshotStore.list()
        restoreLastSnapshot()
    }

    /// Show the most recent saved scan instead of re-reading the disk at every
    /// launch. A 900k-node arena loads in ~40 ms, where rescanning costs
    /// seconds and re-triggers macOS permission prompts for Documents,
    /// Downloads and Desktop. Scanning is now always something the user asks for.
    private func restoreLastSnapshot() {
        guard let latest = snapshots.first,
              let store = SnapshotStore.load(latest.id) else { return }
        self.store = store
        self.scanRootPath = latest.rootPath
        self.loadedFromSnapshot = latest
        self.currentFolderIndex = 0
        self.breadcrumbs = [(AppState.friendlyRootName(latest.rootPath), 0)]
        updateVolumeInfo(for: latest.rootPath)
        recomputeDerived(store: store, rootPath: latest.rootPath)
    }

    private func recomputeDerived(store: NodeStore, rootPath: String) {
        Task.detached(priority: .utility) {
            let qw = QuickWinsEngine.detect(store: store, rootPath: rootPath)
            let am = AgeMapEngine.compute(store: store)
            await MainActor.run {
                self.quickWins = qw
                self.ageMapResult = am
            }
        }
    }

    /// TCC denies reads rather than prompting for a non-interactive scan, so a
    /// scan without Full Disk Access silently under-reports. Probing the TCC
    /// database is the standard way to find out before we mislead anyone.
    static func detectFullDiskAccess() -> Bool {
        let probe = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        return FileManager.default.isReadableFile(atPath: probe)
    }

    public func openFullDiskAccessSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(u)
        }
    }

    public func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)),
                  v.volumeIsBrowsable == true else { return nil }
            return (v.volumeName ?? u.lastPathComponent, u.path)
        }
    }

    deinit {
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
    }

    /// "Home" and "Macintosh HD" read better than the raw username and "/".
    public static func friendlyRootName(_ path: String) -> String {
        if path == NSHomeDirectory() { return "Home" }
        if path == "/" { return "Macintosh HD" }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    // MARK: - Volume Info

    public func updateVolumeInfo(for path: String) {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) {
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
            let used = max(0, total - free)
            self.volumeTotal = total
            self.volumeFree = free
            self.volumeUsed = used
        } else {
            var st = statfs()
            if statfs(path, &st) == 0 {
                let bsize = Int64(st.f_bsize)
                let total = Int64(st.f_blocks) * bsize
                let free = Int64(st.f_bavail) * bsize
                self.volumeTotal = total
                self.volumeFree = free
                self.volumeUsed = max(0, total - free)
            }
        }
    }

    // MARK: - Scanning Actions

    /// If the current scan already covers home, just go back to its root.
    /// Re-scanning on every Home click was the main source of "why is it
    /// scanning again?" — and of repeated permission prompts.
    public func goHome() {
        if store != nil && scanRootPath == NSHomeDirectory() {
            navigateToRoot()
        } else {
            scanHome()
        }
    }

    public func navigateToRoot() {
        currentFolderIndex = 0
        selectedNodeIndex = nil
        breadcrumbs = [(AppState.friendlyRootName(scanRootPath), 0)]
        activeCenterView = .folders
        mainTab = .explore
    }

    /// Explicit re-read of the disk. Everything else reuses the loaded scan.
    public func rescanCurrent() {
        guard !scanRootPath.isEmpty else { return scanHome() }
        startScan(path: scanRootPath, bookmarkData: nil)
    }

    public func scanHome() {
        let home = NSHomeDirectory()
        startScan(path: home, bookmarkData: nil)
    }

    public func scanFullMac() {
        startScan(path: "/", bookmarkData: nil)
    }

    public func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Scan Folder"
        panel.message = "Choose a folder or drive for Disk Buddy Checker to scan"

        if panel.runModal() == .OK, let url = panel.url {
            let bookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            startScan(path: url.path, bookmarkData: bookmark)
        }
    }

    public func rescanRecent(_ item: RecentLocation) {
        var bookmark = item.bookmarkData
        var isStale = false
        if let b = bookmark,
           let resolved = try? URL(resolvingBookmarkData: b, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            if isStale {
                bookmark = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            startScan(path: resolved.path, bookmarkData: bookmark)
        } else {
            startScan(path: item.path, bookmarkData: nil)
        }
    }

    public func cancelScan() {
        currentScanner?.cancel()
        progressTimer?.invalidate()
        progressTimer = nil
        isScanning = false
    }

    public func startScan(path: String, bookmarkData: Data?) {
        cancelScan()

        // Release prior security scoped bookmark
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil

        let url = URL(fileURLWithPath: path)
        if url.startAccessingSecurityScopedResource() {
            activeSecurityScopedURL = url
        }

        saveRecentLocation(path: path, bookmarkData: bookmarkData)
        updateVolumeInfo(for: path)

        self.scanRootPath = path
        self.isScanning = true
        self.liveProgress = ScanProgress(currentPath: path)
        self.currentFolderIndex = 0
        self.selectedNodeIndex = nil
        self.breadcrumbs = [(AppState.friendlyRootName(path), 0)]

        let scanner = ScannerCore.Scanner()
        self.currentScanner = scanner

        // Polling timer for smooth 30Hz live updates
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let prog = scanner.currentProgress()
            Task { @MainActor in
                self.liveProgress = prog
                // NOTE: we deliberately do NOT publish scanner.store mid-scan.
                // Subtree sizes are only meaningful after rollUp(), so an early
                // publish renders every folder as 0 B and sorts by noise.
                // Live feedback comes from `liveProgress` instead.
            }
        }

        let threads = ProcessInfo.processInfo.activeProcessorCount
        let crossMounts = (path == "/")

        scanTask = Task.detached(priority: .userInitiated) {
            scanner.scan(root: path, threads: threads, crossMounts: crossMounts)

            let qw = QuickWinsEngine.detect(store: scanner.store, rootPath: path)
            let am = AgeMapEngine.compute(store: scanner.store)

            await MainActor.run {
                self.progressTimer?.invalidate()
                self.progressTimer = nil
                self.isScanning = false
                self.store = scanner.store
                self.stats = scanner.stats
                self.quickWins = qw
                self.ageMapResult = am
                var prog = scanner.currentProgress()
                prog.isComplete = true
                self.liveProgress = prog
                self.scanElapsed = prog.elapsed
                self.currentFolderIndex = 0
                self.selectedNodeIndex = nil
                self.loadedFromSnapshot = nil
                self.hasFullDiskAccess = AppState.detectFullDiskAccess()
                self.saveSnapshot(store: scanner.store, rootPath: path)
            }
        }
    }

    /// Every completed scan is saved, which is what makes the Snapshots tab
    /// possible and what lets the next launch start instantly.
    public func saveSnapshot(store: NodeStore, rootPath: String, label: String = "") {
        Task.detached(priority: .utility) {
            _ = try? SnapshotStore.save(store: store, rootPath: rootPath, label: label)
            let list = SnapshotStore.list()
            await MainActor.run { self.snapshots = list }
        }
    }

    public func deleteSnapshot(_ id: String) {
        SnapshotStore.delete(id)
        snapshots = SnapshotStore.list()
    }

    public func selectQuickWin(_ detector: QuickWinDetectorType) {
        self.activeCenterView = .quickWin(detector)
        self.selectedNodeIndex = nil
    }

    public func switchView(_ view: ActiveCenterView) {
        self.activeCenterView = view
        self.selectedNodeIndex = nil
    }

    // MARK: - Navigation & Selection

    public func drillInto(nodeIndex: Int) {
        guard let store = store, store.isDir(nodeIndex) else { return }
        currentFolderIndex = nodeIndex
        selectedNodeIndex = nil
        let name = store.name(nodeIndex)
        breadcrumbs.append((name, nodeIndex))
    }

    public func navigateToBreadcrumb(index: Int) {
        guard let sliceIdx = breadcrumbs.firstIndex(where: { $0.index == index }) else { return }
        breadcrumbs = Array(breadcrumbs.prefix(through: sliceIdx))
        currentFolderIndex = index
        selectedNodeIndex = nil
    }

    public func navigateBack() {
        guard breadcrumbs.count > 1 else { return }
        breadcrumbs.removeLast()
        if let parent = breadcrumbs.last {
            currentFolderIndex = parent.index
            selectedNodeIndex = nil
        }
    }

    public func selectNode(_ index: Int?) {
        selectedNodeIndex = index
    }

    // MARK: - Actions (Finder, Quick Look, Copy)

    public func revealInFinder(nodeIndex: Int) {
        guard let store = store else { return }
        let fullPath = store.path(nodeIndex)
        let url = URL(fileURLWithPath: fullPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func copyPath(nodeIndex: Int) {
        guard let store = store else { return }
        let fullPath = store.path(nodeIndex)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullPath, forType: .string)
    }

    public func quickLook(nodeIndex: Int) {
        guard let store = store else { return }
        let fullPath = store.path(nodeIndex)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", fullPath]
        try? p.run()
    }

    // MARK: - Persistence (Recent Locations)

    private func saveRecentLocation(path: String, bookmarkData: Data?) {
        let name = (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
        var recents = recentLocations.filter { $0.path != path }
        recents.insert(RecentLocation(path: path, name: name, bookmarkData: bookmarkData), at: 0)
        if recents.count > 8 { recents = Array(recents.prefix(8)) }
        self.recentLocations = recents
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: "DiskBuddy_RecentLocations")
        }
    }

    private func loadRecentLocations() {
        if let data = UserDefaults.standard.data(forKey: "DiskBuddy_RecentLocations"),
           let recents = try? JSONDecoder().decode([RecentLocation].self, from: data) {
            self.recentLocations = recents
        }
    }
}
