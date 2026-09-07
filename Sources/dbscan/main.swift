import Darwin
import Foundation
import CoreGraphics
import ScannerCore

func human(_ b: Int64) -> String {
    let u = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(b), i = 0
    while v >= 1000 && i < u.count - 1 { v /= 1000; i += 1 }
    return i == 0 ? "\(b) B" : String(format: "%.2f %@", v, u[i])
}

func grouped(_ n: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

// ---- args ----
var root = NSHomeDirectory()
var threads = ProcessInfo.processInfo.activeProcessorCount
var topN = 25
var checkLayouts = false
var checkMonitor = false
var checkApps = false
var checkDupes = false
var checkSnap = false
var checkTemp = false
var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "-j": i += 1; threads = Int(args[i]) ?? threads
    case "-n": i += 1; topN = Int(args[i]) ?? topN
    case "--layouts": checkLayouts = true
    case "--monitor": checkMonitor = true
    case "--apps": checkApps = true
    case "--dupes": checkDupes = true
    case "--snapshot": checkSnap = true
    case "--temp": checkTemp = true
    case "-h", "--help":
        print("""
        dbscan — Phase 0 scanner benchmark (see docs/DESIGN.md §0)

          dbscan [path] [-j threads] [-n top]

        Measures raw getattrlistbulk throughput and builds the flat node arena.
        """)
        exit(0)
    default: root = args[i]
    }
    i += 1
}
root = (root as NSString).expandingTildeInPath
if root.count > 1 && root.hasSuffix("/") { root.removeLast() }

if checkTemp {
    let r = SensorReader().read()
    print("thermal state: \(r.thermalState)")
    if r.sensorsUnavailable {
        print("on-die sensors: UNAVAILABLE on this machine/OS")
    } else {
        print("sensors: \(r.sensors.count)")
        if let avg = r.cpuAverage { print(String(format: "CPU average: %.1f C", avg)) }
        if let h = r.hottest { print(String(format: "hottest: %@ %.1f C", h.name as NSString, h.celsius)) }
        for s in r.sensors.prefix(14) {
            print(String(format: "  [%-8@] %-38@ %6.1f C", s.group as NSString, s.name as NSString, s.celsius))
        }
    }
    let b = r.battery
    if b.present {
        print("battery: \(b.percent)%  charging=\(b.charging)  cycles=\(b.cycleCount)  health=\(b.health)")
    }
    exit(0)
}

if checkApps {
    let t = DispatchTime.now()
    let apps = AppInventory.installedApps()
    let el = Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e9
    print(String(format: "%d apps in %.2fs\n", apps.count, el))
    for a in apps.prefix(8) {
        let lo = AppInventory.leftovers(for: a)
        let loBytes = lo.reduce(Int64(0)) { $0 + $1.size }
        print("\(a.name)  v\(a.version)  \(a.bundleID)")
        print("  bundle \(human(a.bundleSize))   leftovers \(human(loBytes)) in \(lo.count) places   total \(human(a.bundleSize + loBytes))")
        for l in lo.prefix(4) {
            print("    [\(l.confidence.label)] \(l.kind): \(l.name)  \(human(l.size))")
        }
    }
    exit(0)
}

if checkMonitor {
    let sampler = SystemSampler()
    _ = sampler.sample()                     // prime the counters
    Thread.sleep(forTimeInterval: 1.0)
    let m = sampler.sample()
    print(String(format: "CPU   busy %.1f%%  (user %.1f / sys %.1f)  load %.2f",
                 m.cpuBusy, m.cpuUser, m.cpuSystem, m.loadAverage))
    print("MEM   used \(human(m.memUsed)) of \(human(m.memTotal))  wired \(human(m.memWired))  compressed \(human(m.memCompressed))")
    print("NET   down \(human(m.netInPerSec))/s  up \(human(m.netOutPerSec))/s  session in \(human(m.netInTotal))")
    print("PROC  \(m.processes.count) processes")
    let writers = m.processes.filter { $0.diskWrittenBytes > 0 }
        .sorted { $0.diskWrittenBytes > $1.diskWrittenBytes }.prefix(5)
    print("  top by CPU:")
    for p in m.processes.prefix(5) {
        print(String(format: "    %-24@ %5.1f%%  %@", p.name as NSString, p.cpuPercent, human(p.residentBytes) as NSString))
    }
    print("  top by lifetime disk writes:")
    for p in writers {
        print(String(format: "    %-24@ %@", p.name as NSString, human(p.diskWrittenBytes) as NSString))
    }
    exit(0)
}

