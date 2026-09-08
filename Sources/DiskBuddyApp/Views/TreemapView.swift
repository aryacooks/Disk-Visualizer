import SwiftUI
import ScannerCore

public struct TreemapView: View {
    @EnvironmentObject var app: AppState
    @State private var cache = LayoutCache<[TreeCell]>()
    @State private var hoverID: Int? = nil

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let cells = cache.get(LayoutKey(nodes: app.store?.count ?? 0,
                                            root: app.currentFolderIndex,
                                            w: Int(geo.size.width),
                                            h: Int(geo.size.height))) {
                guard let store = app.store, geo.size.width > 10, geo.size.height > 10 else { return [] }
                return TreemapLayout.build(store: store,
                                           root: app.currentFolderIndex,
                                           rect: CGRect(origin: .zero, size: geo.size))
            }

            ZStack(alignment: .bottomLeading) {
                Canvas { ctx, size in
                    guard let store = app.store else { return }
                    for cell in cells {
                        let name = store.name(cell.id)
                        let path = Path(roundedRect: cell.rect.insetBy(dx: 0.5, dy: 0.5),
                                        cornerRadius: cell.rect.width > 12 ? 3 : 1)
                        ctx.fill(path, with: .color(
                            SharedPaint.color(store, cell.id, depth: cell.depth,
                                              mode: app.sizeMode,
                                              rootIndex: app.currentFolderIndex)
                                .opacity(cell.isLeaf ? 0.95 : 0.5)))
                        if cell.rect.width > 3 && cell.rect.height > 3 {
                            ctx.stroke(path, with: .color(Theme.ground.opacity(0.55)), lineWidth: 0.6)
                        }
                        if cell.id == hoverID {
                            ctx.stroke(path, with: .color(Theme.ink), lineWidth: 1.6)
                        }
                        // Labels only where they fit — this is what keeps it legible.
                        if cell.rect.width > 54 && cell.rect.height > 15 {
                            let text = Text(name)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.ink.opacity(0.85))
                            ctx.draw(text, at: CGPoint(x: cell.rect.minX + 5, y: cell.rect.minY + 8),
                                     anchor: .leading)
                        }
                    }
                    _ = size
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hoverID = hit(cells, p)
                    case .ended: hoverID = nil
                    }
                }
                .onTapGesture { p in
                    if let id = hit(cells, p) {
                        app.activate(nodeIndex: id, anchor: p.unitAnchor(in: geo.size))
                    }
                }

                if let h = hoverID, let store = app.store {
                    HoverChip(store: store, index: h)
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }

    /// Deepest cell wins, so a nested file beats its parent folder.
    private func hit(_ cells: [TreeCell], _ p: CGPoint) -> Int? {
        var best: TreeCell? = nil
        for c in cells where c.rect.contains(p) {
            if best == nil || c.depth > best!.depth { best = c }
        }
        return best?.id
    }

}

struct HoverChip: View {
    let store: NodeStore
    let index: Int

    var body: some View {
        let isDir = store.isDir(index)
        let size = isDir ? store.subtree[index] : store.allocated[index]
        let rootTotal = max(Int64(1), store.subtree[0])
        return HStack(spacing: 8) {
            Image(systemName: isDir ? "folder" : "doc")
                .font(.system(size: 11)).foregroundStyle(Theme.inkSecond)
            Text(store.name(index))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Text(Fmt.bytes(size))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.ink)
            Text(Fmt.pct(Double(size) / Double(rootTotal) * 100))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.inkFaint)
            if isDir {
                Text("\(Fmt.count(Int(store.subtreeFiles[index]))) files")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.inkSecond)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.pillSoft))
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Theme.rail)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline, lineWidth: 1))
        )
    }
}
