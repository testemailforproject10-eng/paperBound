# Paperbound

A native iOS PDF reader with optional **Enchanted Ink** and **Footsteps**.
Pages retain the PDF's original colors on a plain white surface. No paper
textures, wear, cuts, marks, lighting, tint or decorative book presentation are
applied. Both effects are off on a fresh install and operate only when enabled.
The imported file is never modified.

Built and tested with **Xcode 27.1 / iOS 27.1 SDK**, deployment target **iOS 18.0**,
iPhone and iPad. 27.1 is required rather than preferred: `UIHingeInteraction`
exists only in that SDK, and the iPhone Duo posture code compiles against it.
Everything it drives is behind `#available(iOS 27.1, *)`, so the app still runs
back to iOS 18 — it just falls back to display observation there. The Swift 6.4 toolchain in **Swift 5 language mode**: the
concurrency boundaries are drawn deliberately (`@MainActor` engines, a
queue-confined PDF worker, `Task.detached` for compositing) rather than being
inferred by the compiler, and moving to Swift 6 mode is a follow-up worth doing
on its own rather than as a side effect of a feasibility build.

---

## Scope of this build

The brief says to begin with a feasibility prototype rather than a wall of
stubs, so this is milestones **0 through 5** of the roadmap, built for real,
plus the reader-depth features PDFKit supports natively.

| Gate | Status |
|---|---|
| **0 — feasibility spike** | Done. Tears remove real content; the native selection/search path is preserved as a separate mode. |
| **1 — PDF reader** | Done. Files import, page turns, zoom, reopen at the same page, shelf. |
| **2 — effects** | Optional Enchanted Ink and three Footsteps trails, with previews and replay. |
| **3 — legacy wear** | Removed from the live reader. Old saved styles are normalized to plain pages. |
| **4 — page rendering** | Plain pages, automatic Duo spreads, bounded visible-page cache. |
| **5 — device adaptation** | Partial, honestly. Layout preserves position across resize/rotation and includes iOS 27.1 hinge and reserved-region integration. The Xcode 27.1 Duo simulator suite passes; hands-on posture checks remain. |
| **6 — EPUB parity** | **Not built.** `ReadingEngine` is the seam it plugs into. |
| **7 — reader depth** | Search, outline, bookmarks, and text-to-speech are done. Highlights have a model but no selection UI yet. |

### What is deliberately absent

* **EPUB / Readium.** Adding a half-working reflowable engine would have cost
  more than it proved. The abstraction it needs (`ReadingEngine`,
  `ReadingLocation`, `stablePageID`) exists and is documented, including the
  rule for where wear lives when text reflows.
* **Hands-on Duo QA.** Automated iOS 27.1 simulator tests pass; posture transitions and real-book visuals still need device review.
* **Backend, accounts, bookstore, AI, CloudKit.** As instructed.

---

## Build and run

```bash
open Paperbound.xcodeproj          # then ⌘R
```

or from the command line:

```bash
xcodebuild -project Paperbound.xcodeproj -scheme Paperbound \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Duo' build

xcodebuild -project Paperbound.xcodeproj -scheme Paperbound \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Duo' test
```

If several Xcodes are installed, point the toolchain at 27.1 first — under 27.0
the build fails on the `UIHinge` symbols, which is the correct failure rather
than a silent fallback:

```bash
sudo xcode-select -s /path/to/Xcode-27.1.app/Contents/Developer   # permanent
DEVELOPER_DIR=/path/to/Xcode-27.1.app/Contents/Developer xcodebuild …  # one-off
```

Both scripts below check this for you and stop with the fix if the active
toolchain is too old.

### Reproducible simulator steps

1. Launch on any iPhone simulator. The shelf is empty.
2. Tap **Add the sample book**. Paperbound generates a six-page PDF (real text,
   one vector figure) and imports it. Alternatively **Import a PDF** and pick
   any PDF from Files.
3. Open the book. It opens in **Physical** mode with plain pages and both effects off.
4. Tap the middle of the page to show controls, then **⋯ → Reading environment**.
5. Choose **Text effects → Enchanted Ink**, then use **Replay effect** in the
   preview.
   Turn on **Page effects → Footsteps** to see three wandering trails;
   **Replay footsteps** resets only that preview.
6. Tap **Pristine** in the top bar. PDFKit's own view appears: text is
   selectable, search highlights, pinch zoom is real. Tap **Physical** to go
   back to the effects-capable reader.
7. Swipe back and forward several pages and return. Every page is identical to
   how you left it.
8. Rotate to landscape on iPad, or run the iPad Pro simulator: the reader opens
   into a two-page spread on the same page you were reading.
9. Use **Use for new books too** to save the current reading settings as your default.

### Capturing the reader screen without tapping

Debug builds accept a launch argument that installs the sample book and opens it
straight into the reader, which is how the reader screenshots below were taken:

```bash
xcrun simctl launch booted com.paperbound.reader \
    -paperbound-demo -paperbound-demo-page 3
xcrun simctl io booted screenshot reader-plain.png
```