// ---- scan ----
let sc = Scanner()
let t0 = DispatchTime.now()
sc.scan(root: root, threads: threads)
let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9

let s = sc.stats
let total = s.files + s.dirs
let rate = Double(total) / elapsed

print("""

  \(root)
  ────────────────────────────────────────────────────────
  size on disk    \(human(s.allocated))
  logical size    \(human(s.logical))
  compressed by   \(human(s.compressedSaved))
  files           \(grouped(s.files))
  folders         \(grouped(s.dirs))
  hardlink dupes  \(human(s.hardlinkDupBytes)) (counted once)
  unreadable      \(grouped(s.skipped)) dirs\(s.skipped > 100 ? "  ← likely needs Full Disk Access" : "")

  elapsed         \(String(format: "%.2f s", elapsed))  on \(threads) threads
  throughput      \(grouped(Int(rate))) entries/sec
""")

// ---- age histogram (free: accumulated during the scan, DESIGN.md §5) ----
let labels = ["last 7 days", "8–30 days", "1–3 months", "3–12 months", "1–2 years", "over 2 years"]
let maxAge = s.ageBytes.max() ?? 1
print("\n  how old are these bytes?")
for (i, l) in labels.enumerated() {
    let w = maxAge > 0 ? Int(Double(s.ageBytes[i]) / Double(maxAge) * 34) : 0
    let pct = s.allocated > 0 ? Double(s.ageBytes[i]) / Double(s.allocated) * 100 : 0
    let bar = String(repeating: "█", count: w) + String(repeating: " ", count: 34 - w)
    let size = human(s.ageBytes[i])
    print("  " + l.padding(toLength: 14, withPad: " ", startingAt: 0) + " " + bar
          + " " + String(repeating: " ", count: max(0, 10 - size.count)) + size
          + String(format: "  %4.1f%%", pct))
}

// ---- top folders + top files ----
let st = sc.store
let n = st.count
var idx = Array(0..<n)

func printTop(_ title: String, _ list: ArraySlice<Int>, sizeOf: (Int) -> Int64) {
    print("\n  \(title)")
    for (rank, i) in list.enumerated() {
        let p = st.path(i)
        let short = p.hasPrefix(root) ? String(p.dropFirst(root.count)).trimmingCharacters(in: ["/"]) : p
        let label = short.isEmpty ? "." : short
        let clipped = label.count > 52 ? "…" + String(label.suffix(51)) : label
        let size = human(sizeOf(i))
        print(String(format: "  %2d  ", rank + 1)
              + clipped.padding(toLength: 52, withPad: " ", startingAt: 0)
              + String(repeating: " ", count: max(0, 12 - size.count)) + size)
    }
}

let dirs = idx.filter { st.flags[$0] & NodeStore.isDir != 0 && $0 != 0 }
    .sorted { st.subtree[$0] > st.subtree[$1] }
printTop("biggest folders anywhere", dirs.prefix(topN), sizeOf: { st.subtree[$0] })

let files = idx.filter { st.flags[$0] & NodeStore.isDir == 0 }
    .sorted { st.allocated[$0] > st.allocated[$1] }
printTop("biggest files anywhere", files.prefix(topN), sizeOf: { st.allocated[$0] })

// ---- memory footprint of the arena ----
let arenaBytes = n * (4+4+2+8+8+8+4+1) + st.names.count
print(String(format: "\n  arena: %@ nodes, %@ (%.0f bytes/node)\n",
             grouped(n) as NSString, human(Int64(arenaBytes)) as NSString,
             n > 0 ? Double(arenaBytes) / Double(n) : 0))


