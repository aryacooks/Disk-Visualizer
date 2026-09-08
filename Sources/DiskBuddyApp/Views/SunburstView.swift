import SwiftUI
import ScannerCore

public struct SunburstView: View {
    @EnvironmentObject var app: AppState
    @State private var cache = LayoutCache<[Arc]>()
    @State private var hoverID: Int? = nil

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let maxR = min(geo.size.width, geo.size.height) / 2 - 12
            let rings = max(1, Int(app.sunburstRings))
            let hubR = maxR * 0.20
            let ringW = (maxR - hubR) / CGFloat(rings)
            let arcs = cache.get(LayoutKey(nodes: app.store?.count ?? 0,
                                           root: app.currentFolderIndex,
                                           rings: rings)) {
                guard let store = app.store else { return [] }
                return SunburstLayout.build(store: store,
                                            root: app.currentFolderIndex,
                                            rings: rings)
            }

            ZStack {
                Canvas { ctx, _ in
                    guard let store = app.store else { return }
                    for arc in arcs {
                        let r0 = hubR + CGFloat(arc.depth) * ringW
                        let r1 = r0 + ringW
                        let path = ringSegment(center: center, r0: r0, r1: r1,
                                               start: arc.start, end: arc.end)
                        ctx.fill(path, with: .color(
                            SharedPaint.color(store, arc.id, depth: arc.depth,
                                              mode: app.sizeMode,
                                              rootIndex: app.currentFolderIndex)))
                        if arc.end - arc.start > 0.02 {
                            ctx.stroke(path, with: .color(Theme.ground.opacity(0.7)), lineWidth: 0.7)
                        }
                        if arc.id == hoverID {
                            ctx.stroke(path, with: .color(Theme.ink), lineWidth: 1.8)
                        }
                        // Label only where the text physically fits: gate on the
                        // arc's LENGTH in points, not its angle, or the outer
                        // rings turn into overlapping mush.
                        let sweep = arc.end - arc.start
                        let rr = (r0 + r1) / 2
                        let arcLen = rr * CGFloat(sweep)
                        if arcLen > 52, sweep > 0.10, ringW > 16, arc.depth < 5 {
                            let mid = (arc.start + arc.end) / 2
                            let p = CGPoint(x: center.x + cos(mid - .pi/2) * rr,
                                            y: center.y + sin(mid - .pi/2) * rr)
                            var sub = ctx
                            sub.translateBy(x: p.x, y: p.y)
                            sub.rotate(by: .radians(mid < .pi ? mid - .pi/2 : mid + .pi/2))
                            let full = store.name(arc.id)
                            let budget = max(3, Int(arcLen / 5.2))
                            let label = full.count > budget
                                ? String(full.prefix(budget - 1)) + "…" : full
                            sub.draw(Text(label)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(Theme.ink.opacity(0.85)),
                                     at: .zero, anchor: .center)
                        }
                    }
                    // Hub
                    let hub = Path(ellipseIn: CGRect(x: center.x - hubR, y: center.y - hubR,
                                                     width: hubR * 2, height: hubR * 2))
                    ctx.fill(hub, with: .color(Theme.ground))
                    ctx.stroke(hub, with: .color(Theme.hairline), lineWidth: 1)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hoverID = hit(arcs, p, center, hubR, ringW, rings)
                    case .ended: hoverID = nil
                    }
                }
                .onTapGesture { p in
                    if let id = hit(arcs, p, center, hubR, ringW, rings) {
                        app.activate(nodeIndex: id, anchor: p.unitAnchor(in: geo.size))
                    }
                }

                // Hub label
                if let store = app.store {
                    let i = app.currentFolderIndex
                    VStack(spacing: 2) {
                        Text(i == 0 ? rootLabel : store.name(i))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text(Fmt.bytes(store.subtree[i]))
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                    }
                    .frame(width: hubR * 1.7)
                    .allowsHitTesting(false)
                }

                if let h = hoverID, let store = app.store {
                    VStack {
                        Spacer()
                        HStack { HoverChip(store: store, index: h); Spacer() }
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }

    private var rootLabel: String {
        AppState.friendlyRootName(app.scanRootPath)
    }

    private func ringSegment(center: CGPoint, r0: CGFloat, r1: CGFloat,
                             start: Double, end: Double) -> Path {
        // -90° so angle zero points up, matching the reference.
        let a0 = Angle(radians: start - .pi / 2)
        let a1 = Angle(radians: end - .pi / 2)
        var p = Path()
        p.addArc(center: center, radius: r1, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: center, radius: r0, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }

    private func hit(_ arcs: [Arc], _ p: CGPoint, _ center: CGPoint, _ hubR: CGFloat,
                     _ ringW: CGFloat, _ rings: Int) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let r = sqrt(dx * dx + dy * dy)
        guard r > hubR, ringW > 0 else { return nil }
        let depth = Int((r - hubR) / ringW)
        guard depth >= 0, depth < rings else { return nil }
        var theta = atan2(dy, dx) + .pi / 2
        if theta < 0 { theta += 2 * .pi }
        if theta > 2 * .pi { theta -= 2 * .pi }
        return arcs.first { $0.depth == depth && theta >= $0.start && theta < $0.end }?.id
    }

}