`-paperbound-demo-page` is 1-based. Add `-paperbound-demo-ink` or
`-paperbound-demo-footsteps` to opt into those effects for a demo.
The hooks are inside `#if DEBUG` and do nothing in release builds.
Condition and theme launch overrides have been removed. Styled screenshots in
`./Screenshots` are historical fixtures, not the current live reader.

### Comparison screenshots

```bash
./make-snapshots.sh              # or: ./make-snapshots.sh "iPad Pro 13-inch (M5)"
```

This runs `SnapshotComparisonTests`, which renders **the same page of the same
book at the same size** under every page condition, plus one material sweep, and
copies the PNGs to `./Screenshots`:

```
text-page3-pristine.png      figure-page5-pristine.png     material-white.png
text-page3-lightWear.png     figure-page5-lightWear.png    material-cream.png
text-page3-wellLoved.png     figure-page5-wellLoved.png    material-aged.png
text-page3-damaged.png       figure-page5-damaged.png      material-parchment.png
                                                           material-dark.png
```

The four `text-page3-*.png` images differ only in condition, so they are a fair
before/after: hold them side by side and the same words disappear under the same
tears at the same coordinates.

Screenshots of the running app sit alongside them. These cannot come from the
test — they have to be taken off a live simulator — so they have their own
script, which opens the reader by launch argument rather than by tapping, and so
lands on the same page in the same environment every run:

```bash
./make-app-captures.sh           # or: ./make-app-captures.sh "iPhone 17" "iPhone Duo"
```

```
app-reader-physical-damaged.png     page 3, composited and heavily worn
app-reader-pristine.png             the same page, every word restored
app-duo-cover.png                   the Duo's cover display, HUD showing
```

One more is deliberately *not* in that script, because it cannot be scripted:

```
app-duo-inner-spread.png            the inner display, unfolded, HUD showing
```

Unfolding is a manual step in the 27.1 DeviceHub. With the device open:

```bash
xcrun simctl io <device> enumerate      # find the 2007 × 2853 display's UUID
xcrun simctl io <device> screenshot --display <uuid> Screenshots/app-duo-inner-spread.png
```

`make-snapshots.sh` deletes and rewrites only the images it renders, so running
it does not take these with it.

---

## Architecture

```
Paperbound/
├── App/           PaperboundApp, RootView
├── Model/         Book · Bookmark · Highlight (SwiftData)
│                  ReadingEnvironment · PageDamage · ReadingLocation
├── Engine/        ReadingEngine (protocol)
│                  PDFReadingEngine  → navigation, search, outline, text
│                  PDFDocumentWorker → background rasterizing, confined to a queue
├── Render/        SeededGenerator  → SplitMix64 + FNV-1a (stable hashing)
│                  DamageGenerator  → (book, sheet, environment) → defects
│                  RaggedPath       → torn geometry
│                  PaperTexture     → procedural stock
│                  PageCompositor   → the layered sheet
│                  PageRenderCache · PageImageProvider
├── Reader/        ReaderViewModel · ReaderView · PagedReaderView
│                  PhysicalPageView · NativePDFReaderView
│                  EnvironmentEditorView · SearchPanelView · ContentsPanelView
│                  SpeechController
├── Library/       LibraryStore · LibraryEnvironment · SampleLibrary
│                  LibraryView · BookTileView · SettingsView
├── Layout/        DeviceLayoutCoordinator
└── Support/       AppSettings · RGBAColor · Info.plist
```

The three responsibilities stay separate, as the brief requires:

* **Engines** own content and navigation. They never know what paper looks like.
* **The environment renderer** owns appearance. It asks the engine for pixels
  and never asks it to change.
* **The layout coordinator** decides how many surfaces are visible. It owns
  neither content nor appearance, and it never owns reading position.

---

## The reading environment

The editor and app defaults expose **Text effects** and **Page effects → Footsteps**.
Instant text and disabled Footsteps are the defaults. Enchanted Ink and Footsteps
are independent opt-in effects, remembered per book and in app defaults.
Presentation, lighting, surface/material, condition, marks, presets and motion
are removed from the live rendering path. Old saved books and defaults retain
their two effect selections while their legacy styling is discarded. Adaptive
Duo layout remains automatic; hidden saved page-layout preferences are ignored.
The reader and preview use a plain compositor: normal source-image drawing over
white, with no procedural paper or damage generation. Source PDF artwork and
colors, including any decoration already inside the PDF, remain intact.

The following describes the legacy fixture compositor, retained for old-data
decoding and regression tests. It does not style pages in the app.

The legacy environment format retains four independent dimensions plus an intensity:

```
PaperMaterial  ×  PageCondition  ×  BookPresentation  ×  LightingStyle  ×  0…1
white              pristine          minimal              flat
cream              lightWear         paperback            warm
aged               wellLoved         hardcover            directional
parchment          damaged           oldJournal           posture-reactive
dark
```

### Legacy compositing order

```
neighbouring sheets in the stack
    ↓
the sheet directly below          ← what a hole reveals (never a black void)
    ↓
shadow cast by the torn edge onto that sheet
    ↓
paper material of the current sheet
    ↓
the document's own pixels, clipped by the cut mask   ← where content is removed
    ↓
stains, foxing, creases
    ↓
fibre halo along every cut: bright core, loose fibre, worked-in dirt
    ↓
lighting: tint, sweep, vignette, spine
```

