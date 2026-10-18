# EPUB support

Paperbound reads PDFs today. This document is the plan and the checklist for
adding EPUB: what it takes, in what order, who owns what, and how we know each
part is done. Tick a box only when its acceptance check has been run, not when
the code is written.

**Started:** 2026-10-01 · **Toolkit:** [Readium Swift toolkit](https://github.com/readium/swift-toolkit) 3.x (3.9.0 at time of writing)

---

## Why EPUB, and what changes

A PDF's text is fixed onto pages. An EPUB's text flows, so the reader decides
the font, the size, the colour and the margins. That is the main reason for
this work: **typography control lives here** (font family, size, colour, line
spacing, margins), which a PDF cannot offer.

## Key decisions

1. **Readium renders EPUB.** We use Readium's `EPUBNavigatorViewController`
   (a paginated web view) rather than writing our own EPUB layout engine.
   It already handles pagination, CSS, fonts, right-to-left, fixed-layout
   EPUBs, locators, text selection, highlights ("decorations") and search.
2. **EPUB is a separate reading surface.** PDFs keep `PagedReaderView`
   (composited page images). EPUBs get a new `EPUBReaderView` that hosts the
   Readium navigator. `ReaderView` picks the surface from `book.format`.
3. **The physical effects do not apply to EPUB in the first release.** Page
   curl, Enchanted Ink, page effects and paper wear all work on rendered page
   *images*. Readium draws live web content, so these come later (Phase 6),
   probably by snapshotting the web view. Until then the effects pickers are
   hidden or disabled for EPUB books, with a short explanation.
4. **Positions are Readium `Locator`s.** `ReadingLocation.epubLocator` is
   changed to carry the full Locator (as JSON) so positions survive font and
   margin changes exactly. This is safe: no EPUB book can have been saved yet,
   because import currently refuses EPUB.
5. **Highlights store a Locator too.** `Highlight` gets an optional
   `locatorJSON` field (defaulted, so existing PDF stores migrate without a
   schema version). PDF highlights keep their page rects and character ranges.
6. **The PDF path must not regress.** Every PDF feature, test and effect keeps
   working exactly as before. Any shared file change is additive.
7. **No DRM.** DRM-protected EPUBs (Adobe ADEPT, Apple FairPlay, LCP) are
   detected and refused with a clear message. LCP support could come later.

## Architecture at a glance

```
LibraryStore ── import .epub ──► Book(format: .epub)
                                     │
ReaderView ── book.format ──┬── .pdf  ──► PagedReaderView / NativePDFReaderView   (unchanged)
                            └── .epub ──► EPUBReaderView
                                              │ hosts
                                              ▼
                                   EPUBNavigatorViewController   (Readium)
                                              ▲
ReaderViewModel ── EPUBReadingEngine ─────────┘  open, locators, TOC, search,
                    (conforms to ReadingEngine)   progress, text for speech
                                              ▲
TypographySettings ── EPUBPreferences ────────┘  font, size, colour, margins, spacing
```

---

## Team and file ownership

Five engineers (agents) work in one tree. To avoid clobbering each other, each
owns a set of files. Edits to files someone else owns must be small, additive
and re-read immediately before editing. Nobody commits; nobody reverts work
they did not write.

| # | Engineer | Owns | Starts |
|---|---|---|---|
| 1 | **Foundation** | Readium package in `project.pbxproj`, `Paperbound/Engine/EPUB*.swift`, `ReadingLocation` changes, `ReaderViewModel` engine abstraction, `ReaderView` routing, EPUB test fixtures in `PaperboundTests/Fixtures/` | First, alone |
| 2 | **Library & import** | `LibraryStore` EPUB import, metadata and cover extraction, DRM detection, `BookTileView`, `SettingsView` copy, `Info.plist` document types | After 1 |
| 3 | **Reader surface** | `Paperbound/Reader/EPUB/EPUBReaderView.swift` and friends: hosting, page turns, tap zones, controls, progress bar, position save/restore, spreads and the Duo | After 1 |
| 4 | **Typography** | `Paperbound/Model/Typography*.swift`, `Paperbound/Reader/EPUB/TypographyPanel*.swift`, the settings persistence and how it reaches Readium | After 1 |
| 5 | **Reading tools** | `Paperbound/Reader/EPUB/EPUBAnnotations*.swift`, `EPUBSearch*.swift`: highlights, the selection bar, search, contents, bookmarks, read-aloud | After 1 |

Each engineer builds with their own DerivedData folder and tests on their own
simulator clone, so parallel builds do not collide. All builds use the Xcode
27.1 in `~/Downloads/Xcode.app` (see the root README).

---

## Phase 1 — Foundation *(engineer 1)*

- [x] Add the Readium Swift toolkit (3.x, pinned to an exact minor) as a Swift
      package: `ReadiumShared`, `ReadiumStreamer`, `ReadiumNavigator`. Add an
      HTTP-server adapter only if the navigator still requires one.
      *Check:* clean build of the app and the test target.
- [x] `EPUBReadingEngine` conforms to `ReadingEngine`: opens a publication with
      `AssetRetriever` + `PublicationOpener`, reports `format`, `pageCount`
      (positions count), capabilities (`reflowTypography`, `textSelection`,
      `fullTextSearch`, `outline`, `speech`), outline, labels, progress and
      order keys. `renderPage` throws `unsupported` for now.
      *Check:* unit tests open the fixture EPUB and read its title, TOC and
      positions.
- [x] `ReadingLocation.epubLocator` carries the full Locator JSON, with
      helpers to convert to and from Readium `Locator`. PDF locations are
      untouched. *Check:* round-trip tests.
- [x] `ReaderViewModel` holds `any ReadingEngine` (or a small enum of engines)
      instead of a concrete `PDFReadingEngine`; PDF-only members
      (`pdfDocument`, page images, text selectors) are reached through the PDF
      engine only. *Check:* every existing PDF test still passes.
- [ ] `ReaderView` routes `.epub` books to an `EPUBReaderView` placeholder.
- [x] Test fixtures: a small reflowable EPUB 3 (several chapters, a nav TOC,
      an image, a footnote) built from source files by a script in `Tools/`, and
      a DRM-flagged EPUB for the refusal test.

### Notes from Phase 1

**Package.** Readium Swift toolkit **3.9.0**, `upToNextMinorVersion` from
3.9.0 (so 3.9.x only), products `ReadiumShared`, `ReadiumStreamer`,
`ReadiumNavigator`, linked into the app target only. **No HTTP-server adapter**:
since 3.x the EPUB navigator serves resources through a custom URL scheme
handler (Readium's migration guide, "Removing the HTTP Server from the EPUB
Navigator"). The test target does not link Readium (it would duplicate the
classes); it `import ReadiumShared`s and resolves against the host app, which
works. Resolved versions are in
`Paperbound.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
The first resolve clones ~9 packages and takes a minute or two.

**`ReadingLocation.epubLocator`** is now
`epubLocator(href:progression:totalProgression:locatorJSON:)`. The JSON (Readium's
canonical, sorted-key `Locator.jsonString()`) is the source of truth; the other
three fields are copies so the model layer can label and sort without Readium.
Never build one by hand — use the helpers in `Paperbound/Engine/EPUBLocator.swift`:
`ReadingLocation(locator:)`, `.readiumLocator` (falls back to href + progression
if the JSON is damaged), `.epubHref`, `.epubTotalProgression`.

**`EPUBReadingEngine`** (`Paperbound/Engine/EPUBReadingEngine.swift`):
- `publication: Publication?` — hand this to `EPUBNavigatorViewController`.
- `positions: [Locator]` — Readium positions; `pageCount` is their count and
  `label(for:)` is the 1-based position number. They do not change with font
  size, so they are *not* screens.
- `positionIndex(for:)` — the position containing any EPUB location (uses the
  locator's `position`, else href + progression).
- `outline()` — the nav TOC flattened with `depth`, each entry resolved to a
  locator (fragments kept, e.g. `#ledger`). Built once in `open()`.
- `search(_:)` / `search(_:limit:)` — Readium's search service; snippets are
  before + match + after with whitespace collapsed, `matchRange` in Characters.
- `text(at:)` answers only from a cache (the protocol is synchronous). Use
  `await loadText(at:)` for speech; `ReaderViewModel.speakCurrentPage()` does.
- `normalizedProgress` = `totalProgression`, snapped to 1 on the last position
  (so `isFinished` still triggers). `orderKey` = totalProgression × 10⁶.
- `stablePageID` = `epub:<href>#<bucket of 8>`; `aspectRatio` is a fixed
  portrait fallback; `renderPage` throws `.renderFailed` (drawn live).
- DRM: Adobe ADEPT / LCP publications come back from Readium as *restricted*
  and `open()` throws `.encryptedDocument`; Apple FairPlay
  (`META-INF/sinf.xml`) is checked by hand because Readium does not flag it.
  Garbage files throw `.unreadableDocument`. Engineer 2 can reuse this logic
  for import, but the engine does not copy or import anything.

**`ReaderViewModel`.** `engine: PDFReadingEngine?` is unchanged and still drives
every PDF path. New: `epubEngine: EPUBReadingEngine?`, computed
`readingEngine: (any ReadingEngine)?`, and `load()` branches on `book.format`
(EPUB: no provider, no GPU prewarm). Format-neutral now: progress,
`positionLabel`, outline, `advance(by:)`, `go(to:)`, `go(toPageIndex:)` (EPUB:
position index, so the existing slider works), `currentPageIndex`, bookmarks,
search, speech. New for the EPUB surface: `reportVisible(epubLocation:)` (save a
location Readium reported, without echoing it back) and
`epubNavigationRequest: EPUBNavigationRequest?` (a jump the app asked for:
contents, search, bookmarks, slider, edge taps). **Still PDF-only:**
`provider`, `pdfDocument`, `textSelector(forPage:)`, `pageAspectRatio(forPage:)`,
`marks(onPage:)`, `addHighlight` / `highlights(overlapping:)` (page rects and
character ranges), `rerollWear`, `reportVisible(pageIndex:)`, `navigationRequest`,
`mode` / `toggleMode()` (Physical / Pristine are PDF renderers), and the
environment editor's effects. Engineer 5 owns EPUB highlights; engineer 3 should
hide the Physical/Pristine toggle and effects for EPUB.

**`EPUBReaderView`** (`Paperbound/Reader/EPUB/EPUBReaderView.swift`) is a working
minimum, not a placeholder: it hosts the navigator at `currentLocation`, reports
`locationDidChange` to the model, follows `epubNavigationRequest`, and toggles
the controls on a tap. It has *not* been checked on screen yet (no EPUB can be
imported until Phase 2) — the routing box above stays unticked for that
reason. `EPUBNavigatorSmokeTests` does host the navigator in a window with the
sample book and confirms it loads and reports a locator in the requested
chapter, so the Readium side works inside the app. External links use Readium's default (opens Safari with
no confirmation) — engineer 3 must override `presentExternalURL`.