// --layouts: headless verification of the treemap / sunburst layout algorithms.
if checkLayouts {
    print("\n  layout check")
    print("  root children: \(st.children(of: 0)?.count ?? -1)")

    let canvas = CGRect(x: 0, y: 0, width: 980, height: 560)
    let cells = TreemapLayout.build(store: st, root: 0, rect: canvas)
    let depth0 = cells.filter { $0.depth == 0 }
    let area = depth0.reduce(0.0) { $0 + $1.rect.width * $1.rect.height }
    print("  treemap cells: \(cells.count)  (depth-0: \(depth0.count))")
    print(String(format: "  depth-0 area coverage: %.1f%% of canvas", area / (980 * 560) * 100))
    if let big = depth0.max(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
        print("  largest: \(st.name(big.id))  \(Int(big.rect.width))x\(Int(big.rect.height))")
    }

    let flame = FlameLayout.build(store: st, root: 0, width: 980, rowHeight: 22)
    print("  flame cells: \(flame.count), max depth \(flame.map { $0.depth }.max() ?? 0)")
    let rowWidth = flame.filter { $0.depth == 1 }.reduce(0.0) { $0 + $1.rect.width }
    print(String(format: "  depth-1 row spans %.1f of 980 px", rowWidth))

    let bubbles = BubbleLayout.build(store: st, root: 0,
                                     center: CGPoint(x: 400, y: 300), radius: 280)
    print("  bubbles: \(bubbles.count)")
    // Siblings must not overlap: check every pair at depth 1.
    let d1 = bubbles.filter { $0.depth == 1 }
    var worstOverlap = 0.0
    for i in 0..<d1.count { for j in (i+1)..<d1.count {
        let dx = d1[i].center.x - d1[j].center.x, dy = d1[i].center.y - d1[j].center.y
        let gap = Double((dx*dx + dy*dy).squareRoot() - d1[i].radius - d1[j].radius)
        worstOverlap = min(worstOverlap, gap)
    } }
    print(String(format: "  depth-1 bubbles: %d, worst sibling overlap: %.2f px (0 = none)",
                 d1.count, -worstOverlap))

    let mind = MindMapLayout.build(store: st, root: 0,
                                   center: CGPoint(x: 400, y: 300), maxRadius: 280)
    print("  mind map nodes: \(mind.count), depths \(Set(mind.map { $0.depth }).sorted())")

    for rings in [3, 7] {
        let arcs = SunburstLayout.build(store: st, root: 0, rings: rings)
        let d0 = arcs.filter { $0.depth == 0 }
        let sweep = d0.reduce(0.0) { $0 + ($1.end - $1.start) }
        print(String(format: "  sunburst rings=%d: %d arcs, depth-0 %d, sweep %.3f of %.3f",
                     rings, arcs.count, d0.count, sweep, 2 * Double.pi))
    }
}


if checkDupes {
    print("\n  duplicate check")
    let r = DuplicateFinder.find(store: st)
    print("  stage 1  same-size candidates: \(grouped(r.candidatesBySize))")
    print("  stage 2  survived head/tail:   \(grouped(r.survivedPrefixHash))")
    print("  stage 3  confirmed groups:     \(grouped(r.groups.count))  (\(grouped(r.totalExtraCopies)) extra copies)")
    print("  hashed \(human(r.bytesHashed)) in \(String(format: "%.2fs", r.elapsed))")
    print("  reclaimable: \(human(r.totalReclaimable))")
    let clones = r.groups.reduce(0) { $0 + $1.cloneCount }
    print("  APFS clones excluded from that figure: \(clones)")
    print("\n  biggest groups:")
    for g in r.groups.prefix(6) {
        print("   \(g.name)  \(human(g.size)) x \(g.files.count) copies  -> reclaim \(human(g.reclaimable))")
        for (i, f) in g.files.prefix(3).enumerated() {
            let tag = i == g.keepIndex ? "KEEP" : (f.isClone ? "clone" : "dup ")
            print("     [\(tag)] \(f.path)")
        }
    }
}


if checkSnap {
    print("\n  snapshot round-trip")
    let t0 = DispatchTime.now()
    let meta = try! SnapshotStore.save(store: st, rootPath: root, label: "verify")
    let saveMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
    let file = SnapshotStore.directory.appendingPathComponent("\(meta.id).dbsnap")
    let onDisk = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
    print(String(format: "  saved %@ nodes in %.0f ms -> %@ on disk",
                 grouped(st.count) as NSString, saveMs, human(Int64(onDisk ?? 0)) as NSString))

    let t1 = DispatchTime.now()
    guard let back = SnapshotStore.load(meta.id) else { print("  LOAD FAILED"); exit(1) }
    let loadMs = Double(DispatchTime.now().uptimeNanoseconds - t1.uptimeNanoseconds) / 1e6
    print(String(format: "  loaded back in %.0f ms", loadMs))

    // Every field that matters must survive the round trip.
    let ok = back.count == st.count
        && back.subtree[0] == st.subtree[0]
        && back.subtreeFiles[0] == st.subtreeFiles[0]
        && back.name(0) == st.name(0)
        && back.path(min(500, st.count - 1)) == st.path(min(500, st.count - 1))
    print("  round-trip identical: \(ok ? "YES" : "NO")")
    print("  total \(human(back.subtree[0])) vs original \(human(st.subtree[0]))")

    let d = SnapshotDiffEngine.diff(old: back, new: st)
    print(String(format: "  self-diff: %d changes (expected 0), %d paths compared in %.2fs",
                 d.changes.count, d.comparedPaths, d.elapsed))
    SnapshotStore.delete(meta.id)
}
