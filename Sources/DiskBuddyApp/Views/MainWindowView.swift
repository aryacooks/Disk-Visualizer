import SwiftUI
import ScannerCore

public struct MainWindowView: View {
    @EnvironmentObject var app: AppState

    public init() {}

    @StateObject private var cleanup = CleanupQueue()

    public var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider().overlay(Theme.hairline)
            if !app.hasFullDiskAccess { FullDiskAccessBanner() }
            if let snap = app.loadedFromSnapshot, !app.isScanning { SnapshotBanner(meta: snap) }

            // A scan takes over the whole body, sidebar and inspector included.
            // Anything left on screen would be the PREVIOUS scan's numbers:
            // live-looking, wrong, and about to be replaced. Partial totals are
            // not merely stale — subtree sizes don't exist until the reverse
            // pass runs, so a half-built tree reads 0 B everywhere.
            if app.isScanning {
                ScanningView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 258)
                Divider().overlay(Theme.hairline)
                Group {
                    if app.mainTab == .explore {
                        CenterPane()
                    } else if app.mainTab == .monitor {
                        MonitorView()
                    } else if app.mainTab == .applications {
                        ApplicationsView()
                    } else if app.mainTab == .duplicates {
                        DuplicatesView()
                    } else if app.mainTab == .snapshots {
                        SnapshotsView()
                    } else {
                        NotBuiltYetPane(tab: app.mainTab)
                    }
                }
                .frame(maxWidth: .infinity)
                if app.showInspector {
                    Divider().overlay(Theme.hairline)
                    InspectorView()
                        .frame(width: 300)
                }
            }
            }
            if cleanup.count > 0 { CleanupBar() }
        }
        .background(Theme.ground)
        .frame(minWidth: 1240, minHeight: 680)
        .environmentObject(cleanup)
        .preferredColorScheme(app.darkMode ? .dark : .light)
        .sheet(isPresented: $cleanup.showReview) { CleanupReviewSheet() }
    }
}

/// Shown when a scan would silently under-report because TCC is blocking us.
private struct FullDiskAccessBanner: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Theme.gauge)
            Text("Without Full Disk Access, parts of your Library, Mail and Photos are invisible to the scan — totals will read low.")
                .font(.system(size: 11)).foregroundStyle(Theme.ink)
            Spacer()
            Button { app.openFullDiskAccessSettings() } label: {
                Text("Open Settings").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.pillText)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.pill))
            }
            .buttonStyle(.plain)
            Text("then relaunch").font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
        }
        .padding(.horizontal, 20).padding(.vertical, 7)
        .background(Theme.gauge.opacity(0.10))
    }
}

/// Makes it obvious the numbers are from a saved scan, not a fresh read.
private struct SnapshotBanner: View {
    @EnvironmentObject var app: AppState
    let meta: SnapshotMeta
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11)).foregroundStyle(Theme.inkSecond)
            Text("Showing your saved scan from \(Fmt.ago(meta.date)) — nothing was re-read from disk.")
                .font(.system(size: 11)).foregroundStyle(Theme.ink)
            Spacer()
            Button { app.rescanCurrent() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    Text("Rescan now").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.pillText)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Theme.pill))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 7)
        .background(Theme.pillSoft.opacity(0.5))
    }
}

/// Persistent footer while anything is staged.
private struct CleanupBar: View {
    @EnvironmentObject var cleanup: CleanupQueue
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.ink)
            Text("\(cleanup.count) staged · \(Fmt.bytes(cleanup.totalBytes))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
            Text("nothing has been deleted").font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
            Spacer()
            Button { cleanup.clear() } label: {
                Text("Clear").font(.system(size: 11)).foregroundStyle(Theme.inkSecond)
            }
            .buttonStyle(.plain)
            Button { cleanup.showReview = true } label: {
                Text("Review \(cleanup.count) items")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.danger))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .background(Theme.rail)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .top)
    }
}