**Fixtures.** `Tools/make-epub-fixtures.sh` rebuilds `Sample.epub` and
`Protected.epub` from `PaperboundTests/Fixtures/epub-src/` byte-for-byte
reproducibly. The `.epub` files are copied into the test bundle by the
synchronized folder; the *sources* are excluded by a membership exception in
`project.pbxproj` that lists each file — **add any new file under `epub-src/`
to that list**, or the test target will copy it as a resource (and collide on
names like `container.xml`). A folder entry in the exception list did not work.

**Verified (2026-10-01, Xcode 27.1, iPhone Duo 27.1 simulator clone).** Clean
`build-for-testing` of the app and the test target. Full `PaperboundTests`:
**345 tests, 0 failures** (includes 16 new `EPUBReadingEngineTests`, and
`ReaderPagingCoordinatorTests`, `TextSelectionSessionTests`,
`HighlightActionBarTests`, `PageTurnStyleTests`, `EnchantedInkRevealSequenceTests`,
`PDFEngineTests`, `ModelTests`). After two small later edits, the EPUB, navigator
smoke and model suites were rerun: 34 tests, 0 failures.

**Gotchas.** Only the `iPhone Duo` device type supports the iOS 27.1 runtime,
so a private test simulator has to be an iPhone Duo clone. `SearchIterator.close()`
(`Closeable` on resources) is deprecated in 3.9 in favour of deinit; the
engine just lets the iterator go.

