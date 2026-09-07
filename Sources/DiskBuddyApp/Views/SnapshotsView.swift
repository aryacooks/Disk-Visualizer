import SwiftUI
import ScannerCore

@MainActor
final class SnapshotsModel: ObservableObject {
    @Published var leftID: String?
    @Published var rightID: String?
    @Published var diff: SnapshotDiffResult?
    @Published var comparing = false
    @Published var filter: ChangeKind?

    func compare(_ a: String, _ b: String) {
        guard !comparing else { return }
        comparing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let older = SnapshotStore.load(a), let newer = SnapshotStore.load(b) else {
                await MainActor.run { self?.comparing = false }
                return
            }
            let d = SnapshotDiffEngine.diff(old: older, new: newer)
            await MainActor.run { self?.diff = d; self?.comparing = false }
        }
    }
}

/// "What grew since last week" — the question people actually have.
public struct SnapshotsView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = SnapshotsModel()

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 288)
            Divider().overlay(Theme.hairline)
            detail.frame(maxWidth: .infinity)
        }
        .background(Theme.ground)
        .onAppear {
            if model.rightID == nil, app.snapshots.count >= 1 {
                model.rightID = app.snapshots.first?.id
                model.leftID = app.snapshots.dropFirst().first?.id
            }
        }
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                RailLabel("Saved scans", trailing: "\(app.snapshots.count)")
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

            if app.snapshots.isEmpty {
                Text("Every completed scan is saved here automatically.")
                    .font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(app.snapshots) { snap in
                            SnapRow(snap: snap,
                                    isOlder: model.leftID == snap.id,
                                    isNewer: model.rightID == snap.id,
                                    onPickOlder: { model.leftID = snap.id; autoCompare() },
                                    onPickNewer: { model.rightID = snap.id; autoCompare() },
                                    onDelete: { app.deleteSnapshot(snap.id) })
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 12)
                }
                .scrollIndicators(.automatic)
            }

            Divider().overlay(Theme.hairline)
            Button {
                if let s = app.store { app.saveSnapshot(store: s, rootPath: app.scanRootPath, label: "Manual") }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "camera").font(.system(size: 11))
                    Text("Snapshot current scan").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(app.store == nil ? Theme.inkFaint : Theme.ink)
                .frame(maxWidth: .infinity).padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            .disabled(app.store == nil)
        }
        .background(Theme.rail)
    }

    private func autoCompare() {
        if let a = model.leftID, let b = model.rightID, a != b { model.compare(a, b) }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if model.comparing {
            VStack(spacing: 10) {
                ProgressView().scaleEffect(0.7)
                Text("Comparing scans…").font(.system(size: 12)).foregroundStyle(Theme.inkSecond)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let d = model.diff {
            diffPane(d)
        } else {
            VStack(spacing: 9) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(Theme.inkFaint)
                Text("Compare two scans").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(app.snapshots.count < 2
                     ? "You need at least two saved scans. Run a scan now, then again later, and this will show exactly what changed."
                     : "Pick an older and a newer scan on the left.")
                    .font(.system(size: 12)).foregroundStyle(Theme.inkSecond)
                    .multilineTextAlignment(.center).frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func diffPane(_ d: SnapshotDiffResult) -> some View {
        let rows = d.changes.filter { model.filter == nil || $0.kind == model.filter }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("Changes").font(.system(size: 25, weight: .bold)).foregroundStyle(Theme.ink)
                    Text(d.netChange >= 0 ? "+\(Fmt.bytes(d.netChange))" : "−\(Fmt.bytes(abs(d.netChange)))")
                        .font(.system(size: 17, weight: .bold).monospacedDigit())
                        .foregroundStyle(d.netChange >= 0 ? Theme.danger : Theme.good)
                    Text("net").font(.system(size: 12)).foregroundStyle(Theme.inkSecond)
                    Spacer()
                    Text("\(Fmt.count(d.comparedPaths)) paths compared in \(String(format: "%.2fs", d.elapsed))")
                        .font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
                }

                HStack(spacing: 8) {
                    FilterChip("All", nil, d.changes.count, model: model)
                    FilterChip("Grew", .grew, d.changes.filter { $0.kind == .grew }.count, model: model)
                    FilterChip("Added", .added, d.changes.filter { $0.kind == .added }.count, model: model)
                    FilterChip("Shrank", .shrank, d.changes.filter { $0.kind == .shrank }.count, model: model)
                    FilterChip("Removed", .removed, d.changes.filter { $0.kind == .removed }.count, model: model)
                    Spacer()
                    Text("↑ \(Fmt.bytes(d.totalGrowth))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.danger)
                    Text("↓ \(Fmt.bytes(d.totalShrink))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.good)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)

            Divider().overlay(Theme.hairline)

            if rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "equal.circle").font(.system(size: 26, weight: .light))
                        .foregroundStyle(Theme.inkFaint)
                    Text("Nothing changed by more than 1 MB.")
                        .font(.system(size: 12)).foregroundStyle(Theme.inkSecond)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rows.prefix(400)) { c in
                            ChangeRow(change: c, maxDelta: rows.first?.magnitude ?? 1)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                }
                .scrollIndicators(.automatic)
            }
        }
    }
}

// MARK: - Pieces

private struct FilterChip: View {
    let label: String
    let kind: ChangeKind?
    let count: Int
    @ObservedObject var model: SnapshotsModel

    init(_ label: String, _ kind: ChangeKind?, _ count: Int, model: SnapshotsModel) {
        self.label = label; self.kind = kind; self.count = count; self.model = model
    }

    var body: some View {
        let active = model.filter == kind
        Button { model.filter = kind } label: {
            HStack(spacing: 5) {
                Text(label).font(.system(size: 11, weight: .medium))
                Text("\(count)").font(.system(size: 10).monospacedDigit()).opacity(0.7)
            }
            .foregroundStyle(active ? Theme.pillText : Theme.inkSecond)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.pill : Theme.rail)
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(active ? Color.clear : Theme.hairline, lineWidth: 1)))
        }
        .buttonStyle(.plain)
    }
}

