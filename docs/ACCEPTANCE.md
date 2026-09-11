# Acceptance cases: composition, state ownership, and the mouth

## The corrected guarantee

The earlier delivery said the module "structurally cannot compete" with the
mouth because `ChoreographyOutput` has no mouth field. Half of that is true and
worth keeping; the other half was wrong, and the difference is exactly where the
risk lives.

**True:** the module cannot write `MotionFrame.mouth` or `mouthWide`. There is no
field for either, so the per-syllable shape of a playing sentence — `MouthTimeline`,
`MouthEnvelope`, bilabial closures, silent gaps — is untouchable from here.

**Wrong:** that it therefore cannot affect mouth shape. Two of the four
expression weights are mouth-shaping on their way through the renderer:

```swift
func mouthOpening(speech: Double, active: Bool) -> Double {
    let open = speech.isFinite ? min(1, max(0, speech)) : 0
    return active || open > 0 ? open : min(1, max(0, parted))   // ← parted IS the aperture
}
```

* `parted` **is** the rendered aperture whenever nothing is playing.
* `pressed` selects the pressed-lip layer, playing or not.

So the module moves the rendered mouth, indirectly, in exactly the place the app
already lets a manually chosen expression move it. The correct claim is about
*which owner acts when*, not about reach. That is what these cases test.

---

## Risks and what was measured

Four risks were probed on the harness that reproduces `renderFrame()`. All four
were real; three were defects and are fixed, one is inherent and is now bounded
and named.

| # | Risk | Measured before | Status |
| --- | --- | ---: | --- |
| B1 | Masking `parted` re-sized the overlay's headroom, handing weight back to the base and stepping every other component when a sentence began | **0.272** step in `pressed`, one frame | **Fixed** — reservation is sized on the unmasked overlay total |
| B3 | `speechMask` was a per-sequence field, so preempting with a different mask changed which components were withheld mid-flight | **0.85** step in `pressed`, one frame | **Fixed** — one host-level policy, no per-sequence override |
| — | Blink was switched off by a `rest >= 0.6` threshold | **1.0** step in `blink`, one frame | **Fixed** — `blink *= 1 - overlay.rest`, proportional and stateless |
| C2 | A sequence releasing `parted` while `RestMouthReturn` ramps it back multiplies two independent controls | aperture rises to **0.147** then closes | **Inherent, bounded** — see below |

### Why C2 is not a defect

`RestMouthReturn` brings the resting aperture back over 0.18 s; the sequence that
asked for that aperture fades out over its own release. The product rises and
falls. That is two owners with *different jobs* scaling one value, not two owners
of the same value: neither could be removed without the module reading
`RestMouthReturn`'s state, which is the coupling the whole design avoids.

It is continuous, monotone up then monotone down, and bounded above by what the
sequence asked for in the first place. Case **C2** pins the peak at 0.147 ± 0.01
so a change in magnitude is noticed rather than discovered, and case **C3**
records the mitigation available to an integrator: cancel while the sentence is
still playing and there is nothing left for the ramp to bring back.

Whether a brief reopening reads as natural or as a gulp is a question for eyes,
not for a test. It is on the visual list below.

### One finding that belongs to the host, not the module

Case **D4** separates them. The rendered aperture steps at speech onset if — and
only if — the speech source itself starts at a non-zero opening. Every source the
app ships opens from closed (`SpeechDemo` begins and ends at `(0, 0)`;
`MouthTimeline.pose` returns a closed mouth outside its frame range), so nothing
steps in practice. Worth knowing before someone adds a source that does not.

---

## The cases

All fifteen run against `HostRenderLoopHarness`, which is the app's own
`renderFrame()` ordering with the adapter inserted — the same harness the earlier
delivery used, no new framework and no re-implemented rendering. The step
ceiling every case compares against is `1.5 / 0.18 / 24`: the fastest per-frame
change the fastest thing in the system (`RestMouthReturn`, 0.18 s) can legitimately
produce at 24 fps. Anything above it is a step nothing asked for.

| ID | Case | Asserts |
| --- | --- | --- |
| **A1** | No mouth column, but a real aperture | No `mouth`/`mouthWide` field exists; a `partedLips` sequence still moves `mouthOpening` from 0 to 0.32 while `frame.mouth` stays 0 |
| **A2** | `pressed` is a mouth shape too | Reaches the lips through the pose, never through the mouth column |
| **B1** | Sentence starts under a masked overlay | No component steps; `pressed` is bit-identical across the boundary |
| **B2** | Sentence ends | Same, in the other direction |
| **B3** | Preemption during a sentence | The new sequence takes over without changing what is withheld |
| **B4** | The mask is a single policy | `ChoreographySequence` has no `speechMask` member |
| **C1** | Aperture returns after a sentence | Monotone, exactly 4 ramp frames, settles on the requested aperture — one ramp, not two |
| **C2** | Release coinciding with the ramp | Bounded rise and fall, no step, settles closed, peak pinned at 0.147 |
| **C3** | Cancel during the sentence | No rise at all |
| **C4** | Module adds no second ramp | A sequence-driven `parted` and a manually selected `partedLips` produce an identical return, frame for frame |
| **D1** | `partedLips` preempted by `smile` | Neither pose nor aperture steps; aperture closes as `parted` leaves |
| **D2** | Cancelling a `pressedLips` sequence | Monotone release, no dip-and-return |
| **D3** | Six interruptions across a real sentence | Nothing steps; the sentence and the parted beats both actually happened |
| **D4** | Aperture steps trace to the speech source | The app's own preview never steps the aperture |
| **E1** | All 72 combinations | Every base × overlay × speaking: budget ≤ 1, `smile + pressed` ≤ 1, no step |