## Phase 2 — Library and import *(engineer 2)*

- [x] `LibraryStore` imports `.epub` (zipped). Exploded EPUB folders are out of scope.
- [x] Title, author and language come from the OPF metadata; the cover image
      becomes the shelf tile. Fall back to the current generated cover if none.
- [x] Same-file re-import still returns the existing book (fingerprint).
- [x] DRM-protected files are refused with a clear message, before copying.
- [x] Malformed or unreadable EPUBs fail with a readable error, not a crash.
- [x] `Info.plist` document types and `LibraryStore.importableTypes` accept
      `org.idpf.epub-container`; Files "Open in" works.
- [ ] Settings: "EPUB — Not yet" becomes supported, with a short note on DRM.
- [x] *Check:* import tests for a good file, a duplicate, a DRM file and a
      corrupt file; shelf screenshot showing an EPUB cover (cover display; see notes).

### Notes from Phase 2

**Demo launch (DEBUG builds only): `-paperbound-demo-epub`.** Launch with
`xcrun simctl launch <udid> com.paperbound.reader -paperbound-demo-epub` (or add
it to the scheme's arguments). It imports the sample EPUB ("The Lamplighter's
Almanac", byte-identical to `PaperboundTests/Fixtures/Sample.epub`) through the
normal import path if it is not already on the shelf, and pushes it straight
into `EPUBReaderView`. The book's saved position is *kept* between launches (so
it can check restore); add `-paperbound-demo-epub-reset` as well to start from
the first page. It does not combine with `-paperbound-demo` (the EPUB one wins).
Verified on a fresh iPhone Duo 27.1 clone: the reader opens on the cover page,
"Page 1 of 10". The bytes are embedded in `Paperbound/Library/DemoEPUBData.swift`
inside `#if DEBUG` (release builds carry nothing); regenerate it with
`Tools/make-demo-epub-source.sh` after `Tools/make-epub-fixtures.sh`.

**Import API.** User imports go through `LibraryStore.importBook(at:into:) async`
(PDF and EPUB). `LibraryEnvironment.importFiles` now fires a `Task` and returns
at once; `importFilesNow(_:into:) async` is the awaitable version. The old
synchronous `importFile(at:into:)` is unchanged and still PDF-only (it throws
`unsupportedFormat` for `.epub`); `SampleLibrary` and the PDF tests keep using it.
An EPUB is read once, fingerprinted (de-dup as before), written to a temporary
`paperbound-import-*.epub`, opened by `EPUBImportInspector` (which uses
`EPUBReadingEngine.open()`, so import and reader agree on DRM and damage), and
only then copied into `Books/`. Refusals: `LibraryError.protectedBook(name)`
(ADEPT/LCP via Readium, FairPlay via `META-INF/sinf.xml`) and
`.unreadableBook(name)`; neither leaves a book, a library file or a staging file.

**Metadata.** `title` = OPF title (file name if empty), `author` = all
`dc:creator`s joined by `ListFormatter`, new `Book.language: String? = nil`
(first `dc:language`; optional with a default, so no schema version),
`pageCount` = Readium positions count, `coverData` = the declared cover as a
JPEG thumbnail ≤ 480 px wide (nil → the shelf's generated cover, unchanged).

**Fixtures.** `Tools/make-epub-fixtures.sh` now also writes
`PaperboundTests/Fixtures/FairPlay.epub` (Sample + a fake `META-INF/sinf.xml`,
generated by the script so no new `epub-src/` file or pbxproj exception was
needed). `Sample.epub` and `Protected.epub` came out byte-identical (same MD5).

**UI copy.** Library menu and empty shelf say "Import a Book" / "Import a PDF
or EPUB"; Settings › Formats shows EPUB "Supported" with a one-line DRM note.

**Verified (2026-10-01, Xcode 27.1, private iPhone Duo 27.1 clone).**
`EPUBImportTests` **13 tests, 0 failures** (good file with title/author/
language/cover, the copy opens in the engine, PDF through `importBook`,
duplicate, Adobe DRM, FairPlay, garbage, truncated, PDF renamed `.epub`, empty
file, importable types, Info.plist types, author line); `LibraryStoreTests` 9,
0 failures (one test renamed: `testSynchronousImportLeavesEpubToTheAsyncPath`).
On screen (cover display): the shelf shows the EPUB's own cover with "The
Lamplighter's Almanac / Wren Halloway"; `simctl openurl` of a protected `.epub`
file routed to the app and showed the DRM alert with nothing added; the same
for `Sample.epub` showed "That book is already in your library." A Release
build compiles and contains neither the demo bytes nor the launch argument.

**Full suite.** 2026-10-01 20:32 (tree at that time): 396 tests, 4 failures,
all in other engineers' in-progress suites (TypographyNavigatorTests,
EPUBAnnotationsTests). A second full run on 2026-10-01/02, against a tree
others had changed since, did not finish: after about 250 passing tests it
stalled in `PageEffectCaptureTests` and was stopped. By then 4 hosted-reader
tests had failed on timeouts or `InvalidTransition`:
`EPUBReaderSurfaceHostedTests.testNavigationRequestsMoveTheNavigatorAndAreSaved`,
`FullReaderInkTests` ×2 and `FullReaderPageEffectTests` ×1. None of them goes
through import. They passed in the first run, so the cause is a later reader-side
change or simulator load, and still needs to be found. Rerun on 2026-10-03:
EPUBImportTests, EPUBReadingEngineTests, LibraryStoreTests, ModelTests and
PDFEngineTests, **73 tests, 0 failures**.

