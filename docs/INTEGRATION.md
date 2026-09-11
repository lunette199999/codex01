# Integration

Additive. `DesktopController` is not replaced, not rewritten, and keeps owning
everything it owns today. There are four insertion points in `renderFrame()` and
`updateTimer()`, plus the lifecycle calls.

Line numbers refer to the 0.3.4 snapshot in `reference/DesktopController.swift`.

---

## 1. Add the package and copy one file

1. Add `ExpressionChoreography` as a Swift package dependency and link the
   `ExpressionChoreography` product to the app target.
2. Copy **one** file into the app target, next to `DesktopController.swift`:

   ```
   integrations/ChoreographyHostKit/ChoreographyBridge.swift
   ```

Do **not** copy the other two files in that directory:

* `MotionHostShim.swift` is an excerpt of the app's own `Motion.swift`, kept
  behind the `CHOREOGRAPHY_HOST_SHIM` flag purely so the adapter can be
  type-checked and tested inside this package. The app already has the real
  declarations.
* `HostRenderLoopHarness.swift` is the head-less reproduction of `renderFrame()`
  used by the demo and the adapter tests. The app has the real controller.

`ChoreographyBridge.swift` deliberately uses default (internal) access, because
`Expression`, `ExpressionPose` and `MotionFrame` are internal in the app and
nothing public may mention them.

---

## 2. One stored property

```swift
final class DesktopController: NSObject, NSWindowDelegate, AVAudioPlayerDelegate {
    ...
    private var restMouthReturn = RestMouthReturn()
    private let choreography = ChoreographyBridge()     // ← add
```

`ChoreographyBridge()` builds its pose table from the app's own
`ExpressionPose.target(_:)`, so the numbers stay stated once. Pass a
configuration if you want a different seed or no idle behaviour:

```swift
private let choreography = ChoreographyBridge(
    configuration: ChoreographyBridge.defaultConfiguration(seed: 0x5EED0001,
                                                           ambient: .disabled)
)
```

---

## 3. `renderFrame()` — the three edits

The existing code (lines 183–193) reads:

```swift
let wasTransitioning = expressionTransition.isActive
var expressionPose = expressionTransition.sample(at: elapsed)
let speechActive = player?.isPlaying == true || voiceFollower.activeID != nil || demoStart != nil
let wasReturning = restMouthReturn.isActive
expressionPose.parted *= restMouthReturn.amount(speaking: speechActive, at: elapsed)
let frame = forced ?? MotionFrame(time: elapsed, blink: idle ? blink.value(at: elapsed) : 0,
                                  mouth: openness, mouthWide: wideness, movement: idle && !reduced ? 1 : 0,
                                  expression: expression, hair: hairPose,
                                  expressionPose: expressionPose, speechActive: speechActive)
...
if (wasTransitioning && !expressionTransition.isActive) || wasReturning != restMouthReturn.isActive { updateTimer() }
```

It becomes:

```swift
let wasTransitioning = expressionTransition.isActive
var expressionPose = expressionTransition.sample(at: elapsed)
let speechActive = player?.isPlaying == true || voiceFollower.activeID != nil || demoStart != nil
let wasReturning = restMouthReturn.isActive

// (a) The blink value moves out of the MotionFrame initialiser so the module
//     can see it. Same expression, same result.
let baseBlink = idle ? blink.value(at: elapsed) : 0

// (b) INSERTION POINT — the overlay is laid on the base pose. This must sit
//     after expressionTransition.sample and before the RestMouthReturn line.
let choreographyFrame = choreography.update(basePose: expressionPose,
                                            baseBlink: baseBlink,
                                            speechActive: speechActive,
                                            at: elapsed)
expressionPose = choreographyFrame.expressionPose

// (c) INSERTION POINT — a beat may ask the app's own BlinkClock for a blink.
//     The clock keeps owning the shape; the blink lands on the next frame.
if choreographyFrame.requestsBlinkTrigger { blink.trigger(at: elapsed) }

// UNCHANGED. RestMouthReturn stays the single owner of how the resting aperture
// comes back after a sentence, and it now scales the composed pose.
expressionPose.parted *= restMouthReturn.amount(speaking: speechActive, at: elapsed)

let frame = forced ?? MotionFrame(time: elapsed, blink: choreographyFrame.blink,
                                  mouth: openness, mouthWide: wideness, movement: idle && !reduced ? 1 : 0,
                                  expression: expression, hair: hairPose,
                                  expressionPose: expressionPose, speechActive: speechActive)
...
// (d) INSERTION POINT — the module says when its own term changed, the same way
//     the app already reacts to a finished transition.
if (wasTransitioning && !expressionTransition.isActive)
    || wasReturning != restMouthReturn.isActive
    || choreographyFrame.timerConditionChanged { updateTimer() }
```

