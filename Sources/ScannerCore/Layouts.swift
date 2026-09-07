import Foundation
import CoreGraphics

public struct TreeCell: Identifiable, Sendable {
    public let id: Int
    public let rect: CGRect
    public let depth: Int
    public let isLeaf: Bool
}

/// Squarified treemap (Bruls–Huizing–van Wijk).
///
/// The performance trick that makes 2M nodes viable: we never lay out a subtree
/// whose rectangle is already smaller than `minArea`. A full home folder has
/// only a few thousand rects bigger than a pixel, so layout cost stops
/// depending on how many files were scanned.
public enum TreemapLayout {
    public static func build(store: NodeStore, root: Int, rect: CGRect,
                      maxDepth: Int = 9, minArea: CGFloat = 24) -> [TreeCell] {
        var out: [TreeCell] = []
        out.reserveCapacity(4096)
        recurse(store, root, rect, 0, maxDepth, minArea, &out)
        return out
    }

    private static func recurse(_ store: NodeStore, _ node: Int, _ rect: CGRect,
                                _ depth: Int, _ maxDepth: Int, _ minArea: CGFloat,
                                _ out: inout [TreeCell]) {
        guard rect.width > 1, rect.height > 1 else { return }
        guard let range = store.children(of: node), !range.isEmpty, depth < maxDepth else {
            return
        }

        var items: [(Int, Double)] = []
        items.reserveCapacity(range.count)
        for k in range {
            let v = store.isDir(k) ? store.subtree[k] : store.allocated[k]
            if v > 0 { items.append((k, Double(v))) }
        }
        guard !items.isEmpty else { return }
        items.sort { $0.1 > $1.1 }
        // Only the biggest children can possibly clear minArea; cap the fan-out
        // so a directory with 100k entries doesn't stall the layout.
        if items.count > 400 { items = Array(items.prefix(400)) }

        let placed = squarify(items, rect)
        for (idx, r) in placed {
            guard r.width > 0.7, r.height > 0.7 else { continue }
            let isDir = store.isDir(idx)
            let area = r.width * r.height
            let willRecurse = isDir && area > minArea && depth + 1 < maxDepth
            out.append(TreeCell(id: idx, rect: r, depth: depth, isLeaf: !willRecurse))
            if willRecurse {
                // Inset to leave room for the folder's own label strip.
                let header: CGFloat = (r.height > 34 && r.width > 60) ? 15 : 2
                let inner = CGRect(x: r.minX + 2, y: r.minY + header,
                                   width: max(0, r.width - 4),
                                   height: max(0, r.height - header - 2))
                recurse(store, idx, inner, depth + 1, maxDepth, minArea, &out)
            }
        }
    }

    private static func worst(_ areas: [Double], _ sum: Double, _ side: Double) -> Double {
        guard let mn = areas.min(), let mx = areas.max(), sum > 0, side > 0, mn > 0 else {
            return .infinity
        }
        let s2 = sum * sum, w2 = side * side
        return max(w2 * mx / s2, s2 / (w2 * mn))
    }

    private static func squarify(_ items: [(Int, Double)], _ bounds: CGRect) -> [(Int, CGRect)] {
        var result: [(Int, CGRect)] = []
        let total = items.reduce(0.0) { $0 + $1.1 }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return result }
        let scale = Double(bounds.width) * Double(bounds.height) / total

        var remaining = items[...]
        var r = bounds

        while !remaining.isEmpty {
            let short = Double(min(r.width, r.height))
            guard short > 0.5, r.width > 0.5, r.height > 0.5 else { break }

            var rowAreas: [Double] = []
            var rowItems: [(Int, Double)] = []
            var rowSum = 0.0
            var best = Double.infinity

            for cand in remaining {
                let a = cand.1 * scale
                let w = worst(rowAreas + [a], rowSum + a, short)
                if !rowItems.isEmpty && w > best { break }
                rowItems.append(cand); rowAreas.append(a); rowSum += a; best = w
            }
            guard !rowItems.isEmpty else { break }

            let thickness = CGFloat(rowSum / short)
            var offset: CGFloat = 0

            if r.width >= r.height {
                for (i, item) in rowItems.enumerated() {
                    let h = CGFloat(rowAreas[i] / max(0.0001, Double(thickness)))
                    result.append((item.0, CGRect(x: r.minX, y: r.minY + offset,
                                                  width: thickness, height: h)))
                    offset += h
                }
                r = CGRect(x: r.minX + thickness, y: r.minY,
                           width: r.width - thickness, height: r.height)
            } else {
                for (i, item) in rowItems.enumerated() {
                    let w = CGFloat(rowAreas[i] / max(0.0001, Double(thickness)))
                    result.append((item.0, CGRect(x: r.minX + offset, y: r.minY,
                                                  width: w, height: thickness)))
                    offset += w
                }
                r = CGRect(x: r.minX, y: r.minY + thickness,
                           width: r.width, height: r.height - thickness)
            }
            remaining = remaining.dropFirst(rowItems.count)
        }
        return result
    }
}