**Not verified.** The inner (2007×2853) display: the fresh clone is folded and
unfolding needs the 27.1 DeviceHub by hand, so `--display` on the inner UUID
returns black; all screenshots are of the cover display. The Settings copy was
not looked at on screen (no UI automation), so that box stays open. The
Files-app picker itself was not driven (`importableTypes` is unit-tested and
"Open in" via `openurl` works).

## Phase 3 — Reader surface *(engineer 3)*

- [x] `EPUBReaderView` hosts `EPUBNavigatorViewController` (a
      `UIViewControllerRepresentable`), paginated, opening at the saved Locator.
- [ ] Page turns by swipe, edge taps and the existing slider; a tap in the
      middle toggles the reader controls, the same as PDFs.
- [x] The current Locator is saved as the reader moves and restored on reopen,
      including after the app is killed.
- [x] Progress bar and page label show the position through the book.
- [ ] Two-page spreads on wide screens and the iPhone Duo (Readium
      `columnCount`); the fold and camera cut-outs are kept clear using the
      existing `DeviceLayoutCoordinator` regions.
- [ ] Rotation, resize and fold changes keep the reader on the same text.
- [ ] Links inside the book (footnotes, cross-references) work; external links
      open in Safari after a confirmation.
- [x] Effects pickers (page turn style, Enchanted Ink, page effects, paper) are
      hidden or disabled for EPUB books, with one line saying why.
- [ ] *Check:* simulator screenshots of single page, spread, and the Duo
      inner display; reopen lands on the same paragraph.

### Notes from Phase 3

**`EPUBNavigatorBridge` — how typography and reading tools reach the live
navigator** (`Paperbound/Reader/EPUB/EPUBNavigatorBridge.swift`, owned by
engineer 3, `@MainActor @Observable`). The open book's bridge is
**`ReaderViewModel.epubBridge`** (a `let`, idle for PDFs). Use it instead of
editing `EPUBReaderView`. Everything can be called before the navigator exists
or while it is being rebuilt: preferences, decorations and decoration
observers are remembered and replayed onto every navigator that attaches, so
set them once. This API is stable; changes will only be additive.