A hole opens onto a second sheet that is darker, offset, and carries a 12%
ghost of type, so it reads as the next leaf rather than as a hole in the world.

### Determinism

Wear is generated, never stored — but it must be *the same* every time.

* `SplitMix64` seeded from `FNV-1a(documentID) ⊕ bookSeed ⊕ FNV-1a(pageID) ⊕
  FNV-1a(environment.damageIdentity)`. Swift's own `Hasher` is randomly seeded
  per process and would move every tear on every launch, so it is not used.
* The random stream is consumed in a **fixed order**. New defect kinds get
  appended and `generatorVersion` is bumped rather than inserted in the middle.
* `damageIdentity` deliberately **excludes** material, presentation, lighting
  and the environment's id. Changing the paper stock or the lamp must not
  shuffle a single tear — there is a test for exactly that.
* Every coordinate is normalized page space (0…1, origin top-left) and scaled by
  the sheet's *shorter* side, so nothing drifts under zoom, rotation or a
  different render resolution.
* Each imported copy gets its own `wearSeed`, so two people reading the same PDF
  have differently worn books. **⋯ → New wear pattern** re-rolls it.

### Paper texture

Procedural, in three octaves: broad mottling, directional fibre, fine grain.
Not a packaged photograph of a vintage page — one scan repeats visibly across a
book, and shipping third-party paper scans without a licence is not an option.
`PaperTextureFactory` is the single place to change if licensed scans are
acquired later.

---

## Rendering and interaction risks, addressed

The brief flags these specifically.

**Selection, search and accessibility under the mask.** The composited page is a
bitmap and cannot be selected. That is why there are two modes, not two styles:
**Pristine** is PDFKit's own `PDFView` with nothing masked — real selection, real
search highlighting, real zoom, real VoiceOver. It is one tap from anywhere and
it shows the complete document. Search and read-aloud work in *both* modes
because both run against the engine's text layer, never against pixels.

**Thread safety.** `PDFDocumentWorker` keeps its **own** `PDFDocument` for the
same file, confined to one serial queue, separate from the instance `PDFView`
uses on the main actor. PDFKit objects are not documented as thread-safe; paying
for a second lazy handle removes the whole class of "rasterized while scrolling"
crashes. Rasterizing and compositing always run off the main thread
(`Task.detached`); the main actor only computes cache keys and hands back
finished bitmaps. Opening records the page count without enumerating every
page's crop box. Aspect ratios are read and cached only when those pages enter
the reader; the PDF outline is parsed when Contents is opened.

**Memory.** `PageRenderCache` enforces a 96 MiB cost limit and drops everything
on a memory warning. Render size is capped at ~4.2 megapixels per sheet regardless
of display scale. Cache keys are bucketed to 8px so layout jitter cannot thrash
them. Procedural paper textures are not generated by the reader.

