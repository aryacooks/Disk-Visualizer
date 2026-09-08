import SwiftUI
import ScannerCore

public struct InspectorView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var cleanup: CleanupQueue

    public init() {}

    /// Falls back to the folder being browsed when nothing is selected,
    /// so the panel is never empty.
    private var target: Int? {
        if let s = app.selectedNodeIndex { return s }
        return app.store == nil ? nil : app.currentFolderIndex
    }

    public var body: some View {
        ScrollView {
            if let store = app.store, let i = target {
                VStack(alignment: .leading, spacing: 14) {
                    headerBlock(store, i)
                    detailsBox(store, i)
                    largestInsideBox(store, i)
                    actionGrid(i)
                    cleanupButton(store, i)
                    Spacer(minLength: 8)
                }
                .padding(14)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Theme.inkFaint)
                    Text("Select an item").font(.system(size: 12)).foregroundStyle(Theme.inkFaint)
                }
                .frame(maxWidth: .infinity).padding(.top, 60)
            }
        }
        .scrollIndicators(.never)
        .background(Theme.rail)
    }

    // MARK: Header

    private func headerBlock(_ store: NodeStore, _ i: Int) -> some View {
        let isDir = store.isDir(i)
        let name = i == 0 ? rootLabel : store.name(i)
        let size = isDir ? store.subtree[i] : store.allocated[i]
        let rootTotal = max(1, store.subtree[0])

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(isDir ? Theme.cardGradient(name)
                                    : LinearGradient(colors: [Theme.pillSoft, Theme.pillSoft.opacity(0.5)],
                                                     startPoint: .top, endPoint: .bottom))
                    Image(systemName: isDir ? "folder.fill" : "doc.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.inkSecond)
                }
                .frame(width: 46, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: isDir ? "folder" : "doc")
                            .font(.system(size: 9))
                        Text(isDir ? "Folder" : "File")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Theme.inkSecond)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.pillSoft.opacity(0.7)))
                }
                Spacer(minLength: 0)
            }

            Text(store.path(i))
                .font(.system(size: 10))
                .foregroundStyle(Theme.inkFaint)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(Fmt.bytes(size))
                    .font(.system(size: 26, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Text("\(Fmt.pct(Double(size) / Double(rootTotal) * 100)) of scan")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkFaint)
            }
        }
    }

    private var rootLabel: String {
        AppState.friendlyRootName(app.scanRootPath)
    }

    // MARK: Details

    private func detailsBox(_ store: NodeStore, _ i: Int) -> some View {
        let isDir = store.isDir(i)
        let onDisk = isDir ? store.subtree[i] : store.allocated[i]
        let logical = isDir ? store.subtreeLogical[i] : store.logical[i]
        let compressed = isDir ? store.subtreeCompressed[i] : max(0, store.logical[i] - store.allocated[i])
        let showCompressed = compressed > 0 && (isDir || store.isCompressed(i))
        let sparse = !isDir && store.isSparse(i)

        return InsetBox(title: "Details") {
            VStack(spacing: 7) {
                DetailRow("Size on disk", Fmt.bytes(onDisk), bold: true)
                DetailRow("Logical size", Fmt.bytes(logical))
                if showCompressed {
                    DetailRow("Compressed by", Fmt.bytes(compressed), tint: Theme.good)
                }
                if sparse {
                    DetailRow("Sparse file", Fmt.bytes(max(0, logical - onDisk)) + " unwritten", tint: Theme.inkSecond)
                }
                if isDir {
                    DetailRow("Files", Fmt.count(Int(store.subtreeFiles[i])))
                    DetailRow("Folders", Fmt.count(max(0, Int(store.subtreeDirs[i]) - 1)))
                }
                if i != 0 { DetailRow("Of parent", Fmt.pct(store.percentOfParent(i))) }
                DetailRow("Modified", Fmt.ago(store.modifiedDate(i)))
                DetailRow("Created", Fmt.ago(store.creationDate(i)))
            }
        }
    }

    // MARK: Largest inside

    @ViewBuilder
    private func largestInsideBox(_ store: NodeStore, _ i: Int) -> some View {
        let kids = store.largestChildren(of: i, limit: 10)
        if !kids.isEmpty {
            let total = max(Int64(1), store.subtree[i])
            let childCount = Int(store.childCount[i])
            InsetBox(title: "Largest Inside", trailing: "\(childCount) items") {
                VStack(spacing: 8) {
                    ForEach(kids, id: \.self) { k in
                        let sz = store.isDir(k) ? store.subtree[k] : store.allocated[k]
                        let name = store.name(k)
                        Button { app.selectNode(k) } label: {
                            VStack(spacing: 4) {
                                HStack(spacing: 6) {
                                    Circle().fill(Theme.markColor(name)).frame(width: 6, height: 6)
                                    Text(name)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    Text(Fmt.bytes(sz))
                                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                                        .foregroundStyle(Theme.inkSecond)
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Theme.track).frame(height: 2.5)
                                        Capsule().fill(Theme.markColor(name))
                                            .frame(width: max(2, geo.size.width * CGFloat(sz) / CGFloat(total)),
                                                   height: 2.5)
                                    }
                                }
                                .frame(height: 3)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func actionGrid(_ i: Int) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SmallRailButton(icon: "arrow.up.forward.square", title: "Reveal") { app.revealInFinder(nodeIndex: i) }
                SmallRailButton(icon: "eye", title: "Quick Look") { app.quickLook(nodeIndex: i) }
            }
            HStack(spacing: 8) {
                SmallRailButton(icon: "scope", title: "Focus") {
                    if app.store?.isDir(i) == true { app.activate(nodeIndex: i, anchor: .center) }
                }
                SmallRailButton(icon: "doc.on.clipboard", title: "Copy Path") { app.copyPath(nodeIndex: i) }
            }
        }
    }

    @ViewBuilder
    private func cleanupButton(_ store: NodeStore, _ i: Int) -> some View {
        let path = store.path(i)
        let staged = cleanup.contains(path)
        let protected = CleanupQueue.isProtected(path)

        Button {
            if staged { cleanup.remove(path) }
            else { _ = cleanup.add(store: store, nodeIndex: i, origin: "Explore") }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: staged ? "checkmark.circle.fill" : "trash")
                    .font(.system(size: 12))
                Text(staged ? "Staged for cleanup" : "Add to Cleanup")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(protected ? Theme.inkFaint : Theme.pillText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(protected ? Theme.pillSoft : (staged ? Theme.good : Theme.pill)))
        }
        .buttonStyle(.plain)
        .disabled(protected)
        .help(protected
              ? "This location is protected and can never be staged."
              : "Staging never deletes. Review the queue at the bottom of the window first.")
    }

}

// MARK: - Pieces

struct InsetBox<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RailLabel(title, trailing: trailing)
            content
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.inset)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
        )
    }
}

private struct DetailRow: View {
    let label: String, value: String
    var bold: Bool = false
    var tint: Color = Theme.ink

    init(_ label: String, _ value: String, bold: Bool = false, tint: Color = Theme.ink) {
        self.label = label; self.value = value; self.bold = bold; self.tint = tint
    }

    var body: some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.inkSecond)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: bold ? .semibold : .medium).monospacedDigit())
                .foregroundStyle(tint)
        }
    }
}