Nothing else in `renderFrame()` moves. `openness`, `wideness`, the mouth
timeline, the voice follower, `SpeechDemo`, `hairPose`, `movement`, `reduced`,
the renderer call and the peak counters are all untouched.

Order matters in three ways:

* **After `expressionTransition.sample`** — the module needs the base pose the
  app is currently showing; that is what makes an interruption continue from the
  visible state.
* **Before the `RestMouthReturn` line** — so that one owner scales the composed
  pose, not just the base. The module does not apply its own ramp.
* **`blink.trigger(at:)` after `blink.value(at:)`** — the requested blink starts
  on the next frame, which is what `BlinkClock` expects.

`renderFrame(forced:)` with a supplied frame still bypasses the module, exactly
as it bypasses the transition today.

---

## 4. `updateTimer()` — one term

Line 143 reads:

```swift
let needed = window.isVisible && !suspended && (idle || expressionTransition.isActive
    || restMouthReturn.isActive || player?.isPlaying == true
    || demoStart != nil || voiceFollower.activeID != nil)
```

Add one term:

```swift
let needed = window.isVisible && !suspended && (idle || expressionTransition.isActive
    || restMouthReturn.isActive || player?.isPlaying == true
    || demoStart != nil || voiceFollower.activeID != nil
    || choreography.needsContinuousUpdates)                      // ← add
```

**How the timer stops.** `needsContinuousUpdates` is true only while a sequence
is running, a release fade is in flight, or something is queued. The module never
asks for a frame it does not need:

* A sequence ends → the final beat lands, any overlay fades out over
  `releaseBlend`, then the flag goes false on the next frame, `timerConditionChanged`
  is true for that frame, edit (d) calls `updateTimer()`, and with `idle` off and
  nothing else running the timer invalidates.
* Idle behaviour does **not** keep the flag true. Self-scheduled sequences only
  run while `idle` is on, and the app's existing `idle` term already holds the
  timer open in that case. With idle off there is no idle behaviour to schedule.
* Hidden or suspended → the flag is false, always.

The adapter test `testTheTimerFlagOnlyReportsAChangeOnTheFrameItChanges` pins
this: on, then off, exactly once each.

---

## 5. Lifecycle

| Existing method | Add |
| --- | --- |
| `show()` | `choreography.setPresentation(.visible)` next to `blink.reset(at: elapsed)` |
| `hide()` | `choreography.setPresentation(.hidden)` |
| `windowWillClose(_:)` | `choreography.setPresentation(.hidden)` |
| `willSleep()` | `choreography.setPresentation(.suspended)` |
| `didWake()` | `choreography.setPresentation(.visible)` when `window.isVisible` |
| `toggleIdle()` | `choreography.setIdleEnabled(idle && !reduced)` after the toggle |

What each one means:

* **Hidden or suspended** — the running sequence and the whole queue are dropped
  (each reported as `cancelled(.presentationChanged)`), the overlay clears in the
  same call, the idle countdown is disarmed, and anything submitted while hidden
  is refused with `.notVisible`. Nothing is banked.
* **Visible again** — the overlay starts at zero, so the first rendered frame is
  exactly the app's own base pose; no backlog replays and nothing pops into an
  exaggerated state. The idle countdown is re-armed from the moment of the
  resume, so a ten-minute sleep does not produce a burst.
* **Idle off** — a running *idle* sequence releases smoothly and no new one is
  scheduled. Explicit sequences are unaffected: they still blend, and they still
  let the timer stop when they finish.

