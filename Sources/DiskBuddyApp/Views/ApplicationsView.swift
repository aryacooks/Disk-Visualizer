import SwiftUI
import AppKit
import ScannerCore

@MainActor
final class AppsModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var loading = false
    @Published var selected: InstalledApp?
    @Published var search = ""
    @Published var leftovers: [LeftoverItem] = []
    @Published var loadingLeftovers = false

    // Uninstall review
    @Published var showReview = false
    @Published var checked: Set<String> = []
    @Published var result: String?

    func load() {
        guard apps.isEmpty, !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let found = AppInventory.installedApps()
            await MainActor.run {
                self.apps = found
                self.loading = false
                if self.selected == nil { self.select(found.first) }
            }
        }
    }

    func select(_ app: InstalledApp?) {
        selected = app
        leftovers = []
        result = nil
        guard let app else { return }
        loadingLeftovers = true
        Task.detached(priority: .userInitiated) {
            let lo = AppInventory.leftovers(for: app)
            await MainActor.run {
                guard self.selected?.id == app.id else { return }
                self.leftovers = lo
                self.loadingLeftovers = false
            }
        }
    }

    var filtered: [InstalledApp] {
        guard !search.isEmpty else { return apps }
        let q = search.lowercased()
        return apps.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
    }

    // MARK: Uninstall

    /// Paths we refuse to touch no matter what the UI says.
    private static let denyPrefixes = ["/System", "/bin", "/sbin", "/Library/Apple", "/private/var/db"]

    func canRemove(_ path: String) -> Bool {
        if Self.denyPrefixes.contains(where: { path.hasPrefix($0) }) { return false }
        if path.hasPrefix("/usr") && !path.hasPrefix("/usr/local") { return false }
        return true
    }

    var isSelectedRunning: Bool {
        guard let bid = selected?.bundleID, !bid.isEmpty else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bid }
    }

    func beginReview() {
        guard let app = selected else { return }
        // Only exact bundle-ID matches are pre-checked. Fuzzier matches are
        // shown but left off, so a name collision can't delete someone's data.
        checked = Set(leftovers.filter { $0.confidence == .high }.map { $0.path })
        checked.insert(app.path)
        result = nil
        showReview = true
    }

    var reviewItems: [(path: String, name: String, kind: String, size: Int64, confidence: LeftoverConfidence)] {
        guard let app = selected else { return [] }
        var rows: [(String, String, String, Int64, LeftoverConfidence)] = [
            (app.path, app.name + ".app", "Application bundle", app.bundleSize, .high)
        ]
        rows += leftovers.map { ($0.path, $0.name, $0.kind, $0.size, $0.confidence) }
        return rows.map { (path: $0.0, name: $0.1, kind: $0.2, size: $0.3, confidence: $0.4) }
    }

    var checkedBytes: Int64 {
        reviewItems.filter { checked.contains($0.path) }.reduce(0) { $0 + $1.size }
    }

    /// Moves the checked items to the Trash. Never unlinks: everything stays
    /// recoverable. Each item is re-checked immediately before the move.
    func performUninstall() {
        let targets = reviewItems.filter { checked.contains($0.path) }
        var freed: Int64 = 0
        var moved = 0
        var skipped: [String] = []

        for item in targets {
            guard canRemove(item.path) else { skipped.append("\(item.name) (protected location)"); continue }
            guard FileManager.default.fileExists(atPath: item.path) else {
                skipped.append("\(item.name) (already gone)"); continue
            }
            // Re-measure so the "freed" figure is what actually left the disk.
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
            msg += "\n\nSkipped \(skipped.count): " + skipped.prefix(4).joined(separator: "; ")
        }
        msg += "\n\nNothing was permanently deleted — everything is recoverable from the Trash."
        result = msg
        showReview = false

        // Refresh
        apps.removeAll { $0.id == selected?.id }
        selected = nil
        leftovers = []
    }
}

