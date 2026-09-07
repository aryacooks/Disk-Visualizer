import SwiftUI
import ScannerCore

/// "The biggest items, ranked" — three scopes, proportional bars.
public struct TopSizesView: View {
    @EnvironmentObject var app: AppState

    public init() {}

    private var rows: [Int] {
        guard let store = app.store else { return [] }
        var list = store.topNodes(scope: app.topSizesScope,
                                  folderIndex: app.currentFolderIndex,
                                  limit: 200)
        if !app.filterText.isEmpty {
            let q = app.filterText.lowercased()
            list = list.filter { store.name($0).lowercased().contains(q) }
        }
        return list
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                ForEach(TopSizesScope.allCases) { scope in
                    let active = app.topSizesScope == scope
                    Button { app.topSizesScope = scope } label: {
                        Text(scope.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(active ? Theme.pillText : Theme.inkSecond)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(active ? Theme.pill : .clear))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("\(rows.count) shown")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.inkFaint)
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(Theme.rail)
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.hairline, lineWidth: 1))
            )
            .padding(.horizontal, 22)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element) { rank, idx in
                        TopSizeRow(rank: rank + 1, index: idx, maxSize: maxSize)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.automatic)
        }
    }

    private var maxSize: Int64 {
        guard let store = app.store, let first = rows.first else { return 1 }
        return max(1, store.isDir(first) ? store.subtree[first] : store.allocated[first])
    }
}

private struct TopSizeRow: View {
    @EnvironmentObject var app: AppState
    let rank: Int
    let index: Int
    let maxSize: Int64
    @State private var hovering = false

    var body: some View {
        guard let store = app.store else { return AnyView(EmptyView()) }
        let name = store.name(index)
        let isDir = store.isDir(index)
        let size = isDir ? store.subtree[index] : store.allocated[index]
        let files = isDir ? Int(store.subtreeFiles[index]) : 1
        let rootTotal = max(Int64(1), store.subtree[0])
        let selected = app.selectedNodeIndex == index

        return AnyView(
            Button { app.selectNode(index) } label: {
                HStack(spacing: 10) {
                    Text("\(rank)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.inkFaint)
                        .frame(width: 22, alignment: .trailing)

                    Image(systemName: isDir ? "folder" : "doc")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkSecond)
                        .frame(width: 14)

                    // Proportional bar with the label sitting on top of it
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 5).fill(Theme.track.opacity(0.5))
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Theme.cardColor(name))
                                .frame(width: max(6, geo.size.width * CGFloat(size) / CGFloat(maxSize)))
                            Text(name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1).truncationMode(.middle)
                                .padding(.leading, 9)
                                .padding(.trailing, 9)
                        }
                    }
                    .frame(height: 26)

                    Text("\(Fmt.count(files)) files")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.inkFaint)
                        .frame(width: 84, alignment: .trailing)
                    Text(Fmt.pct(Double(size) / Double(rootTotal) * 100))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.inkFaint)
                        .frame(width: 48, alignment: .trailing)
                    Text(Fmt.bytes(size))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                        .frame(width: 78, alignment: .trailing)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected ? Theme.pillSoft.opacity(0.9)
                                       : (hovering ? Theme.pillSoft.opacity(0.4) : .clear))
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if isDir { app.drillInto(nodeIndex: index) }
            })
        )
    }
}