public struct Arc: Identifiable, Sendable {
    public let id: Int
    public let depth: Int
    public let start: Double   // radians
    public let end: Double
}

/// Radial partition: angle ∝ size, radius ∝ depth. Same traversal as the
/// treemap, different coordinate system — and the same culling rule, expressed
/// as a minimum sweep angle instead of a minimum area.
public enum SunburstLayout {
    public static func build(store: NodeStore, root: Int, rings: Int,
                      minSweep: Double = 0.004) -> [Arc] {
        var out: [Arc] = []
        out.reserveCapacity(4096)
        recurse(store, root, 0, 2 * .pi, 0, rings, minSweep, &out)
        return out
    }

    private static func recurse(_ store: NodeStore, _ node: Int,
                                _ start: Double, _ end: Double,
                                _ depth: Int, _ maxDepth: Int,
                                _ minSweep: Double, _ out: inout [Arc]) {
        guard depth < maxDepth, end - start > minSweep else { return }
        guard let range = store.children(of: node), !range.isEmpty else { return }

        var items: [(Int, Double)] = []
        items.reserveCapacity(range.count)
        var total = 0.0
        for k in range {
            let v = Double(store.isDir(k) ? store.subtree[k] : store.allocated[k])
            if v > 0 { items.append((k, v)); total += v }
        }
        guard total > 0 else { return }
        items.sort { $0.1 > $1.1 }

        var cursor = start
        let span = end - start
        for (idx, v) in items {
            let sweep = span * (v / total)
            if sweep <= minSweep { cursor += sweep; continue }
            out.append(Arc(id: idx, depth: depth, start: cursor, end: cursor + sweep))
            if store.isDir(idx) {
                recurse(store, idx, cursor, cursor + sweep, depth + 1, maxDepth, minSweep, &out)
            }
            cursor += sweep
        }
    }
}


// MARK: - Flame (icicle)

public struct FlameCell: Identifiable, Sendable {
    public let id: Int
    public let rect: CGRect
    public let depth: Int
}

/// Depth top-to-bottom, size left-to-right. Same traversal as the sunburst,
/// unrolled into Cartesian coordinates — an arc's angle becomes a width.
public enum FlameLayout {
    public static func build(store: NodeStore, root: Int, width: CGFloat,
                             rowHeight: CGFloat, maxDepth: Int = 14,
                             minWidth: CGFloat = 0.6) -> [FlameCell] {
        var out: [FlameCell] = []
        out.reserveCapacity(4096)
        out.append(FlameCell(id: root, rect: CGRect(x: 0, y: 0, width: width, height: rowHeight), depth: 0))
        recurse(store, root, 0, width, 1, maxDepth, rowHeight, minWidth, &out)
        return out
    }

    private static func recurse(_ store: NodeStore, _ node: Int,
                                _ x0: CGFloat, _ x1: CGFloat,
                                _ depth: Int, _ maxDepth: Int,
                                _ rowH: CGFloat, _ minW: CGFloat,
                                _ out: inout [FlameCell]) {
        guard depth < maxDepth, x1 - x0 > minW else { return }
        guard let range = store.children(of: node), !range.isEmpty else { return }

        var items: [(Int, Double)] = []
        var total = 0.0
        for k in range {
            let v = Double(store.isDir(k) ? store.subtree[k] : store.allocated[k])
            if v > 0 { items.append((k, v)); total += v }
        }
        guard total > 0 else { return }
        items.sort { $0.1 > $1.1 }

        var cursor = x0
        let span = x1 - x0
        for (idx, v) in items {
            let w = span * CGFloat(v / total)
            if w <= minW { cursor += w; continue }
            out.append(FlameCell(id: idx,
                                 rect: CGRect(x: cursor, y: CGFloat(depth) * rowH,
                                              width: w, height: rowH),
                                 depth: depth))
            if store.isDir(idx) {
                recurse(store, idx, cursor, cursor + w, depth + 1, maxDepth, rowH, minW, &out)
            }
            cursor += w
        }
    }
}