private struct SnapRow: View {
    let snap: SnapshotMeta
    let isOlder: Bool, isNewer: Bool
    let onPickOlder: () -> Void, onPickNewer: () -> Void, onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "camera").font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
                Text(snap.displayName).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                if !snap.label.isEmpty {
                    Text(snap.label).font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.pillSoft))
                }
                Spacer()
                Text(Fmt.bytes(snap.totalBytes))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.inkSecond)
            }
            HStack(spacing: 6) {
                Text(Fmt.ago(snap.date)).font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
                Text("·").foregroundStyle(Theme.inkFaint)
                Text("\(Fmt.count(snap.fileCount)) files")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.inkFaint)
                Spacer()
                PickButton("Older", active: isOlder, action: onPickOlder)
                PickButton("Newer", active: isNewer, action: onPickNewer)
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(isOlder || isNewer ? Theme.pillSoft.opacity(0.6) : Theme.ground)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline, lineWidth: 1)))
    }
}

private struct PickButton: View {
    let title: String
    let active: Bool
    let action: () -> Void
    init(_ t: String, active: Bool, action: @escaping () -> Void) {
        title = t; self.active = active; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(active ? Theme.pillText : Theme.inkSecond)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(active ? Theme.pill : Theme.pillSoft.opacity(0.7)))
        }
        .buttonStyle(.plain)
    }
}

private struct ChangeRow: View {
    let change: SnapshotChange
    let maxDelta: Int64

    private var tint: Color {
        switch change.kind {
        case .grew, .added: return Theme.danger
        case .shrank, .removed: return Theme.good
        }
    }

    private var badge: String {
        switch change.kind {
        case .grew: return "GREW"
        case .added: return "NEW"
        case .shrank: return "SHRANK"
        case .removed: return "GONE"
        }
    }

    private var deltaBar: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.5))
                    .frame(width: max(2, geo.size.width * CGFloat(change.magnitude) / CGFloat(max(1, maxDelta))))
            }
        }
        .frame(width: 80, height: 7)
    }

    private var deltaText: some View {
        Text("\(change.delta >= 0 ? "+" : "−")\(Fmt.bytes(change.magnitude))")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(tint)
            .frame(width: 78, alignment: .trailing)
    }

    private var rangeText: some View {
        Text("\(Fmt.bytes(change.oldSize)) → \(Fmt.bytes(change.newSize))")
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(Theme.inkFaint)
            .frame(width: 124, alignment: .trailing)
            .fixedSize()
    }

    var body: some View {
        HStack(spacing: 9) {
            Text(badge).font(.system(size: 8, weight: .bold)).tracking(0.4)
                .foregroundStyle(tint)
                .frame(width: 46)
                .padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(0.13)))

            Image(systemName: change.isDir ? "folder" : "doc")
                .font(.system(size: 10)).foregroundStyle(Theme.inkFaint)

            // The name must win the space fight: fixed-width siblings were
            // squeezing it to nothing in a narrow pane.
            VStack(alignment: .leading, spacing: 1) {
                Text(change.name).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                Text(change.path).font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
                    .lineLimit(1).truncationMode(.head)
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            // Drop the least important columns first when the pane is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    deltaBar
                    deltaText
                    rangeText
                }
                HStack(spacing: 9) { deltaBar; deltaText }
                deltaText
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.rail.opacity(0.5)))
    }
}
