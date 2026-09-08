import SwiftUI
import ScannerCore

/// "Branches from the root, sized by weight."
public struct MindMapView: View {
    @EnvironmentObject var app: AppState
    @State private var cache = LayoutCache<[MindNode]>()
    @State private var hoverID: Int? = nil

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let maxR = min(geo.size.width, geo.size.height) / 2 - 34
            let nodes = cache.get(LayoutKey(nodes: app.store?.count ?? 0,
                                            root: app.currentFolderIndex,
                                            w: Int(geo.size.width),
                                            h: Int(geo.size.height))) {
                guard let store = app.store, maxR > 40 else { return [] }
                return MindMapLayout.build(store: store, root: app.currentFolderIndex,
                                           center: center, maxRadius: maxR)
            }

            ZStack {
                Canvas { ctx, _ in
                    guard let store = app.store else { return }

                    // Edges first, so dots sit on top of them.
                    for n in nodes {
                        var p = Path()
                        p.move(to: n.parentCenter)
                        // Bow the link outward along the branch's own angle.
                        let mx = (n.parentCenter.x + n.center.x) / 2
                        let my = (n.parentCenter.y + n.center.y) / 2
                        let bow: CGFloat = 14
                        let ctrl = CGPoint(x: mx + cos(n.angle - .pi / 2) * bow * 0.4,
                                           y: my + sin(n.angle - .pi / 2) * bow * 0.4)
                        p.addQuadCurve(to: n.center, control: ctrl)
                        ctx.stroke(p, with: .color(SharedPaint.color(store, n.id,
                                                                    depth: n.depth,
                                                                    mode: app.sizeMode,
                                                                    rootIndex: app.currentFolderIndex)
                                                    .opacity(0.55)),
                                   lineWidth: max(0.6, 3.2 - CGFloat(n.depth) * 0.7))
                    }

                    for n in nodes {
                        let rect = CGRect(x: n.center.x - n.radius, y: n.center.y - n.radius,
                                          width: n.radius * 2, height: n.radius * 2)
                        let dot = Path(ellipseIn: rect)
                        ctx.fill(dot, with: .color(SharedPaint.color(store, n.id,
                                                                    depth: n.depth,
                                                                    mode: app.sizeMode,
                                                                    rootIndex: app.currentFolderIndex)))
                        ctx.stroke(dot, with: .color(Theme.ground.opacity(0.85)), lineWidth: 1)
                        if n.id == hoverID {
                            ctx.stroke(dot, with: .color(Theme.ink), lineWidth: 1.8)
                        }
                        // Label the branches that carry real weight.
                        if n.radius > 9.5, n.depth <= 3 {
                            let size = store.isDir(n.id) ? store.subtree[n.id] : store.allocated[n.id]
                            let out = n.radius + 9
                            let lp = CGPoint(x: n.center.x + cos(n.angle - .pi / 2) * out,
                                             y: n.center.y + sin(n.angle - .pi / 2) * out)
                            let anchor: UnitPoint = cos(n.angle - .pi / 2) >= 0 ? .leading : .trailing
                            ctx.draw(Text(store.name(n.id))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Theme.ink.opacity(0.9)),
                                     at: lp, anchor: anchor)
                            ctx.draw(Text(Fmt.bytes(size))
                                        .font(.system(size: 8.5).monospacedDigit())
                                        .foregroundStyle(Theme.inkFaint),
                                     at: CGPoint(x: lp.x, y: lp.y + 11), anchor: anchor)
                        }
                    }

                    // The root hub.
                    let hubR: CGFloat = 34
                    let hub = Path(ellipseIn: CGRect(x: center.x - hubR, y: center.y - hubR,
                                                     width: hubR * 2, height: hubR * 2))
                    ctx.fill(hub, with: .color(Theme.pill))
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hoverID = hit(nodes, p)
                    case .ended: hoverID = nil
                    }
                }
                .onTapGesture { p in
                    if let id = hit(nodes, p) {
                        app.activate(nodeIndex: id, anchor: p.unitAnchor(in: geo.size))
                    }
                }

                if let store = app.store {
                    let i = app.currentFolderIndex
                    VStack(spacing: 1) {
                        Text(i == 0 ? AppState.friendlyRootName(app.scanRootPath) : store.name(i))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.pillText)
                            .lineLimit(1)
                        Text(Fmt.bytes(store.subtree[i]))
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(Theme.pillText)
                    }
                    .frame(width: 62)
                    .allowsHitTesting(false)
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

    private func hit(_ nodes: [MindNode], _ p: CGPoint) -> Int? {
        var best: MindNode? = nil
        var bestD = CGFloat.greatestFiniteMagnitude
        for n in nodes {
            let dx = p.x - n.center.x, dy = p.y - n.center.y
            let d = (dx * dx + dy * dy).squareRoot()
            if d <= max(n.radius, 7), d < bestD { bestD = d; best = n }
        }
        return best?.id
    }
}