/// "Uninstall apps and their leftovers."
public struct ApplicationsView: View {
    @StateObject private var model = AppsModel()

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            appList.frame(width: 268)
            Divider().overlay(Theme.hairline)
            detail.frame(maxWidth: .infinity)
        }
        .background(Theme.ground)
        .onAppear { model.load() }
        .sheet(isPresented: $model.showReview) { reviewSheet }
    }

    // MARK: List

    private var appList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                TextField("Search apps...", text: $model.search)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ground)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1)))
            .padding(10)

            if model.loading {
                VStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text("Measuring app bundles…").font(.system(size: 11)).foregroundStyle(Theme.inkSecond)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.filtered) { app in
                            AppRow(app: app, isSelected: model.selected?.id == app.id) {
                                model.select(app)
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 10)
                }
                .scrollIndicators(.automatic)
            }
        }
        .background(Theme.rail)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let app = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(app)
                    footprint(app)
                    associatedFiles(app)
                    if let r = model.result {
                        Text(r).font(.system(size: 11)).foregroundStyle(Theme.good)
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.good.opacity(0.1)))
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.never)
        } else if let r = model.result {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle").font(.system(size: 30)).foregroundStyle(Theme.good)
                Text(r).font(.system(size: 12)).foregroundStyle(Theme.inkSecond)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Select an app").font(.system(size: 12)).foregroundStyle(Theme.inkFaint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ app: InstalledApp) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable().frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 5) {
                Text(app.name).font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.ink)
                HStack(spacing: 6) {
                    if !app.version.isEmpty { Chip("v" + app.version) }
                    if let used = app.lastUsed { Chip("Used " + Fmt.ago(used), icon: "clock") }
                    if model.isSelectedRunning { Chip("Running now", icon: "bolt.fill", tint: Theme.danger) }
                }
                Text(app.bundleID.isEmpty ? app.path : app.bundleID)
                    .font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
            }
            Spacer()
            Button { model.beginReview() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash").font(.system(size: 11))
                    Text("Uninstall Completely").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.danger))
            }
            .buttonStyle(.plain)
            .disabled(model.loadingLeftovers)
        }
    }

    private func footprint(_ app: InstalledApp) -> some View {
        let support = model.leftovers.reduce(Int64(0)) { $0 + $1.size }
        let total = max(Int64(1), app.bundleSize + support)
        return Panel(title: "Total footprint",
                     trailing: Fmt.bytes(app.bundleSize + support)) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.ink)
                        .frame(width: max(3, geo.size.width * CGFloat(app.bundleSize) / CGFloat(total)))
                    RoundedRectangle(cornerRadius: 3).fill(Theme.gauge)
                        .frame(width: max(2, geo.size.width * CGFloat(support) / CGFloat(total)))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 11)
            HStack(spacing: 16) {
                LegendDot(color: Theme.ink, label: "Bundle", value: Fmt.bytes(app.bundleSize))
                LegendDot(color: Theme.gauge, label: "Support files", value: Fmt.bytes(support))
                Spacer()
            }
        }
    }

    private func associatedFiles(_ app: InstalledApp) -> some View {
        Panel(title: "Associated files", trailing: "\(model.leftovers.count)") {
            if model.loadingLeftovers {
                HStack(spacing: 7) {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                    Text("Searching the Library…").font(.system(size: 11)).foregroundStyle(Theme.inkSecond)
                }
            } else if model.leftovers.isEmpty {
                Text("Nothing outside the app bundle. This one cleans up after itself.")
                    .font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
            } else {
                VStack(spacing: 4) {
                    ForEach(model.leftovers) { item in
                        HStack(spacing: 9) {
                            Text(item.kind)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.inkSecond)
                                .frame(width: 128, alignment: .leading)
                            Text(item.name)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1).truncationMode(.middle)
                            if item.confidence != .high {
                                Text(item.confidence.label)
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(Theme.gauge)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Capsule().fill(Theme.gauge.opacity(0.14)))
                            }
                            Spacer(minLength: 4)
                            Text(Fmt.bytes(item.size))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(Theme.inkSecond)
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                            } label: {
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: Review sheet

    private var reviewSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Move to Trash").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                Text("Review each item. Only exact bundle-ID matches are ticked for you; anything matched by name alone is left for you to decide.")
                    .font(.system(size: 11)).foregroundStyle(Theme.inkSecond)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isSelectedRunning {
                    Label("This app is running. Quit it first, or the uninstall will be incomplete.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.danger)
                        .padding(.top, 3)
                }
            }
            .padding(16)

            Divider().overlay(Theme.hairline)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(model.reviewItems, id: \.path) { item in
                        let allowed = model.canRemove(item.path)
                        HStack(spacing: 9) {
                            Toggle("", isOn: Binding(
                                get: { model.checked.contains(item.path) },
                                set: { on in
                                    if on { model.checked.insert(item.path) }
                                    else { model.checked.remove(item.path) }
                                }))
                                .labelsHidden()
                                .disabled(!allowed)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(allowed ? Theme.ink : Theme.inkFaint)
                                    .lineLimit(1)
                                Text(allowed ? "\(item.kind) · \(item.confidence.label)"
                                             : "\(item.kind) · protected location, cannot be removed")
                                    .font(.system(size: 9))
                                    .foregroundStyle(allowed ? Theme.inkFaint : Theme.danger)
                            }
                            Spacer(minLength: 4)
                            Text(Fmt.bytes(item.size))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.inkSecond)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 300)

            Divider().overlay(Theme.hairline)

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(model.checked.count) items · \(Fmt.bytes(model.checkedBytes))")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    Text("Moved to the Trash, not deleted — you can put them back.")
                        .font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
                }
                Spacer()
                Button("Cancel") { model.showReview = false }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
                Button {
                    model.performUninstall()
                } label: {
                    Text("Move \(model.checked.count) to Trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.danger))
                }
                .buttonStyle(.plain)
                .disabled(model.checked.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 620)
        .background(Theme.ground)
    }
}

// MARK: - Pieces

private struct AppRow: View {
    let app: InstalledApp
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.name).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink).lineLimit(1)
                    Text(app.version.isEmpty ? app.bundleID : "v" + app.version)
                        .font(.system(size: 9)).foregroundStyle(Theme.inkFaint).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(Fmt.bytes(app.bundleSize))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.inkSecond)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Theme.pillSoft : .clear))
        }
        .buttonStyle(.plain)
    }
}

private struct Chip: View {
    let text: String
    var icon: String? = nil
    var tint: Color = Theme.inkSecond
    init(_ text: String, icon: String? = nil, tint: Color = Theme.inkSecond) {
        self.text = text; self.icon = icon; self.tint = tint
    }
    var body: some View {
        HStack(spacing: 4) {
            if let i = icon { Image(systemName: i).font(.system(size: 8)) }
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.pillSoft.opacity(0.75)))
    }
}

private struct LegendDot: View {
    let color: Color, label: String, value: String
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.inkSecond)
            Text(value).font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
        }
    }
}
