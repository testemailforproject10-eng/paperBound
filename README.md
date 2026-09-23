# Paperbound

A native iOS e-reader whose distinguishing feature is user-selected **reading
environments**: the same imported PDF can be presented as clean paper, a worn
paperback, an aged journal page, or a dark-stock night page. Wear affects what
is drawn on screen — including cutting through letters and artwork — and never
touches the imported file.

Built against **Xcode 27.1 / iOS 27.1 SDK**, deployment target **iOS 18.0**,
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
| **2 — environment MVP** | Done. Six presets; material, condition, presentation and lighting are independently selectable; Pristine is one tap. |
| **3 — wear identity** | Done. Seeded per-page cut-outs, torn corners, fibre, shadows. Repeat visits are byte-identical (tested). |
| **4 — book presentation** | Done. Spine, page-stack depth, two-page spread, bounded visible-page cache. |
| **5 — device adaptation** | Partial, honestly. Layout is geometry-driven and preserves position across resize/rotation. **The installed SDK exposes no public hinge API**, so none is faked — see below. |
| **6 — EPUB parity** | **Not built.** `ReadingEngine` is the seam it plugs into. |
| **7 — reader depth** | Search, outline, bookmarks, and text-to-speech are done. Highlights have a model but no selection UI yet. |

### What is deliberately absent

* **EPUB / Readium.** Adding a half-working reflowable engine would have cost
  more than it proved. The abstraction it needs (`ReadingEngine`,
  `ReadingLocation`, `stablePageID`) exists and is documented, including the
  rule for where wear lives when text reflows.
* **A hinge API.** See *Device layout* below.
* **Backend, accounts, bookstore, AI, CloudKit.** As instructed.

---

## Build and run

```bash
open Paperbound.xcodeproj          # then ⌘R
```

or from the command line:

```bash
xcodebuild -project Paperbound.xcodeproj -scheme Paperbound \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build

xcodebuild -project Paperbound.xcodeproj -scheme Paperbound \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' test
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
3. Open the book. It opens in **Physical** mode with the *Soft cream* default.
4. Tap the middle of the page to show controls, then **⋯ → Reading environment**.
5. Set **Condition → Damaged** and push **Intensity** to 100%. Tears appear at
   the fore-edge and corners; on the figure page a tear cuts the diagram.
6. Tap **Pristine** in the top bar. PDFKit's own view appears: text is
   selectable, search highlights, pinch zoom is real. Tap **Physical** to go
   back — the wear is exactly where it was.
7. Swipe back and forward several pages and return. Every page is identical to
   how you left it.
8. Rotate to landscape on iPad, or run the iPad Pro simulator: the reader opens
   into a two-page spread with spine shading, on the same page you were reading.
9. **⋯ → New wear pattern** re-rolls this copy's damage and keeps everything else.

### Capturing the reader screen without tapping

Debug builds accept a launch argument that installs the sample book and opens it
straight into the reader, which is how the reader screenshots below were taken:

```bash
xcrun simctl launch booted com.paperbound.reader \
    -paperbound-demo -paperbound-demo-condition damaged -paperbound-demo-page 3
xcrun simctl io booted screenshot reader-damaged.png
```

`-paperbound-demo-condition` takes `pristine`, `lightWear`, `wellLoved` or
`damaged`; `-paperbound-demo-page` is 1-based. The hook is inside `#if DEBUG`
and does nothing in release builds.

The wear you see in the app will *not* match `./Screenshots` tear for tear, and
that is correct: each imported copy draws its own random `wearSeed`, so your
book is worn differently from anyone else's. What does match is that it stays
the same every time you open it.

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

A saved environment is four independent dimensions plus an intensity:

```
PaperMaterial  ×  PageCondition  ×  BookPresentation  ×  LightingStyle  ×  0…1
white              pristine          minimal              flat
cream              lightWear         paperback            warm
aged               wellLoved         hardcover            directional
parchment          damaged           oldJournal           posture-reactive
dark
```

That is 5 × 4 × 4 × 4 = 320 combinations from twenty values, not 320 hard-coded
themes. Presets write into these same four controls; editing any of them turns
the preset into "Custom".

**The old-journal look is one selectable condition, not the app's identity.**
The default on a fresh install is *Soft cream* — light wear, warm light.

### Compositing order

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
finished bitmaps.

**Memory.** `PageRenderCache` is an `NSCache` with a 96 MB cost limit that also
drops everything — and purges paper textures — on a memory warning. Render size
is capped at ~4.2 megapixels per sheet regardless of display scale. Textures are
bucketed to 64px and cache keys to 8px so layout jitter cannot thrash them.

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

The SwiftUI spelling trailed in beta, `onHingeChange`, did not ship. What
shipped is `UIHingeInteraction`, a `UIInteraction` you add to a view — so
`HingeObservationView` is a zero-size `UIViewRepresentable` that exists only to
give it somewhere to live.

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
| **Open, inner portrait** | Single page, but a materially larger one than the cover screen gives. |
| **Open, inner landscape** | Two-page spread with the full-depth spine shadow. |
| **Resized / reserved regions** | Safe-area insets become `reservedRegions`, and the control bars inset the reading surface rather than covering it. |

Page turns stay tap- and swipe-driven throughout. Folding changes what is shown,
never how you turn a page. Reading position is preserved across the transition:
paging units are derived from the page index, so page 7 maps to unit 7 single
and unit 3 in a spread, and back again.

A spread has to clear two bars, both measured on the page *as it will be drawn*
rather than on the box it sits in. It must leave each page at least 320pt wide,
and it must not make the page **smaller than reading one page at a time would**.

The second bar is the one that separates the Duo's own two displays:

| inner display | one page | spread page | what the spread costs |
|---|---|---|---|
| landscape `951 × 590` | 393pt | **393pt** | the spread is free |
| portrait `669 × 860` | **573pt** | 328pt | the spread costs 43% of the page |

Halving the width costs nothing once each half is already wide enough that the
page is capped by the surface's *height* instead — which is the same as saying
the surface is proportioned at least as wide as the open book it would draw. In
landscape it is, so two pages are drawn at exactly the size one page would have
been and the reader gets the second one for nothing. In portrait it is not, so
a spread would trade two fifths of the screen for empty board.

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

**Unfolding the device made the page smaller.** The spread rule used to ask one
question — is each page at least 320pt wide? On the inner display in portrait
the answer was 328pt, so it opened a spread. But one page on that same surface
is 573pt, and the cover screen the reader had just unfolded *from* gives 348pt.
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
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' test
```

149 tests in twelve suites, covering the claims that matter:

* **SeededGeneratorTests** — pins SplitMix64's output bytes and FNV-1a's hashes,
  so an "optimisation" cannot silently reshuffle everyone's books.
* **DamageGeneratorTests** — determinism; different pages/copies/documents
  differ; pristine removes nothing; material, presentation, lighting and renames
  move nothing; the bound edge takes far less damage than the fore-edge;
  every defect stays in bounds.
* **RenderPipelineTests** — the compositor is byte-deterministic; the cut mask
  removes measurable area; heavier conditions remove more; a tear erases inked
  pixels; a hole reveals a *darker* sheet; content is never drawn flipped;
  materials change pixels without changing damage.
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