Run them with:

```
swift test --filter CompositionAcceptanceTests
```

---

## Verified on Linux / needs macOS / needs an eye

### Verified here, on Linux

Swift 5.9.1, x86_64 Linux, `swift test`: **114 cases, 0 failures, 0 warnings**
(the 99 from the first delivery plus these 15). Specifically verified:

* Every numeric claim in the table above.
* No frame-to-frame step above the ceiling in any tested combination.
* The weight budget across all 72 base × overlay × speaking combinations.
* `RestMouthReturn` produces an identical return whether the aperture came from
  a sequence or from a manual selection (C4) — the single-owner claim.
* Determinism: same seed, same timestamps, byte-identical output.

### Needs macOS to confirm

Nothing here has seen an Apple SDK. These need a build on macOS 13+:

* That `ChoreographyBridge.swift` compiles inside the app target at all. It was
  type-checked against `MotionHostShim.swift`, a verbatim excerpt of the 0.3.4
  `Motion.swift`. **If the installed `Motion.swift` has diverged from the
  snapshot in the task package, this is where it breaks.** Diff those two files
  first.
* That the four insertion points land where `docs/INTEGRATION.md` says. The line
  numbers are from the snapshot.
* Timer behaviour on a real `RunLoop`: that the frame timer actually invalidates
  when `needsContinuousUpdates` goes false, and that `Timer.tolerance = 0.005`
  does not produce deltas the module treats as anomalies.
* `ProcessInfo.systemUptime` across a real sleep/wake, and whether `didWake`
  fires before or after the first `renderFrame`.
* `accessibilityDisplayShouldReduceMotion`. **Gap in the integration guide:** the
  app disables hair and body movement under reduce-motion, but nothing currently
  disables idle sequences. They are motion too. `setIdleEnabled(idle && !reduced)`
  is the fix; it is now in `docs/INTEGRATION.md` but has not been run.
* `renderFrame(forced:)`: the module advances and may consume a blink request on
  a frame whose pose is then discarded. No caller passes `forced` in the
  snapshot; confirm that is still true.

### Needs an eye, and cannot be settled by any test

* **C2's rise and fall.** Does a brief reopening after a sentence read as the
  mouth relaxing, or as a gulp? Watch a sequence cancelled within ~0.2 s of a
  sentence ending.
* **`pressed` during speech.** The default mask deliberately lets a pressed-lip
  weight stay while a sentence plays, because the shipped app already lets a
  manually selected 轻抿唇 stay. A sequence can now *start* one mid-sentence,
  which the app could not do before. Pressed lips over an open mouth may look
  wrong; `.speechOwnedStrict` is the switch if it does.
* **The reservation's dimming.** While a masked sequence runs, the base is scaled
  by the overlay's reservation even though the overlay is contributing nothing
  visible — a `pressedLips` base sits at 0.578 rather than 0.85 for the duration.
  This is the price of not stepping, and it is constant rather than moving, but
  whether the dimming is noticeable is a question for the screen.
* **Blink fading under a partial eye-rest.** `ambientEyeRest` closes the eyes to
  0.45, so a blink underneath still shows at 55 %. Intended; needs confirming it
  does not look like a twitch.
* Whether any example sequence reads as a *new expression* rather than a
  combination of existing ones. It must not: no new material was produced.

---

## Reviewing the local integration patch against these cases

**The local integration patch has not been received in this session.** Nothing
below has been reviewed; this is the checklist I will run it against when it
arrives.

1. **Insertion order.** `choreography.update` after `expressionTransition.sample`
   and before `expressionPose.parted *= restMouthReturn.amount(...)`. Putting the
   `RestMouthReturn` line first would scale only the base and let the overlay's
   `parted` through during a sentence — silent double control of the aperture.
2. **`RestMouthReturn` applied exactly once per frame, to the composed pose.**
   Two calls in one frame, or a call on the base before layering, both break C1
   and C4.
3. **The blink value is hoisted, not duplicated.** `idle ? blink.value(at:) : 0`
   must be computed once and passed in; calling `blink.value` again for the frame
   advances the clock twice.
4. **`blink.trigger(at:)` after `blink.value(at:)`,** so the requested blink
   lands on the next frame.
5. **`mouth` and `mouthWide` still come from `openness`/`wideness`,** untouched
   by anything the module returned.
6. **`needsContinuousUpdates` ORed into `needed`, not replacing a term,** and
   `timerConditionChanged` reaching `updateTimer()`.
7. **Lifecycle completeness:** `show`, `hide`, `windowWillClose`, `willSleep`,
   `didWake`, `toggleIdle` — and whether `reduced` gates idle.
8. **Nothing else in `DesktopController` moved.** Particularly the voice
   follower, `demoStart`, the peak counters and the renderer call.
9. **Whether the patch introduced a second source of expression state** — e.g.
   writing `expression` from a sequence, or keeping its own copy of the pose.
   The base expression must remain the app's, written only by `setExpression`.

Send the patch (or the branch and commit) and I will work through it case by
case.
