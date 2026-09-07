# Build Prompt — Disk Buddy Checker

> **How to use this:** paste everything below the line into a fresh Claude Code
> session opened in this project folder. It is written to be self-contained — an
> agent starting with zero context can follow it. Build one phase per session;
> don't paste the whole thing and ask for "everything at once."

---

## Who you are and what we're making

You are building **Disk Buddy Checker**, a native macOS app that shows a person
exactly where their disk space went and helps them safely get some of it back.

Think of the user as someone whose Mac just said "Your disk is almost full."
They don't know what a `node_modules` is. They want to see, in one glance, what
is eating their 500 GB, and they want to delete some of it without breaking
their computer. Everything you build serves that moment.

The reference product is DiskBuddy (diskbuddy.com) — $19, macOS 14+, 6.2 MB,
scans ~2 million files in about 10 seconds. We're building our own version of
that idea, with a developer-focused angle.

**Read `docs/DESIGN.md` in this repo before writing any code.** It contains the
full technical teardown: how the scanner works, the APFS details, the permission
model, the layout algorithms, and the list of bugs that ruin disk tools. This
prompt tells you *what to build and in what order*; that document tells you
*how the tricky parts actually work*. When the two disagree, DESIGN.md wins on
technical detail and this prompt wins on scope and priority.

---

## The one non-negotiable constraint

The entire architecture exists to hit **200,000 filesystem entries per second.**

That number is why we use `getattrlistbulk(2)` instead of `FileManager`, why the
data model is flat arrays instead of objects, and why rendering culls before it
lays out. If you ever find yourself writing code that touches each file with a
separate syscall, or allocating a Swift object per file, or creating a SwiftUI
`View` per file — stop, you've taken a wrong turn.

**Phase 0 is already done.** `Sources/dbscan` contains a working scanner that
measures 205k entries/sec on a 2.55M-entry home folder, validated against `du`.
Read that code first. It is the foundation; the app is a UI wrapped around it.
Do not rewrite it. Extend it.

---

## Tech stack

- **Swift 6, SwiftUI**, targeting macOS 14+. Universal (Apple silicon + Intel).
- **No third-party dependencies** in the scanning or UI core. The whole appeal of
  this category is a tiny, fast, offline binary. (Sparkle for updates in the
  final phase is the one acceptable exception.)
- The existing SwiftPM package stays as the scanner library; add an Xcode app
  target that links it, or convert to a workspace — your call, but keep `dbscan`
  runnable as a CLI, because it's how we benchmark.
- Runs **fully offline**. No analytics, no accounts, no network calls at all
  except an optional license check much later.

---

## Ground rules for how you work

1. **Verify, don't assume.** After each phase, actually run the app and check the
   numbers against `du -sh`, `ls -l`, and Finder's Get Info. Disk tools that
   report wrong numbers are worse than useless. If something doesn't match, say
   so plainly rather than moving on.
2. **Never claim something works until you've run it.** "Build succeeded" is not
   "it works."
3. **Benchmark after every scanner change.** Run `./.build/release/dbscan ~` and
   compare throughput to the last recorded number. A 30% regression is a bug.
