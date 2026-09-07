# Disk Buddy Checker — Reverse-engineering & Build Plan

Target of study: DiskBuddy (diskbuddy.com) — macOS 14+, universal, 6.2 MB download,
$19 one-time, sandboxed, offline. Claim: **118 GB / ~2M files scanned in ~10s** on Apple silicon.

This doc is two things:
1. **How it works** — the actual mechanisms behind each feature.
2. **How we build it** — phased plan, with the hard parts called out first.

---

## 0. The one number that defines the architecture

10 seconds for 2,000,000 files = **200,000 files/second**.

That single figure rules out most naive designs, and it's the best forcing
function for the whole project. Work backwards from it:

| Approach | Syscalls per file | Realistic throughput |
|---|---|---|
| `FileManager.enumerator` + `resourceValues` | ~3–5 (plus ObjC/Foundation boxing) | 15–40k/s |
| `readdir` + `lstat` | 2 | 60–100k/s |
| `getattrlistbulk(2)` | ~1 per **batch of ~50–200 entries** | 300k–1M/s |

So: **`getattrlistbulk` is not an optimization, it is the architecture.** Everything
else (data model, threading, UI) is downstream of it.

### 0.1 Measured — Phase 0 is done, the number holds

`Sources/dbscan` implements the architecture below. Measured on this machine
(M-series, macOS 26.6, 10 threads, `-Ounchecked`):

| Scan | Entries | Wall | Throughput |
|---|---|---|---|
| `~` cold cache | 2,551,640 | 17.1 s | 150k/s |
| `~` warm cache | 2,551,699 | 12.4 s | **205k/s** |
| `~/Documents` warm | 907k | 3.4 s | **269k/s** |

**DiskBuddy's claim is 2M files in ~10 s ≈ 200k/s. We are at parity on the first
attempt.** The arena costs 55–61 bytes/node (155 MB for 2.5M nodes), which is
within the §2 budget once name storage is included.

CPU profile: `1.2 s user / 58.9 s system` at 479% CPU — almost entirely kernel
time in the VFS layer, exactly as §1.2 predicts. The remaining headroom is in
the kernel, not in our code, so more threads and micro-optimising Swift will buy
little. Cold-vs-warm is the real variable.

**Correctness validated against `du`:** on a fixture tree with a hardlink, `du -sk`
reports 3428 KB and `dbscan` reports 3.51 MB — exact, with the hardlink charged
once on disk and twice logically.

**A finding worth keeping:** a home-folder scan showed 404 GB on disk against
1.41 TB logical. That is not a bug — a single Docker sparse file
(`Docker.raw`: 994 GB logical, 12 GB allocated) accounts for essentially the whole
gap. Any tool that reports logical size as "space used" is off by 2.5× on a
developer's Mac. This is the strongest argument for the honest-accounting angle in §11.

---

## 1. Scanner core

### 1.1 Enumeration primitive
`getattrlistbulk(2)` returns many directory entries *and their metadata* in one
syscall — name, type, logical size, allocated size, mtime/ctime/btime, inode,
device, flags. `readdir`+`lstat` needs a syscall per entry; bulk gets ~50–200
entries per call.

Request exactly these attributes and nothing more (each extra field costs the
kernel work):

```
ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE
| ATTR_CMN_MODTIME | ATTR_CMN_CRTIME | ATTR_CMN_FILEID | ATTR_CMN_DEVID
| ATTR_CMN_FLAGS
| ATTR_FILE_TOTALSIZE     (logical, incl. resource fork)
| ATTR_FILE_ALLOCSIZE     (bytes actually on disk)
```

Always check `ATTR_CMN_RETURNED_ATTRS` — network volumes (SMB/NFS) silently
omit fields. Fall back to `lstat` per entry on those volumes.

### 1.2 Parallelism
Parallelize **per directory, not per file**. A lock-free work-stealing deque of
directory file descriptors, one worker per performance core (`activeProcessorCount`,
capped ~8–10 — more threads just thrash the VFS name cache).

- Open each directory once with `O_DIRECTORY | O_NOFOLLOW`, keep the fd, use
  `getattrlistbulk` on it, then `openat()` children relative to it. Avoids
  re-resolving long paths for every level.