**Enchanted Ink.** This optional per-book effect begins with blank paper. Faint
ink spreads and deposits inside printed shapes. Seeded moisture sources and
fixed fibre permeability produce repeatable patches, while each
page takes a different 3-to-4-second interval. Both pages in a spread
start together and fill independently.
Enabling the effect plays the editor preview immediately and starts the open page
or spread after settings finish dismissing. The inline Instant/Enchanted Ink
selector, thumbnail, and Replay effect button stay together so playback remains
visible while choosing an effect. Selection, replay, and returning to the preview
create fresh GPU visits, including when the page images are cached. Reduce Motion
shows finished print and an explanation in settings. The slider previews the selected
page number while dragging and navigates once on release. Edge taps, slider
commits, and native scroll observations share a paging coordinator; each arrival
gets one visit, with simultaneous spread starts after GPU readiness. Disabling
ink shows finished content immediately. Preparation and completion callbacks
must match the page, raster identity, and visit. Layout settling and controls
must not create extra visits. At normal scale the native scroll view owns
horizontal scrolling; the custom pan gesture is enabled only while zoomed.
The compositor builds a finished page and matching clean paper, publishing paper
before completing the second pass.
The preparation background is plain white; source PDF colors are preserved.
A SwiftUI-wrapped [MTKView](https://developer.apple.com/documentation/metalkit/mtkview)
uses persistent, alternating Metal textures for moisture, mobile pigment and
per-channel deposited pigment. GPU initialization derives immutable optical-density
targets and print boundaries from the image pair. Neighboring printed pixels
exchange mobile pigment; local reservoirs supply disconnected letters. Rendering
uses deposited optical density over paper, plus additive light pigment. There is
no arrival map, animated finished-image blend, CPU pixel readback, or PDF work
during animation. A shared 60 Hz scheduler runs bounded fixed steps and stops
when finished or offscreen. Paper remains visible with a spinner until both
visible pages' GPU sessions are ready; prefetch never advances a simulation.

The paired CPU images share a strict 96 MiB cache, with speculative entries
evicted first. One speculative job runs at a time, yielding priority to visible
pages. GPU admission allows at most two sessions within 64 MiB, accounting for
uploaded inputs, targets and both state buffers. Raster sizing checks that same
aligned allocation estimate after 8-pixel cache bucketing, reducing the common
scale before rendering if necessary. Admission waits at most one second for
retiring sessions before recording an error and showing finished content. Opening
a panel completes covered reader sessions so its preview does not compete with
a hidden spread. Instant-only reading does not prewarm Metal.
Effect pages use an 850,000-pixel
cap before rendering, with a floor of one raster pixel per displayed point;
moisture alone is capped at 512 pixels on its longest edge. If the minimum
resolution cannot fit, an explicit resource error shows the finished page.
Retiring sessions release their leases before new sessions are admitted.
Drawables and temporary upload scratch memory are measured separately.
No OCR or handwriting reconstruction is involved; scanned print and
illustrations use their raster pigment. The reader
uses the iOS 27.1 SwiftUI reserved-region geometry for Duo division and camera
occlusion areas, with the existing safe-area layout on earlier systems. See
Apple's [Duo adaptive-layout guidance](https://developer.apple.com/videos/play/tech-talks/111463/),
[hinge and display guidance](https://developer.apple.com/videos/play/tech-talks/111464/),
and the [27.1 beta release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode_27_1_release-notes).
Hinge updates affect layout and shading only; page visibility and elapsed time
drive ink flow, so folding does not advance the book or start an animation.

**Footsteps.** This optional page overlay uses a matched pair of small worn
shoe-print stamps, based on the marks on an old hand-drawn map. Three walkers
leave independent trails of alternating translucent prints every 0.40–0.55
seconds, follow seeded curved routes, and pause briefly between segments. Their
starting points are spread across the visible paper, and the shared Canvas keeps
at most 32 live prints. Prints settle in 120 ms and disappear
by 3.5 seconds; they never alter the PDF or the composited page. One Canvas spans
the visible page unit, including side-by-side or stacked Duo spreads. Its route
crosses the fold in time but stamps only on paper, clear of reserved display
regions. It starts when both visible sheets report paper ready, independently of
the ink GPU session. Turning Footsteps on or off does not invalidate image caches
or restart Enchanted Ink. Reduce Motion suppresses it. The editor uses the same
route controller and renderer at thumbnail scale, with its own replay button.

**Preview validation (2026-09-30).** The settings regression operates the actual
segmented picker in the full reader's sheet and verifies the thumbnail stays
inside the visible scroll area. Captured GPU frames show blank paper, partial
pigment after about one second, and finished print. Pixel assertions require
substantial partial density, not just an active GPU session. Tests also cover
cached reselection, Replay, foreground return, reopening settings, and the reader
animation after dismissal. Two booted Duo instances were found; one still ran a
September 28 app build. Both were updated to the verified build without removing
their app data.

**Sample-book opening profile (2026-09-30).** On Duo instance
`97A96543-D458-4F98-8BC4-570B4F9B2E56`, the previous 776 × 1096 raster exceeded
the aligned per-page GPU reservation and failed initialization on both pages.
The shared sizing calculation now selects 768 × 1096 for that geometry. In two
fresh-process runs of the updated app, measured from reader opening, paper
appeared in 284–333 ms and the first simulated frame in 457–478 ms. GPU admission
wait was 0 ms; initialization was 17.6–27.1 ms per page, with no fallback. These
are sample-document simulator observations, not physical-device percentiles.
The intended 3–4-second animation starts after preparation. The Instant run
did not initialize Metal. Tests cover aligned sizing across Duo geometries,
both full-size sessions, bounded admission waits, and releasing failed leases.
A subsequent optional startup-flash change was withdrawn after its follow-up
run on the other simulator stalled and failed. The retained loading changes are
the version that passed the 229-test suite on the user-facing Duo instance.

**Navigation validation (2026-09-30).** All 229 tests passed with the builds
below, including two full-reader scenarios at phone size and on the Duo spread.
Each scenario produced five completed GPU visits; tests inspect actual first-ink
render callbacks rather than manually supplying activation. The native pager
accepts continuous scroll input, and direct scroll geometry changes activate ink
without scroll-phase callbacks. A simulator recording was inspected for partial
ink and sharp completed content. Device Hub UI automation timed out. The user
previously confirmed trackpad swipes worked, but later reported they stopped
working on the other Duo instance; physical trackpad input remains unresolved
pending a fresh observation on the updated app. Apple's [Xcode 27 beta notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
describe forwarding trackpad scrolling to standard UIKit components. Native
scroll tests alone do not verify that forwarding. A separate live-app launch also logged simultaneous ink activation and
completion. Touch-drag input and hands-on folding remain pending; native scroll
tests do not establish those input paths. Metal validation was enabled;
there were no Metal validation failures. The full-reader run also reported the
existing AVAudioSession main-thread warning from speech setup/teardown.

**27.1 validation.** The full simulator test suite passes with Xcode 27.1 (build
27A9269), the iOS 27.1 Simulator SDK (build 24A94403), and the iPhone Duo 27.1
runtime (build 24A94401). Tests exercise actual compute/render kernels, a hosted
MTKView scheduler, deterministic stepping, neighbor isolation, monotonic deposits,
light print, endpoints, cancellation and resource release. Captures at 0%, 25%,
50%, 75%, 98.5% and 100% cover generated text, illustration, image-only PDF,
damaged and dark-paper fixtures, with enlarged text details. Existing simultaneous
spread, delayed-readiness, stale-visit and Duo layout tests remain in the suite.
Footsteps tests cover deterministic walking, alternating cadence, stride, Duo
gutter crossing, reserved regions, three independent trails, settling and fading, bounded live prints,
paused time, stale paper callbacks, and backward-compatible settings decoding.
Live Duo captures show a trail crossing from the left paper to the right, plus
light stamps on the dark illustrated unmatched final page; the
initial-layout callback race found during that check is covered by re-reporting
paper readiness to the current visit. Physical-device frame cost and folding
mid-crossing remain to be measured on hardware.

With the plain reader on September 27, the Duo launch trace measured white-page
fill at 0.9–1.5 ms and finished-page drawing at 11.7–16.1 ms per page, at roughly
1368–1416 × 2008 pixels. This sample excludes GPU initialization and is not a
physical-device loading benchmark. The prior procedural paper path is no longer
used by the app.

Historical simulator measurements with the legacy styled compositor on
September 25, 2026 (MacBook Pro host):

| Measurement | Result | Scope |
| --- | --- | --- |
| Previous CPU flow preparation test | 4.275 s | Two 600×800 compositor preparations |
| GPU-input compositor test | 0.141–0.142 s | Same geometry/fixture; excludes PDF and GPU initialization |
| Warm GPU initialization p95 | 16.8–17.5 ms | 20 preparations per run at 768×1104 |
| Spread compute + rendering p95 | 3.1–4.3 ms wall; 0.33–0.40 ms reported GPU | 40 frames per run, three steps per page, no readback |
| Input preparation | 186–200 ms | Four uncached sample PDF pages per run at 768×1104 |
| Paper ready | 150–161 ms | Same uncached requests, before finished composition |
| Cached retrieval | 0.007–0.044 ms | Eight back/forward requests per run; GPU initialization is additional |
| Spread GPU reservation | 63,799,296 bytes | Includes initialization uploads, conservative alignment and two sessions |

Offscreen render targets add 6,782,976 logical bytes; upload scratch adds
3,391,488 bytes per concurrent page. Simulator `allocatedSize` reports zero for
render targets, so drawable allocation must be checked with device Instruments.
Signposts separately identify PDF rasterization, paper/finished composition,
prefetch waiting, uploads, initialization, first paper and first ink.
These are fixture measurements, not a complete cold-opening A/B benchmark.
**Delivery gate remains open:** physical-device 60 FPS/loading/thermal profiling,
real imported-book review, rapid gesture cancellation and folding during either
page's effect still need hands-on validation. No physical iPhone was attached.

**Startup fixes (September 27).** A live debugger sample caught ink preparation
stopped at Metal's feature-support assertion in `dispatchThreads`. That API
requires [nonuniform threadgroup support](https://developer.apple.com/documentation/metal/mtlcomputecommandencoder/dispatchthreads(_:threadsperthreadgroup:)).
Compute work now uses rounded-up uniform threadgroups and the kernels' bounds
checks. The test scheme enables `MTL_DEBUG_LAYER=1`; GPU tests include partial
edge groups and run on `MTLDebugDevice` so validation failures cannot hide behind
successful unvalidated rendering.

Launch tracing also exposed overlapping renders from transient layout sizes and
offscreen lazy-stack children. Only current/outgoing/incoming page views request
foreground rendering; speculative work stays with the provider. Uncached requests
coalesce geometry for 80 ms (100 ms for prefetch), and canceling the last consumer cancels the detached
render. Canceling one consumer preserves work still needed by another. Cached
pages incur no settling delay. Prefetch follows the same geometry identity as
visible requests, including startup size changes. The selected 3–4-second animation is independent
of this preparation.

Prefetch now prepares only the next paging unit in the last committed travel
direction, after visible work has been idle for 120 ms. It skips cached pages,
and a canceled request waiting on PDFKit's serial queue is dropped before
rasterization. The compositor checks cancellation between its expensive stages.
The visible spread still needs both full pages; splitting a fitted page into
tiles would add work without reducing the amount of paper on screen.

In Debug, `-paperbound-startup-trace` prints timestamped `PB_TIMING` records for
app initialization, library appearance, reader/PDF opening, page requests and
render/GPU stages. Combine `-paperbound-demo -paperbound-demo-ink` to reproduce
sample-book ink startup on a test simulator. These traces distinguish application
launch, preparation and intentional animation rather than counting the spinner
as a single timing measurement.
Add `-paperbound-demo-footsteps` to inspect the page overlay on the same sample.

In the sampled Duo launches, foreground requests fell from 12 to 2 after the
scheduling fix. Overlapping paper passes previously took roughly 715–857 ms;
the two visible paper passes then took 260 ms each. Library appearance was
318–356 ms after app initialization began. These are simulator trace examples,
not physical-device launch benchmarks; logs also show the PDF/sample-book open
itself taking only 6–10 ms.

In a later Xcode 27.1 / Duo 27.1 trace with directional prefetch and cooperative
cancellation, transient layout still started one obsolete pair, but both paper
passes stopped before costly drawing. The final pair's paper passes took 276–280
ms; first paper appeared 746 ms after reader opening. The following spread was
prefetched only after visible preparation finished. This sample does not establish
a physical-device speedup or cover large scanned books.

**Drift.** Tears are anchored in normalized page space and the document is
rasterized at exactly the sheet rect the mask is built for, so content and
damage share one coordinate system by construction.

**Licensing.** Every pixel is generated: procedural paper, vector geometry, and
a sample PDF whose prose was written for this app. No third-party assets.

---

## iPhone Duo

### Three sources of posture, best one wins, each says how it knows

**iOS 27.1 added a hinge API, and this app uses it.**

This section used to open by arguing there wasn't one. That was true of the
**iOS 27.0** SDK the project was first written against — searching its SwiftUI
and UIKit module interfaces finds no `onHingeChange`, no fold property on
`UIWindowScene`, and no `Hinge` symbols outside private IOKit. It stopped being
true in 27.1, which is the runtime the Duo simulator was already using:

```objc
// UIKit/UIHinge.h, iPhoneSimulator27.1.sdk — API_AVAILABLE(ios(27.1))
typedef NS_ENUM(NSInteger, UIHingeStatus) {
    UIHingeStatusUnknown, UIHingeStatusClosed,
    UIHingeStatusPartiallyOpen, UIHingeStatusFullyOpen
};
@property (nonatomic, readonly) UIHingeStatus status;
@property (nonatomic, readonly) CGFloat angle;   // radians
```

The iOS 27.1 SDK's SwiftUICore interface declares both `View.onHingeChange` and
`GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior:)`. The
UIKit interface also declares `UIHingeInteraction`; this reader retains that
existing integration through the zero-size `HingeObservationView` representable.

Posture now comes from whichever of three sources can answer, in order:

| | source | knows | admits |
|---|---|---|---|
| **1** | `HingePostureProvider` — the hinge | closed · partly open · fully open, plus an angle | iOS 27.1+, hinged devices only |
| **2** | `DisplayPostureProvider` — which screen | folded vs book-like, *once both screens have been seen* | needs a fold to have happened |
| **3** | `GeometryPostureProvider` — window shape | wide and short reads as book-like | a guess; `reportsRealPosture == false` |

The hinge earns first place on two counts. It is the only source that can see
the **partly open** posture at all — a display can only ever say cover or inner
— and it reports on the very first update, where display observation must wait
for the device to be folded once before it can claim anything.

Source 2 stays, and not only as a fallback for iOS 18 … 27.0. The Duo's device
profile declares two integrated screens, and the app measured both facts itself:

| | display | window | note |
|---|---|---|---|
| **cover** | 466 × 678 pt @3x | **386 × 678 pt** | 80pt reserved for the sensor strip |
| **inner** | 669 × 951 pt @3x | — | from the device profile |

The cover screen does not describe itself the same way twice. Across launches of
the same simulator the app has been handed both `window 386 × 678, insets r0`
and `window 466 × 678, insets r84` — the same ~80pt strip, once as a narrowed
window and once as a safe-area inset. Nothing hard-codes either shape: the
reading surface is derived from the window less its insets, so both arrive at
the same 382–386pt of usable width and the same 348pt page.

Folding moves the app's scene between them, and `UIWindowScene.screen` reports
which one it is on — current, public, non-deprecated API. `UIScreen.screens` and
`UIScreen.main` are both deprecated and neither is used.

The environment editor prints whichever source answered — "Book posture (from
hinge 90° open)", "Folded (from cover display 466×678)", "Flat (from window
size)" — so the app never claims to know more than it does. Basic reading
depends on none of it.

**The angle is used for shading and nothing else.** Apple's own header says the
rate and precision of angle updates are system policy and not to be depended on,
so every layout decision is made from `status`. The angle only sets how deep the
gutter shadow falls: a book held half-open has its deepest crease, and one
pressed flat to 180° has almost none. `testTheAngleNeverDecidesTheMode` pins
that separation.

### What changes when it folds

| state | behaviour |
|---|---|
| **Closed, cover screen** | Single page, shallowest spine shadow. A spread is refused even if the reader asked for "Two pages" — two 190pt columns are not reading. |
| **Partly open** | Book posture, from `UIHingeStatusPartiallyOpen`. The deepest gutter shadow of any state: the leaves are falling away from the spine. Only the hinge can see this one. |
| **Open, inner portrait** | With an active fold division, one page per panel when each panel can fit a readable page; without a reported division, the existing single-page fallback remains. |
| **Open, inner landscape** | Two-page spread with the full-depth spine shadow. |
| **Resized / reserved regions** | Safe-area insets keep controls and text readable; an active fold division places sheets in separate panels, and camera occlusions move the content bounds clear of hardware. |

Page turns stay tap- and swipe-driven throughout. Folding changes what is shown,
never how you turn a page. Reading position is preserved across the transition:
paging units are derived from the page index, so page 7 maps to unit 7 single
and unit 3 in a spread, and back again.

Without a reported fold division, a spread has to clear two bars, both measured
on the page *as it will be drawn* rather than on the box it sits in. Each page
must be at least 320pt wide, and the spread must not make a page **smaller than
reading one page at a time would**. When Duo reports an active division, the
fold defines the panel edges and the spread is judged against those panels;
the divider itself becomes the gutter.

These are the reference sizes when no active division geometry is supplied:

| inner display, no division region | one full-screen page | spread page | what the spread costs |
|---|---|---|---|
| landscape `951 × 590` | 393pt | **393pt** | the spread is free |
| portrait `669 × 860` | **573pt** | 328pt | the spread costs 43% of the page |

Halving the width costs nothing once each half is already wide enough that the
page is capped by the surface's *height* instead — which is the same as saying
the surface is proportioned at least as wide as the open book it would draw. In
landscape it is, so two pages are drawn at exactly the size one page would have
been and the reader gets the second one for nothing. In portrait it is not, so
a spread would trade two fifths of the screen for empty board.

With a reported portrait fold, the two 329pt panels each receive one page and
the gutter follows the reserved fold frame. If the fold is not reported, the
reader keeps the conservative single-page fallback. Camera occlusions are also
subtracted from the readable rectangle before PDF rasterization, so lines do
not run beneath them.

The 320pt bar still does its own work elsewhere: an iPhone in landscape has
plenty of width per column, but the fitted page comes out 262pt, so it stays
single.

### Two layout bugs the Duo found

**The control bars covered the page.** They used to float *over* the reading
surface. On a tall phone that cost a few millimetres; on the Duo's short
386 × 678 cover screen it hid the torn head and tail of the sheet entirely.
They are now `safeAreaInset`s, so the sheet is fitted to the space that is
actually free. `Screenshots/app-duo-cover.png` is the fixed layout on the real
simulator, with the debug HUD showing the measurements above.

**Unfolding the device made the page smaller.** Without an active division, the
spread rule used to ask one question — is each page at least 320pt wide? On the
inner display in portrait the answer was 328pt, so it opened a spread. But one
page on that same surface is 573pt, and the cover screen the reader had just
unfolded *from* gives 348pt.
Opening the device took the page from 348pt to 328pt and called it a feature.

Nothing about this was visible from the geometry table; it only showed up when
the rendered image was put next to the cover-screen one. The rule now compares
the spread against the single page it replaces, and
`DuoLayoutTests.testUnfoldedPortraitStillGivesABiggerPageThanTheCoverScreen`
pins the thing that was actually wrong: unfolding must buy the reader a larger
page.

### What is verified how

* **Cover display** — verified live on the iPhone Duo simulator (iOS 27.1).
  Launch with `-paperbound-demo-hud` to see the numbers the app is working from.
* **Two-page spread** — verified live on an iPad simulator, which exercises the
  identical code path.
* **Inner display** — **verified live, unfolded.** The 27.1 DeviceHub can fold
  and unfold the Duo, and the two displays are separately addressable
  framebuffers, so each can be captured on its own:

  ```bash
  xcrun simctl io <device> enumerate          # lists both displays and their UUIDs
  xcrun simctl io <device> screenshot --display <uuid> out.png
  ```

  `Screenshots/app-duo-inner-spread.png` is that capture — the real inner
  display, open, HUD showing. `simctl` alone is still no help (it has no fold
  subcommand; `simctl ui` covers appearance and contrast, nothing postural), so
  the fold itself is a manual step in DeviceHub and cannot be scripted.

  The rendered set below stays, because it is the thing that runs in CI and
  fails a build. It is produced by `DuoLayoutTests` at the exact reported
  geometry and by `Screenshots/duo-*.png`, rendered through the **same** layout
  coordinator and compositor the live app uses:

```
duo-cover-folded.png            single page,  386 × 522
duo-inner-portrait.png          single page,  669 × 860
duo-inner-landscape-spread.png  two pages,    951 × 590
```

* **The hinge** — **reports live on the Duo simulator.** With the app built
  against the 27.1 SDK, `UIHingeInteraction` fires and returns
  `UIHingeStatusClosed` at 0°, and `Screenshots/app-duo-cover.png` shows the
  whole chain working:

  ```
  hinge      closed · 0°
  posture    Folded (from hinge closed)
  reported   yes — platform
  spine      gutter 0 · shadow 0.4
  ```

  The row above it is the point. `displays: 1 seen` — the scene has never been
  on a second screen, so display observation would have shrugged and reported
  "Flat (from window size)", which is what this same HUD said before the hinge
  was wired in. The hinge got it right on the first update.

  `partiallyOpen` reports too, once the device is opened in DeviceHub:

  ```
  screen     951×669 @3x                  ← the inner display
  hinge      partiallyOpen · 127.78°
  posture    Book posture (from hinge 128° open)
  mode       spread
  spine      gutter 0.02 · shadow 0.9      ← not the base 1.0
  pages      423.3×635 | 423.3×635
  ```

  That shadow is the angle doing its one job, and the arithmetic is checkable:
  openness = 127.78 / 180 = 0.710, flatness = (0.710 − 0.5) / 0.5 = 0.420, and
  1 − 0.25 × 0.420 = **0.895**. Opening the device further relieves the gutter
  rather than deepening it.

  The spread on that surface is the page-size rule confirmed against a real
  display rather than against arithmetic: one page on 867 × 635 would be
  635 / 1.5 = 423.3pt, and each spread page *is* 423.3pt, so the second page
  costs nothing.

  `HingeLayoutTests` still carries the cases a hand cannot reach reliably — 17
  tests over a plain `HingeSnapshot` value, pinning the status mapping, the
  angle clamping at both ends, both fallbacks, the evidence strings, and the
  separation that matters: the angle shades the gutter and never decides the
  page count.

---

## Tests

```bash
xcodebuild -project Paperbound.xcodeproj -scheme Paperbound \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone Duo' test
```

229 tests, including:

* **FullReaderInkTests / ReaderPagingCoordinatorTests** — actual ReaderView,
  settings dismissal, initial opening, edge navigation actions, slider release,
  native scroll geometry back to page zero, simultaneous spread activation,
  unmatched final pages, stale render/visit rejection, and controls without replay.
* **EnchantedInkRevealSequenceTests** — simultaneous readiness, seeded timing,
  stale callback rejection, enabling on an open spread, and accessibility completion.

* **ReaderEffectsTests** — old book/default styles are discarded while effect
  toggles survive; plain paper, unchanged source colors and Duo reserved regions.

* **SeededGeneratorTests** — pins SplitMix64's output bytes and FNV-1a's hashes,
  so an "optimisation" cannot silently reshuffle everyone's books.
* **DamageGeneratorTests** — determinism; different pages/copies/documents
  differ; pristine removes nothing; material, presentation, lighting and renames
  move nothing; the bound edge takes far less damage than the fore-edge;
  every defect stays in bounds.
* **RenderPipelineTests** — the compositor is byte-deterministic; the cut mask
  removes measurable area; heavier conditions remove more; a tear erases inked
  pixels; a hole reveals a *darker* sheet; content is never drawn flipped;
  materials change pixels without changing damage; Enchanted Ink pairs matching
  paper and print images and charges both to the cache; speculative entries
  are evicted before visited pages.
* **InkGPUSimulationTests** — actual Metal neighbor transport, deterministic
  stepping, empty counters, monotonic deposits, light print, converged endpoints,
  cancellation, memory leases, production MTKView scheduling, enabling/disabling
  and reenabling on the same open page, frame captures and
  full-resolution initialization/spread benchmarks.
* **PDFEngineTests** — a real generated PDF driven through open, navigate,
  clamp, search (with exact snippet offsets), render at exact pixel sizes, and
  six concurrent renders at once.
* **LibraryStoreTests** — import, metadata, cover, dedupe on re-import,
  unsupported formats refused clearly, delete, and **the source file is
  byte-identical after import and reading**.
* **LayoutTests / ModelTests** — spread thresholds both ways round (a spread
  refused because it would shrink the page, and one offered because it costs
  nothing), posture honesty, Codable round-trips, the `UInt64` wear-seed round
  trip through SwiftData's `Int`.
* **DuoLayoutTests** — the Duo's reported geometry, pinned: a cover screen that
  refuses a spread even when asked, the reserved sensor strip as a
  `reservedRegion`, position preserved across a fold, and the rule the fold
  found — unfolding must buy the reader a *larger* page.
* **HingeSnapshotTests / HingePostureTests** — the iOS 27.1 hinge path without
  the API in the loop: status → posture, angle → openness with clamping at both
  ends, evidence strings that never overclaim, the fall-through to display
  observation and then to geometry, and the separation that matters — the angle
  shades the gutter and never decides the page count.
* **SnapshotComparisonTests** — renders the comparison set above, and asserts
  that a page re-rendered after the texture cache is purged comes back
  byte-identical.

---

## Known compromises

* **Highlights are modelled but not editable.** `Highlight` stores quoted text
  and normalized rects, but there is no selection UI. Doing it properly means
  mapping `PDFSelection` rects through the damage mask, which is real work.
* **Zoom in Physical mode is a transform, not a re-render.** Pinching past ~2×
  shows softening. Pristine mode gives true resolution-independent zoom. A
  re-render at zoom level is the obvious next step.
* **No page-curl animation.** The brief says to earn Metal after a 2D prototype
  succeeds; the 2D prototype has only just succeeded.
* **EPUB import is refused at the door**, with a clear message, rather than
  importing a book that cannot be opened.
* **Speech reads one page at a time** and does not auto-advance.

## Next steps, in order

1. Highlights and notes with selection mapped through the mask.
2. Re-render at zoom level in Physical mode.
3. Readium EPUB adapter behind `ReadingEngine`, with the reflow wear rule
   implemented as documented.
4. CBZ adapter (trivial once the engine seam has two conformances).
5. Metal page curl, now that there is a 2D baseline to beat.