private struct CleanupReviewSheet: View {
    @EnvironmentObject var cleanup: CleanupQueue
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Move \(cleanup.count) items to the Trash")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                Text("Each item is re-measured just before it moves, so the figure below is what you will actually get back. Nothing is deleted outright — it all lands in the Trash.")
                    .font(.system(size: 11)).foregroundStyle(Theme.inkSecond)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(cleanup.items) { item in
                        HStack(spacing: 9) {
                            Image(systemName: item.isDir ? "folder" : "doc")
                                .font(.system(size: 11)).foregroundStyle(Theme.inkSecond)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.ink).lineLimit(1)
                                Text("\(item.origin) · \(item.path)")
                                    .font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
                                    .lineLimit(1).truncationMode(.head)
                            }
                            Spacer(minLength: 4)
                            Text(Fmt.bytes(item.size))
                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.inkSecond)
                            Button { cleanup.remove(item.path) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 320)
            Divider().overlay(Theme.hairline)
            HStack {
                Text("\(cleanup.count) items · \(Fmt.bytes(cleanup.totalBytes))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button { cleanup.showReview = false } label: {
                    Text("Cancel").font(.system(size: 12))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button { cleanup.emptyToTrash() } label: {
                    Text("Move to Trash").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.danger))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .frame(width: 640)
        .background(Theme.ground)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @EnvironmentObject var app: AppState

    /// One entry in the rendered trail: a clickable crumb, or the elision.
    private enum Crumb {
        case crumb(name: String, index: Int, isLast: Bool)
        case gap
    }

    /// Root, an ellipsis, then the last three. Drilling from a deep sunburst
    /// arc can produce a dozen levels at once, and a trail that long doesn't
    /// fit beside five tabs, a search field and four toolbar controls.
    private var crumbTrail: [Crumb] {
        let all = app.breadcrumbs
        let last = all.count - 1
        func entry(_ i: Int) -> Crumb {
            .crumb(name: all[i].name, index: all[i].index, isLast: i == last)
        }
        guard all.count > 4 else { return all.indices.map(entry) }
        return [entry(0), .gap] + ((all.count - 2)...last).map(entry)
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AppState.MainTab.allCases) { tab in
                TabPill(tab: tab, isActive: app.mainTab == tab) { app.mainTab = tab }
            }

            Divider().frame(height: 18).padding(.horizontal, 8)

            // Breadcrumb
            Button { app.zoomOut { app.navigateBack() } } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(app.breadcrumbs.count > 1 ? Theme.inkSecond : Theme.inkFaint.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(app.breadcrumbs.count <= 1)

            ForEach(Array(crumbTrail.enumerated()), id: \.offset) { i, entry in
                switch entry {
                case .gap:
                    // The elided middle. A click on it is a click on the level
                    // just below the root, which is the only sane target.
                    Text("…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.inkFaint)
                        .padding(.horizontal, 4)
                case .crumb(let name, let index, let isLast):
                    Button { app.zoomOut { app.navigateToBreadcrumb(index: index) } } label: {
                        Text(name)
                            .font(.system(size: 12, weight: isLast ? .semibold : .regular))
                            .foregroundStyle(isLast ? Theme.ink : Theme.inkSecond)
                            // A single click in the sunburst can land ten levels
                            // down. Without these the trail wrapped every crumb
                            // onto its own line and pushed the toolbar to three
                            // times its height.
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 110)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(isLast ? Theme.pillSoft.opacity(0.7) : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
                if i < crumbTrail.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.inkFaint)
                }
            }

            Spacer(minLength: 12)

            // Filter field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkFaint)
                TextField("Filter by name...", text: $app.filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(width: 216)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.ground)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
            )

            Button { app.showFullPaths.toggle() } label: {
                IconChip(system: "textformat.abc", filled: app.showFullPaths)
            }
            .buttonStyle(.plain)
            .help(app.showFullPaths ? "Showing full paths" : "Showing names only")

            Menu {
                ForEach(Array(app.volumes.enumerated()), id: \.offset) { _, v in
                    Button("\(v.name)  —  \(v.path)") {
                        app.startScan(path: v.path, bookmarkData: nil)
                    }
                }
                Divider()
                Button("Refresh volume list") { app.refreshVolumes() }
            } label: {
                IconChip(system: "externaldrive", filled: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
            .help("Scan another volume")

            Menu {
                Button { app.darkMode = false } label: {
                    Label("Paper", systemImage: app.darkMode ? "" : "checkmark")
                }
                Button { app.darkMode = true } label: {
                    Label("Ink", systemImage: app.darkMode ? "checkmark" : "")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    Text(app.darkMode ? "Ink" : "Paper").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.ink)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Button { app.showInspector.toggle() } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.rail)
    }
}

private struct TabPill: View {
    let tab: AppState.MainTab
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.icon).font(.system(size: 11, weight: .medium))
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    // "Applications" broke across two lines as soon as a deep
                    // breadcrumb competed for the same row.
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(isActive ? Theme.pillText : Theme.inkSecond)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Theme.pill : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct IconChip: View {
    let system: String
    var filled: Bool = false
    var body: some View {
        Image(systemName: system)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(filled ? Theme.pillText : Theme.ink)
            .frame(width: 26, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(filled ? Theme.pill : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(filled ? Color.clear : Theme.hairline, lineWidth: 1))
            )
    }
}

// MARK: - Centre pane

private struct CenterPane: View {
    /// Named so that a folder card inside a scroll view can report where it
    /// sits relative to the pane, and the zoom can anchor on it.
    static let space = "centerPane"

    @EnvironmentObject var app: AppState

    private var titleName: String {
        guard let store = app.store else { return "" }
        let n = store.name(app.currentFolderIndex)
        if app.currentFolderIndex == 0 {
            return n == NSHomeDirectory() ? "Home" : (n as NSString).lastPathComponent
        }
        return n
    }

    var body: some View {
        VStack(spacing: 0) {
            // Scanning is handled one level up, in MainWindowView's body: it
            // replaces the entire window content, not just this pane.
            if app.store == nil {
                EmptyStatePane()
            } else {
                header
                Divider().overlay(Theme.hairline).padding(.top, 2)
                content
            }
        }
        .background(Theme.ground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(titleName)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.ink)
                if let store = app.store {
                    let i = app.currentFolderIndex
                    Text(Fmt.bytes(store.subtree[i]))
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    Text("·").foregroundStyle(Theme.inkFaint)
                    Text("\(Fmt.count(Int(store.subtreeFiles[i]))) files")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Theme.inkSecond)
                    Text("·").foregroundStyle(Theme.inkFaint)
                    Text("\(Fmt.count(max(0, Int(store.subtreeDirs[i]) - 1))) folders")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Theme.inkSecond)
                }
                Spacer()
                if app.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                        Text("scanning…").font(.system(size: 11)).foregroundStyle(Theme.inkSecond)
                    }
                }
            }

            HStack(spacing: 10) {
                ViewSwitcher()
                Spacer(minLength: 8)
                // Drop the caption before letting anything wrap.
                ViewThatFits(in: .horizontal) {
                    Text(app.activeCenterView.caption)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkFaint)
                        .lineLimit(1)
                        .fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                SizeModeSegments()
                if case .sunburst = app.activeCenterView {
                    HStack(spacing: 7) {
                        Image(systemName: "circle.hexomegrid")
                            .font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
                        Slider(value: $app.sunburstRings, in: 3...12, step: 1).frame(width: 90)
                        Text("\(Int(app.sunburstRings))")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.inkSecond)
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        // One place, every visualiser: changing folder replays the zoom.
        centerContent
            .zoomDrill(key: app.currentFolderIndex,
                       anchor: app.zoomAnchor,
                       zoomingIn: app.zoomingIn)
            .clipped()      // the outgoing level grows past the pane's edges
            .coordinateSpace(name: CenterPane.space)
            .background(
                GeometryReader { g in
                    Color.clear.onAppear { app.paneSize = g.size }
                        .onChange(of: g.size) { _, new in app.paneSize = new }
                }
            )
    }

    @ViewBuilder
    private var centerContent: some View {
        switch app.activeCenterView {
        case .folders:            FoldersView()
        case .sunburst:           SunburstView()
        case .flame:              FlameView()
        case .bubbles:            BubblesView()
        case .mindMap:            MindMapView()
        case .treemap:            TreemapView()
        case .topSizes:           TopSizesView()
        case .ageMap:             AgeMapView()
        case .quickWin(let d):    QuickWinDetailView(detector: d)
        }
    }
}

