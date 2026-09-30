# Page-effect validation — 2026-09-30

## Toolchain and scope

- Xcode 27.1, build **27A9269**, selected per command from `~/Downloads/Xcode.app`.
- iOS Simulator SDK **24A94403**; iPhone Duo runtime **24A94401**.
- Primary simulator: `97A96543-D458-4F98-8BC4-570B4F9B2E56`.
- Metal API Validation was enabled during the simulator test runs.
- New effects use Canvas sprites; Enchanted Ink's Metal simulation is unchanged.

## Loading measurements

These measurements are the initial effect implementation's baseline, before the
continuous articulation revision below; they have not been rerun for that revision.

Each of the twelve selections received **10 fresh reader openings and 30 cached
turns**, using the same sample document and current Duo geometry with Instant text.
A fresh opening creates a new reading model, PDF engine, and CPU page cache. It is
**not** a fresh app-process launch or a cold filesystem-cache measurement. Cached
turns alternate between two already-prepared units. Times end at visible paper
readiness, independently of artwork initialization or animation completion.

| Selection | Fresh reader p95 (ms) | Cached turn p95 (ms) |
|---|---:|---:|
| none | 156.3 | 28.6 |
| footsteps | 137.7 | 37.4 |
| paperMessengers | 147.8 | 36.4 |
| marginCreatures | 135.6 | 38.1 |
| pixieDust | 140.6 | 41.3 |
| wanderingWisps | 172.3 | 38.3 |
| enchantedButterflies | 140.7 | 39.3 |
| fallingRosePetals | 136.4 | 38.1 |
| floatingLanterns | 136.8 | 38.2 |
| wonderlandCards | 138.9 | 37.3 |
| winterMargins | 143.1 | 37.7 |
| littleHearthSpirit | 135.4 | 37.3 |

All ten additions remained below the target of 50 ms additional p95 readiness
relative to None in this simulator run. This measures the loading path, not GPU
frame execution or physical-device energy use.

## Regression evidence

- The initial implementation's full suite passed **237 tests**, including hosted full-reader ink navigation,
  page-effect switching, migration, asset-cache memory, seeded movement, pauses,
  bounded sprites, and Canvas clipping.
- The hosted reader switched through every new effect with both Instant and
  Enchanted Ink. The provider's cache-miss preparation count stayed unchanged,
  proving no additional PDF/compositor jobs; ink visit identities/counts stayed
  unchanged.
- One subsequent focused run timed out in the hosted reader test; the loading
  benchmark itself completed and passed. The final focused run after isolating
  asynchronous artwork ownership passed the reader test again. The timeout's
  precise cause was not established; do not characterize it as a proven fix.
- Final focused checks passed: **8 tests**, followed by **7 tests** after adding
  the preview background/Reduce Motion guard.
- The final code snapshots sprite values before asynchronous Canvas drawing,
  and uses separate ownership tokens for asynchronous asset requests so a canceled
  request cannot release another request's cache lease.

## Visual artifacts

`Screenshots/PageEffectReview/index.html` selects among ten 12-second animated GIFs.
`contact-sheet.png` and individual PNGs include actual sample text at reading size
and enlarged artwork. These use the production controller/drawing path and a fixed
seed, now sampled at 30 fps with enlarged animated detail. GIF playback can quantize
frame timing. The clips are renderer exports,
not recordings of app navigation. Paper surfaces are white; effects do not tint PDFs.

The expanded picker was visually inspected on the inner landscape display;
its preview/replay controls remain above the list.

## First continuous motion revision (superseded below)

- Removed pose cycling from moving characters. A registered drawing now uses
  articulated wing/leg parts and continuous flame-band deformation. This avoids
  changes in silhouette, scale, and registration between unrelated drawings.
- Prepared arc-length route tables keep speed even. Persistent actors retain their
  endpoint, heading, and stride across rests and subsequent journeys. Destinations
  and waypoints explore page interiors and neighboring sheets.
- Added tests for continuity at journey boundaries, intermediate wing shapes at
  30 Hz, stride speed, interior routes, and conservative rig-memory accounting.
- Final focused run passed **11 tests** on the same recorded Xcode/SDK/runtime:
  nine controller/cache tests, the hosted full-reader switching test with both
  text modes, and the production Canvas capture/clipping test. Switching still
  caused zero page preparations and no additional ink visits. Result bundle:
  `/tmp/paperbound-effects-build/Logs/Test/Test-Paperbound-2026.09.30_10-28-16--0700.xcresult`.
