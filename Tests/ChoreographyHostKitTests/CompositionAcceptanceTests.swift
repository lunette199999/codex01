import XCTest
import ExpressionChoreography
@testable import ChoreographyHostKit

/// Acceptance cases for the way the module's expression weights reach the mouth.
///
/// The module never writes `MotionFrame.mouth` or `mouthWide`, but two of the
/// four weights it composes shape the mouth anyway: `ExpressionPose.mouthOpening`
/// reads `parted` as the resting aperture, and `pressed` selects the pressed-lip
/// layer. So the honest question is not "can it touch the mouth" — it can — but
/// "does it ever step, and does anything end up with two owners".
///
/// Every case here runs against `HostRenderLoopHarness`, which is the app's own
/// `renderFrame()` order with the adapter inserted. Nothing is re-implemented.
final class CompositionAcceptanceTests: XCTestCase {

    // MARK: - Harness helpers

    private func drive(_ harness: HostRenderLoopHarness,
                       frames: Int,
                       from start: Int = 0,
                       fps: Double = 24,
                       speech: (Double) -> HostSpeechSample = { _ in .silent }) -> [MotionFrame] {
        (start..<(start + frames)).map { index in
            let time = Double(index) / fps
            return harness.renderFrame(at: time, speech: speech(time))
        }
    }

    /// The aperture the renderer would actually use for a frame.
    private func aperture(_ frame: MotionFrame) -> Double {
        (frame.expressionPose ?? ExpressionPose()).mouthOpening(speech: frame.mouth, active: frame.speechActive)
    }

    /// Largest single-frame change in any weight, and in the rendered aperture.
    private func worstStep(_ frames: [MotionFrame]) -> (weights: Double, aperture: Double) {
        var weights = 0.0
        var apertureStep = 0.0
        for (a, b) in zip(frames, frames.dropFirst()) {
            let p = a.expressionPose ?? ExpressionPose()
            let q = b.expressionPose ?? ExpressionPose()
            weights = max(weights, max(max(abs(p.smile - q.smile), abs(p.rest - q.rest)),
                                       max(abs(p.pressed - q.pressed), abs(p.parted - q.parted))))
            apertureStep = max(apertureStep, abs(aperture(a) - aperture(b)))
        }
        return (weights, apertureStep)
    }

    /// A step no blend asked for. 0.38 s is the app's own `ExpressionTransition`
    /// duration and `RestMouthReturn` is faster still at 0.18 s, so this is a
    /// generous ceiling for "the fastest thing anything here is allowed to move".
    private var stepCeiling: Double { 1.5 * 1.0 / 0.18 / 24 * 1.05 }

    private func heldPose(_ key: ExpressionKey, id: String, intensity: Double = 1,
                          blend: Double = 0.3, priority: ChoreographyPriority = .standard) -> ChoreographySequence {
        ChoreographySequence(id: id,
                             steps: [ChoreographyStep(key, intensity: intensity, blend: blend, hold: 30, label: id)],
                             priority: priority)
    }

    // MARK: - A1  The corrected guarantee, stated as a test

    func testA1TheModuleNeverWritesTheMouthColumnsButDoesReachTheRenderedAperture() {
        // Half of the old claim is true and worth pinning: no mouth field exists.
        let names = Mirror(reflecting: ChoreographyOutput()).children.compactMap(\.label)
        XCTAssertFalse(names.contains { $0.lowercased().contains("mouth") })

        // The other half was wrong. A parted overlay moves the aperture the
        // renderer actually uses, with no sentence playing and `mouth` at zero.
        let harness = HostRenderLoopHarness(idleEnabled: false)
        let before = harness.renderFrame(at: 0)
        XCTAssertEqual(before.mouth, 0)
        XCTAssertEqual(harness.mouthOpening, 0)

        harness.play(heldPose(.partedLips, id: "parted"))
        _ = drive(harness, frames: 24, from: 1)
        XCTAssertEqual(harness.frame.mouth, 0, "still nothing in the mouth column")
        XCTAssertEqual(harness.mouthOpening, 0.32, accuracy: 1e-9,
                       "yet the rendered aperture moved, because mouthOpening reads parted")
    }

