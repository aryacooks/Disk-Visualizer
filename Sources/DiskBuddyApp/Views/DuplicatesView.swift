import SwiftUI
import AppKit
import ScannerCore

@MainActor
final class DuplicatesModel: ObservableObject {
    @Published var result: DuplicateResult?
    @Published var running = false
    @Published var progress = DuplicateProgress()
    @Published var expanded: Set<String> = []
    @Published var selected: Set<Int> = []          // node indices staged for Trash
    @Published var outcome: String?
    @Published var search = ""

    private var task: Task<Void, Never>?
    /// Set when the user cancels. The finder does synchronous work inside
    /// `concurrentPerform`, which `Task.cancel()` cannot interrupt on its own —
    /// without this flag a cancelled run keeps hashing in the background and
    /// a second run can start on top of it.
    private let cancelFlag = CancelFlag()
    /// Guards against a stale run publishing over a newer one.
    private var generation = 0

    func run(store: NodeStore) {
        guard !running else { return }
        cancelFlag.reset()
        generation += 1
        let myGeneration = generation
        running = true
        outcome = nil
        selected = []
        progress = DuplicateProgress(stage: "Grouping by size")

        let flag = cancelFlag
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let r = DuplicateFinder.find(store: store,
                                         isCancelled: { flag.isSet }) { p in
                Task { @MainActor in
                    guard let self, self.generation == myGeneration else { return }
                    self.progress = p
                }
            }
            await MainActor.run {
                guard let self, self.generation == myGeneration else { return }
                if !flag.isSet { self.result = r }
                self.running = false
            }
        }
    }

    func cancel() {
        cancelFlag.set()
        task?.cancel()
        running = false
    }

    var groups: [DuplicateGroup] {
        guard let g = result?.groups else { return [] }
        guard !search.isEmpty else { return g }
        let q = search.lowercased()
        return g.filter { $0.name.lowercased().contains(q) }
    }

    /// Everything that is neither the keeper nor a clone — i.e. exactly the
    /// copies whose removal actually returns bytes to the disk.
    func selectAllRedundant() {
        var s = Set<Int>()
        for g in groups {
            for (i, f) in g.files.enumerated() where i != g.keepIndex && !f.isClone {
                s.insert(f.nodeIndex)
            }
        }
        selected = s
    }

    func selectedBytes(_ all: [DuplicateGroup]) -> Int64 {
        var total: Int64 = 0
        for g in all {
            for f in g.files where selected.contains(f.nodeIndex) && !f.isClone {
                total += f.size
            }
        }
        return total
    }

    private static let denyPrefixes = ["/System", "/bin", "/sbin", "/Library/Apple", "/usr/bin", "/usr/lib"]

    func canRemove(_ path: String) -> Bool {
        !Self.denyPrefixes.contains(where: { path.hasPrefix($0) })
    }

    /// Moves every staged copy to the Trash. Refuses to empty a group: if all
    /// copies somehow got ticked, the keeper is put back first.
    func trashSelected(_ all: [DuplicateGroup]) {
        var freed: Int64 = 0
        var moved = 0
        var skipped: [String] = []

        for g in all {
            let staged = g.files.filter { selected.contains($0.nodeIndex) }
            guard !staged.isEmpty else { continue }
            // Never let a group lose its last copy.
            let survivors = g.files.filter { !selected.contains($0.nodeIndex) }
            var toRemove = staged
            if survivors.isEmpty {
                let keeper = g.files[g.keepIndex]
                toRemove.removeAll { $0.nodeIndex == keeper.nodeIndex }
                skipped.append("\(keeper.name) (kept — last copy in its group)")
            }

            for f in toRemove {
                guard canRemove(f.path) else { skipped.append("\(f.name) (protected)"); continue }
                var sb = stat()
                guard lstat(f.path, &sb) == 0 else { skipped.append("\(f.name) (gone)"); continue }
                // Re-verify size before acting; the file may have changed since the scan.
                guard sb.st_size == f.size else { skipped.append("\(f.name) (changed since scan)"); continue }
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: f.path), resultingItemURL: nil)
                    freed += f.isClone ? 0 : f.size
                    moved += 1
                } catch {
                    skipped.append("\(f.name) (\(error.localizedDescription))")
                }
            }
        }

        var msg = "Moved \(moved) file\(moved == 1 ? "" : "s") to the Trash, freeing \(Fmt.bytes(freed))."
        if !skipped.isEmpty {
            msg += " Skipped \(skipped.count): " + skipped.prefix(3).joined(separator: "; ")
        }
        msg += " Nothing was permanently deleted."
        outcome = msg
        selected = []
    }
}