private struct ViewSwitcher: View {
    @EnvironmentObject var app: AppState

    private struct Item: Identifiable {
        let id: String
        let icon: String
        let view: AppState.ActiveCenterView?   // nil = not built yet
    }

    private let items: [Item] = [
        .init(id: "Folders",   icon: "folder",                              view: .folders),
        .init(id: "Sunburst",  icon: "circle.circle",                       view: .sunburst),
        .init(id: "Flame",     icon: "flame",                               view: .flame),
        .init(id: "Bubbles",   icon: "circle.grid.3x3",                     view: .bubbles),
        .init(id: "Mind Map",  icon: "point.3.connected.trianglepath.dotted", view: .mindMap),
        .init(id: "Top Sizes", icon: "chart.bar.fill",                      view: .topSizes),
        .init(id: "Age Map",   icon: "calendar",                            view: .ageMap),
        .init(id: "Treemap",   icon: "square.grid.3x3.square",              view: .treemap),
    ]

    var body: some View {
        HStack(spacing: 2) {
            Button {
                let order: [AppState.ActiveCenterView] =
                    [.folders, .sunburst, .flame, .bubbles, .mindMap, .topSizes, .ageMap, .treemap]
                let i = order.firstIndex(of: app.activeCenterView) ?? 0
                app.switchView(order[(i + 1) % order.count])
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.inkSecond)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Cycle through the views")

            ForEach(items) { item in
                let active = item.view != nil && app.activeCenterView == item.view!
                Button {
                    if let v = item.view { app.switchView(v) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon).font(.system(size: 11, weight: .medium))
                        if active {
                            Text(item.id)
                                .font(.system(size: 12, weight: .medium))
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(active ? Theme.pillText
                                            : (item.view != nil ? Theme.ink : Theme.inkFaint.opacity(0.5)))
                    .frame(height: 26)
                    .padding(.horizontal, active ? 10 : 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(active ? Theme.pill : .clear))
                }
                .buttonStyle(.plain)
                .disabled(item.view == nil)
                .help(item.view == nil ? "\(item.id) — not built yet" : item.id)
            }
        }
        .fixedSize()
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Theme.rail)
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.hairline, lineWidth: 1))
        )
    }
}

