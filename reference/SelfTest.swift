import Foundation

@main struct SelfTest {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            count += 1
        }
        var clock = BlinkClock()
        check(clock.value(at: 1) == 0, "eyes remain open before blink")
        clock.trigger(at: 2)
        check(clock.value(at: 2.09) == 1, "blink closes")
        let reopening = clock.value(at: 2.18)
        check(reopening > 0 && reopening < 1, "blink reopens gradually")
        check(clock.value(at: 2.23, nextInterval: { 5 }) == 0, "blink ends")
        check(abs(clock.nextBlink - 7.23) < 0.001, "rest interval after blink")
        clock.reset(at: 100)
        check(clock.value(at: 100.2) == 0, "no stale blink after resuming")
        clock.trigger(at: 101)
        check(clock.value(at: 110) == 0, "a missed frame or long pause cannot leave an eye closed")
        var transition = ExpressionTransition()
        transition.set(.resting, at: 0)
        let halfClosed = transition.sample(at: 0.19)
        check(abs(halfClosed.rest - 0.5) < 1e-6, "manual close traverses intermediate eyelid poses")
        transition.set(.natural, at: 0.19)
        check(transition.sample(at: 0.19) == halfClosed, "interrupting a close starts reopening without a pose jump")
        check(transition.sample(at: 0.60) == ExpressionPose() && !transition.isActive, "manual reopening reaches open even when idle motion is disabled")
        transition.set(.softSmile, at: 1)
        check(transition.sample(at: 1) == ExpressionPose(), "smile does not pop in at selection")
        check(transition.sample(at: 2) == .target(.softSmile) && !transition.isActive, "expression transition finishes after a missed frame")
        let parted = ExpressionPose.target(.partedLips)
        check(parted.mouthOpening(speech: 0, active: false) > 0, "parted expression opens lips during rest")
        check(parted.mouthOpening(speech: 0, active: true) == 0, "parted expression cannot override a speaking bilabial closure")
        check(parted.mouthOpening(speech: 0.7, active: true) == 0.7, "audio mouth shape takes priority over resting expression")
        transition.set(.pressedLips, at: 2)
        let pressedIntermediate = transition.sample(at: 2.19)
        check(pressedIntermediate.pressed > 0 && pressedIntermediate.smile > 0 && pressedIntermediate.smile + pressedIntermediate.pressed <= 1, "smile to pressed lips uses bounded shared weights")
        transition.set(.smile, at: 2.19)
        check(transition.sample(at: 2.19) == pressedIntermediate, "pressed-lip transition can reverse without jumping")
        check(SpeechDemo.pose(at: 1.6).open == 0 && SpeechDemo.pose(at: 3.2).open == 0, "silent demonstration contains actual closed-mouth pauses")
        check(SpeechDemo.pose(at: 1.18).wide > 0.6 && SpeechDemo.pose(at: 2.22).wide < -0.6, "silent demonstration includes distinct wide and rounded vowels")
        check(SpeechDemo.pose(at: SpeechDemo.duration).open == 0, "silent demonstration ends closed")
        var mouth = MouthEnvelope()
        check(mouth.update(decibels: -60, delta: 0.05) == 0, "noise floor stays closed")
        check(mouth.update(decibels: -12, delta: 0.05) > 0.5, "speech opens mouth")
        for _ in 0..<12 { _ = mouth.update(decibels: nil, delta: 0.05) }
        check(mouth.value == 0, "silence closes mouth")
        check(mouth.update(decibels: .nan, delta: 0.05) == 0, "invalid audio level is ignored")
        let timeline = MouthTimeline(audio: "test.wav", sample_rate: 24000,
            frames: [.init(t: 0, open: 0, wide: 0), .init(t: 0.2, open: 0, wide: 0),
                     .init(t: 0.3, open: 1, wide: 1), .init(t: 0.5, open: 0, wide: 0),
                     .init(t: 0.8, open: 0, wide: 0), .init(t: 1, open: 0, wide: 0)],
            fallback_intervals: [.init(start: 0.85, end: 0.95)])
        check(timeline.isValid(audioName: "test.wav", duration: 1), "valid sidecar is accepted")
        check(!timeline.isValid(audioName: "another.wav", duration: 1), "a sidecar for another audio is rejected")
        check(timeline.pose(at: 0.1) == MouthPose(), "initial silence does not slowly open toward the first word")
        check(abs(timeline.pose(at: 0.25)!.wide - 0.5) < 1e-6, "width and openness interpolate at the audio playhead")
        check(timeline.pose(at: 0.65) == MouthPose(), "long silence stays fully closed")
        check(timeline.pose(at: 0.9) == nil, "unsupported tokens request amplitude fallback")
        check(timeline.pose(at: 1.2) == MouthPose(), "mouth closes after timeline end")
        check(timeline.pose(at: .nan) == MouthPose(), "invalid playback time stays closed")
        let invalidTimeline = MouthTimeline(audio: "test.wav", sample_rate: 24000,
            frames: [.init(t: 0, open: 0, wide: 0), .init(t: 0, open: 2, wide: 0)], fallback_intervals: nil)
        check(!invalidTimeline.isValid(audioName: "test.wav", duration: 1), "duplicate times and out-of-range poses are rejected")
        check(!timeline.isValid(audioName: "test.wav", duration: 0.4), "stale timing longer than the actual audio is rejected")
        var restingMouth = RestMouthReturn()
        check(restingMouth.amount(speaking: false, at: 0) == 1, "resting expression starts intact")
        check(restingMouth.amount(speaking: true, at: 1) == 0, "speech immediately owns mouth closure")
        check(restingMouth.amount(speaking: false, at: 2) == 0 && restingMouth.isActive, "speech end begins a continuous return")
        check(abs(restingMouth.amount(speaking: false, at: 2.09)-0.5) < 1e-8, "resting aperture returns gradually")
        check(restingMouth.amount(speaking: false, at: 2.3) == 1 && !restingMouth.isActive, "resting aperture settles and stops its timer")
        var hair = HairPhysics()
        let initialHair = hair.advance(delta: 1.0 / 24, wind: 1)
        check(initialHair.maximumDisplacement > 0 && initialHair.maximumDisplacement < 0.001, "hair accelerates instead of jumping to the wind target")
        for _ in 0..<120 { _ = hair.advance(delta: 1.0 / 24, wind: 1) }
        check(hair.pose.left.z > hair.pose.left.x && hair.pose.left.x > 0, "pinned-root chain is stiffer at the root than the tip")
        check(hair.pose.maximumDisplacement <= 0.050, "wind displacement stays within the configured five-percent limit")
        for _ in 0..<240 { _ = hair.advance(delta: 1.0 / 24, wind: 0) }
        check(hair.pose.maximumDisplacement < 0.00001, "hair settles after the wind stops")
        var at24 = HairPhysics(), at60 = HairPhysics()
        for _ in 0..<240 { _ = at24.advance(delta: 1.0 / 24) }
        for _ in 0..<600 { _ = at60.advance(delta: 1.0 / 60) }
        check(abs(at24.pose.left.z - at60.pose.left.z) < 1e-9 && abs(at24.pose.right.z - at60.pose.right.z) < 1e-9, "hair response is independent of display refresh rate")
        check(abs(at24.pose.left.z - at24.pose.right.z) > 1e-7, "left and right locks do not move as a rigid sheet")
        check(at24.advance(delta: 30).maximumDisplacement == 0, "resuming after a long pause cannot introduce a catch-up jump")
        check(at24.advance(delta: .nan).maximumDisplacement == 0, "invalid frame interval does not corrupt the simulation")
        let screen = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let recovered = WindowPlacement.fit(CGRect(x: 2400, y: -500, width: 900, height: 1100), in: [screen])
        check(screen.contains(recovered), "offscreen window returns to screen")
        check(abs(recovered.width / recovered.height - WindowPlacement.aspect) < 0.00001, "aspect ratio is preserved")
        check(recovered.width <= 520, "oversized window is clamped")
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = CGRect(x: -1100, y: 100, width: 320, height: 320 / WindowPlacement.aspect)
        check(WindowPlacement.fit(window, in: [right, left]) == window, "negative monitor coordinates stay valid")
        print("PASS: \(count) animation and window-placement checks")
    }
}
