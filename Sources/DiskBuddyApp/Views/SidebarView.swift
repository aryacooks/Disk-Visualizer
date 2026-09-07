import SwiftUI
import ScannerCore

public struct SidebarView: View {
    @EnvironmentObject var app: AppState

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                scanButtons
                recentSection
                diskStorageSection
                currentViewSection
                quickWinsSection
                fileTypesSection
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.never)
        .background(Theme.rail)
    }

    // MARK: Scan buttons

    private var scanButtons: some View {
        VStack(spacing: 8) {
            Button { app.scanFullMac() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "internaldrive").font(.system(size: 12, weight: .medium))
                    Text("Scan Full Mac").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Theme.pillText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.pill))
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                SmallRailButton(icon: "house.fill", title: "Home") { app.goHome() }
                SmallRailButton(icon: "folder", title: "Folder…") { app.chooseFolder() }
            }
        }
    }

    // MARK: Recent

    @ViewBuilder
    private var recentSection: some View {
        if !app.recentLocations.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                RailLabel("Recent")
                ForEach(app.recentLocations.prefix(4)) { loc in
                    Button { app.rescanRecent(loc) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.inkFaint)
                            Text(displayName(loc))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.inkSecond)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func displayName(_ loc: RecentLocation) -> String {
        if loc.path == NSHomeDirectory() { return "Home" }
        if loc.path == "/" { return "Macintosh HD" }
        return loc.name
    }

    // MARK: Disk storage

    private var diskStorageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RailLabel("Disk Storage", trailing: volumeName)

            HStack(spacing: 14) {
                DiskRing(fraction: usedFraction)
                    .frame(width: 78, height: 78)

                VStack(alignment: .leading, spacing: 6) {
                    StatRow(label: "Total", value: Fmt.bytes(app.volumeTotal), tint: Theme.ink)
                    StatRow(label: "Used",  value: Fmt.bytes(app.volumeUsed),  tint: Theme.danger)
                    StatRow(label: "Free",  value: Fmt.bytes(app.volumeFree),  tint: Theme.good)
                }
            }
        }
    }

    private var volumeName: String {
        let url = URL(fileURLWithPath: app.scanRootPath.isEmpty ? NSHomeDirectory() : app.scanRootPath)
        return (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "Macintosh HD"
    }

    private var usedFraction: Double {
        guard app.volumeTotal > 0 else { return 0 }
        return Double(app.volumeUsed) / Double(app.volumeTotal)
    }

    // MARK: Current view

    @ViewBuilder
    private var currentViewSection: some View {
        if let store = app.store {
            VStack(alignment: .leading, spacing: 8) {
                RailLabel("Current View",
                          trailing: app.scanElapsed > 0 ? String(format: "%.1fs scan", app.scanElapsed) : nil)

                Text(app.currentFolderIndex == 0 ? rootLabel : store.name(app.currentFolderIndex))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(store.path(app.currentFolderIndex))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    SmallRailButton(icon: "arrow.up.forward.square", title: "Reveal") {
                        app.revealInFinder(nodeIndex: app.currentFolderIndex)
                    }
                    SmallRailButton(icon: "doc.on.clipboard", title: "Copy Path") {
                        app.copyPath(nodeIndex: app.currentFolderIndex)
                    }
                }
                SmallRailButton(icon: "arrow.clockwise", title: "Rescan this folder") {
                    app.rescanCurrent()
                }
            }
        }
    }

    private var rootLabel: String {
        AppState.friendlyRootName(app.scanRootPath)
    }

    // MARK: Quick wins

    @ViewBuilder
    private var quickWinsSection: some View {
        if !app.quickWins.isEmpty {
            let ordered = QuickWinDetectorType.allCases.compactMap { app.quickWins[$0] }
                .filter { $0.totalBytes > 0 }
                .sorted { $0.totalBytes > $1.totalBytes }
            let total = ordered.reduce(Int64(0)) { $0 + $1.totalBytes }

            VStack(alignment: .leading, spacing: 9) {
                RailLabel("Quick Wins", trailing: Fmt.bytes(total))
                ForEach(ordered) { win in
                    QuickWinRow(win: win, isActive: app.activeCenterView == .quickWin(win.detector)) {
                        app.selectQuickWin(win.detector)
                    }
                }
            }
        }
    }

    // MARK: File types

    @ViewBuilder
    private var fileTypesSection: some View {
        if let stats = app.stats {
            let cats = FileTypeCategory.allCases.map { ($0, stats.categoryBytes[$0] ?? 0) }
            let total = max(1, cats.reduce(Int64(0)) { $0 + $1.1 })

            VStack(alignment: .leading, spacing: 9) {
                RailLabel("File Types")

                // Proportional stacked bar
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(cats.filter { $0.1 > 0 }, id: \.0) { cat, bytes in
                            Theme.categoryColor(cat)
                                .frame(width: max(2, geo.size.width * CGFloat(bytes) / CGFloat(total)))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .frame(height: 7)

                VStack(spacing: 5) {
                    ForEach(cats.sorted { $0.1 > $1.1 }, id: \.0) { cat, bytes in
                        HStack(spacing: 7) {
                            Circle().fill(Theme.categoryColor(cat)).frame(width: 6, height: 6)
                            Text(cat.rawValue)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.inkSecond)
                            Spacer()
                            Text(Fmt.bytes(bytes))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

private struct StatRow: View {
    let label: String, value: String, tint: Color
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.inkSecond)
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(tint)
        }
    }
}

struct SmallRailButton: View {
    let icon: String, title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.ground)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct QuickWinRow: View {
    let win: QuickWinResult
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: win.detector.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecond)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(win.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text("\(Fmt.count(win.itemCount)) item\(win.itemCount == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.inkFaint)
                }
                Spacer(minLength: 4)
                Text(Fmt.bytes(win.totalBytes))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.inkFaint)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? Theme.pillSoft.opacity(0.8) : .clear))
        }
        .buttonStyle(.plain)
    }
}

/// The amber capacity ring from the reference.
private struct DiskRing: View {
    let fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 9)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(Theme.gauge, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(String(format: "%.1f%%", fraction * 100))
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Text("USED")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.inkFaint)
            }
        }
    }
}