// MARK: - Bubbles (circle packing)

public struct Bubble: Identifiable, Sendable {
    public let id: Int
    public let center: CGPoint
    public let radius: CGFloat
    public let depth: Int
    public let isLeaf: Bool
}

/// Nested circle packing, one circle per child.
///
/// Siblings are packed with a greedy tangent placement: each circle, largest
/// first, is placed tangent to two already-placed circles at whichever valid
/// spot sits closest to the group's centre. That is O(n^3) in the worst case,
/// which is fine because we only ever pack the biggest ~32 children of a node —
/// everything smaller is culled before it reaches here.
public enum BubbleLayout {
    public static func build(store: NodeStore, root: Int, center: CGPoint,
                             radius: CGFloat, maxDepth: Int = 5,
                             minRadius: CGFloat = 2.5) -> [Bubble] {
        var out: [Bubble] = []
        out.reserveCapacity(2048)
        out.append(Bubble(id: root, center: center, radius: radius, depth: 0, isLeaf: false))
        recurse(store, root, center, radius, 1, maxDepth, minRadius, &out)
        return out
    }

    private static func recurse(_ store: NodeStore, _ node: Int,
                                _ center: CGPoint, _ radius: CGFloat,
                                _ depth: Int, _ maxDepth: Int,
                                _ minR: CGFloat, _ out: inout [Bubble]) {
        guard depth <= maxDepth, radius > minR * 2.5 else { return }
        guard let range = store.children(of: node), !range.isEmpty else { return }

        var items: [(Int, Double)] = []
        for k in range {
            let v = Double(store.isDir(k) ? store.subtree[k] : store.allocated[k])
            if v > 0 { items.append((k, v)) }
        }
        guard !items.isEmpty else { return }
        items.sort { $0.1 > $1.1 }
        if items.count > 32 { items = Array(items.prefix(32)) }

        // Area proportional to bytes, so radius goes as the square root.
        let radii = items.map { CGFloat(($0.1).squareRoot()) }
        var placed = packSiblings(radii)
        guard !placed.isEmpty else { return }

        // Scale the packed cluster to sit inside the parent, with a little padding.
        var enclosing: CGFloat = 0
        for (i, p) in placed.enumerated() {
            enclosing = max(enclosing, (p.x * p.x + p.y * p.y).squareRoot() + radii[i])
        }
        guard enclosing > 0 else { return }
        let usable = radius * (depth == 1 ? 0.92 : 0.86)
        let scale = usable / enclosing

        for i in placed.indices { placed[i] = CGPoint(x: placed[i].x * scale, y: placed[i].y * scale) }

        for (i, item) in items.enumerated() {
            let r = radii[i] * scale
            guard r >= minR else { continue }
            let c = CGPoint(x: center.x + placed[i].x, y: center.y + placed[i].y)
            let isDir = store.isDir(item.0)
            let willRecurse = isDir && depth < maxDepth && r > minR * 3
            out.append(Bubble(id: item.0, center: c, radius: r, depth: depth, isLeaf: !willRecurse))
            if willRecurse {
                recurse(store, item.0, c, r, depth + 1, maxDepth, minR, &out)
            }
        }
    }

    /// Positions circles of the given radii around the origin, no overlaps.
    static func packSiblings(_ radii: [CGFloat]) -> [CGPoint] {
        var pos = [CGPoint](repeating: .zero, count: radii.count)
        guard !radii.isEmpty else { return pos }
        pos[0] = .zero
        if radii.count == 1 { return pos }

        pos[1] = CGPoint(x: radii[0] + radii[1], y: 0)
        if radii.count == 2 { return pos }

        for i in 2..<radii.count {
            let r = radii[i]
            var best: CGPoint? = nil
            var bestDist = CGFloat.greatestFiniteMagnitude

            // Candidate spots: tangent to every pair of already-placed circles.
            for a in 0..<i {
                for b in (a + 1)..<i {
                    for cand in tangentPoints(pos[a], radii[a] + r, pos[b], radii[b] + r) {
                        var ok = true
                        for j in 0..<i where j != a && j != b {
                            let dx = cand.x - pos[j].x, dy = cand.y - pos[j].y
                            if (dx * dx + dy * dy).squareRoot() < radii[j] + r - 0.01 { ok = false; break }
                        }
                        if ok {
                            let d = (cand.x * cand.x + cand.y * cand.y).squareRoot()
                            if d < bestDist { bestDist = d; best = cand }
                        }
                    }
                }
            }

            if let b = best {
                pos[i] = b
            } else {
                // Fall back to a ring outside everything placed so far.
                var outer: CGFloat = 0
                for j in 0..<i {
                    outer = max(outer, (pos[j].x * pos[j].x + pos[j].y * pos[j].y).squareRoot() + radii[j])
                }
                let angle = CGFloat(i) * 2.399963  // golden angle, spreads them out
                pos[i] = CGPoint(x: cos(angle) * (outer + r), y: sin(angle) * (outer + r))
            }
        }
        return pos
    }

