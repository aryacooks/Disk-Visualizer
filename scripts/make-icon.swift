#!/usr/bin/env swift
//
// Generates Resources/AppIcon.icns from code, so the icon lives in git as
// something readable and tweakable rather than as an opaque binary.
//
//   swift scripts/make-icon.swift
//
// The mark is the Sunburst view in miniature: a ring of proportional segments
// in the app's own pastel palette, with one amber slice pulled out — the "this
// is the folder eating your disk" moment the app exists to produce.
//
import AppKit

// MARK: - Palette (mirrors Sources/DiskBuddyApp/Views/Theme.swift)

func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

let ground   = rgb(0.996, 0.984, 0.965)   // #FEFBF6 warm paper
let groundLo = rgb(0.980, 0.960, 0.925)
let ink      = rgb(0.086, 0.082, 0.078)
let amber    = rgb(0.722, 0.549, 0.196)
let hairline = rgb(0.898, 0.878, 0.843)

// Ring segments, in draw order. Angles are proportions of the full circle.
// Deliberately uneven: a disk is never neatly divided, and the icon should
// say so at a glance.
let segments: [(share: Double, color: NSColor)] = [
    (0.30, amber),                        // the culprit
    (0.17, rgb(0.827, 0.886, 0.937)),     // sky
    (0.13, rgb(0.855, 0.898, 0.831)),     // sage
    (0.11, rgb(0.976, 0.851, 0.859)),     // blush
    (0.09, rgb(0.878, 0.867, 0.933)),     // lilac
    (0.07, rgb(0.973, 0.882, 0.831)),     // clay
    (0.06, rgb(0.933, 0.914, 0.827)),     // wheat
    (0.07, rgb(0.898, 0.878, 0.847)),     // stone
]

// MARK: - Drawing

/// Draws the icon into the current context at `size` x `size` points.
func drawIcon(size s: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let u = s / 1024.0   // one design unit == one pixel of the 1024 master

    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Below 128 px the artwork has to fight for every pixel: the tile grows
    // into the canvas, the ring thickens, and the pastels deepen. Without this
    // the Dock and Finder sidebar show a beige smudge.
    let compact = s < 128

    // --- The tile ---------------------------------------------------------
    // macOS icons sit in a rounded square inset from the canvas, leaving room
    // for the system's own shadow and for optical alignment in the Dock.
    let inset: CGFloat = (compact ? 40 : 100) * u
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = tile.width * 0.2246          // Apple's continuous-corner ratio
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u),
                  blur: 24 * u,
                  color: NSColor.black.withAlphaComponent(0.18).cgColor)
    ground.setFill()
    tilePath.fill()
    ctx.restoreGState()

    // Warm vertical gradient so the tile isn't flat cream.
    ctx.saveGState()
    tilePath.addClip()
    NSGradient(starting: ground, ending: groundLo)?
        .draw(in: tile, angle: -90)
    ctx.restoreGState()

    // Hairline edge — the same one that separates panels in the app.
    hairline.withAlphaComponent(0.9).setStroke()
    tilePath.lineWidth = 2 * u
    tilePath.stroke()

    // --- The ring ---------------------------------------------------------
    let centre = CGPoint(x: s / 2, y: s / 2)
    let outer: CGFloat = (compact ? 400 : 320) * u
    let inner: CGFloat = (compact ? 210 : 158) * u
    // Segment gaps vanish under downscaling anyway; spending pixels on them
    // small just eats contrast.
    let gap: CGFloat = compact ? 0 : 1.6

    // The amber segment is pulled out of the ring, the way a selected slice
    // lifts in the Sunburst view.
    let explode: CGFloat = compact ? 0 : 26 * u

    var angle: Double = 90                    // start at 12 o'clock
    for seg in segments {
        let sweep = seg.share * 360
        let start = angle - sweep + gap / 2
        let end = angle - gap / 2
        let isCulprit = seg.color == amber

        var c = centre
        if isCulprit {
            let mid = (start + end) / 2 * .pi / 180
            c.x += cos(mid) * explode
            c.y += sin(mid) * explode
        }

        let path = NSBezierPath()
        path.appendArc(withCenter: c, radius: outer,
                       startAngle: start, endAngle: end, clockwise: false)
        path.appendArc(withCenter: c, radius: inner,
                       startAngle: end, endAngle: start, clockwise: true)
        path.close()

        // Pastels that read as "soft" at 512 read as "empty" at 32.
        let fill = compact ? seg.color.blended(withFraction: 0.22, of: ink)! : seg.color

        if isCulprit && !compact {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -4 * u),
                          blur: 12 * u,
                          color: NSColor.black.withAlphaComponent(0.22).cgColor)
            fill.setFill()
            path.fill()
            ctx.restoreGState()
        } else {
            fill.setFill()
            path.fill()
        }

        angle -= sweep
    }

    // --- The hub ----------------------------------------------------------
    // A near-black disc anchors the composition and survives downscaling to
    // 16 px, where the segments themselves blur into a single warm ring.
    let hubR: CGFloat = (compact ? 150 : 100) * u
    let hub = CGRect(x: centre.x - hubR, y: centre.y - hubR,
                     width: hubR * 2, height: hubR * 2)
    ink.setFill()
    NSBezierPath(ovalIn: hub).fill()

    // The magnifier stroke inside the hub — this is a *checker*, not a chart.
    // Skipped below 64 px, where it would only read as mud.
    if s >= 64 {
        let lensR: CGFloat = 40 * u
        let lensC = CGPoint(x: centre.x - 8 * u, y: centre.y + 10 * u)
        ground.setStroke()
        let lens = NSBezierPath(ovalIn: CGRect(x: lensC.x - lensR, y: lensC.y - lensR,
                                               width: lensR * 2, height: lensR * 2))
        lens.lineWidth = 16 * u
        lens.stroke()

        let handle = NSBezierPath()
        handle.move(to: CGPoint(x: lensC.x + lensR * 0.72, y: lensC.y - lensR * 0.72))
        handle.line(to: CGPoint(x: lensC.x + lensR * 1.45, y: lensC.y - lensR * 1.45))
        handle.lineWidth = 16 * u
        handle.lineCapStyle = .round
        handle.stroke()
    }
}

/// Renders one PNG at `px` pixels square.
func renderPNG(px: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed to encode \(px)px\n".data(using: .utf8)!)
        exit(1)
    }
    try! data.write(to: url)
}

// MARK: - Iconset

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Each size is drawn natively rather than downscaled from the master, so the
// 16 px version gets real hinting instead of a blurred 1024.
let wanted: [(name: String, px: Int)] = [
    ("icon_16x16",      16),  ("icon_16x16@2x",     32),
    ("icon_32x32",      32),  ("icon_32x32@2x",     64),
    ("icon_128x128",   128),  ("icon_128x128@2x",  256),
    ("icon_256x256",   256),  ("icon_256x256@2x",  512),
    ("icon_512x512",   512),  ("icon_512x512@2x", 1024),
]

for w in wanted {
    renderPNG(px: w.px, to: iconset.appendingPathComponent("\(w.name).png"))
}

// A standalone 1024 for README / release art.
try? FileManager.default.createDirectory(
    at: root.appendingPathComponent("docs/art"), withIntermediateDirectories: true)
renderPNG(px: 1024, to: root.appendingPathComponent("docs/art/icon.png"))

print("wrote \(wanted.count) sizes to build/AppIcon.iconset + docs/art/icon.png")
