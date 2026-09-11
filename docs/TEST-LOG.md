# Test log

**Everything below was actually compiled and actually run.** Nothing in this file
is a projection. The raw output is in `docs/logs/build-and-test.txt`.

## Environment

| | |
| --- | --- |
| Host | Linux 6.18.44 x86_64, Ubuntu 24.04.4 LTS |
| Toolchain | `SwiftWasm Swift version 5.9.1 (swift-5.9.1-RELEASE)`, target `x86_64-unknown-linux-gnu` |
| Build system | SwiftPM, `swift-tools-version:5.9` |
| Test framework | XCTest (corelibs) |
| Date | 2026-09-11 |

A note on the toolchain, because the name is confusing: this is the standard
Swift 5.9.1 compiler and standard library, distributed by the SwiftWasm project,
and it was used to build and run **native x86_64 Linux** binaries — not
WebAssembly. It was used because the usual `download.swift.org` host is blocked by
this environment's egress policy. `swift --version`, the build log and the test
log in `docs/logs/` are the primary evidence.

## Result

```
$ swift build
Build complete!                     0 warnings, 0 errors

$ swift build --build-tests
Build complete!                     0 warnings, 0 errors

$ swift test
Executed 127 tests, with 0 failures (0 unexpected)
```

| Suite | Tests | What it covers |
| --- | ---: | --- |
| `PoseWeightsTests` | 9 | Clamping and NaN handling, the layering budget over every pair of expressions, continuity, masking, the bundled pose table, the smooth-step shape |
| `TimeTests` | 8 | First frame, accumulation, NaN, infinity, rewound clock, oversized step, re-synchronisation, invalid cap |
| `SequenceValidationTests` | 8 | Structural refusals, non-finite timing, clamping, overlong sequences, zero-length endless sequences, repeat and jitter repair |
| `ArbitrationTests` | 15 | Three-beat run, interruption, reversal, lower priority, equal priority, `rejectIfBusy`, queueing and queue order, queue bound, cancel, cancel-all, no standing overlay, timer term, repeats, endless |
| `SpeechAndBlinkTests` | 12 | No mouth column is written, smile survives speech, parted withheld, pose untouched with nothing running, the reservation holds across a sentence boundary, strict mask, silent gap, blink pass-through, hold, proportional fade under a rest overlay, continuity with a blink in flight, fade switchable, trigger edge, per-repeat triggers |
| `LifecycleTests` | 12 | Hide, hidden pass-through, refusal while hidden, resume, idle re-arm, large step, idle off, idle off mid-sequence, ambient refusal, speech pause, reset |
| `RobustnessTests` | 9 | NaN clock, poisoned base pose, rewound clock, 6 000-frame hostile fuzz, 3 000-frame realistic fuzz, zero-length steps, zero blend, duplicate timestamps, no internal clock |
| `BridgeTests` | 6 | Vocabulary taken from the app's own table, bundled copy matches, both-way enum bridging, exact pose conversion, poisoned pose, timer-change edge |
| `EyelidCompositionTests` | 13 | The eyelid contract: the rest ladder 0 / 0.30 / 0.55 / 0.70 / 1, the same frames scored under the composition 1.2.0 replaced, the exact crossover at a half, rest changing mid-blink, cancel and preempt mid-blink, base rest and overlay rest together, and the measured travel and visible-frame table |
| `CompositionAcceptanceTests` | 15 | Composition, mouth ownership and the speech-mask interactions. Set out in full in `docs/ACCEPTANCE.md`, including the three defects they found and the one interaction they bound |
| `RenderLoopTests` | 12 | Mouth columns untouched, aperture identical with and without a sequence, closures and pauses stay closed, smile survives while parted does not, `RestMouthReturn` sole ownership, manual expression with idle off, layering over a manual expression, timer returns to false, blink request reaches `BlinkClock`, eye-rest holds the blink, hide/resume, every rendered frame in range |

The two fuzz tests drive roughly 9 000 additional frames with hostile inputs
(NaN and negative timestamps, 600-second jumps, out-of-range base poses, random
submissions, cancels and presentation changes) and assert on every one of them
that the output stays finite, inside `0...1`, and never makes the weight budget
worse than the base pose already was.

## The command-line demo was run too

All eleven scenarios ran and their output is committed under `examples/output/`.
Regenerate with `./examples/run-all.sh`. The determinism claim was checked by
running the idle scenario twice with the same seed and comparing bytes, and by
running it across five seeds to confirm the choice actually varies.