- Enlarged production-renderer frame sequences were inspected for butterflies,
  creatures, cards, wisps, and the hearth spirit. Card leg crops were adjusted to
  avoid moving part of the body with the feet. All ten comparison clips were
  regenerated at 30 fps; these are still lightweight articulated illustrations,
  not hand-drawn frame-by-frame character animation.
- Route preparation and bitmap slicing happen outside frame drawing. The 16 MiB
  asset limit includes cropped parts conservatively, even when CoreGraphics
  shares backing storage. The 30 Hz cap and page-readiness independence remain.

## Grounded walking, flames, and continuous weather

- Replaced swinging leg crops with planted page-space foot contacts, eased swing
  recovery, bent-knee legs, and isolated illustrated boots/feet. Slower 18–26 pt/s
  travel keeps the gait readable. Removed boot fragments from the card torso crop.
- Replaced flame-strip deformation with small continuously changing vector flame
  contours and gradient fills. Independent tips stretch and curl; the base stays
  anchored. These are stylized flames, not physically simulated fire. Wisps use
  the same renderer at a slower rate. No image pose switching remains in either.
- Three persistent actors now occupy each character effect. Plane flights,
  lantern arrivals, and fairy trails overlap. Petals and snow use independent
  continuous emissions, mixed fall speeds, and coherent wind with individual
  flutter. A bounded prefilled population avoids an empty start or batch gaps.
- Added regression checks for stationary stance contacts, lifted recovery,
  continuously populated weather, multiple subjects, and changing flame outlines.
  **14 focused tests passed**, including the real reader with Instant and Enchanted
  Ink. PDF/compositor preparation and ink visit counts remain unchanged when
  selecting effects. Following the final flame-outline and opacity adjustments,
  all **13 controller/cache and production-renderer tests passed again**.
- Final capture result:
  `/tmp/paperbound-effects-build/Logs/Test/Test-Paperbound-2026.09.30_10-54-03--0700.xcresult`.
- Reconfirmed Xcode **27A9269**, SDK **24A94403**, and Duo runtime **24A94401**.
  Metal API Validation was enabled. Enlarged sequential frames and sample-page
  captures were inspected; all ten 30 Hz comparison clips were regenerated.
- Installed on both booted Duo simulators, with Falling Rose Petals selected on
  the primary device and Little Hearth Spirit on the secondary device.
- No rasterization, compositing, readback, blur, or fluid simulation was added.
  CPU/GPU frame time and loading benchmarks have not been rerun for this revision;
  the earlier loading table remains a baseline, not a new performance claim.

## Purposeful scenes and weather arrivals

- Removed the prefilled particle population and fixed replacement cadence. Each
  scene starts empty. New visitors originate beyond the complete viewport, then
  enter the paper; folds and interior sheet edges are not spawning boundaries.
- Character groups vary from one to four (hearth spirits one to three). Creatures
  and cards arrive at spaced meeting positions, wait for their companions, face
  one another, and depart in order along a shared route. Actor identity, gait,
  position, and phase continue across the encounter. There are quiet spells after
  groups leave. These are coordinated behaviors, not a general collision/AI system.
- Petals are now 25–39 points long. Prepared, uniformly timed trajectories integrate
  drag, terminal settling speed, gusts, and individual flutter; the renderer samples
  those trajectories without doing physical integration each frame. Snow and
  petals arrive in uneven bursts with varying totals, depths, and intervals.
- Tall-spread admission checks reserve capacity across each particle's lifetime.
  Excess proposed emissions are skipped before entry. Existing particles are not
  removed and later exposed by truncating an overfull draw list.
- Full-reader switching passed with both text modes and unchanged PDF preparation
  and ink visit counts. The scene/physics tests cover empty starts, external entry
  and exit, handoff continuity, companion ordering, variable populations, quiet
  spells, larger petals, deterministic trajectories, and stacked-display capacity.
- Final focused run passed **16 tests** (15 controller/cache/physics tests and the
  hosted reader regression). The two renderer capture checks passed in the
  preceding runs. Final result:
  `/tmp/paperbound-effects-build/Logs/Test/Test-Paperbound-2026.09.30_11-19-03--0700.xcresult`.
- Regenerated all ten production clips at 30 Hz, now 30–60 seconds long. Added a
  separate seed-2 two-creature encounter clip and a sequential contact sheet to
  show arrival, waiting, and following across the gutter. The gallery uses that
  encounter for Margin Creatures; other clips use seed 731. No new artwork or
  page-rendering passes were introduced.
- Xcode 27.1 **27A9269**, SDK **24A94403**, runtime **24A94401**; simulator Metal
  validation enabled. Loading and physical-device frame benchmarks remain pending
  for this revision; older measurements above are historical baselines.