    func testA2ThePressedWeightIsAMouthShapeToo() {
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.play(heldPose(.pressedLips, id: "pressed"))
        _ = drive(harness, frames: 24)
        XCTAssertEqual((harness.frame.expressionPose ?? ExpressionPose()).pressed, 0.85, accuracy: 1e-9)
        XCTAssertEqual(harness.frame.mouth, 0, "but it reaches the lips through the pose, not the mouth column")
    }

    // MARK: - B  Speech mask against the rest of the pose

    func testB1WithholdingTheMouthDoesNotBrightenTheRestOfTheFace() {
        // The regression this suite was written for: sizing the overlay's
        // headroom on what survives the mask handed weight back to the base and
        // stepped `pressed` by 0.27 in one frame when a sentence began.
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.setExpression(.pressedLips, at: 0)
        _ = drive(harness, frames: 24)
        harness.play(heldPose(.partedLips, id: "parted"))
        let quiet = drive(harness, frames: 24, from: 24)
        let speaking = drive(harness, frames: 24, from: 48,
                             speech: { _ in HostSpeechSample(open: 0.4, isActive: true) })

        let across = worstStep(Array(quiet.suffix(2) + speaking.prefix(2)))
        XCTAssertLessThan(across.weights, stepCeiling, "a sentence starting must not step the pose")
        XCTAssertEqual((quiet.last?.expressionPose ?? ExpressionPose()).pressed,
                       (speaking.first?.expressionPose ?? ExpressionPose()).pressed,
                       accuracy: 1e-12)
    }

    func testB2TheSameHoldsWhenTheSentenceEnds() {
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.setExpression(.pressedLips, at: 0)
        _ = drive(harness, frames: 24)
        harness.play(heldPose(.partedLips, id: "parted"))
        _ = drive(harness, frames: 24, from: 24)
        let speaking = drive(harness, frames: 24, from: 48,
                             speech: { _ in HostSpeechSample(open: 0.4, isActive: true) })
        let after = drive(harness, frames: 24, from: 72)
        let across = worstStep(Array(speaking.suffix(2) + after.prefix(4)))
        XCTAssertLessThan(across.weights, stepCeiling)
    }

    func testB3APreemptionDuringSpeechCannotChangeWhichComponentsAreWithheld() {
        // The mask used to be a per-sequence field, so preempting with a
        // different one stepped `pressed` by 0.85 in a single frame. It is one
        // host policy now, and there is no per-sequence override to disagree with.
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.play(heldPose(.pressedLips, id: "a"))
        let before = drive(harness, frames: 24, speech: { _ in HostSpeechSample(open: 0.4, isActive: true) })
        harness.play(heldPose(.pressedLips, id: "b", priority: .urgent))
        let after = drive(harness, frames: 12, from: 24,
                          speech: { _ in HostSpeechSample(open: 0.4, isActive: true) })
        XCTAssertEqual(harness.activeSequenceID, "b")
        XCTAssertLessThan(worstStep(Array(before.suffix(2) + after.prefix(2))).weights, stepCeiling)
    }

    func testB4TheMaskIsConfiguredOnceForTheWholeModule() {
        let names = Mirror(reflecting: ChoreographySequence(id: "x", steps: [ChoreographyStep(.smile)]))
            .children.compactMap(\.label)
        XCTAssertFalse(names.contains("speechMask"),
                       "a per-sequence mask would let two sequences disagree mid-preemption")
    }

    // MARK: - C  RestMouthReturn stays the single owner

    func testC1TheApertureComesBackOnExactlyOneRampAfterASentence() {
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.play(heldPose(.partedLips, id: "parted"))
        _ = drive(harness, frames: 24)
        _ = drive(harness, frames: 24, from: 24, speech: { _ in HostSpeechSample(open: 0.4, isActive: true) })
        let after = drive(harness, frames: 24, from: 48)
        let track = after.map { ($0.expressionPose ?? ExpressionPose()).parted }
        XCTAssertEqual(track.first ?? 1, 0, accuracy: 1e-12)
        XCTAssertEqual(track.last ?? 0, 0.32, accuracy: 1e-9)
        XCTAssertEqual(track, track.sorted(), "monotone — one ramp, not two fighting")
        // 0.18 s at 24 fps: a handful of frames, and it is RestMouthReturn's shape.
        XCTAssertEqual(track.filter { $0 > 1e-9 && $0 < 0.3199 }.count, 4)
    }

