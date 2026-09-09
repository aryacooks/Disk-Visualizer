<p align="center">
  <img src="docs/art/icon.png" width="128" alt="Disk Visualizer">
</p>

<h1 align="center">Disk Visualizer</h1>

<p align="center">
  <em>Where did 400 GB go?</em><br>
  A fast macOS disk-space visualizer. Eight views of one scan,<br>
  clone-aware duplicate detection, and nothing deleted without your say-so.
</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-000000?style=flat-square">
  <img alt="swift" src="https://img.shields.io/badge/Swift-5.9-F05138?style=flat-square">
  <img alt="speed" src="https://img.shields.io/badge/scan-205k%20files%2Fsec-2ea44f?style=flat-square">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-blue?style=flat-square">
</p>

---

Your Mac fills up and Finder is useless at telling you why. Get Info on a folder
and wait. Sort by size and you get the top of one directory, not the top of your
disk. This scans 2.55 million files in about twelve seconds, then lets you look
at the result eight different ways until the culprit is obvious.

It was built by working out how [DiskBuddy](https://www.diskbuddy.com) does it,
the speed and the layouts and the safety rules, then rebuilding it from scratch
in Swift. `docs/DESIGN.md` is the teardown.

<p align="center">
  <img src="docs/art/folders.png" alt="Folders view showing 404 GB across 2.28 million files">
</p>

## Install

You need macOS 14 or later and the Xcode command-line tools. If `swift --version`
prints something, you're ready. If not:

```bash
xcode-select --install
```

Then:

```bash
git clone https://github.com/aryacooks/Disk-Visualizer.git
cd Disk-Visualizer
./scripts/bundle-app.sh
open "Disk Buddy Checker.app"
```

One script builds the binary, wraps it in an `.app`, and ad-hoc signs it. Drag
the bundle to `/Applications` if you want it to stick around.

<details>
<summary><b>"Apple could not verify this app"</b></summary>

The bundle is signed ad-hoc, not notarized, so Gatekeeper doesn't know it. Right
click the app, choose Open, then Open again. Or:

```bash
xattr -dr com.apple.quarantine "Disk Buddy Checker.app"
```
</details>

<details>
<summary><b>Full Disk Access</b></summary>

Without it macOS silently hides parts of your disk from the scan and your totals
come out too small. The app detects this and shows a banner with a button that
deep-links to the right Settings pane, so it never quietly under-reports.

**System Settings → Privacy & Security → Full Disk Access → +**, then pick the app.

macOS keys these grants to *code identity*, which is why the build script signs
with a stable identifier. Grant it once and every future build inherits it.
</details>

## Dev mode

```bash
./scripts/dev.sh
```

Debug build, bundled, signed, and launched in the foreground, so `print` output
and crash traces come back to your terminal. Ctrl-C quits. Any previous dev
instance is killed first, so you never look at a stale build.

```bash
./scripts/dev.sh --build     # build, don't launch
```

It bundles rather than running `.build/debug/DiskBuddyApp` directly on purpose.
The bare binary does launch, but it has no stable code identity, so macOS treats
every rebuild as a new app and re-asks for Documents, Downloads and Desktop
access every time. The dev bundle carries the same fixed identifier as the
release one, so one grant covers both.

For work on the engine, skip the GUI. This loop is tighter, and it is where
every algorithm bug in the project was actually caught:

```bash
swift run -c release dbscan ~ -n 20
```

## While it scans

<p align="center">
  <img src="docs/art/scanning.png" alt="Scanning screen with a live ring, counters, a files-per-second graph and four named stages">
</p>

A scan takes over the whole window, sidebar and inspector included. Anything
left on screen would be the *previous* scan's numbers, which look live and
aren't. Partial results are worse than stale ones here: subtree sizes don't
exist until the reverse pass runs, so a half-built tree reads 0 B for every
folder and sorts by noise.

Every number on that screen is measured. The counters are the scanner's own and
the graph is real throughput sampled once a second. The ring is honestly
indeterminate, because a filesystem doesn't tell you how big it is before you
have walked it, so a percentage there would be invented.

The four stages are named as they happen: reading, adding up folder sizes,
looking for easy wins, sorting by age. A scan isn't one job, and the last three
used to run behind a spinner that had already stopped moving, so a finished walk
looked exactly like a hang.

## Releasing

```bash
./scripts/release.sh 1.0.0 --publish
```

Builds, signs with a Developer ID, notarizes with Apple, staples the ticket,
packages a drag-to-Applications DMG, and creates the GitHub release. It checks
everything up front and fails loudly rather than dying four minutes into a
notarization.

It needs three things it can't create for you: an Apple Developer Program
membership, a *Developer ID Application* certificate in your keychain, and a
stored `notarytool` credential profile. The script's header walks through all
three. Credentials are read from the keychain by profile name, so no secret is
ever passed on a command line or written into this repo.

The icon is generated from code by `scripts/make-icon.swift`, so it lives in git
as something you can read and tweak instead of an opaque binary. Each of the ten
sizes is drawn natively rather than downscaled: below 128 px the tile grows, the
ring thickens and the pastels deepen, because a design tuned for 512 px turns
into a beige smudge in the Dock.

## What's in it

Eight views, one scan: Folders, Sunburst, Flame, Bubbles, Mind Map, Top Sizes,
Age Map, Treemap. Switching between them is instant, because they are all
projections of the same tree in memory. A branch keeps one colour family
everywhere, with each node shaded within it, so you can see both that Library is
big and that it holds a hundred different things.

It fits in a window. The inspector hides below 1180pt, the sidebar narrows below
1040, and the tab labels drop to icons below 1120. Nothing needs horizontal
scrolling and nothing needs fullscreen.

<table>
<tr>
<td width="50%"><img src="docs/art/sunburst.png" alt="Sunburst view"></td>
<td width="50%"><img src="docs/art/treemap.png" alt="Treemap view"></td>
</tr>
<tr>
<td><b>Sunburst.</b> Every ring is a directory level, every arc sized by what it holds. Hover an arc for its size and share.</td>
<td><b>Treemap.</b> Every file as a rectangle, sized by bytes. Layout culls anything too small to see, so 907k nodes become 11k cells.</td>
</tr>
</table>

Clicking a shape zooms into it. The level you were on grows past you, anchored
on what you clicked, and the next level settles in its place. Back plays the
same motion in reverse.

A click on an outer sunburst arc can drop ten levels at once, so the breadcrumb
is derived from the tree, the real ancestor chain rather than a jump with the
middle missing. It collapses to `root … parent child` once the trail outgrows
the toolbar.

The full path of whatever you are looking at gets its own line under the view
switcher, and clicking it copies the path. Beside it is Up (`⌘↑`), which names
the folder it takes you out to.

Back and forward are a browser history rather than a parent chain. They retrace
where you actually went, which is a different thing once you have jumped via a
breadcrumb, a Quick Win or Home. They take `⌘[` and `⌘]`, and each tooltip names
where it goes. Up walks the tree instead of your route, which is usually what you
want after landing somewhere by clicking a deep arc.

Duplicates run through a three-stage funnel: group by exact size, hash the first
and last 4 KB, then full SHA-256 for the survivors. On a real home folder that is
823,921 same-size files narrowed to 57,144 genuine groups. It knows an APFS clone
shares its blocks and frees nothing when deleted, so it finds them and *excludes*
them. Hardlinks never show up as duplicates at all.

Every scan is saved as a snapshot. 907k nodes take 12.5 MB and load back in
37 ms. Compare any two and see what grew.

Deleting an app leaves caches, preferences, saved state and support files
scattered across 17 Library roots. Uninstall completely finds them and ranks each
by confidence: exact bundle-ID match, app name, or a name fragment.

The Monitor tab covers CPU, memory, network, per-process disk I/O, and on-die
temperatures in Celsius, plus battery health and cycle count.

<p align="center">
  <img src="docs/art/monitor.png" alt="Monitor tab showing CPU, memory, network, storage, temperature and battery with all 44 sensors listed">
</p>

## Nothing gets deleted

Every path that can remove something follows the same rules, no exceptions:

- Files are moved to the Trash with `trashItem`, never `unlink`. Everything is
  recoverable.
- Nothing is removed when you stage it. A review sheet with a running total and
  an explicit confirm always comes first.
- Every item is re-measured and re-checked at the moment you confirm, not when
  it was queued.
- A hard denylist (`/System`, `/bin`, `/sbin`, `/Library/Apple`, `/usr` except
  `/usr/local`, your home root, volume roots) can't be staged at all, whatever
  the UI does.
- Duplicates starts with nothing ticked, never pre-selects a keeper or a clone,
  and refuses to empty a group of its last copy.
- Only exact bundle-ID matches are pre-ticked when uninstalling. Name-only
  matches are shown, unticked, for you to judge.
- Running apps are detected and skipped.

## How it's fast

The whole design follows from one number: 200,000 entries per second.

The usual approach, `readdir` then `lstat` on every entry, costs two or more
syscalls per file. At 2.5 million files that is five million context switches and
you have already lost. `getattrlistbulk(2)` returns a batch of entries *and*
their metadata in a single call, roughly one syscall per 50 to 200 entries.

Results go into a flat struct-of-arrays arena: parallel `parent`, `childStart`,
`logical` and `mtime` arrays plus one contiguous UTF-8 blob of names, at about 55
bytes a node against 150 to 250 for a class-per-node object graph. Children are
always allocated after their parent, so subtree totals fall out of a single
reverse pass in O(n).

Layouts cull before they lay out: recursion stops when a rectangle is too small
to see. That is how 907,000 nodes become 11,159 treemap cells, and why layout
cost barely depends on file count.

Measured on a 2.55M-entry home folder: 205k entries/sec warm, and totals that
match `du` exactly.

## Verifying

```bash
./scripts/verify.sh
```

Eight checks: scanner totals against `du` including hardlink de-duplication, all
five layout algorithms, the duplicate funnel against a purpose-built fixture, the
snapshot round-trip and self-diff, the temperature sensors, the system sampler,
and app bundle sizes against `du`.

The duplicate fixture is the sharpest test here. It builds five files of
identical size: an original, an APFS clone (`cp -c`), a genuine copy, a hardlink,
and a same-size file with different bytes. The funnel has to report 8 MB
reclaimable, not 16 MB. The hardlink never appears, the different file dies at
stage 2, and the clone is found but excluded because deleting it would free
nothing.

## Layout

```
Sources/ScannerCore/     the engine, no SwiftUI, so it is testable headlessly
Sources/DiskBuddyApp/    the SwiftUI app
Sources/dbscan/          the CLI, which doubles as benchmark and test rig
docs/DESIGN.md           how it works, and the bugs that ruin disk tools
docs/BUILD_PROMPT.md     the phase-by-phase build brief
scripts/                 bundle-app.sh, dev.sh, verify.sh
```

Every layout algorithm and every scanner behaviour lives in `ScannerCore` as a
pure function, provable from the command line before any pixel is drawn. That
wasn't the original plan. It is what the sunburst taught us after it spent an
afternoon rendering its hub and nothing else, while the algorithm behind it was
correct the whole time.

## License

MIT.
