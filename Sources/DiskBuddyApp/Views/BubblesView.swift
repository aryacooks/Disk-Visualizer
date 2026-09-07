import SwiftUI
import ScannerCore

/// "Nested bubbles, one per folder."
public struct BubblesView: View {
    @EnvironmentObject var app: AppState
    @State private var cache = LayoutCache<[Bubble]>()
    @State private var hoverID: Int? = nil

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = min(geo.size.width, geo.size.height) / 2 - 10
            let bubbles = cache.get(LayoutKey(nodes: app.store?.count ?? 0,
                                              root: app.currentFolderIndex,
                                              w: Int(geo.size.width),
                                              h: Int(geo.size.height))) {
                guard let store = app.store, radius > 20 else { return [] }
                return BubbleLayout.build(store: store, root: app.currentFolderIndex,
                                          center: center, radius: radius)
            }

            ZStack {
                Canvas { ctx, _ in
                    guard let store = app.store else { return }
                    for b in bubbles {
                        let rect = CGRect(x: b.center.x - b.radius, y: b.center.y - b.radius,
                                          width: b.radius * 2, height: b.radius * 2)
                        let path = Path(ellipseIn: rect)
                        if b.depth == 0 {
                            ctx.fill(path, with: .color(Theme.rail))
                            ctx.stroke(path, with: .color(Theme.hairline), lineWidth: 1)
                        } else {
                            ctx.fill(path, with: .color(SharedPaint.color(store, b.id,
                                                                         depth: b.depth,
                                                                         mode: app.sizeMode,
                                                                         rootIndex: app.currentFolderIndex)
                                                         .opacity(b.isLeaf ? 0.9 : 0.42)))
                            ctx.stroke(path, with: .color(Theme.ground.opacity(0.6)), lineWidth: 0.8)
                        }
                        if b.id == hoverID {
                            ctx.stroke(path, with: .color(Theme.ink), lineWidth: 1.8)
                        }
                        // Container labels ride on top; leaf labels sit in the middle.
                        if b.radius > 26 {
                            let y = b.isLeaf ? b.center.y : b.center.y - b.radius + 11
                            ctx.draw(Text(store.name(b.id))
                                        .font(.system(size: min(12, max(8, b.radius / 4.5)),
                                                      weight: .medium))
                                        .foregroundStyle(Theme.ink.opacity(0.85)),
                                     at: CGPoint(x: b.center.x, y: y), anchor: .center)
                        }
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hoverID = hit(bubbles, p)
                    case .ended: hoverID = nil
                    }
                }
                .onTapGesture { p in
                    if let id = hit(bubbles, p) { app.selectNode(id) }
                }

                if let h = hoverID, let store = app.store {
                    VStack { Spacer(); HStack { HoverChip(store: store, index: h); Spacer() } }
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }

    /// Smallest containing circle wins, so nested bubbles stay reachable.
    private func hit(_ bubbles: [Bubble], _ p: CGPoint) -> Int? {
        var best: Bubble? = nil
        for b in bubbles {
            let dx = p.x - b.center.x, dy = p.y - b.center.y
            if (dx * dx + dy * dy).squareRoot() <= b.radius {
                if best == nil || b.radius < best!.radius { best = b }
            }
        }
        return best?.id
    }
}
