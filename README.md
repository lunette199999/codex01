# ExpressionChoreography

A small, portable Swift module that turns the six expressions the portrait
already has into **describable, composable, cancellable sequences** with explicit
priority — and nothing else.

It is the choreography layer only. It receives time, events and the host's own
state, and returns expression weights, a blink value, and whether the host's
frame timer is still needed. It never reads a clock, starts a timer, spawns a
thread, touches the screen, opens a socket, or calls a model or speech service.
The core depends on Foundation alone.

* `Sources/ExpressionChoreography/` — the portable core.
* `integrations/ChoreographyHostKit/` — the drop-in adapter onto `MotionFrame` /
  `ExpressionPose`, plus a compile-check shim and a head-less reproduction of
  `DesktopController.renderFrame()`.
* `examples/ChoreographyDemo/` — `choreo-demo`, a per-frame CSV/JSONL dump.
* `Tests/` — 97 XCTest cases; see [docs/TEST-LOG.md](docs/TEST-LOG.md) for what
  was actually compiled and run.
* [docs/INTEGRATION.md](docs/INTEGRATION.md) — the four insertion points.

---

## What this does not do

Stated first, because the boundaries matter more than the feature list.

* **It does not fix the lighting and background jump during speech.** It cannot:
  it never touches the renderer, the relight settings, the background, or any
  photo or video asset. That belongs to whoever is working on the renderer.
* **It produces no new facial expressions.** Every beat resolves to one of the
  six weights already in `ExpressionPose.target(_:)`. The example sequences
  demonstrate the framework; they are not new artwork. Real expression material
  still has to come from the original four photographs and four clips.
* **It adds no pose, gesture, head or neck rotation, prop or garment.**
* **It never produces a mouth shape.** `ChoreographyOutput` has no aperture and
  no width field, so it structurally cannot compete with `MouthTimeline`,
  `MouthEnvelope`, or a silent-gap closure. There is no new phoneme timeline and
  no smoothing over a consonant closure.
* **It does not rewrite `DesktopController`.** The adapter is additive: four
  insertion points, no replacement.

---

## Read the existing code first — what is *not* rebuilt here

Version 0.3.4 already solves several problems well. None of them is
reimplemented under a new name; the module consumes them.

| Already shipped, left alone | What the module adds around it |
| --- | --- |
| `ExpressionTransition` — one interruptible cross-fade | Multi-beat named sequences that layer **on top** of whatever it is showing |
| `BlinkClock` — blink timing and shape | Per-beat directives: hold the eyes, or ask that clock for one blink |
| `MouthTimeline` — word-level mouth poses | Nothing. The module has no mouth output at all |
| `MouthEnvelope` — loudness fallback | Nothing |
| `RestMouthReturn` — the aperture returning after a sentence | A speech mask, so the module stops *driving* `parted` while a sentence plays and that one owner still decides when it comes back |
| `HairPhysics`, body movement, window placement | Nothing |
| `SpeechDemo` — the silent preview | Nothing; the demo replays it as an input |

What is genuinely new:

* **Sequences.** A named list of beats, each with a pose, an intensity, a blend
  in, a hold, an easing and a blink directive. Start, duration and end are all
  expressible, and so is repetition.
* **Priority arbitration.** Exactly one sequence owns the expression channel at a
  time, so two events can never take turns nudging the same weight. Admission is
  `preempt`, `rejectIfBusy` or `enqueue` against a bounded queue.
* **Cancel and switch from the visible state.** A new or cancelled sequence
  always continues from the pose currently on screen — never via natural first.
* **A stated hide / sleep / resume contract.** Leaving the screen drops running
  and queued work; resuming starts from a zero overlay and re-arms the idle
  countdown from the moment of the resume. Nothing is banked and replayed.
* **An external-time contract.** NaN, infinity, a rewound clock and an oversized
  step each have a defined, tested outcome, and none of them reaches the renderer.
* **Switchable, seeded idle behaviour.** Self-scheduled behaviour can be turned
  off entirely; when on, every random choice comes from an injected seed, so the
  same input reproduces the same frames.
* **A "still needs a frame" answer,** so the app's existing timer can stop as
  soon as a sequence ends.
* **Validation and clamping** of every externally supplied number.

---

## Who owns what

The single rule: **the host owns everything that persists, the module owns one
transient overlay.** The overlay always returns to zero, so the module never
leaves hidden state behind.

| State | Owner | Notes |
| --- | --- | --- |
| Selected expression (`expression`, the menu tick) | **Host** | The module never writes it |
| `ExpressionTransition` (the base cross-fade) | **Host** | Sampled and passed in as `basePose` |
| Sequence overlay on the four weights | **Module** | Always ends at zero |
| Final composed `ExpressionPose` | **Module** composes, **host** renders | `layer(base:overlay:)` |
| `BlinkClock` state, blink shape and interval | **Host** | The module may hold a value for a beat, or request one trigger |
| Blink value in the frame | **Module** returns it | Host's own value unless a beat overrode it |
| `mouth`, `mouthWide` | **Host** | The module has no such field |
| `MouthTimeline`, `MouthEnvelope`, silent-gap closure | **Host** | Untouched |
| `RestMouthReturn` and the aperture's return | **Host** | The module only stops driving `parted` while speaking |
| `HairPhysics`, `movement`, window frame, relight | **Host** | Untouched |
| Frame timer, run loop, threads | **Host** | The module contributes one boolean |
| Window visibility and sleep | **Host** | Told to the module via `setPresentation` |
| Idle on/off (`自然待机动作`) | **Host** | Mirrored via `setIdleEnabled` |
| Sequence queue and arbitration | **Module** | Dropped on hide, sleep or a stall |

---

## Quick start