**Reduce motion.** The app already drops hair and body movement when
`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is set. Self-scheduled
idle sequences are motion too and should go with them, which is why the table
above passes `idle && !reduced`. `reduced` is read per frame in `renderFrame()`,
so either re-check it there and call `setIdleEnabled` when it changes, or observe
`NSWorkspace.didChangeAccessibilityDisplayOptionsNotification`. Explicit
sequences are a deliberate response to something and are not gated by this — that
is a product decision, not a technical one, so make it deliberately. **This
specific wiring has not been compiled or run; it needs macOS.**

There is a second, independent safeguard for the case where the app keeps
rendering but the clock jumps anyway — a stalled main thread, a paused VM. Any
step over `maximumTimeStep` (0.5 s, matching `HairPhysics`) cancels running and
queued work and fades back to the base pose. That frame animates nothing, so the
fade happens over real time afterwards rather than collapsing into the stall
frame.

---

## 6. Playing something

Anywhere the app decides a sequence should run — a menu item, a notification, a
reply arriving:

```swift
choreography.play(SequenceLibrary.softSmileGreeting())
renderFrame()
updateTimer()
```

`play` returns a `SubmissionResult`: `.accepted`, `.rejected(reason)` (hidden,
idle disabled) or `.invalid(error)` (structural problem). Arbitration against
whatever is already running happens on the next `update` and is reported in
`ChoreographyFrame.notices`, because that is the frame it takes effect.

A menu submenu alongside the existing expression list:

```swift
let sequences = NSMenu()
for sequence in SequenceLibrary.explicit {
    let item = NSMenuItem(title: sequence.id, action: #selector(playSequence(_:)), keyEquivalent: "")
    item.representedObject = sequence
    item.target = self
    sequences.addItem(item)
}

@objc private func playSequence(_ item: NSMenuItem) {
    guard let sequence = item.representedObject as? ChoreographySequence else { return }
    show()
    choreography.play(sequence)
    renderFrame()
    updateTimer()
}
```

The existing expression menu stays exactly as it is: `setExpression(_:)` remains
the only way the selected expression changes, and the module never writes it.

---

## 7. What the renderer sees

The renderer's contract is unchanged. It receives an `ExpressionPose` whose four
weights are finite, inside `0...1`, and sum to at most 1 whenever the base pose
did — which covers every pose `ExpressionTransition` can produce, since it only
ever cross-fades between two `ExpressionPose.target` values.

Layering is the base's remaining headroom rather than an addition:

```
share  = min(1, overlay.smile + overlay.rest + overlay.pressed + overlay.parted)
result = base * (1 - share) + overlay
```

so a full-strength overlay is an ordinary cross-fade to that pose, a zero overlay
returns the base bit for bit, and everything between is continuous in both
arguments. `smile + pressed <= 1` therefore still holds mid-blend, which is what
the shipped self-test asserts.

`mouth` and `mouthWide` are not produced by the module at all — the output type
has no field for either — so `MouthTimeline`, `MouthEnvelope` and silent-gap
closure keep full control of the *playing* mouth, and no consonant closure is
smoothed.

That is not the same as saying the module cannot reach the mouth. When nothing
is playing, `ExpressionPose.mouthOpening` returns `parted` as the resting
aperture, and `pressed` selects the pressed-lip layer either way. A sequence that
reaches for 自然微张唇 therefore does move the rendered aperture — in the same
place a manually selected expression already moves it. Two things keep that out
of a playing sentence, and the order in §3 is what makes them work:

* `configuration.speechMask` (default `.speechOwned` = `parted`) stops the module
  *driving* the aperture while `speechActive`.
* `RestMouthReturn`, applied by the app to the **composed** pose, stays the only
  thing that decides when the aperture becomes visible again. The module adds no
  ramp of its own, so there is never a second controller on that value.

The layering reservation is sized on the overlay's total *before* the mask, so
withholding the aperture does not hand weight back to the base and step the rest
of the face. `docs/ACCEPTANCE.md` measures all of this.

---

## 8. Checklist

- [ ] Package added, `ChoreographyBridge.swift` copied, shim and harness **not** copied
- [ ] `private let choreography = ChoreographyBridge()`
- [ ] `renderFrame()`: blink hoisted, `choreography.update` inserted after the
      transition sample and before the `RestMouthReturn` line
- [ ] `renderFrame()`: `blink.trigger(at:)` on `requestsBlinkTrigger`
- [ ] `renderFrame()`: `|| choreographyFrame.timerConditionChanged` on the
      `updateTimer()` call
- [ ] `updateTimer()`: `|| choreography.needsContinuousUpdates`
- [ ] `show` / `hide` / `windowWillClose` / `willSleep` / `didWake` / `toggleIdle`
- [ ] `setIdleEnabled` gated on `reduced` as well as `idle`
- [ ] Nothing else in `DesktopController` changed
- [ ] Reviewed against `docs/ACCEPTANCE.md` — especially insertion order relative
      to the `RestMouthReturn` line, and `RestMouthReturn` being called exactly
      once per frame on the composed pose
