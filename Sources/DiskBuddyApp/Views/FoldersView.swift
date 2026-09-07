import SwiftUI
import ScannerCore

/// The default view: a grid of folder-shaped pastel cards, biggest first.
public struct FoldersView: View {
    @EnvironmentObject var app: AppState

    public init() {}

    private var children: [Int] {
        guard let store = app.store else { return [] }
        // "Browse folder by folder" — files live in Top Sizes and the Treemap.
        var kids = store.sortedChildren(of: app.currentFolderIndex, directoriesOnly: true)
        if !app.filterText.isEmpty {
            let q = app.filterText.lowercased()
            kids = kids.filter { store.name($0).lowercased().contains(q) }
        }
        return kids
    }

    public var body: some View {
        let kids = children
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("Folders")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("\(kids.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.inkSecond)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pillSoft.opacity(0.8)))
                }

                if kids.isEmpty {
                    Text(app.filterText.isEmpty ? "No sub-folders here — switch to Top Sizes to see the files." : "No folder matches “\(app.filterText)”.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkFaint)
                        .padding(.top, 20)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 230, maximum: 400), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(kids, id: \.self) { idx in
                            FolderCard(index: idx)
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .scrollIndicators(.automatic)
    }
}

private struct FolderCard: View {
    @EnvironmentObject var app: AppState
    let index: Int
    @State private var hovering = false

    var body: some View {
        guard let store = app.store else { return AnyView(EmptyView()) }
        let name = store.name(index)
        let isDir = store.isDir(index)
        let size = isDir ? store.subtree[index] : store.allocated[index]
        let items = isDir ? Int(store.subtreeFiles[index]) : 0
        let selected = app.selectedNodeIndex == index

        return AnyView(
            Button {
                app.selectNode(index)
            } label: {
                ZStack(alignment: .bottomLeading) {
                    if isDir {
                        FolderShape().fill(Theme.cardGradient(name))
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(Theme.cardGradient(name))
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Spacer(minLength: 0)
                        Text(name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        HStack(spacing: 7) {
                            if isDir {
                                CategoryDots(store: store, index: index)
                                Text("\(Fmt.count(items)) items")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(Theme.inkSecond)
                            } else {
                                Text(fileKind(name))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.inkSecond)
                            }
                            Spacer(minLength: 4)
                            Text(Fmt.bytes(size))
                                .font(.system(size: 14, weight: .bold).monospacedDigit())
                                .foregroundStyle(Theme.ink)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 13)
                    .padding(.top, 28)
                }
                .frame(height: 132)
                .overlay(
                    Group {
                        if isDir {
                            FolderShape().stroke(selected ? Theme.ink : Color.clear, lineWidth: 2)
                        } else {
                            RoundedRectangle(cornerRadius: 12).stroke(selected ? Theme.ink : Color.clear, lineWidth: 2)
                        }
                    }
                )
                .shadow(color: .black.opacity(hovering ? 0.10 : 0.04),
                        radius: hovering ? 7 : 3, y: hovering ? 3 : 1)
                .scaleEffect(hovering ? 1.008 : 1.0)
                .animation(.easeOut(duration: 0.14), value: hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if isDir { app.drillInto(nodeIndex: index) }
            })
            .help(isDir ? "Double-click to open \(name)" : name)
        )
    }

    private func fileKind(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "File" : ext.uppercased()
    }
}

/// The three little coloured dots on each card — the dominant file types inside.
private struct CategoryDots: View {
    let store: NodeStore
    let index: Int

    var body: some View {
        HStack(spacing: -3) {
            ForEach(Array(dominant.enumerated()), id: \.offset) { _, c in
                Circle()
                    .fill(Theme.categoryColor(c))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Theme.ground.opacity(0.8), lineWidth: 1.2))
            }
        }
    }

    /// Sample the immediate children rather than the whole subtree — this runs
    /// per visible card, so it must stay O(children), not O(subtree).
    private var dominant: [FileTypeCategory] {
        guard let range = store.children(of: index) else { return [] }
        var totals: [FileTypeCategory: Int64] = [:]
        for k in range.prefix(400) where !store.isDir(k) {
            let ext = (store.name(k) as NSString).pathExtension
            totals[FileTypeCategory.classify(extension: ext), default: 0] += store.allocated[k]
        }
        if totals.isEmpty { return [.other] }
        return totals.sorted { $0.value > $1.value }.prefix(3).map { $0.key }
    }
}