    func testC2ASequenceReleasingAsASentenceEndsProducesABoundedRiseAndFallNotAStep() {
        // Two legitimate, independent controls multiply here: RestMouthReturn
        // ramping the aperture back in while the sequence that asked for it fades
        // out. The product rises and falls. That is not double control of one
        // value — it is one value scaled by two owners with different jobs — but
        // it is a real visual event, so it is bounded and named rather than hidden.
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.play(heldPose(.partedLips, id: "parted", blend: 0.2))
        _ = drive(harness, frames: 24)
        _ = drive(harness, frames: 24, from: 24, speech: { _ in HostSpeechSample(open: 0.4, isActive: true) })
        harness.cancelAll()
        let after = drive(harness, frames: 24, from: 48)
        let apertures = after.map(aperture)
        let peak = apertures.max() ?? 0

        XCTAssertGreaterThan(peak, 0, "the aperture does come back briefly")
        XCTAssertLessThan(peak, 0.32, "never past what the sequence asked for")
        XCTAssertLessThan(worstStep(after).aperture, stepCeiling, "and it gets there and back without a step")
        XCTAssertEqual(apertures.last ?? 1, 0, accuracy: 1e-9, "settling closed, since the sequence ended")
        // Recorded so a change in magnitude is noticed rather than discovered.
        XCTAssertEqual(peak, 0.147, accuracy: 0.01)
    }

    func testC3CancellingDuringTheSentenceAvoidsTheRiseAltogether() {
        // The mitigation an integrator has: cancel while the mouth is still
        // speech-owned and there is nothing left for the ramp to bring back.
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.play(heldPose(.partedLips, id: "parted", blend: 0.2))
        _ = drive(harness, frames: 24)
        _ = drive(harness, frames: 12, from: 24, speech: { _ in HostSpeechSample(open: 0.4, isActive: true) })
        harness.cancelAll()
        _ = drive(harness, frames: 24, from: 36, speech: { _ in HostSpeechSample(open: 0.4, isActive: true) })
        let after = drive(harness, frames: 24, from: 60)
        let peak = after.map(aperture).max() ?? 1
        XCTAssertEqual(peak, 0, accuracy: 1e-9)
    }