private struct SizeModeSegments: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        ViewThatFits(in: .horizontal) {
            segments(showLabels: true)
            segments(showLabels: false)
        }
    }

    private func segments(showLabels: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(AppState.SizeMode.allCases) { mode in
                let active = app.sizeMode == mode
                Button { app.sizeMode = mode } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.icon).font(.system(size: 10))
                        if showLabels {
                            Text(mode.rawValue).font(.system(size: 11, weight: .medium)).fixedSize()
                        }
                    }
                    .foregroundStyle(active ? Theme.ink : Theme.inkSecond)
                    .frame(height: 20)
                    .padding(.horizontal, showLabels ? 9 : 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.pillSoft : .clear))
                }
                .buttonStyle(.plain)
                .help(mode.rawValue)
            }
        }
        .fixedSize()
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.rail)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
        )
    }
}

// MARK: - Empty / scanning states

private struct EmptyStatePane: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.inkFaint)
            Text("Nothing scanned yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("Scan your home folder to see where the space went.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecond)
            Button { app.scanHome() } label: {
                Text("Scan Home Folder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.pillText)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.pill))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// Honest placeholder for the tabs that aren't implemented yet, rather than
/// silently showing the Explore content under a different tab name.
private struct NotBuiltYetPane: View {
    let tab: AppState.MainTab

    private var blurb: String {
        switch tab {
        case .duplicates:
            return "Byte-identical files, found with a size → head/tail-hash → full-hash funnel, with APFS clones flagged as freeing nothing."
        case .applications:
            return "Uninstall Completely: an app plus the caches, preferences and containers it scattered across your Library."
        case .monitor:
            return "Live CPU, memory and per-process disk I/O, so you can see which app is writing to your disk right now."
        case .snapshots:
            return "Compare today's scan against an earlier one — what grew, what shrank, what appeared."
        case .explore:
            return ""
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: tab.icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.inkFaint)
            Text(tab.rawValue)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text("Not built yet")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.inkSecond)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Theme.pillSoft))
            Text(blurb)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecond)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }
}