4. **Ask before deleting anything, ever** — in the code (user confirmation) and
   in your own work (don't remove files I wrote without checking).
5. **Small, working increments.** I'd rather have a great Folders view than eight
   mediocre visualizations.
6. When something is genuinely ambiguous, make the sensible call and tell me what
   you assumed. Don't stop and ask about small stuff.

---

# The build, phase by phase

Each phase has a **goal**, the **work**, and a **done test**. Don't start the next
phase until the done test passes.

## Phase 1 — The shell and the Folders view

**Goal:** a real app window that scans my home folder and lets me click through
it, with correct sizes.

**Work:**
- Three-pane window: left sidebar, center content, right inspector. Minimum
  window size around 1000×640; everything must reflow gracefully.
- Wire the existing scanner in. Show live progress while scanning — a
  determinate-ish bar plus "1,204,332 files · 43.1 GB so far". The scan already
  produces partial results; use them, don't wait for completion.
- **Folders view:** a grid of cards, one per child folder, sorted biggest-first.
  Each card shows the folder name, item count, and size. Click to drill in;
  breadcrumb bar at the top to go back up.
- **Inspector (right pane)** for the selected item:
  - Size on disk, logical size, and "Compressed by" when they differ
  - File count, folder count, "% of parent"
  - Modified and created dates, phrased humanly ("4 hours ago", "1 year ago")
  - "Largest inside" — the ten biggest children with proportional bars
  - Buttons: Reveal in Finder, Quick Look, Copy Path
- **Left sidebar:**
  - "Scan Full Mac" button, plus "Home" and "Choose Folder…"
  - Recent scan locations
  - A disk gauge: a ring showing % used, with Total / Used / Free
  - A file-type breakdown bar (Video, Audio, Image, Document, Developer, Archive,
    Other) with sizes
- **Permissions:** when the user picks a folder, save a **security-scoped
  bookmark** so re-scanning later doesn't re-prompt. Hold the security scope at
  the scan root, not per file.

**Watch out for:**
- Free space from `statfs` won't match Finder. Use
  `URLResourceValues.volumeAvailableCapacityForImportantUsage` to match what the
  user sees in Finder, or show both honestly.
- Sizes must be `.monospacedDigit()` and right-aligned, or the columns will
  visibly jitter as numbers update during the scan.

**Done test:** Scan `~/Documents`. The total matches `du -sh ~/Documents` within
rounding. Clicking three levels deep and back works. The inspector numbers are
right for a file I check by hand with `ls -l`.

---

## Phase 2 — The free wins

**Goal:** three more features that cost almost nothing because the scanner
already has the data.

**Work:**
- **Top Sizes view:** a ranked bar list of the biggest items, with three scopes —
  "In this folder", "Biggest files anywhere", "Biggest folders anywhere". Show
  rank, name, file count, % of scan, and size.
- **Age Map view:** two panels.
  - "How old are these bytes?" — a horizontal bar chart across buckets: last 7
    days, 8–30 days, 1–3 months, 3–12 months, 1–2 years, over 2 years. (The CLI
    already computes this.)
  - "Bytes by last-modified month" — a year × month heatmap grid, GitHub-contribution
    style, with a "busiest month" callout.
  - "Big & Untouched" — a side list of files over ~40 MB not modified in a year,
    with a "Stage all for cleanup" button.
- **Quick Wins** in the sidebar: rule-based detectors that run over the finished
  scan. Each is a small path/name predicate and is independently testable:

  | Detector | Rule |
  |---|---|
  | Downloads | `~/Downloads`, older than 30 days |
  | Caches & logs | `~/Library/Caches/*`, `~/Library/Logs/*` |
  | iOS Simulators | `~/Library/Developer/CoreSimulator/Devices/*` |
  | node_modules | directory named `node_modules`, not nested in another |
  | Build artifacts | `target/`, `build/`, `dist/`, `.next/`, `.gradle/` |
  | Xcode DerivedData | `~/Library/Developer/Xcode/DerivedData/*` |
  | Large media | over 100 MB with a video/audio type |

  Each row shows a label, item count, and total reclaimable size, with a
  disclosure arrow into a filtered list.

**This is the highest value-per-line work in the whole project.** People buy disk
tools for Quick Wins. Give it real care.

**Done test:** Quick Wins finds my actual `node_modules` and Rust `target`
folders and the sizes match `du -sh` on them.

---

## Phase 3 — The pretty views

**Goal:** the visualizations that make the app feel worth paying for.

All five read the same tree; only the layout differs. Build them in this order:

1. **Treemap** — squarified treemap (Bruls–Huizing–van Wijk algorithm). Every
   file becomes a sized rectangle.
2. **Sunburst** — concentric rings from the scan root: angle proportional to
   size, radius to depth. Include a ring-count slider (default 7).
3. **Flame** — the same layout as sunburst but in Cartesian coordinates: depth
   downward, size left-to-right. Nearly free once sunburst exists.
4. **Bubbles** — circle packing, nested per folder.
5. **Mind Map** — a radial tree, branches sized by weight.

**The performance trick that makes this possible:** cull *before* you lay out.
Recurse only while a node's rectangle would be larger than about 1 px², then draw
one aggregate rectangle for everything below the threshold. A 2M-node treemap
only has 5–10k visible rects. Do this and layout cost stops depending on file
count.

Start with SwiftUI `Canvas` — it handles 20–50k primitives at 60 fps, which is
enough. Only reach for Metal if profiling proves you need it.

Color: hash each folder's name to a stable pastel hue so the same folder is the
same color in every view and across sessions. Hover highlights and shows a
tooltip; click selects and updates the inspector; double-click re-roots.

**Done test:** Treemap of my home folder renders in under a second and stays at
60 fps while I hover around.

---

## Phase 4 — Cleanup (be extremely careful here)

**Goal:** let people delete things without any chance of disaster.

**Non-negotiable safety rules:**
- **Always `FileManager.trashItem`, never `unlink`.** Everything must be
  recoverable from the Trash.
- **Nothing is ever deleted at the moment it's added.** "Add to Cleanup" stages
  an item. The user reviews the full staged list with a running total, then
  confirms once.
- **Hard denylist**, refuse regardless of what the user clicks: `/System`, `/usr`
  (except `/usr/local`), `/bin`, `/sbin`, `/Library/Apple`, any read-only volume,
  and the bundle of any currently running application.
- **Re-check every item immediately before deleting.** If its size or modified
  date changed since it was staged, skip it and tell the user.
- **Report the honest number.** Sum *allocated* bytes, not logical, and subtract
  hardlink duplicates and APFS clones. Promising 34 GB and freeing 6 GB destroys
  trust permanently. This is our differentiator — every competitor gets it wrong.

**Work:**
- A staged cleanup queue: a reviewable list, per-item remove, running total,
  one confirm step, then a progress sheet and a summary of what was actually freed.
- **Applications tab** with "Uninstall Completely": read the app's
  `CFBundleIdentifier`, then find its scattered leftovers across
  `~/Library/{Application Support, Caches, Preferences, Containers, Group
  Containers, Saved Application State, Logs, HTTPStorages, WebKit, Cookies,
  LaunchAgents}`, the `/Library` equivalents, and `pkgutil --pkgs` receipts.
  Rank each match by confidence — an exact bundle-ID folder is high confidence, a
  name substring is low. **Pre-check only the high-confidence ones** and let the
  user opt into the rest. Never auto-delete a fuzzy match.

**Done test:** Stage a folder I created for the test, delete it, confirm it's in
the Trash and restorable, and confirm the freed number matches what the disk
gauge actually moved by.

---

## Phase 5 — Duplicates, Snapshots, Monitor

**Duplicates tab** — a three-stage funnel, because hashing everything takes hours:
1. Group by exact file size (eliminates ~99% for free — we already have sizes).
2. Hash the first and last 4 KB of survivors.
3. Full content hash only for groups still colliding.

Then two refinements that separate a good tool from a bad one:
- **Skip APFS clones.** They're byte-identical but share blocks on disk, so
  deleting one frees nothing. Label them "clones — no space savings".
- **Suggest which copy to keep**: prefer the one outside `Downloads`, with the
  oldest creation date, not inside an `.app`.

**Snapshots tab** — saving a scan is just serializing the flat arena (compress
with LZFSE). Comparing two scans is a merge-join over sorted paths. Show what
grew, what shrank, what appeared, what vanished. *"What grew since last week"* is
a question nobody answers well — make it the headline of this tab.

**Monitor tab** — cheap to build, disproportionately impressive:
- CPU and memory via `host_statistics64`
- **Per-process disk I/O** via `proc_pid_rusage(pid, RUSAGE_INFO_V4)` →
  `ri_diskio_bytesread` / `ri_diskio_byteswritten`, diffed over a 1-second tick.
  This is how you build "which app is writing to my disk right now."
  Note these are lifetime totals, so show "—" on the first tick instead of a spike.
- Network via `getifaddrs` counters, diffed
- Free space polled every 2 seconds, animating during cleanup

---

## Phase 6 — Ship it

- Full Disk Access onboarding: detect it by trying to open
  `~/Library/Application Support/com.apple.TCC/TCC.db` — `EPERM` means we don't
  have it. Show a friendly explainer with a button that deep-links to
  `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
  **The app must be relaunched after the user grants it** — say so, and offer to
  relaunch.
- Never silently under-report. If directories were skipped, say
  "12,403 items couldn't be read — grant Full Disk Access to include them."
- Hardened runtime, notarization, a signed DMG.
- App icon, About window, keyboard shortcuts, Help menu.
- Sparkle for updates. Optional offline-tolerant license check (works two weeks
  without contacting anything).

---

# Visual design

The look is deliberately warm and un-utilitarian — that's most of what people are
paying for. Match this closely:

- **Background:** warm paper, around `#F7F3EC`. Never pure white.
- **Folder cards:** soft desaturated pastels — dusty rose, sage, butter, lilac,
  clay. Low saturation, high lightness. Hue derived from a hash of the folder
  name so it's stable everywhere.
- **Active states:** near-black filled pills. Everything inactive is unfilled with
  no border.
- **Type:** SF Pro. Sizes always `.monospacedDigit()` and right-aligned.
  Section headers are small, uppercase, wide-tracked, in a muted gray.
- **Numbers are always humanized:** "68.4 GB", never "68,412,334,081 bytes".
- **Generous whitespace.** Cards have big padding and gentle corner radii (~12 pt).
- **Dark mode is required** and must be a genuine warm-dark, not inverted paper.
- Support a theme picker later (the reference app ships a "Paper" theme), but
  build one excellent theme first.

---

# The bugs that ruin disk tools

Check every one of these off. Each has silently wrecked a real product:

- [ ] **Firmlinks:** on APFS, `/Users` and `/System/Volumes/Data/Users` are the
      same bytes. Scanning `/` naively double-counts the entire data volume.
- [ ] **Hardlinks:** count the bytes once, but still show the file in every
      location it appears. Time Machine local snapshots are full of these.
- [ ] **Mount boundaries:** compare `st_dev`; don't wander into external drives
      when scanning `/` unless asked.
- [ ] **`/home` and `/net`:** autofs paths that will hang the scan on a network
      timeout. Never descend.
- [ ] **Symlinks:** never follow. Report the link's own size.
- [ ] **Network volumes** return incomplete attribute sets — always check
      `ATTR_CMN_RETURNED_ATTRS` and fall back to `lstat`.
- [ ] **Files deleted mid-scan** produce `ENOENT`. Skip the entry; never abort.
- [ ] **Sparse files vs compressed files** look identical (allocated ≪ logical).
      Only `UF_COMPRESSED` means compression. Docker and VM images are sparse —
      one such file on this machine is 994 GB logical and 12 GB on disk.
- [ ] **Purgeable space** makes free-space math disagree with Finder.
- [ ] **Unicode normalization:** APFS filenames can be NFD or NFC. Normalize
      before comparing paths, or the duplicate finder will lie.
- [ ] **Security-scoped resource leaks:** there's a limit on concurrent scopes.
      Hold one at the root.
- [ ] **Reclaim estimate ≠ bytes actually freed.**

---

# Where we're trying to win

A straight clone competes with GrandPerspective (free), DaisyDisk ($10), and
OmniDiskSweeper (free). Three angles are genuinely open — weight your effort
toward them:

1. **Developer-first.** Quick Wins already leans this way. Go further: a
   per-project view ("this repo costs you 14 GB"), Docker and `.venv` and Gradle
   and Rust `target` caches, and a `dbscan clean --dry-run` CLI for CI.
2. **Growth over time.** Snapshot diffing is nearly free given our arena format,
   and "what grew since last week" is the question people actually have.
3. **Honest accounting.** Clone- and hardlink-aware "you will actually free X GB."
   Every competitor over-promises. Being the one that doesn't is a real,
   defensible reason to choose us.

---

## Start here

Read `docs/DESIGN.md`, then read `Sources/dbscan`, then run
`swift build -c release && ./.build/release/dbscan ~` so you've seen the scanner
work with your own eyes and know the baseline throughput.

Then build **Phase 1 only**. Show me the running app before going further.