/// Thread-safe cancellation flag shared with the finder's worker threads.
final class CancelFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
    func reset() { lock.lock(); flag = false; lock.unlock() }
}

/// Byte-identical files, found with a size → head/tail → full-hash funnel.
public struct DuplicatesView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = DuplicatesModel()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            if app.store == nil {
                empty("Scan a folder first", "Duplicates are found within the folder you scanned.")
            } else if model.running {
                runningPane
            } else if let r = model.result {
                results(r)
            } else {
                idlePane
            }
        }
        .background(Theme.ground)
    }

    // MARK: States

    private func empty(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "doc.on.doc").font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.inkFaint)
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(sub).font(.system(size: 12)).foregroundStyle(Theme.inkSecond)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var idlePane: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.on.doc").font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.inkFaint)
            Text("Find duplicate files").font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.ink)
            Text("Compared by content, not by name. Files are grouped by exact size, then by a hash of their first and last 4 KB, and only the survivors are hashed in full — so this reads a fraction of your disk instead of all of it.")
                .font(.system(size: 12)).foregroundStyle(Theme.inkSecond)
                .multilineTextAlignment(.center).frame(maxWidth: 470)
                .fixedSize(horizontal: false, vertical: true)
            Text("APFS clones are detected and excluded from the reclaimable total — they share their blocks, so deleting one frees nothing.")
                .font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let s = app.store { model.run(store: s) }
            } label: {
                Text("Find Duplicates").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.pillText)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.pill))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var runningPane: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(0.8)
            Text(verbatim: model.progress.stage).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            if model.progress.total > 0 {
                ProgressView(value: Double(model.progress.done),
                             total: Double(max(1, model.progress.total)))
                    .frame(width: 300)
                Text("\(Fmt.count(model.progress.done)) of \(Fmt.count(model.progress.total)) files")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.inkSecond)
            }
            if model.progress.bytesHashed > 0 {
                Text("\(Fmt.bytes(model.progress.bytesHashed)) hashed")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.inkFaint)
            }
            Button("Cancel") { model.cancel() }
                .buttonStyle(.plain).font(.system(size: 12))
                .foregroundStyle(Theme.inkSecond).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Results

    private func results(_ r: DuplicateResult) -> some View {
        let all = model.groups
        return VStack(spacing: 0) {
            summaryBar(r)
            Divider().overlay(Theme.hairline)

            if let msg = model.outcome {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                    Text(msg).font(.system(size: 11)).foregroundStyle(Theme.ink)
                    Spacer()
                    Button { if let s = app.store { model.run(store: s) } } label: {
                        Text("Rescan").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.inkSecond)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22).padding(.vertical, 8)
                .background(Theme.good.opacity(0.08))
            }

            if all.isEmpty {
                empty("No duplicates found", "Every file in this scan is unique.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(all.prefix(400)) { group in
                            GroupRow(group: group, model: model)
                        }
                        if all.count > 400 {
                            Text("Showing the 400 groups with the most to reclaim, of \(Fmt.count(all.count)).")
                                .font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                                .padding(.vertical, 12)
                        }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 12)
                }
                .scrollIndicators(.automatic)

                Divider().overlay(Theme.hairline)
                actionBar(all)
            }
        }
    }

    private func summaryBar(_ r: DuplicateResult) -> some View {
        let clones = r.groups.reduce(0) { $0 + $1.cloneCount }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Duplicates").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.ink)
                Text(Fmt.bytes(r.totalReclaimable))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.gauge)
                Text("reclaimable").font(.system(size: 12)).foregroundStyle(Theme.inkSecond)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                        .foregroundStyle(Theme.inkFaint)
                    TextField("Filter by name...", text: $model.search)
                        .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 160)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.rail)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1)))
            }

            HStack(spacing: 18) {
                Stat("\(Fmt.count(r.groups.count))", "groups")
                Stat("\(Fmt.count(r.totalExtraCopies))", "extra copies")
                Stat("\(Fmt.count(clones))", "APFS clones", tint: Theme.inkFaint,
                     help: "Byte-identical but block-sharing. Deleting these frees nothing, so they are excluded from the reclaimable figure.")
                Stat(Fmt.bytes(r.bytesHashed), "hashed")
                Stat(String(format: "%.1fs", r.elapsed), "elapsed")
                Spacer()
                Text("\(Fmt.count(r.candidatesBySize)) same-size → \(Fmt.count(r.survivedPrefixHash)) matched head/tail → \(Fmt.count(r.groups.count)) confirmed")
                    .font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
            }
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 12)
    }

    private func actionBar(_ all: [DuplicateGroup]) -> some View {
        let bytes = model.selectedBytes(all)
        return HStack(spacing: 10) {
            Button { model.selectAllRedundant() } label: {
                Text("Select all redundant copies")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Ticks every copy that is neither the suggested keeper nor an APFS clone")

            if !model.selected.isEmpty {
                Button { model.selected = [] } label: {
                    Text("Clear").font(.system(size: 12)).foregroundStyle(Theme.inkSecond)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(model.selected.count) selected · \(Fmt.bytes(bytes))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Text("Moved to the Trash, never deleted outright.")
                    .font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
            }

            Button { model.trashSelected(all) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash").font(.system(size: 11))
                    Text("Move to Trash").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(model.selected.isEmpty ? Theme.inkFaint : Theme.danger))
            }
            .buttonStyle(.plain)
            .disabled(model.selected.isEmpty)
        }
        .padding(.horizontal, 22).padding(.vertical, 11)
        .background(Theme.rail)
    }
}

