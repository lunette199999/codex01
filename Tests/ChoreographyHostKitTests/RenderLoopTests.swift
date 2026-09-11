import XCTest
import ExpressionChoreography
@testable import ChoreographyHostKit

/// Drives the harness that reproduces `DesktopController.renderFrame()` with the
/// adapter inserted, so the ownership rules are checked on real frames.
final class RenderLoopTests: XCTestCase {

    private func run(_ harness: HostRenderLoopHarness,
                     seconds: Double,
                     from start: Double = 0,
                     fps: Double = 24,
                     speech: (Double) -> HostSpeechSample = { _ in .silent },
                     at: (Double, MotionFrame) -> Void = { _, _ in }) {
        let count = Int((seconds * fps).rounded())
        for index in 0..<count {
            let time = start + Double(index) / fps
            at(time, harness.renderFrame(at: time, speech: speech(time)))
        }
    }

    // MARK: - The mouth stays where it was

    func testTheModuleNeverAltersTheMouthColumnsOfAFrame() {
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.play(SequenceLibrary.speakingSmile())
        var checked = 0
        run(harness, seconds: 6, speech: { HostSpeechSample.silentDemo(at: $0) }) { time, frame in
            let expected = HostSpeechSample.silentDemo(at: time)
            XCTAssertEqual(frame.mouth, expected.open, accuracy: 0, "aperture changed at \(time)")
            XCTAssertEqual(frame.mouthWide, expected.wide, accuracy: 0, "width changed at \(time)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 100)
    }

    func testARunningSequenceLeavesTheRenderedApertureIdenticalToARunWithoutOne() {
        let withSequence = HostRenderLoopHarness(idleEnabled: false)
        let without = HostRenderLoopHarness(idleEnabled: false)
        withSequence.play(SequenceLibrary.speakingSmile())

        var apertures: [Double] = []
        var baseline: [Double] = []
        run(withSequence, seconds: 7, speech: { HostSpeechSample.silentDemo(at: $0) }) { _, _ in
            apertures.append(withSequence.mouthOpening)
        }
        run(without, seconds: 7, speech: { HostSpeechSample.silentDemo(at: $0) }) { _, _ in
            baseline.append(without.mouthOpening)
        }
        XCTAssertEqual(apertures, baseline)
        XCTAssertGreaterThan(apertures.filter { $0 > 0.3 }.count, 10, "the sentence really did open the mouth")
    }

    func testBilabialClosuresAndSilentGapsInsideASentenceStayClosed() {
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.play(SequenceLibrary.speakingSmile())
        // 1.6 s and 3.2 s are closed-lip pauses in the shipped silent preview.
        for time in [1.6, 3.2, 5.0] {
            run(harness, seconds: 0.05, from: time, speech: { HostSpeechSample.silentDemo(at: $0) })
            XCTAssertEqual(harness.frame.mouth, 0, "a pause at \(time) must stay closed")
            XCTAssertEqual(harness.mouthOpening, 0, "and the expression must not prise it open")
        }
    }

    func testASmileSurvivesTheSentenceWhileThePartedWeightDoesNot() {
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.play(SequenceLibrary.speakingSmile())
        run(harness, seconds: 2, speech: { HostSpeechSample.silentDemo(at: $0) })
        let pose = harness.frame.expressionPose ?? ExpressionPose()
        XCTAssertEqual(pose.smile, 0.32, accuracy: 1e-9)
        XCTAssertEqual(pose.parted, 0)
    }

    func testRestMouthReturnRemainsTheOnlyOwnerOfTheApertureComingBack() {
        let harness = HostRenderLoopHarness(idleEnabled: false)
        // A held pose, so anything that moves the aperture afterwards is the
        // host's RestMouthReturn rather than the sequence moving on.
        harness.play(ChoreographySequence(id: "parted.hold", steps: [
            ChoreographyStep(.partedLips, intensity: 0.8, blend: 0.3, hold: 8, label: "hold"),
        ]))
        run(harness, seconds: 0.5, speech: { _ in .silent })
        XCTAssertEqual((harness.frame.expressionPose ?? ExpressionPose()).parted, 0.256, accuracy: 1e-6)

        // Speech owns it immediately, exactly as the shipped code does.
        run(harness, seconds: 0.2, from: 0.5, speech: { _ in HostSpeechSample(open: 0.4, isActive: true) })
        XCTAssertEqual((harness.frame.expressionPose ?? ExpressionPose()).parted, 0)

        // And it comes back over RestMouthReturn's own 0.18 s ramp, not instantly
        // and not over a second ramp of the module's.
        var samples: [Double] = []
        run(harness, seconds: 0.4, from: 0.7, speech: { _ in .silent }) { _, frame in
            samples.append((frame.expressionPose ?? ExpressionPose()).parted)
        }
        XCTAssertEqual(samples.first ?? 1, 0, accuracy: 1e-9, "the return starts from closed")
        XCTAssertEqual(samples.last ?? 0, 0.256, accuracy: 1e-6, "and settles on the requested aperture")
        XCTAssertEqual(samples, samples.sorted(), "monotone: a single owner, not two ramps fighting")
        let rampFrames = samples.filter { $0 > 1e-9 && $0 < 0.2559 }.count
        XCTAssertGreaterThanOrEqual(rampFrames, 2, "0.18 s at 24 fps is a handful of frames, not a jump")
        XCTAssertLessThanOrEqual(rampFrames, 6)
    }

    // MARK: - Base expression ownership

    func testAManualExpressionStillTransitionsWithIdleOffAndThenStopsTheTimer() {
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.setExpression(.softSmile, at: 0)
        var track: [Double] = []
        run(harness, seconds: 1.0, at: { _, frame in track.append((frame.expressionPose ?? ExpressionPose()).smile) })
        XCTAssertEqual(track.first ?? 1, 0, accuracy: 1e-9, "it does not pop in at selection")
        XCTAssertEqual(track.last ?? 0, 0.32, accuracy: 1e-9)
        XCTAssertTrue(track.contains { $0 > 0.05 && $0 < 0.3 }, "intermediate poses are rendered")
        XCTAssertFalse(harness.needsTimer, "with idle off and nothing running, the timer can stop")
        XCTAssertFalse(harness.isBaseTransitionActive)
    }

    func testASequenceLayersOnTopOfAManualExpressionWithoutOverwritingIt() {
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.setExpression(.pressedLips, at: 0)
        run(harness, seconds: 1.0)
        XCTAssertEqual(harness.expression, .pressedLips)
        let settled = (harness.frame.expressionPose ?? ExpressionPose()).pressed
        XCTAssertEqual(settled, 0.85, accuracy: 1e-9)

        harness.play(SequenceLibrary.softSmileGreeting())
        run(harness, seconds: 1.0, from: 1.0)
        let during = harness.frame.expressionPose ?? ExpressionPose()
        XCTAssertEqual(during.smile, 0.32, accuracy: 1e-9)
        XCTAssertGreaterThan(during.pressed, 0.4, "the manual selection is still underneath")
        XCTAssertLessThanOrEqual(during.smile + during.pressed + during.rest + during.parted, 1 + 1e-9)

        // When the overlay ends the app's own expression is exactly as it was.
        run(harness, seconds: 2.0, from: 2.0)
        XCTAssertEqual(harness.expression, .pressedLips)
        XCTAssertEqual((harness.frame.expressionPose ?? ExpressionPose()).pressed, 0.85, accuracy: 1e-9)
        XCTAssertFalse(harness.needsTimer)
    }

    func testTheTimerTermGoesBackToFalseAfterASequenceEndsWithIdleOff() {
        let harness = HostRenderLoopHarness(idleEnabled: false)
        run(harness, seconds: 0.2)
        XCTAssertFalse(harness.needsTimer)
        harness.play(SequenceLibrary.warmSmile())
        run(harness, seconds: 0.5, from: 0.2)
        XCTAssertTrue(harness.needsTimer)
        run(harness, seconds: 4, from: 0.7)
        XCTAssertFalse(harness.needsTimer)
    }

    // MARK: - Blink ownership

    func testABlinkRequestReachesTheAppsOwnBlinkClock() {
        let harness = HostRenderLoopHarness(idleEnabled: true)
        harness.play(SequenceLibrary.warmSmile())
        var sawBlink = false
        run(harness, seconds: 1.0, at: { _, frame in if frame.blink > 0.5 { sawBlink = true } })
        XCTAssertEqual(harness.blinkTriggersRequested, 1)
        XCTAssertTrue(sawBlink, "the host clock produced the blink the step asked for")
    }

    func testAnEyeRestBeatHoldsTheAutomaticBlinkShutInTheRenderedFrame() {
        let harness = HostRenderLoopHarness(idleEnabled: true)
        harness.play(SequenceLibrary.briefEyeRest())
        var blinks: [Double] = []
        run(harness, seconds: 1.5, at: { _, frame in blinks.append(frame.blink) })
        XCTAssertTrue(blinks.allSatisfy { $0 == 0 })
        XCTAssertEqual((harness.frame.expressionPose ?? ExpressionPose()).rest, 1, accuracy: 1e-9)
    }

    // MARK: - Window lifecycle

    func testHidingAndResumingLeavesTheFirstVisibleFrameOnTheHostPose() {
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.setExpression(.softSmile, at: 0)
        harness.play(SequenceLibrary.warmSmile())
        run(harness, seconds: 0.6)
        XCTAssertGreaterThan((harness.frame.expressionPose ?? ExpressionPose()).smile, 0.5)

        harness.setPresentation(.hidden, at: 0.6)
        harness.setPresentation(.visible, at: 600)
        let resumed = harness.renderFrame(at: 600)
        XCTAssertEqual((resumed.expressionPose ?? ExpressionPose()).smile, 0.32, accuracy: 1e-9,
                       "back to the app's own expression, not an exaggerated frame")
        XCTAssertFalse(harness.needsTimer)

        run(harness, seconds: 3, from: 600)
        XCTAssertEqual((harness.frame.expressionPose ?? ExpressionPose()).smile, 0.32, accuracy: 1e-9,
                       "and nothing replays")
    }

    func testEveryRenderedFrameStaysInsideTheRenderersExpectations() {
        let harness = HostRenderLoopHarness(idleEnabled: true)
        harness.play(SequenceLibrary.warmSmile())
        run(harness, seconds: 30, speech: { $0 > 5 && $0 < 12 ? HostSpeechSample.silentDemo(at: $0 - 5) : .silent }) { _, frame in
            let pose = frame.expressionPose ?? ExpressionPose()
            for value in [pose.smile, pose.rest, pose.pressed, pose.parted, frame.blink] {
                XCTAssertTrue(value.isFinite && value >= 0 && value <= 1)
            }
            XCTAssertLessThanOrEqual(pose.smile + pose.rest + pose.pressed + pose.parted, 1 + 1e-9)
        }
    }
}