| Member | For | What it does |
|---|---|---|
| `submit(_ preferences: EPUBPreferences)` | eng. 4 | Applies typography now and to every later navigator. Submit the **whole** set each time (replaces, not merges). Readium keeps the reader on the same text. |
| `submittedPreferences`, `effectivePreferences` | eng. 4 | What you submitted / what the navigator is given (yours + the surface's layout keys). |
| `settings: EPUBSettings?`, `editor(of:) -> EPUBPreferencesEditor?` | eng. 4 | Readium's resolved settings and editor (ranges, steps). `nil` with no navigator. |
| `fontFamilyDeclarations: [AnyHTMLFontFamilyDeclaration]` | eng. 4 | Extra fonts (bundled OpenDyslexic etc.). Creation-time, see below. |
| `editingActions: [EditingAction]` | eng. 5 | The selection menu. Default `EditingAction.defaultActions`. Creation-time. |
| `editingActionTarget: NSObject?` (weak) | eng. 5 | Implements the `@objc` selectors of custom actions, e.g. `EditingAction(title: "Highlight", action: #selector(EPUBAnnotationActions.highlight(_:)))`. The navigator's container forwards the action to it (`target(forAction:withSender:)`). |
| `decorationTemplates` | eng. 5 | `[Decoration.Style.Id: HTMLDecorationTemplate]`, default `HTMLDecorationTemplate.defaultTemplates()`. Creation-time. |
| `apply(_ decorations: [Decoration], in group: DecorationGroup)` | eng. 5 | Draws a group (e.g. `"highlights"`, `"search"`, `"tts"`), replacing it; `[]` clears. Remembered and replayed. `decorations(in:)` returns the last set. |
| `observeDecorationInteractions(inGroup:onActivated:)` | eng. 5 | Tap on a decoration. Register **once** per group (it is replayed, not de-duplicated). |
| `shouldShowMenuForSelection: ((Selection) -> Bool)?` | eng. 5 | Return `false` to suppress the system edit menu (e.g. to show the app's highlight bar). |
| `canPerformAction: ((EditingAction, Selection) -> Bool)?` | eng. 5 | Hide individual actions. |
| `onSelectionChange: ((Selection?) -> Void)?` | eng. 5 | A selection appeared (reported when the menu would show) or was cleared (`clearSelection()`, page turn). |
| `currentSelection`, `clearSelection()` | eng. 5 | Readium's current selection. |
| `tapInterceptor: ((CGPoint) -> Bool)?` | eng. 5 | First look at every tap on the page (navigator-view coordinates); return `true` to consume it so it neither turns the page nor toggles the controls. |
| `go(to: Locator, animated:) async -> Bool` | both | Raw jump. For reader-initiated jumps (contents, search hits, bookmarks) prefer **`ReaderViewModel.go(to: ReadingLocation(locator:))`** — it saves the position and reaches the navigator through `epubNavigationRequest`. |
| `currentLocator`, `addLocationObserver(_:) -> UUID` | both | Last reported location / called on every location change (after the model saved it). |
| `whenAttached(_:) -> UUID`, `removeObserver(_:)` | both | Run code with the navigator now and with every navigator that attaches later. Escape hatch: `navigator` (weak), `attachCount` (observable), `isAttached`, `evaluateJavaScript(_:)`. |
| `surfaceLayout: EPUBSurfaceLayout`, `isShowingSpread` | both | Where the navigator sits and whether two columns are showing (observable, read-only). |

**Creation-time settings.** Readium reads `editingActions`,
`decorationTemplates` and `fontFamilyDeclarations` only when it creates the
navigator. Changing one after the reader is open makes `EPUBReaderView` build a
new navigator at the current location (one blink). Set them as early as you
can — e.g. right after `ReaderViewModel.load()` — and avoid changing them while
reading.

**Layout keys belong to the surface.** `scroll` (always `false`: paginated),
`columnCount` and `spread` are set by `EPUBReaderView` from the screen and the
fold, and override whatever is submitted. Everything else in
`EPUBPreferences` (font, size, colours, theme, margins, spacing, alignment,
publisher styles) is typography's.

**Taps.** Edge taps (outer 28% of the width, as for PDFs) turn the page through
Readium; the middle toggles the controls. `tapInterceptor` runs before both.
Readium's own `didTapAt` delegate callback is not used (it fires for edge taps
too).

**Surface (engineer 3).** `EPUBReaderView` hosts `EPUBNavigatorContainerController`
(same file), which owns the navigator as a child view controller and is its
delegate. Files: `Paperbound/Reader/EPUB/EPUBReaderView.swift`,
`EPUBNavigatorBridge.swift`, `EPUBSurfaceLayout.swift` (pure geometry +
`EPUBTapZone`). Shared-file edits: `ReaderViewModel.epubBridge` (one `let`);
`ReaderView` hides the Physical/Pristine toggle for EPUB and shows "Two pages"
from `epubBridge.isShowingSpread`; `EnvironmentEditorView` shows one line
instead of the effects for EPUB ("Page turns, Enchanted Ink, page effects and
paper work on PDF books only for now…"). PDF branches are unchanged.
`SettingsView` (engineer 2) still shows the global effect pickers; they are
the PDF defaults, so they were left alone.

- **Controls float over the text.** The navigator fills the screen and the bars
  overlay it, so toggling the controls never repaginates. The window's safe area
  is used, but per screen size it only ever grows (the Duo cover's status bar
  appears with the controls; following it would reflow every toggle).
- **Placement** (`EPUBSurfaceLayout.make`): cut-outs push in from whichever edge
  costs least (the Duo cover's full-height 84 pt sensor strip narrows the frame;
  a camera hole lowers the top inset). Two columns when landscape and ≥ 600 pt
  wide, when the hinge says open-book, or across a vertical fold — then the
  navigator is centred on the fold so the middle gutter lies on it. A
  horizontal fold uses the larger panel. Folded never spreads.
- **Columns are forced with Readium CSS RS variables** (`--RS__colCount: 2`,
  `--RS__colWidth: 200px`, `--RS__colGap: 0`), because Readium's user
  `columnCount` only applies ≥ 960 px. RS variables are creation-time, so a
  change of column count rebuilds the navigator at the current Locator (one
  blink on rotation/fold). Don't use `--RS__colGap`: Readium pages by whole
  screens, so a CSS gap drifts every later page (seen on screen). A fold wider
  than the gutters widens `--RS__pageGutter` instead.
- **Same text after resize/rotation/fold:** the last reported Locator is the
  anchor; locations Readium reports while the layout settles are not saved, and
  the navigator is sent back to the anchor afterwards.
- **External links** (`presentExternalURL`): an alert "Leave the book?" names the
  host; only http/https/mailto; Open → `UIApplication.open`. Internal links and
  footnotes are Readium's default handling.
- **DEBUG capture hooks** (env, pass with `SIMCTL_CHILD_`):
  `PAPERBOUND_EPUB_AUTO_TURN=<delay>[,<count>]` taps the right edge `<count>`
  times through the real tap handler; `PAPERBOUND_EPUB_HIDE_CONTROLS=1`;
  `PAPERBOUND_EPUB_SIMULATE_SURFACE=669x951` lays the reader out for that size
  with a 12 pt vertical fold in the middle, scaled to fit (red band = fold), for
  capturing the Duo inner-display spread on a simulator that cannot be unfolded
  by script.

**Verified (2026-10-03, Xcode 27.1, private iPhone Duo 27.1 clone, folded —
cover display 466×678).** `EPUBSurfaceLayoutTests` (13), `EPUBNavigatorBridgeTests`
(4), `EPUBReaderSurfaceHostedTests` (4, real navigator in a scene window on
Sample.epub: opens at the saved Locator, saves every move to `book.savedLocation`,
a second model reopens on the same screen (same href and progression), the
slider path reaches the last position with progress 1, preferences submitted
before attach reach the navigator and survive a rebuild, 669×951 → 951×669 gives
two columns on the same Readium position): **21 tests, 0 failures**. On screen
(`-paperbound-demo-epub`): the cover, then three edge-tap turns into chapter I;
kill + relaunch landed on the identical page (same first line); with controls
"Page 3 of 10 · 20%" and no Physical/Pristine toggle; the environment panel shows
only the EPUB note; the simulated inner-display surface shows two columns with
the gap on the fold band and no text crossing it.
**Not verified:** a real unfolded inner display (no scriptable unfold; the
user's unfolded Duo was off limits), swipes and the middle-tap toggle (no touch
injection; swipes are Readium's own), internal links/footnotes and the external
link alert on screen, live rotation on a device.
Unticked boxes, and why: page turns (edge taps verified through the real tap
handler by `PAPERBOUND_EPUB_AUTO_TURN`, the slider path by test; swipe and the
middle tap not exercised); spreads and resize/fold (logic tested, spread seen
only on the simulated inner surface, not the real unfolded display); links
(implemented, not exercised on screen); screenshots (single page and the
simulated spread only). Full `PaperboundTests` on 2026-10-03: **417 tests, 0
failures**. In a later rerun under heavy machine load
`FullReaderPageEffectTests.testSwitchingAllEffectsDoesNotPreparePagesOrRestartInk`
and once `FullReaderInkTests.testInitialOpeningAndNavigationAtPhoneSize` timed
out (500+ s runs, 15 s waits); they drive `ReaderViewModel` directly and passed
in the full run on the same app build — timing flakes, not the EPUB surface.

**Reopen could save the chapter's start (fixed 2026-10-18).** Readium goes
idle as soon as it starts loading a spread, so under load a new navigator's
first report can be progression 0 of the chapter it was asked to open
further into, before the web view has scrolled. The surface saved every
report, so for a moment the book's saved place was the chapter's start (lost
for good if the app died then). `EPUBNavigatorContainerController` now holds
such reports back (`isUnsettledLoad`) until the navigator reports any other
place, asks Readium again to go to the saved place, and does not use a timer
(the first report can take over a second). `testOpensAtTheSavedLocator…` now
checks every report after reopen, not only the first. Before the fix it failed
about 1 run in 9 to 15; after, 40 of 40. Full suite: 418 tests, 1 failure, the
known `FullReaderPageEffectTests` flake above (it passed 3 of 3 run after the
hosted EPUB tests).

## Phase 4 — Typography *(engineer 4)*

The reason for this whole project.

- [x] Font family: Publisher default, plus a curated set (e.g. New York,
      Georgia, Palatino, Avenir Next, SF Pro, OpenDyslexic if bundled with
      its licence).
- [x] Font size: a slider or steps (roughly 75%–250%), live.
- [x] Text colour and background: themes (Paper, Sepia, Grey, Night) plus a
      custom text colour, with a contrast warning below WCAG AA.
- [x] Margins: from tight ("a little gap, not much") to wide, so text can sit
      close to the screen edges.
- [x] Line spacing and justification (publisher / left / justified).
- [ ] "Publisher defaults" resets everything.
- [x] Settings persist globally, with an optional per-book override, and
      survive relaunch.
- [x] Changing any setting keeps the reader on the same text (Locator-based).
- [ ] A typography panel reachable from the reader's controls, matching the
      app's existing visual style; works with Dynamic Type and VoiceOver.
- [x] *Check:* screenshots at the smallest and largest size, each theme, and
      tight vs wide margins; a test that settings map to the right
      `EPUBPreferences`.

### Notes from Phase 4

**Files.** `Paperbound/Model/TypographySettings.swift` (the value: font, size,
theme, custom ink, margins, line height, alignment; WCAG `ColorContrast`;
DEBUG demo parser), `Paperbound/Model/TypographyStore.swift` (global + per-book
storage on `AppSettings`), `Paperbound/Reader/EPUB/TypographyPreferences.swift`
(pure `TypographySettings → EPUBPreferences` mapping, and
`TypographyLiveApplier`), `Paperbound/Reader/EPUB/TypographyPanel.swift` (the
"Aa" sheet), `PaperboundTests/TypographyTests.swift`. Hooks in shared files:
`AppSettings` (two defaulted keys `settings.epubTypography`,
`settings.epubTypographyOverrides`), `ReaderPanel.typography`, one line in
`ReaderViewModel.init` (submits the book's typography to `epubBridge` so the
first layout already uses it), and in `ReaderView` the "Aa"
(`textformat.size`) button for EPUB books, the panel case and the medium
detent.

**Fonts.** Book's font (nil), New York (`ui-serif` — WebKit does not expose
it by name), Georgia, Palatino, Iowan Old Style, Avenir Next, San Francisco
(`system-ui`), OpenDyslexic. OpenDyslexic is not bundled by us: Readium ships
the files in its navigator resource bundle and declares the `@font-face`
itself (the panel registers the same file to preview it). OpenDyslexic is
under the SIL Open Font License; Readium's bundle carries no licence file for
it, so add one to the app's acknowledgements before release. Seven of the eight
were seen rendering on the simulator; San Francisco (`system-ui`) is mapped and tested but was not screenshotted.

**Themes.** Paper `#FBF8F1`/`#1E1B17`, Sepia `#F2E6CE`/`#3B2D1C`, Grey
`#4A4A4D`/`#F0EFEB`, Night `#121212`/`#C9C4BA` (Night also darkens images).
Every theme ink clears 7:1 (tested). A custom ink below 4.5:1 shows a warning
with the ratio. Grey and Night use Readium's dark theme as a base, with
explicit colours on top.

**Margins.** Readium's `pageMargins` multiplies its page gutter (20 pt on a
phone, 30 pt phone-landscape, 40–50 pt on tablets). Default **0.5** (10 pt on a
phone): clear of the rounded corners, not a frame. Steps 0.25…2.5
(5–50 pt). Verified in CSS (`padding-left: 10px` → `40px`). On the Duo cover
display the empty band on the right is the surface's camera cut-out
reservation, not the margin.

**Publisher styles.** Line height and alignment only work with
`publisherStyles = false`, so it is turned off only when one of them is set;
font, size, colours and margins keep the book's own styling.

**Position across changes — Readium does not do it.** A preference change
updates CSS in the loaded page and snaps by scroll offset, so shrinking the
text moved the reader *forward* (test: progression 0.025 → 0.125).
`TypographyLiveApplier` takes `firstVisibleElementLocator()` before the first
change of a burst and `go(to:)`s back to it after 350 ms. Use it (not
`bridge.submit`) for any live typography change.

**Persistence.** Per-book overrides are JSON in UserDefaults keyed by
`Book.id`, not a `Book` field: no SwiftData migration, and it is a reading
preference like the page-turn style. Decoding is lossy-safe (missing or unknown
values fall back; damaged entries are dropped). Orphaned overrides of deleted
books are not cleaned up (`removeTypographyOverride(for:)` exists).

**DEBUG hooks.** `-paperbound-demo-typography "font=georgia,size=2.5,theme=night,margins=0.25,spacing=1.5,align=justified,ink=E3B266"`
presets the global typography for that launch (not persisted).
`-paperbound-demo-panel typography` opens the sheet;
`PAPERBOUND_TYPOGRAPHY_SCROLL=font|layout|reset` (via `SIMCTL_CHILD_`) scrolls it.

**Verified (2026-10-01, Xcode 27.1, iPhone Duo 27.1 clone).**
`TypographyTests` 20 tests, 0 failures; `TypographyNavigatorTests` 1 test, 0
failures (hosts the real navigator: CSS padding, font family, colours, justify,
and the first visible element stays on screen after a size change). Full
`PaperboundTests`: 419 tests, 6 failures, none in typography (5 in
`EPUBReaderSurfaceHostedTests`, 1 float-rounding in `EPUBAnnotationsTests`; see
below). Screenshots (cover display): 75% and 250%, each theme, margins 0.25 vs
2.5, justified + 1.65 spacing, left-aligned, OpenDyslexic, the panel (top,
fonts, layout, low-contrast warning, Night with amber ink, accessibility-large
text). **Not verified:** "Publisher defaults" and the per-book toggle were not
tapped on screen (simulator cannot tap; the store logic is unit-tested);
VoiceOver labels are set but were not run with VoiceOver; the Duo inner
display was not captured. Those boxes stay unticked.

**Note for engineer 3.** `EPUBReaderSurfaceHostedTests` builds a scene-less
`UIWindow(frame:)`; on this runtime such a window is never laid out and the web
view stays 0×0 (I hit the same thing). `UIWindow(windowScene:)` with the host
app's scene fixed it in `TypographyNavigatorTests`.

## Phase 5 — Reading tools *(engineer 5)*

- [ ] Highlights: select text, and the existing highlight action bar (styles,
      colours, Copy, Clear) works on EPUB. Marks are drawn with Readium
      decorations and stored with a Locator. Tapping a mark opens it.
- [x] Highlights survive font, size and margin changes.
- [x] Search across the book (Readium search service) in the existing search
      panel, jumping to and flashing the result.
- [x] Contents panel shows the EPUB's table of contents, nested.
- [x] Bookmarks use Locators and sort correctly with `orderKey`.
- [ ] Read aloud works for EPUB (Readium TTS or the existing
      `SpeechController` fed with the current text).
- [x] *Check:* tests for highlight storage and round-trip; screenshots of a
      highlight, a search result and the contents panel.

### Notes from Phase 5

**Files (engineer 5).** `Paperbound/Reader/EPUB/EPUBAnnotationsAnchor.swift`
(quote anchoring, `EPUBTextRange`), `EPUBAnnotationsDecorations.swift` (style
mapping, templates, groups), `EPUBAnnotationsController.swift` (selection, the
bar's rules, storage, search flash, DEBUG staging), `EPUBAnnotationsOverlay.swift`
(the bar over the surface), `PaperboundTests/EPUBAnnotationsTests.swift`.
Shared-file edits, all additive: `Highlight.locatorJSON: String? = nil`
(Book.swift); `ReaderViewModel.epubAnnotations` plus one `install(model:)` call in
`loadEPUB()` before the engine is published (templates are creation-time);
one `.overlay { EPUBAnnotationsOverlay(model:) }` line in `EPUBReaderView`;
an EPUB `flash(result)` call in `SearchPanelView`; EPUB position labels and
wording in `ContentsPanelView`, whose outline load is now keyed on
`model.isLoading` (a panel opened during loading used to stay empty forever).
`HighlightActionBar`, `ReaderAnnotationOverlay` and every PDF path are unchanged.

**Selection and the bar.** The selection is Readium's native web selection.
`bridge.shouldShowMenuForSelection` returns `false` (no system menu) and feeds the
controller; `HighlightActionBar` is shown at the selection's frame (converted to
window coordinates, so the navigator's inset around the fold does not matter).
The rules are `PagedReaderView.applyMark`'s, verbatim: a chosen style tapped
again comes off, a new style goes on in the existing colour, a colour recolours
what is under the selection or marks it fresh, marks under the selection show as
chosen, Clear removes every overlapping mark, the selection stays open. Readium
does not report a selection being *dropped* by a tap, so the controller polls
`currentSelection` every 0.3 s while one is open. A decoration tap
(`observeDecorationInteractions`) opens the mark in edit mode with Delete (the
open mark is drawn `isActive`); `tapInterceptor` closes it, and a page turn
closes it too. "Tap the selection to grow it to the sentence" is PDF-only (the
web view's own selection gestures apply instead).

**Storage.** A mark is a `Highlight` with `locatorJSON` = the Readium locator
(href + the quote `highlight`/`before`/`after`, which is what Readium anchors the
decoration on), `location` = the same locator as a `ReadingLocation`,
`normalizedRects` empty, and `rangeLocation/rangeLength` = the canonical range
below. The page's `cssSelector` is dropped (it would restrict Readium's search
for the quote to one element); progression/totalProgression/position are
recomputed from where the quote sits in the chapter, so `orderKey`
(= totalProgression × 10⁶, as bookmarks) sorts marks in reading order.

**Overlap detection.** Readium gives quotes, not offsets. Each chapter's XHTML is
reduced to an approximation of `body.textContent` (what Readium's quotes come
from), then *all* whitespace (and soft hyphens, zero-width chars) is removed,
because `Selection.toString()` and `textContent` disagree only on whitespace. The
quote is found in that canonical text; repeats are disambiguated by how much of
`before`/`after` matches, then by the progression hint. Result: `EPUBTextRange`
(href + UTF-16 range). Two marks overlap iff same resource and the ranges
intersect (touching is not overlapping). If a chapter could not be read, it falls
back to quote containment. On a two-page spread Readium labels a selection with
the spread's current href, so anchoring also tries the neighbouring resources and
corrects the href.

**Decorations.** highlight → Readium `highlight`; underline → Readium `underline`
(templates rebuilt with alpha 0.45 to match PDF marks); strikethrough → custom
`paperbound-strikethrough` (a 2 px rule through the middle of each line box);
squiggly → custom `paperbound-squiggly` (a percent-encoded inline SVG wave under
each line, coloured per mark — percent-encoded because XHTML parses the element
as XML). All four render; no fallback was needed. Groups:
`paperbound-highlights`, `paperbound-search`.

**Search.** Unchanged panel; on EPUB a tapped result is flashed (a `highlight`
decoration with `isActive`, 3 s) and the jump goes through `model.go(to:)` with
the result's own locator, so Readium lands on the match.

**Contents / bookmarks.** The nested TOC shows with Readium position numbers
(same numbering as the slider). Bookmarks were already Locator-based; tested.

**Read aloud — not ticked.** `speakCurrentPage()` feeds `loadText(at:)` to
`SpeechController`; tested that each position's text starts at that position,
stays in its chapter, and that the positions together cover the chapter's last
sentence. Not verified: audio itself (no audio check in the simulator). Where it
stops: at the end of the current Readium *position* (~1,000 chars of source,
≈ 2,200 characters of text in the sample), which is not the visible screen —
it can stop mid-screen or run past it — and it does not continue to the next
position on its own (same as the PDF reader, which reads one page). Swiping
pages does not restart speech (`reportVisible` does not announce), also as PDF.

**DEBUG staging** (simulator has no touch), with `-paperbound-demo-epub`:
`PAPERBOUND_DEMO_EPUB_PAGE=n` (go to position n first),
`PAPERBOUND_DEMO_EPUB_MARKS=1` (one mark per style on the first sentences on
screen), `PAPERBOUND_DEMO_EPUB_SELECT=1` (selects a sentence with the DOM
selection API — reported through Readium exactly like a finger),
`PAPERBOUND_DEMO_EPUB_EDIT=1` (opens the oldest mark), `PAPERBOUND_DEMO_EPUB_SEARCH=q`
(search, jump, flash), `PAPERBOUND_DEMO_EPUB_FLASH_SECONDS=s`. Pass them with
`SIMCTL_CHILD_`.

**Verified (2026-10-03, Xcode 27.1, iPhone Duo 27.1 clone, cover display).**
`EPUBAnnotationsTests`: 16 tests, 0 failures. Full `PaperboundTests`: 417 tests,
2 failures (1 unexpected), both in the one test
`FullReaderPageEffectTests.testSwitchingAllEffectsDoesNotPreparePagesOrRestartInk`
(enchanted-ink completion timeout under full-suite load); that suite and `FullReaderInkTests` rerun alone: 4 tests,
0 failures. `HighlightActionBarTests` 21/0, `TextSelectionSessionTests` 8/0.
Screenshots: four styles drawn as decorations; a real (DOM) selection with the bar
above it showing the colour under it as chosen; the same marks re-anchored after
relaunching at size 2.0 / tight margins / sepia and at wide margins; an open mark
in edit mode with Delete; a search result ("ironmonger") jumped to and flashed;
the nested contents panel.

**Not verified / limits.** A finger long-press and a finger tap on a decoration
(no touch injection) — the activation callback path is covered by tests calling
the same handler, not by Readium firing it; hence the first box stays unticked.
Highlight survival was checked across relaunches with different typography, not
by watching a live change (Readium re-lays decorations out on resize). The bar's
container is the safe area only, so with the reader controls showing it can sit
under the top bar (the PDF overlay computes its container the same way).

## Phase 6 — Physical effects on EPUB *(later, not in this round)*

- [ ] Snapshot the visible page of the web view so the page curl can bend it.
- [ ] Enchanted Ink and page effects on a snapshot of the page.
- [ ] Paper wear anchored to stable content segments, per `stablePageID` in
      `ReadingEngine.swift` (wear belongs to the text, not to a screen).

## Phase 7 — Hardening

- [ ] Large books (1,000+ pages) open quickly; memory stays bounded.
- [ ] Right-to-left and vertical-writing books display correctly.
- [ ] Fixed-layout EPUBs (picture books, comics) open in their own mode.
- [ ] Accessibility pass: VoiceOver reads the text, controls are labelled.
- [ ] The root `README.md` gate table marks milestone 6 as done.

---

## Definition of done for this round (Phases 1–5)

- A user can import an EPUB, see its cover, open it, read with page turns,
  change font, size, colour and margins, highlight, search, use the contents,
  and reopen at the same place.
- All existing PDF tests pass, and the PDF reader looks and behaves as before.
- New EPUB tests pass.
- Nothing is committed without the owner's go-ahead.

## Known limits

- No DRM support (LCP may come later).
- The physical page effects do not apply to EPUB until Phase 6.
- `xcodebuild test` on the Duo simulator can hang after the tests pass, in
  `simctl diagnose`; read the `Test Suite ... passed/failed` lines from a log
  file and stop the process.
- Tests that put a Readium navigator on screen must host it with
  `HostedTestWindow` (in `PaperboundTests/`) and close it in a teardown block.
  Only hiding the window keeps its web view alive in the scene, and that
  stalled the full-reader PDF tests that ran later in the same process (pages
  never became ready, ink reveals never finished). Fixed 2026-10-04; the full
  suite then passed twice in a row, 417 of 417.