## Conversation, visible snow, and smoother character rendering

- Addressed two concrete sources of visual discontinuity: independently blended
  overlapping character parts and abrupt facing/foot changes at route boundaries.
  Articulated actors now composite as one opacity group; ordinary particles draw
  directly. Turns are time-based and resting feet settle before the next route.
- Social walkers arrive in groups of two to four. After everybody arrives, each
  takes a 2.6-second speaking turn, with a wordless speech bubble and body gesture;
  listeners nod in response. The group leaves after the conversation. This makes
  interaction visible rather than encoding it only as waiting and following.
- Slowed wisps to 24–36 pt/s and butterflies to 30–44 pt/s. Wingbeats, hovering,
  lantern ascent, fairy passages, and petal fall/flutter are more leisurely.
- Snow's pale, small sprites were difficult to distinguish on white paper, and
  outside entrances could delay visible activity. Flakes now measure 14–23 pt and
  use blue-gray shading on light paper/pale blue on dark paper, up to 60% opacity.
  The first flakes enter from a nearby outer edge. Variable bursts and lulls remain.
- **23 checks passed**, including the full reader, controller tests, both capture
  tests, and actual renderer regressions. Pixel checks confirm snow contrast on
  white paper at full and preview scale and 50% character opacity even where
  multiple parts overlap. Conversation tests verify alternating speakers and
  listener reactions; continuity tests cover turning and planted feet.
  Result: `/tmp/paperbound-effects-build/Logs/Test/Test-Paperbound-2026.09.30_11-33-49--0700.xcresult`.
- Final particle drawing optimization and conversation close-up passed **21 checks**:
  `/tmp/paperbound-effects-build/Logs/Test/Test-Paperbound-2026.09.30_11-37-15--0700.xcresult`.
- All comparison clips were regenerated. The dedicated encounter clip includes
  enlarged speech/gesture detail. These fixes address the inspected artifacts;
  they are not proof that every possible visual glitch has been eliminated.

## Varied character encounters (September 30, 2026)

- Replaced the fixed round-robin conversation with prepared, seeded social cues
  for creatures and cards. A shuffled subset participates; others traverse one
  uninterrupted route, without stopping or displaying a reply. Some encounters
  are unanswered greetings. Speaker choice, question/chat choice, response delay,
  number of exchanges, and each participant's departure vary independently.
- Added drawn `?` and `!` bubbles. Questions can elicit a brief surprised torso
  recoil/stretch or a nod. Gestures ease in and out, preserve foot contact, and
  pause on the same clock as locomotion. Artwork and PDF preparation are unchanged.
- **23 focused checks passed**: 19 controller/persistence/lifecycle checks, three
  actual Canvas pixel checks, and a two-sequence capture check. Forty seeds exercise
  mixed participation, unanswered questions, distinct cues, causal responses,
  early departures and deterministic replay. Motion assertions confirm ignoring
  visitors actually keep moving through the gathering.
- Inspected production-renderer captures over real PDF pages at reading size and
  enlarged detail: `Screenshots/PageEffectReview/marginCreatures-encounter.gif`
  (seed 0, mixed participation) and `marginCreatures-ignored.gif` (seed 4, unanswered
  question). The gallery opens the updated encounter and includes both variants.
- Xcode **27.1 (27A9269)**, SDK **24A94403**, Duo runtime **24A94401**;
  Metal API Validation enabled. Focused result:
  `/tmp/paperbound-effects-build/Logs/Test/Test-Paperbound-2026.09.30_12-59-29--0700.xcresult`.
  That run also included the full-reader check, which timed out at Enchanted Ink
  completion after the Instant effect-switching phase. An isolated retry on the
  same simulator repeated that timeout. The unchanged full-reader test then
  **passed on the second Duo simulator**, including both ink modes, zero extra
  page preparation during effect switching, stable ink visits, and navigation:
  `/tmp/paperbound-effects-build/Logs/Test/Test-Paperbound-2026.09.30_13-02-32--0700.xcresult`.
  The primary simulator timeout remains a validation caveat; no unrelated ink
  behavior was changed or test expectation weakened.

## Remaining validation limits

- Physical-device additional frame-work target (**under 2 ms**), energy/thermal
  measurements, and real-device loading timings are pending.
- Full manual matrix of Duo outer/inner displays, live folding, camera cutouts,
  multitasking resize, pinch gestures, canceled physical swipes, and Mac trackpad
  forwarding is pending; existing geometry and navigation automation is retained.
- Fresh-process app-launch benchmarking and additional imported illustrated/scanned
  document review are pending. No zero-cost or GPU-free claim is made.