## What was NOT verified here, and why

Stated plainly, because these are real gaps:

* **Nothing was compiled against macOS or AppKit.** There is no macOS SDK in this
  environment. The core and the adapter are Foundation-only and contain no
  platform API, so they compile here; `DesktopController.swift` itself was never
  built, on any platform.
* **The app was not built or launched.** This package is standalone, as asked.
  The four insertion points in `docs/INTEGRATION.md` are described against the
  0.3.4 snapshot in `reference/`; they have not been applied to the installed app
  and no one has compiled the result.
* **The adapter was type-checked against a copy, not against the app.** `integrations/ChoreographyHostKit/MotionHostShim.swift` is an excerpt of the
  app's `Motion.swift` reproduced verbatim except for `public` modifiers. If the
  real file has diverged from the snapshot in this task package, the adapter
  could still fail to compile in the app. `BridgeTests` checks the pose table and
  both enum directions against that copy, which is the closest check available
  without the app.
* **Nothing visual was checked.** No renderer, no window, no artwork. Whether a
  sequence *looks* right is not something these tests can say. They assert
  numeric continuity — no frame-to-frame jump larger than the blend itself
  implies — which is a necessary condition, not a sufficient one.
  `docs/ACCEPTANCE.md` lists the five specific things that still need an eye.
* **No timing or performance measurement on a real 24 fps run loop.** The module
  does a few dozen floating-point operations per frame and allocates only the
  notice array, but that has not been profiled on the target machine.
* **The lighting and background jump during speech was not investigated**, tested
  or affected. It is outside this module by design.
* **Swift 6 strict concurrency was not exercised.** The package builds in Swift 5
  language mode. Value types are `Sendable`; `ChoreographyDirector` is a
  deliberately non-`Sendable` class meant to be driven from the same thread as
  `renderFrame()`.

## Second pass: composition review

`docs/ACCEPTANCE.md` records a follow-up review of how the module's expression
weights reach the mouth. It corrected an over-broad claim in this delivery (the
module cannot write the mouth *columns*, but `parted` and `pressed` do shape the
mouth), found three real discontinuities and fixed them, and bounded a fourth
interaction that is inherent rather than a defect. The fifteen cases in
`CompositionAcceptanceTests` are the result and are included in the 114 above.

## Third pass: local integration patch review

`docs/PATCH-REVIEW.md` reviews the 0.3.5 integration patch against the nine
points. The wiring is correct on all nine. Two things came out of it:

* The 12 on-device acceptance cases cannot distinguish core 1.0.0 from 1.1.0 —
  the bridge is byte-identical between the two versions, the 1.1.0 bridge
  compiles cleanly against the 1.0.0 core, and none of the four sequences the
  cases play carries a masked component. Measured on both cores here: the same
  input steps `pressed` by 0.272 on 1.0.0 and 0.000 on 1.1.0.
  `integrations/local-patch-review/` carries a compile-time and a runtime proof.
* Reduce-motion is not wired to `setIdleEnabled`. The minimal fix is in
  `integrations/local-patch-review/reduce-motion.patch`; the module behaviour it
  relies on is verified here, the AppKit code itself is not.

## Fourth pass: the eyelid contract (1.2.0)

`docs/EYELID-CONTRACT.md`. The local team's on-device C preview found a blink
that was numerically present and visually absent at `rest ≈ 0.55` (eye pixels
max 5, mean 0.08). The cause was mine: `PortraitRenderer.blinkAmount` already
composes eyelid closure once with `max(pose.rest, frame.blink)`, and 1.1.0
multiplied the blink by `1 - overlay.rest` upstream — a second composition point.
`max(rest, blink × (1 − rest))` hides the blink for every `rest ≥ 0.5`, which is
arithmetic, not tuning.

1.2.0 deletes that rule; the renderer is untouched. Measured on both cores here,
travel at `rest = 0.55` goes from 0.000 to 0.450 and the final peak reaches full
closure. `EyelidCompositionTests` scores the identical frames under both
compositions so a case that cannot separate them fails rather than passing twice.

This also corrected a claim made in the previous pass: the four-way weight sum is
**not** a renderer requirement. `rest` feeds only `blinkAmount`, `parted` only
`mouthOpening`, and `mouthPose` normalises the `smile`/`pressed` pair itself.

## Reproducing

```
swift build
swift test
./examples/run-all.sh
```