```swift
import ExpressionChoreography

let director = ChoreographyDirector(
    configuration: ChoreographyConfiguration(
        vocabulary: .version0_3_4,      // or the host's own ExpressionPose.target table
        seed: 0x5EED0001,               // reproducible idle behaviour
        ambient: AmbientConfiguration() // .disabled turns self-scheduled behaviour off
    )
)

director.play(SequenceLibrary.softSmileGreeting())   // 自然 → 微微笑 → 自然

// Once per rendered frame, from wherever the app already renders:
let output = director.update(
    time: elapsed,                                   // the host's clock
    input: ChoreographyInput(basePose: currentBasePose,
                             baseBlink: currentBlink,
                             isSpeechActive: speaking)
)

output.pose                     // composed weights, finite and inside the budget
output.blink                    // host value unless a beat overrode it
output.requestsBlinkTrigger     // one-frame edge for BlinkClock.trigger(at:)
output.needsContinuousUpdates   // OR this into the app's timer condition
```

Writing a sequence:

```swift
let thinking = ChoreographySequence(
    id: "mood.thinking",
    steps: [
        ChoreographyStep(.pressedLips, blend: 0.30, hold: 0.80, label: "轻抿唇"),
        ChoreographyStep(nil,          blend: 0.40, label: "回到自然"),   // nil = back to the host's pose
    ],
    priority: .user,
    admission: .preempt,
    cancelBehavior: .release(blend: 0.38),
    speechMask: .speechOwned
)
```

`SequenceLibrary` ships seven explicit sequences and two idle ones, all built
from the six existing expressions: `softSmileGreeting`, `warmSmile`,
`consideration`, `briefEyeRest`, `attentive`, `urgentSmile`, `speakingSmile`,
`ambientMicroSmile`, `ambientEyeRest`.

---

## Behaviour worth knowing

**Weight budget.** The renderer treats the four numbers as blend weights, and the
shipped self-test already asserts that a mid cross-fade keeps `smile + pressed
<= 1`. Layering uses the base's remaining headroom rather than addition:

```
result = base * (1 - min(1, overlay.total)) + overlay
```

so `base.total <= 1` guarantees `result.total <= 1`, and a full-strength overlay
is an ordinary cross-fade. Every pose the host can produce satisfies the
precondition. If a base pose were already over budget the module is guaranteed
not to make it worse.

**Speech.** While `isSpeechActive`, a sequence's `speechMask` components are not
emitted. The default is `.speechOwned` (`parted` only), which matches what the
shipped app already does: it zeroes `parted` during playback and lets a
pressed-lip selection stay. A smile is untouched. `.speechOwnedStrict` also holds
back `pressed` for sequences that want it. Un-masking is a single step with no
ramp of its own, because `RestMouthReturn` — applied by the host to the composed
pose — is the one thing that decides how the aperture comes back.

**Time.** The module converts the host clock into a monotonic internal clock:

| Input | Result |
| --- | --- |
| NaN or infinity | Zero delta, state frozen, `timeAnomaly == .nonFinite` |
| Time moved backwards | Zero delta, re-synchronised, `.wentBackwards` |
| Step above `maximumTimeStep` (0.5 s) | The frame animates nothing, running and queued work is cancelled, and the overlay fades back to the base pose over `releaseBlend`. `.largeStep` |
| Anything else | Ordinary advance |

The 0.5 s threshold matches the one `HairPhysics` already uses for a resumed
window, and the "cancel rather than fast-forward" rule is what stops a resume
landing on an exaggerated frame.

**Determinism.** Randomness comes only from `SeededGenerator` (SplitMix64) keyed
on the configured seed; sequence seeds are derived with FNV-1a rather than
`String.hashValue`, which is randomly seeded per process. Same seed plus the same
timestamps reproduce every frame — `choreo-demo --seed N` twice gives identical
bytes.

**Limits.** 32 steps per sequence, 10 s per blend, 30 s per hold, 180 s per pass,
64 repeats, a queue depth of 8, 64-character identifiers. Out-of-range numbers
are clamped; structural problems (no steps, empty id, non-finite timing) are
refused at `submit` with a `ChoreographyValidationError` rather than at render
time.

---

## Command line demo

```
swift run choreo-demo --list
swift run choreo-demo --scenario greeting
swift run choreo-demo --scenario speech --format jsonl --fps 24
swift run choreo-demo --scenario ambient --seed 42 --duration 240
```

Eleven scenarios cover the reversal, interruption, cancellation, speech masking,
idle-off, hide/resume, large-step and queueing cases. Output is one row per
frame: host time, internal clock, active sequence and beat, base weights, overlay
weights, composed weights, blink, mouth columns, whether the timer is still
needed, any time anomaly, and the notices for that frame. It draws nothing and
needs no renderer, no artwork and no window.

Recorded output for every scenario is in `examples/output/`; regenerate with
`./examples/run-all.sh`.

---

## Integration

See [docs/INTEGRATION.md](docs/INTEGRATION.md). In short: add the package, copy
`integrations/ChoreographyHostKit/ChoreographyBridge.swift` into the app, and
make four small edits inside `DesktopController` — one in `renderFrame()` after
the existing `expressionTransition.sample(at:)` and before the existing
`RestMouthReturn` line, one for the blink trigger, one term added to the `needed`
expression in `updateTimer()`, and the lifecycle calls in
`show()`/`hide()`/`willSleep()`/`didWake()`/`toggleIdle()`.

## Testing

97 XCTest cases, compiled and run. Exactly what ran, on what, and what could not
be checked here is recorded in [docs/TEST-LOG.md](docs/TEST-LOG.md) with the raw
log in `docs/logs/build-and-test.txt`.

```
swift build
swift test
```

Requires Swift 5.9 or newer. The core and the adapter are Foundation-only, so
both build on Linux as well as macOS 13+.