// MARK: - Rows

private struct Stat: View {
    let value: String, label: String
    var tint: Color = Theme.ink
    var help: String? = nil
    init(_ value: String, _ label: String, tint: Color = Theme.ink, help: String? = nil) {
        self.value = value; self.label = label; self.tint = tint; self.help = help
    }
    var body: some View {
        HStack(spacing: 4) {
            Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
        }
        .help(help ?? "")
    }
}

private struct GroupRow: View {
    let group: DuplicateGroup
    @ObservedObject var model: DuplicatesModel

    private var isOpen: Bool { model.expanded.contains(group.id) }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if isOpen { model.expanded.remove(group.id) } else { model.expanded.insert(group.id) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.inkFaint)
                        .frame(width: 10)
                    Image(systemName: "doc.on.doc").font(.system(size: 12))
                        .foregroundStyle(Theme.inkSecond)
                    Text(group.name).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                    Text("\(group.files.count) copies")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.inkSecond)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.pillSoft))
                    if group.cloneCount > 0 {
                        Text("\(group.cloneCount) clone\(group.cloneCount == 1 ? "" : "s")")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.gauge)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.gauge.opacity(0.14)))
                            .help("Share blocks with another copy — removing them frees nothing")
                    }
                    Spacer(minLength: 6)
                    Text(Fmt.bytes(group.size)).font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.inkFaint)
                    Text(Fmt.bytes(group.reclaimable))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(group.reclaimable > 0 ? Theme.gauge : Theme.inkFaint)
                        .frame(width: 76, alignment: .trailing)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.rail))
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(spacing: 2) {
                    ForEach(Array(group.files.enumerated()), id: \.element.nodeIndex) { i, file in
                        CopyRow(file: file, isKeeper: i == group.keepIndex, model: model)
                    }
                }
                .padding(.top, 3).padding(.leading, 22)
            }
        }
    }
}

private struct CopyRow: View {
    let file: DuplicateFile
    let isKeeper: Bool
    @ObservedObject var model: DuplicatesModel

    var body: some View {
        HStack(spacing: 9) {
            Toggle("", isOn: Binding(
                get: { model.selected.contains(file.nodeIndex) },
                set: { on in
                    if on { model.selected.insert(file.nodeIndex) }
                    else { model.selected.remove(file.nodeIndex) }
                }))
                .labelsHidden()

            if isKeeper {
                Text("KEEP").font(.system(size: 8, weight: .bold)).tracking(0.5)
                    .foregroundStyle(Theme.good)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.good.opacity(0.15)))
                    .help("Suggested original: shallower path, older, not in Downloads or a cache")
            } else if file.isClone {
                Text("CLONE").font(.system(size: 8, weight: .bold)).tracking(0.5)
                    .foregroundStyle(Theme.gauge)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.gauge.opacity(0.15)))
                    .help("Shares blocks with another copy — deleting it frees nothing")
            }

            Text(file.path)
                .font(.system(size: 10))
                .foregroundStyle(isKeeper ? Theme.ink : Theme.inkSecond)
                .lineLimit(1).truncationMode(.head)

            Spacer(minLength: 4)
            Text(Fmt.ago(file.mtime)).font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            } label: {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 10))
                    .foregroundStyle(Theme.inkFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isKeeper ? Theme.good.opacity(0.05) : Color.clear))
    }
}