    /// The 0–2 points at distance ra from a and rb from b.
    private static func tangentPoints(_ a: CGPoint, _ ra: CGFloat,
                                      _ b: CGPoint, _ rb: CGFloat) -> [CGPoint] {
        let dx = b.x - a.x, dy = b.y - a.y
        let d = (dx * dx + dy * dy).squareRoot()
        guard d > 0.0001, d <= ra + rb, d >= abs(ra - rb) else { return [] }
        let x = (d * d - rb * rb + ra * ra) / (2 * d)
        let ySq = ra * ra - x * x
        guard ySq >= 0 else { return [] }
        let y = ySq.squareRoot()
        let ux = dx / d, uy = dy / d
        let px = a.x + x * ux, py = a.y + x * uy
        return [CGPoint(x: px - y * uy, y: py + y * ux),
                CGPoint(x: px + y * uy, y: py - y * ux)]
    }
}

// MARK: - Mind map (radial tree)

public struct MindNode: Identifiable, Sendable {
    public let id: Int
    public let center: CGPoint
    public let radius: CGFloat
    public let depth: Int
    public let parentCenter: CGPoint
    public let angle: Double
}

/// Branches radiating from the root, each node sized by its weight. Angular
/// wedges are allocated exactly as in the sunburst; only the drawing differs.
public enum MindMapLayout {
    public static func build(store: NodeStore, root: Int, center: CGPoint,
                             maxRadius: CGFloat, maxDepth: Int = 4,
                             minSweep: Double = 0.012) -> [MindNode] {
        var out: [MindNode] = []
        let ring = maxRadius / CGFloat(max(1, maxDepth))
        let rootTotal = Double(max(1, store.subtree[root]))
        recurse(store, root, center, 0, 2 * .pi, 1, maxDepth, ring, minSweep, rootTotal, center, &out)
        return out
    }

    private static func recurse(_ store: NodeStore, _ node: Int, _ parentPt: CGPoint,
                                _ start: Double, _ end: Double,
                                _ depth: Int, _ maxDepth: Int, _ ring: CGFloat,
                                _ minSweep: Double, _ rootTotal: Double,
                                _ center: CGPoint, _ out: inout [MindNode]) {
        guard depth <= maxDepth, end - start > minSweep else { return }
        guard let range = store.children(of: node), !range.isEmpty else { return }

        var items: [(Int, Double)] = []
        var total = 0.0
        for k in range {
            let v = Double(store.isDir(k) ? store.subtree[k] : store.allocated[k])
            if v > 0 { items.append((k, v)); total += v }
        }
        guard total > 0 else { return }
        items.sort { $0.1 > $1.1 }
        if items.count > 24 { items = Array(items.prefix(24)) }

        var cursor = start
        let span = end - start
        for (idx, v) in items {
            let sweep = span * (v / total)
            if sweep <= minSweep { cursor += sweep; continue }
            let mid = cursor + sweep / 2
            let r = ring * CGFloat(depth)
            let pt = CGPoint(x: center.x + cos(mid - .pi / 2) * r,
                             y: center.y + sin(mid - .pi / 2) * r)
            // Dot area tracks bytes, floored so deep twigs stay visible.
            let frac = v / rootTotal
            let dot = max(2.5, min(22, CGFloat((frac * 900).squareRoot()) + 2.5))
            out.append(MindNode(id: idx, center: pt, radius: dot, depth: depth,
                                parentCenter: parentPt, angle: mid))
            if store.isDir(idx) {
                recurse(store, idx, pt, cursor, cursor + sweep, depth + 1, maxDepth,
                        ring, minSweep, rootTotal, center, &out)
            }
            cursor += sweep
        }
    }
}
