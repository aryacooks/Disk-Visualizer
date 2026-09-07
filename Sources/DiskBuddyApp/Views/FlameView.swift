import SwiftUI
import ScannerCore

/// "Depth top to bottom, size left to right."
public struct FlameView: View {
    @EnvironmentObject var app: AppState
    @State private var cache = LayoutCache<[FlameCell]>()
    @State private var hoverID: Int? = nil

    private let rowH: CGFloat = 27

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let cells = cache.get(LayoutKey(nodes: app.store?.count ?? 0,
                                            root: app.currentFolderIndex,
                                            w: Int(geo.size.width))) {
                guard let store = app.store, geo.size.width > 10 else { return [] }
                return FlameLayout.build(store: store, root: app.currentFolderIndex,
                                         width: geo.size.width, rowHeight: rowH)
            }
            let depth = (cells.map { $0.depth }.max() ?? 0) + 1

            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        guard let store = app.store else { return }
                        for cell in cells {
                            let r = CGRect(x: cell.rect.minX, y: cell.rect.minY,
                                           width: max(0.5, cell.rect.width - 1),
                                           height: cell.rect.height - 1.5)
                            let path = Path(roundedRect: r, cornerRadius: r.width > 8 ? 3 : 0.5)
                            ctx.fill(path, with: .color(SharedPaint.color(store, cell.id,
                                                                         depth: cell.depth,
                                                                         mode: app.sizeMode,
                                                                         rootIndex: app.currentFolderIndex)))
                            if cell.id == hoverID {
                                ctx.stroke(path, with: .color(Theme.ink), lineWidth: 1.5)
                            }
                            if r.width > 46 {
                                ctx.draw(Text(store.name(cell.id))
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(Theme.ink.opacity(0.88)),
                                         at: CGPoint(x: r.minX + 6, y: r.midY), anchor: .leading)
                            }
                        }
                    }
                    .frame(height: CGFloat(depth) * rowH)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            hoverID = cells.last { $0.rect.contains(p) }?.id
                        case .ended: hoverID = nil
                        }
                    }
                    .onTapGesture { p in
                        if let id = cells.last(where: { $0.rect.contains(p) })?.id {
                            app.selectNode(id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .overlay(alignment: .bottomLeading) {
                if let h = hoverID, let store = app.store {
                    HoverChip(store: store, index: h).padding(10).allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }
}