- Per-worker output buffers, merged at the end. No shared mutable state on the
  hot path except the deque.
- On NVMe this is **CPU-bound on metadata parsing**, not I/O-bound. Profile with
  Instruments' System Trace, not Disk I/O.

### 1.3 Traversal correctness (where clones get this wrong)
These are the bugs that make a disk tool report nonsense:

- **Mount boundaries** — compare `st_dev`; don't descend into a mounted volume
  when scanning `/` unless the user asked.
- **Firmlinks** — on APFS, `/Users` and `/System/Volumes/Data/Users` are the same
  bytes. Scanning `/` naively double-counts the entire data volume. Skip
  `/System/Volumes/Data` when the root is `/`.
- **Hardlinks** — keep a `Set<(dev, ino)>`; count bytes once, but show the file in
  every location. Time Machine local snapshots are hardlink-dense.
- **Symlinks** — never follow. Report link size, not target size.
- **Never descend**: `/dev`, `/net`, `/home` (autofs — will hang on a network
  timeout), `.fseventsd`, `.Spotlight-V100`.
- **Packages** — `.app`, `.photoslibrary`, `.xcodeproj` are directories. Scan
  inside them, but let the UI collapse them to one row by default.

### 1.4 Incremental results
The scan publishes partial trees so the UI draws while scanning ("incremental
scanning shows visualizations while the scan runs"). Implementation: workers push
completed subtree summaries onto a ring buffer; the UI drains it at 30 Hz and
re-lays-out. Subtree sizes roll up with a relaxed atomic add to each ancestor —
approximate mid-scan, exact at the end.

---

## 2. Data model — flat arena, not an object graph

2M `class Node` objects = ARC traffic, pointer chasing, ~150–250 bytes each,
and a multi-second deinit storm when you drop the tree. Use struct-of-arrays:

```swift
struct NodeStore {
    var parent:      [Int32]   // index, -1 for root
    var firstChild:  [Int32]
    var nextSibling: [Int32]
    var nameOff:     [UInt32]  // offset into one contiguous UTF-8 blob
    var nameLen:     [UInt16]
    var logical:     [Int64]
    var allocated:   [Int64]
    var subtree:     [Int64]   // filled by a post-order pass
    var mtime:       [Int32]   // unix seconds; 2038 is someone else's problem
    var flags:       [UInt8]   // isDir|isSymlink|isPackage|isCompressed|isSparse|isHardlinkDup
}
```

~44 bytes/node → **~90 MB for 2M files**, contiguous, cache-friendly, and
freed in one `deallocate`. Names live in a single append-only byte blob.

Subtree sums: one post-order pass over the arena after the scan (indices are
allocated in discovery order, so a reverse iteration is nearly post-order — sort
by depth once and it's exact). Linear, ~10 ms.

Serialize this arena directly (+ LZFSE) for **Snapshots** — a saved scan is just
the arena on disk, and diffing two scans is a merge-join over sorted paths.

---

## 3. APFS: logical vs. physical, and why the Inspector shows three numbers

The screenshot inspector shows `Size on disk 5.12 GB / Logical size 8.36 GB /
Compressed by 3.24 GB`. That triple is the whole APFS story:

- **Logical size** = `st_size` / `ATTR_FILE_TOTALSIZE` — what the file claims.
- **Size on disk** = `ATTR_FILE_ALLOCSIZE` (`st_blocks * 512`) — blocks charged.
- **Compression savings** = logical − allocated, when the file has the
  `UF_COMPRESSED` flag. macOS transparent compression (`decmpfs`) stores small
  files' data inside the `com.apple.decmpfs` xattr or the resource fork; `st_blocks`
  can read near zero while `st_size` is megabytes. Xcode ships enormously
  compressed — that's why `Library` and `Developer` dominate a dev's disk in
  logical terms but less so physically.
- **Sparse files** — same signature (alloc << logical), no `UF_COMPRESSED`. VM
  disk images, Docker `.raw`. Label them separately; "compressed" is wrong.
- **APFS clones** — `cp -c` / Finder duplicate share blocks copy-on-write. Two
  files each report full `ALLOCSIZE`, but deleting one frees ~nothing. There's no
  clean public API; `fcntl(F_LOG2PHYS_EXT)` on the first extent of two same-size
  files is a good heuristic. **This matters a lot for the duplicate finder.**

**Free space** — `statfs` disagrees with Finder because of purgeable space and
local snapshots. To match Finder, use
`URLResourceValues.volumeAvailableCapacityForImportantUsage`. Show both if you
want to be honest ("25.6 GB free, 41 GB purgeable").

---

## 4. Permissions — the thing that will eat a week

- **Sandboxed** + `com.apple.security.files.user-selected.read-write`. Every scan
  root the user picks becomes a **security-scoped bookmark** persisted in
  `UserDefaults`/app support, so "Recent: Home, diskbuddy" re-scans without
  re-prompting. Wrap every access in `startAccessingSecurityScopedResource()` /
  `stop...` and honor the ~a-few-hundred concurrent-scope limit — hold the scope
  at the *root*, not per file.
- **Full Disk Access** is the real gate for "Scan Full Mac". Without it you get
  `EPERM` on `~/Library/Mail`, `~/Library/Messages`, `~/Library/Safari`, Photos
  libraries, Time Machine. Detect by attempting to open
  `~/Library/Application Support/com.apple.TCC/TCC.db` — `EPERM` means no FDA.
  Deep-link to Settings with
  `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
  Note: the app must be **relaunched** after the user grants FDA.
- **Silent denials**: TCC returns `EPERM`/empty dirs rather than prompting for a
  non-interactive scan. Count skipped directories and surface "12,403 items not
  scanned — grant Full Disk Access" instead of quietly under-reporting.
- Distribution: DiskBuddy is direct-download with license keys, so it's
  **notarized + hardened runtime**, sandbox likely on with FDA. App Store
  distribution would forbid the FDA story entirely — plan for direct download.

---

## 5. The eight views are one tree, eight layouts

Every view reads the same arena. Layout is pure and cacheable per (root, size-metric).

| View | Algorithm | Notes |
|---|---|---|
| **Folders** | grid of children, sorted desc | trivial; the default, and the one people actually use |
| **Treemap** | **squarified treemap** (Bruls–Huizing–van Wijk) | classic; aspect ratios near 1 |
| **Sunburst** | radial partition: angle ∝ size, radius ∝ depth | UI has a ring-count slider (their screenshot shows 7) |
| **Flame** | icicle chart — x ∝ size, y = depth | same layout as sunburst in Cartesian coords |
| **Bubbles** | circle packing (Wang / d3 `pack`) | prettiest, least informative |
| **Mind Map** | radial tidy tree, edges as splines | pure decoration; cheap to add once tree walk exists |
| **Top Sizes** | sorted list, 3 scopes | **free during scan** — keep a bounded min-heap of K=200 |
| **Age Map** | mtime histogram + year×month heatmap | **free during scan** — 12×N buckets, one atomic add per file |

Two of the eight cost nothing but a counter in the scan loop. That's the cheapest
"we have 8 visualizations" you'll ever ship.

### Rendering
The killer detail: **cull before you lay out.** A 2M-node treemap has maybe
5–10k nodes with a rect larger than 1 px². Recurse only while
`rect.area > threshold`, then draw a single aggregate rect for the remainder.
Layout cost becomes independent of file count.

- SwiftUI `Canvas` handles ~20–50k primitives at 60 fps. Good enough for v1.
- Beyond that, `CAMetalLayer` + one instanced quad draw call; colors and rects in
  a single buffer. Hit-testing via a CPU-side R-tree or by re-running the cull.
- **Never** make one SwiftUI `View` per node.

---

## 6. Duplicate finder — a three-stage funnel

Hashing everything is the naive failure mode (hours, and it thrashes the disk).

1. **Group by exact size.** ~99% of files are eliminated here, for free — you
   already have every size from the scan.
2. **Hash head+tail 4 KB** of each survivor (xxHash3 or BLAKE3). One `pread` each.
3. **Full-content hash** only for groups still colliding. Stream at 1 MB chunks,
   parallel across files.

Then two refinements that separate a good tool from a bad one:
- **Skip APFS clones** — they're byte-identical but share blocks; deleting one
  frees nothing. Flag them as "clones (no space savings)".
- **Rank which copy to keep** — prefer the one in a non-`Downloads` path, the
  oldest `btime`, the one not inside a `.app`.

---

## 7. Cleanup, safely

Deleting user files is the part where a bug is unforgivable. Rules:

- **`FileManager.trashItem`, never `unlink`.** Recoverable by definition.
- **Staged queue.** Nothing is deleted at add time; the user reviews a list with
  total reclaimable size, then confirms once. (This is DiskBuddy's "Add to
  Cleanup" → review → delete flow, and it's the right one.)
- **Hard denylist**: `/System`, `/usr` (except `/usr/local`), `/bin`, `/sbin`,
  `/Library/Apple`, anything on a read-only volume, any bundle of a currently
  running process (`NSWorkspace.runningApplications`), active mail/photo stores.
- **Show the true reclaim number** — sum `allocated`, not `logical`, and subtract
  hardlink duplicates and clones. Nothing destroys trust faster than promising
  34 GB and freeing 6.
- Re-check size and mtime immediately before deleting; abort the item if it
  changed since staging.

### "Quick Wins" — the actual feature people buy this for
Rule-based detectors run over the finished arena. Each is a path/name predicate
plus a size floor:

| Detector | Match |
|---|---|
| Downloads | `~/Downloads`, files older than 30d |
| Caches & logs | `~/Library/Caches/*`, `~/Library/Logs/*`, `*/Cache*` |
| iOS Simulators | `~/Library/Developer/CoreSimulator/Devices/*` (unavailable runtimes especially) |
| node_modules | dir named `node_modules`, not nested inside another |
| Build artifacts | `target/`, `build/`, `.next/`, `dist/`, `DerivedData` |
| Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData/*` |
| Large media | > 100 MB, video/audio UTI |
| Big & Untouched | > 40 MB and `mtime` > 1 year |

Each detector is ~10 lines and independently testable. This is the highest
value-per-line feature in the whole app.

### "Uninstall Completely"
Given an `.app`: read `CFBundleIdentifier`, then sweep for that id (and the app
name as a fallback) across:
`~/Library/{Application Support, Caches, Preferences, Containers, Group Containers,
Saved Application State, Logs, HTTPStorages, WebKit, Cookies, LaunchAgents}`,
the `/Library` equivalents, and `pkgutil --pkgs` receipts.
Rank each hit by confidence (exact bundle-id dir = high, name substring = low) and
**let the user uncheck the low-confidence ones**. Never auto-delete a fuzzy match.

---

## 8. Monitor tab

Cheap to build, disproportionate perceived value.

- **CPU / memory**: `host_statistics64(HOST_CPU_LOAD_INFO / HOST_VM_INFO64)`.
- **Per-process disk I/O**: `proc_pid_rusage(pid, RUSAGE_INFO_V4, …)` →
  `ri_diskio_bytesread` / `ri_diskio_byteswritten`. Diff across a 1 s tick to get
  a rate. Works without privileges for your own user's processes; other users'
  need root. This is exactly how "which app is writing to my disk" gets built.
- **Network**: `getifaddrs` byte counters, diffed.
- **Free space**: poll volume resource keys every 2 s; animate the meter during
  cleanup.

Note: `proc_pid_rusage` disk counters are **lifetime totals**, so the first tick
has no rate — show "—" rather than a spike.

---

## 9. Visual design (from the screenshots)

The aesthetic is a deliberate anti-utility look, and it's most of the $19:

- Warm paper ground (~`#F7F3EC`), never pure white. Theme picker literally
  labelled "Paper".
- Muted desaturated pastels for folder cards, each folder hashed to a stable hue
  so the same folder is the same color across views and sessions.
- Near-black pills for the active tab/segment; everything else is unfilled.
- **Tabular figures everywhere** for sizes (`.monospacedDigit()`), right-aligned.
- Three-pane: left rail (disk gauge + Quick Wins + file-type bar), center
  (view switcher + canvas), right (inspector + actions).
- Sizes are humanized aggressively — `68.4 GB`, never `68,412,334,081 bytes`.

---

## 10. Build phases

**Phase 0 — prove the number (1–2 days).**
A Swift command-line tool: `getattrlistbulk` + flat arena + parallel deque.
Print total size, file count, elapsed, and top 50 items. Benchmark against your
own home folder. If you can't hit ~150k files/s here, no UI will save it. **Do
not write a single line of UI before this passes.**

**Phase 1 — one view, real data.** SwiftUI shell, Folders view, inspector,
security-scoped bookmarks, Reveal in Finder. Ship-shaped but one view.

**Phase 2 — the free wins.** Top Sizes + Age Map (counters in the scan loop),
file-type breakdown, disk gauge, Quick Wins detectors.

**Phase 3 — the pretty ones.** Squarified treemap, then sunburst/flame (one
layout, two coordinate systems), then bubbles/mind map.

**Phase 4 — actions.** Staged cleanup queue, trash, Uninstall Completely.

**Phase 5 — the rest.** Duplicates funnel, Snapshots (serialize + diff the arena),
Monitor tab.

**Phase 6 — ship.** Notarization, hardened runtime, FDA onboarding flow,
Sparkle updates, license-key check.

---

## 11. If this is going to market, not just a clone

DiskBuddy is $19 with 8 views and a clean cleanup flow. A straight clone competes
with GrandPerspective (free), DaisyDisk ($10), OmniDiskSweeper (free), CleanMyMac
(subscription). Angles that are actually open:

- **Developer-first.** The Quick Wins list already leans this way (node_modules,
  DerivedData, simulators). Go all the way: per-project reclaim view, "this repo
  costs you 14 GB", Docker/`.venv`/Rust `target`/Gradle caches, a
  `diskbuddy clean --dry-run` CLI for CI.
- **Growth over snapshots.** Nobody does "what grew since last week" well.
  Snapshot diffing is cheap given the arena format, and it's the question people
  actually have.
- **Honest reclaim accounting.** Clone- and hardlink-aware "you will actually free
  X" is a real differentiator, because every competitor over-promises.

---

## 11.5 Build log — what actually got built, and what bit

Phases 0–3 are implemented. Three things worth recording because they cost real
time and none of them were predicted by the design:

**The root node has no metadata.** `appendRoot` creates node 0 before the scan
starts, so its `mtime`/`crtime` stayed 0 and the inspector cheerfully reported
the user's home folder as "Modified 56 years ago". Fixed by `lstat`-ing the root
and back-filling (`setRootMetadata`).

**Never publish a partial tree.** Exposing `scanner.store` mid-scan for "live
visualisation" looks like a feature and is actually a bug: `subtree` sizes are
only meaningful after `rollUp()`, so every folder rendered as 0 B and the grid
sorted by noise. Live feedback now comes from the progress counters only, and
the tree is published once, complete.

**Derive layouts, don't store them.** The treemap and sunburst layouts first
lived in `@State`, refreshed from `onAppear` + `onChange`. The sunburst then
rendered its hub and no arcs — *intermittently*. Moving the algorithms into
`ScannerCore` as pure functions proved the maths was fine (703 arcs, sweep
6.275 of 6.283 rad), which located the fault in the SwiftUI wiring. `.task(id:)`
narrowed it but did not close it. The fix was to stop treating a derived value
as state: layouts are now computed inside `body` through a small key-based memo
(`LayoutCache`), so what gets drawn always matches the current inputs.

The general lesson, and it generalises past this app: when a value is a pure
function of other state, storing a second copy of it creates a staleness bug
that reproduces only sometimes. Extracting the pure part into a testable library
is what turned an intermittent UI bug into a five-second headless check.

---

## 11.6 Second build log — the remaining views, Monitor and Applications

**Verify the algorithm before you debug the UI.** After the sunburst episode in
§11.5, every new layout was written as a pure function in `ScannerCore` and
checked from the CLI *before* a view existed: flame rows span 978.7 of 980 px,
bubbles report zero sibling overlap, the mind map builds four depths. All three
then worked first time in SwiftUI. The five-second headless check is worth more
than an hour of screenshotting.

**Mach ticks are not nanoseconds.** `proc_taskinfo.pti_total_user` and
`pti_total_system` are in mach absolute-time units, despite reading like
nanosecond counters. Treating them as nanoseconds under-reported every process's
CPU by the timebase ratio — 125/3 on Apple silicon, so roughly 42x. The symptom
was subtle and easy to ship: a plausible-looking process list where the busiest
app used 0.7% CPU while the load average sat at 2.3. Multiply by
`mach_timebase_info().numer / .denom`.

**`FileManager.enumerator` was both slow and wrong.** Measuring 51 app bundles
took ~40 seconds cold, and `.skipsPackageDescendants` silently skipped nested
packages — Xcode came out as 2.89 GB against `du`'s 4.31 GB, a 1.4 GB
under-count. Rewriting the walk on `getattrlistbulk` and parallelising across
bundles took it to 1.8 s *and* made it agree with `du` exactly. The same
primitive that the scanner is built on was the answer here too.

**Discovery is the safe half of uninstalling.** Docker is 2.12 GB of bundle and
13.29 GB of leftovers; showing that is most of the value and carries no risk.
The removal path is deliberately conservative: only exact bundle-ID matches are
pre-ticked, name-only matches are shown but left unticked, protected prefixes are
refused outright, a running app raises a warning, every item is re-measured
immediately before the move, and nothing is unlinked — it all goes to the Trash,
so the reported "freed" figure is recoverable.

---

## 11.7 Third build log — the duplicate funnel

Built as specced in §6, and the funnel's economics hold up. On a 2.28M-file home
folder: **823,921 files shared a size with something else, 396,576 survived the
head/tail hash, and 57,144 groups were confirmed** — 19.20 GB genuinely
reclaimable, from 62 GB hashed in 165s. Hashing everything would have meant
reading 405 GB.

**The clone count is the whole argument for this design.** That scan found
**162,638 APFS clones** — byte-identical files that share their blocks. A tool
that stops at "same content" would have offered all of them as free space and
delivered almost none of it. The reclaimable figure excludes every clone and
every keeper, so it is what the disk will actually give back.

Verification is a fixture, not a screenshot: five same-size files — an original,
a `cp -c` clone, a real copy, a hardlink, and a same-size file with different
bytes. The funnel must report 8 MB reclaimable rather than 16, drop the hardlink
at stage 1, and kill the different file at stage 2. That test is now in
`scripts/verify.sh` and is the most valuable regression guard in the project.

Two bugs worth recording:

**Parallelise across the work, not within each unit.** The first version called
`DispatchQueue.concurrentPerform` once per size-group. Most groups hold two or
three files, so with hundreds of thousands of groups the thread-pool setup cost
dwarfed the reads. Flattening every candidate into one array and issuing a
single chunked parallel pass cut `~/Documents` from 21.6s to 15.9s, and much
more than that on a full home folder.

**Cancel has to reach the worker threads.** `Task.cancel()` cannot interrupt the
synchronous work inside `concurrentPerform`. Pressing Cancel returned the UI to
idle while the hash kept running, and starting a new scan then put a second pass
on top of the first — both competing for disk. The fix is an explicit
thread-safe flag checked at every chunk boundary and between stages, plus a
generation counter so a stale run can never publish its result over a newer one.
Any long job driven from a UI needs both halves: a way to ask it to stop, and a
way to ignore it if it answers late.

---

## 12. Sharp edges checklist

- [ ] Firmlink double-count when scanning `/`
- [ ] Hardlink double-count (Time Machine local snapshots)
- [ ] Mount-boundary descent into external volumes
- [ ] `/home`, `/net` autofs hangs
- [ ] Network volumes returning partial attribute sets
- [ ] Files deleted mid-scan → `ENOENT`, must not abort the scan
- [ ] Purgeable space making free-space math disagree with Finder
- [ ] Sparse files mislabelled as compressed
- [ ] Security-scoped resource leak / concurrent-scope limit
- [ ] FDA granted but app not relaunched
- [ ] Unicode-normalization: HFS+/APFS filename comparison (NFD vs NFC) in the
      duplicate finder and path matching
- [ ] Reclaim estimate ≠ actual freed bytes