    func testC4TheModuleAddsNoSecondRampOfItsOwnWhenSpeechStops() {
        // If the module also faded the mask back in, the aperture would be the
        // product of two ramps and would lag RestMouthReturn's 0.18 s.
        let withSequence = HostRenderLoopHarness(idleEnabled: false)
        let baseline = HostRenderLoopHarness(idleEnabled: false)
        withSequence.play(heldPose(.partedLips, id: "parted"))
        baseline.setExpression(.partedLips, at: 0)

        for harness in [withSequence, baseline] {
            _ = drive(harness, frames: 48)
            _ = drive(harness, frames: 24, from: 48, speech: { _ in HostSpeechSample(open: 0.4, isActive: true) })
        }
        let a = drive(withSequence, frames: 12, from: 72).map { ($0.expressionPose ?? ExpressionPose()).parted }
        let b = drive(baseline, frames: 12, from: 72).map { ($0.expressionPose ?? ExpressionPose()).parted }
        // Same number of ramp frames and the same shape: one owner in both runs.
        XCTAssertEqual(a.filter { $0 > 1e-9 && $0 < 0.3199 }.count,
                       b.filter { $0 > 1e-9 && $0 < 0.3199 }.count)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1e-9) }
    }

    // MARK: - D  Cancellation and preemption

    func testD1PreemptingAPartedSequenceWithASmileMovesTheApertureWithoutAStep() {
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.play(heldPose(.partedLips, id: "parted"))
        let before = drive(harness, frames: 24)
        harness.play(heldPose(.smile, id: "smile", priority: .urgent))
        let after = drive(harness, frames: 24, from: 24)
        let across = worstStep(before + after)
        XCTAssertLessThan(across.weights, stepCeiling)
        XCTAssertLessThan(across.aperture, stepCeiling)
        XCTAssertEqual(harness.mouthOpening, 0, accuracy: 1e-3, "and the aperture closes as parted leaves")
    }

    func testD2CancellingAPressedSequenceReleasesTheLipsWithoutAStep() {
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.play(heldPose(.pressedLips, id: "pressed"))
        let before = drive(harness, frames: 24)
        harness.cancelAll()
        let after = drive(harness, frames: 36, from: 24)
        XCTAssertLessThan(worstStep(before + after).weights, stepCeiling)
        let track = after.map { ($0.expressionPose ?? ExpressionPose()).pressed }
        XCTAssertEqual(track, track.sorted(by: >), "monotone release, no dip and return")
        XCTAssertEqual(track.last ?? 1, 0, accuracy: 1e-9)
    }

    func testD3AChainOfInterruptionsDuringASentenceNeverSteps() {
        // The sentence is the app's own silent preview, which starts and ends
        // closed. That matters: a speech source that switched on at a non-zero
        // aperture would step the mouth by itself, with or without this module.
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.setExpression(.softSmile, at: 0)
        var frames: [MotionFrame] = []
        let poses: [ExpressionKey] = [.partedLips, .pressedLips, .smile, .resting, .partedLips, .natural]
        func speech(_ time: Double) -> HostSpeechSample {
            time >= 1.0 ? HostSpeechSample.silentDemo(at: time - 1.0) : .silent
        }
        for (index, pose) in poses.enumerated() {
            harness.play(heldPose(pose, id: "beat\(index)", blend: 0.25, priority: .urgent))
            frames += drive(harness, frames: 24, from: index * 24, speech: speech)
        }
        harness.cancelAll()
        frames += drive(harness, frames: 36, from: poses.count * 24, speech: speech)

        let across = worstStep(frames)
        XCTAssertLessThan(across.weights, stepCeiling, "no interruption may step the pose")
        XCTAssertTrue(frames.contains { $0.speechActive }, "the sentence really did play")
        XCTAssertTrue(frames.contains { ($0.expressionPose ?? ExpressionPose()).parted > 0.2 },
                      "and a parted beat really was visible outside it")
    }

    func testD4TheApertureStepsOnlyWhenTheSpeechSourceItselfSteps() {
        // Separating the two owners: with the app's own preview, which opens from
        // zero, nothing steps. The module contributes no step of its own either way.
        let harness = HostRenderLoopHarness(idleEnabled: false)
        harness.play(heldPose(.partedLips, id: "parted"))
        var frames = drive(harness, frames: 24)
        frames += drive(harness, frames: 180, from: 24,
                        speech: { HostSpeechSample.silentDemo(at: $0 - 1.0) })
        frames += drive(harness, frames: 24, from: 204)
        XCTAssertLessThan(worstStep(frames).aperture, stepCeiling,
                          "a sentence that opens from closed never steps the aperture")
    }

    // MARK: - E  The weight budget under every combination

    func testE1TheBudgetHoldsAcrossEveryBaseOverlayAndMaskCombination() {
        for base in ExpressionKey.allCases {
            for overlay in ExpressionKey.allCases {
                for speaking in [false, true] {
                    let harness = HostRenderLoopHarness(idleEnabled: false)
                    harness.setExpression(ChoreographyBridge.expression(for: base), at: 0)
                    _ = drive(harness, frames: 24)
                    harness.play(heldPose(overlay, id: "overlay"))
                    let frames = drive(harness, frames: 36, from: 24,
                                       speech: { _ in speaking ? HostSpeechSample(open: 0.4, isActive: true) : .silent })
                    for frame in frames {
                        let pose = frame.expressionPose ?? ExpressionPose()
                        let total = pose.smile + pose.rest + pose.pressed + pose.parted
                        XCTAssertLessThanOrEqual(total, 1 + 1e-9, "\(base) under \(overlay), speaking \(speaking)")
                        XCTAssertLessThanOrEqual(pose.smile + pose.pressed, 1 + 1e-9)
                    }
                    XCTAssertLessThan(worstStep(frames).weights, stepCeiling, "\(base) under \(overlay)")
                }
            }
        }
    }
}
