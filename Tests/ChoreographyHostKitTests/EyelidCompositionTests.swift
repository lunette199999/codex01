import XCTest
import ExpressionChoreography
@testable import ChoreographyHostKit

/// Acceptance for the eyelid contract.
///
/// `pose.rest` and `frame.blink` are two requests for the same physical
/// quantity — how far the eyelid is down — and `PortraitRenderer.blinkAmount`
/// resolves them in exactly one place with `max`. Every case here asserts on
/// that final value (`HostEyelid.amount(for:)`, a verbatim copy of the
/// renderer's own function), never on the module's request alone: a blink that
/// is numerically present but sits under the resting lid is not a blink.
///
/// The ladder cases each also evaluate the composition 1.2.0 replaced, so a
/// case that cannot tell the two apart fails loudly rather than passing twice.
final class EyelidCompositionTests: XCTestCase {

    private let fps = 24.0

    /// The rungs the contract is specified at.
    private let ladder: [Double] = [0, 0.30, 0.55, 0.70, 1]

    // MARK: - Harness

    /// Holds `rest` steady with a sequence, triggers one blink, and records the
    /// eyelid closure the renderer would show on every frame.
    private func blinkTrack(atRest rest: Double, seconds: Double = 1.2) -> (final: [Double], old: [Double], overlayRest: Double) {
        let harness = HostRenderLoopHarness(idleEnabled: true)
        harness.useManualBlinks()
        if rest > 0 {
            harness.play(ChoreographySequence(id: "rest.\(rest)", steps: [
                ChoreographyStep(.resting, intensity: rest, blend: 0.3, hold: 30, label: "rest"),
            ]))
        }
        // Settle the pose, and let the first automatic blink pass, so the blink
        // we measure is one we asked for at a known moment.
        var time = 0.0
        for _ in 0..<Int(4 * fps) { harness.renderFrame(at: time); time += 1 / fps }
        let settled = (harness.frame.expressionPose ?? ExpressionPose()).rest
        XCTAssertEqual(settled, rest, accuracy: 1e-9, "the pose did not reach the requested rest")

        harness.triggerBlinkForTesting(at: time)
        var final: [Double] = [], old: [Double] = []
        for _ in 0..<Int(seconds * fps) {
            let frame = harness.renderFrame(at: time)
            final.append(HostEyelid.amount(for: frame))
            old.append(HostEyelid.amountUnder1_1_0(for: frame, overlayRest: harness.overlay.rest))
            time += 1 / fps
        }
        return (final, old, harness.overlay.rest)
    }

    private func travel(_ track: [Double], from rest: Double) -> Double {
        (track.max() ?? rest) - rest
    }

    private func visibleFrames(_ track: [Double], above rest: Double) -> Int {
        track.filter { $0 > rest + 1e-9 }.count
    }

    private func worstStep(_ track: [Double]) -> Double {
        zip(track, track.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    // MARK: - The ladder

    func testFullyOpenKeepsTheOriginalBlinkExactly() {
        let (final, _, _) = blinkTrack(atRest: 0)
        XCTAssertEqual(final.max() ?? 0, 1, accuracy: 1e-9, "a blink from open eyes still closes fully")
        XCTAssertEqual(final.last ?? 1, 0, accuracy: 1e-9, "and returns to open")
        XCTAssertGreaterThanOrEqual(visibleFrames(final, above: 0), 4)
    }

    func testEveryHalfClosedRungCompletesAClosureAndReturnsToItsOwnRest() {
        for rest in ladder where rest < 1 {
            let (final, _, _) = blinkTrack(atRest: rest)
            XCTAssertEqual(final.max() ?? 0, 1, accuracy: 1e-9,
                           "rest \(rest): the lid must still reach full closure")
            XCTAssertEqual(final.last ?? 0, rest, accuracy: 1e-9,
                           "rest \(rest): and come back to exactly the resting lid, not past it")
            XCTAssertEqual(travel(final, from: rest), 1 - rest, accuracy: 1e-9,
                           "rest \(rest): the travel is everything that was left")
            XCTAssertGreaterThanOrEqual(visibleFrames(final, above: rest), 2,
                                        "rest \(rest): a closure that shows on fewer than two frames is not one")
            XCTAssertTrue(final.allSatisfy { $0 >= rest - 1e-9 },
                          "rest \(rest): the lid may never open past its own resting position")
        }
    }

    func testFullyClosedNeverOpensBackwards() {
        let (final, _, _) = blinkTrack(atRest: 1)
        XCTAssertTrue(final.allSatisfy { abs($0 - 1) < 1e-9 },
                      "a blink under a fully closed lid must change nothing at all")
        XCTAssertEqual(travel(final, from: 1), 0, accuracy: 1e-9)
    }

    // MARK: - The same cases indict the composition this replaced

    func testTheReplacedCompositionHidesTheBlinkFromHalfClosedUpwards() {
        // Not a test of the new function in isolation: the identical frames are
        // also scored under 1.1.0's rule, which must fail where 1.2.0 passes.
        var indicted: [Double] = []
        for rest in ladder where rest > 0 && rest < 1 {
            let (final, old, overlayRest) = blinkTrack(atRest: rest)
            XCTAssertEqual(overlayRest, rest, accuracy: 1e-9, "the overlay is what holds the lid here")
            XCTAssertGreaterThan(travel(final, from: rest), 0, "rest \(rest): 1.2.0 must show a blink")

            if rest >= 0.5 {
                XCTAssertEqual(travel(old, from: rest), 0, accuracy: 1e-12,
                               "rest \(rest): 1.1.0 scaled the peak to \(1 - rest) < \(rest), so nothing showed")
                indicted.append(rest)
            } else {
                // Below a half the old rule still showed something, which is why
                // the defect was only found at 0.55 and not at 0.30.
                XCTAssertGreaterThan(travel(old, from: rest), 0)
                XCTAssertLessThan(travel(old, from: rest), travel(final, from: rest))
            }
        }
        XCTAssertEqual(indicted, [0.55, 0.70],
                       "the rungs at and above a half are exactly the ones the old rule hid")
    }

    func testTheCrossoverIsAtAHalfAndIsExact() {
        // 1.1.0 showed a blink only while peak (1 - rest) > rest, i.e. rest < 0.5.
        for rest in [0.45, 0.49, 0.50, 0.51, 0.55] {
            let (final, old, _) = blinkTrack(atRest: rest)
            XCTAssertGreaterThan(travel(final, from: rest), 0, "rest \(rest)")
            if rest < 0.5 {
                XCTAssertGreaterThan(travel(old, from: rest), 0, "rest \(rest) was below the crossover")
            } else {
                XCTAssertEqual(travel(old, from: rest), 0, accuracy: 1e-12, "rest \(rest) was at or above it")
            }
        }
    }

    // MARK: - Continuity, bounds, and the awkward moments

    func testTheFinalClosureStaysContinuousAndBoundedOnEveryRung() {
        // max of two continuous, bounded requests: the result cannot step beyond
        // the fastest of them. BlinkClock's own rise is 0 -> 1 over 0.055 s,
        // which is under one and a half frames at 24 fps, so a full-scale step is
        // the blink doing its job rather than a composition artefact.
        let blinkRise = 1.0 / 0.055 / fps
        for rest in ladder {
            let (final, _, _) = blinkTrack(atRest: rest)
            XCTAssertTrue(final.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "rest \(rest)")
            XCTAssertLessThanOrEqual(worstStep(final), blinkRise + 1e-9, "rest \(rest)")
        }
    }

    func testRestRisingDuringABlinkNeitherStepsNorOpensTheLid() {
        let harness = HostRenderLoopHarness(idleEnabled: true)
        harness.useManualBlinks()
        var time = 0.0
        for _ in 0..<Int(2 * fps) { harness.renderFrame(at: time); time += 1 / fps }

        // Start a slow close, then blink in the middle of it.
        harness.play(ChoreographySequence(id: "closing", steps: [
            ChoreographyStep(.resting, intensity: 0.8, blend: 1.0, hold: 30, label: "closing"),
        ]))
        var track: [Double] = []
        for index in 0..<Int(2.0 * fps) {
            if index == 12 { harness.triggerBlinkForTesting(at: time) }
            let frame = harness.renderFrame(at: time)
            track.append(HostEyelid.amount(for: frame))
            time += 1 / fps
        }
        XCTAssertEqual(track.max() ?? 0, 1, accuracy: 1e-9, "the blink still closed the lid")
        XCTAssertLessThanOrEqual(worstStep(track), 1.0 / 0.055 / fps + 1e-9)
        // The lid must never be further open than the pose alone would have it.
        let poseOnly = (harness.frame.expressionPose ?? ExpressionPose()).rest
        XCTAssertGreaterThanOrEqual(track.last ?? 0, poseOnly - 1e-9)
    }

    func testCancellingTheRestSequenceDuringABlinkIsContinuous() {
        let harness = HostRenderLoopHarness(idleEnabled: true)
        harness.useManualBlinks()
        var time = 0.0
        harness.play(ChoreographySequence(id: "rest", steps: [
            ChoreographyStep(.resting, intensity: 0.7, blend: 0.3, hold: 30, label: "rest"),
        ]))
        for _ in 0..<Int(3 * fps) { harness.renderFrame(at: time); time += 1 / fps }

        harness.triggerBlinkForTesting(at: time)
        var track: [Double] = []
        for index in 0..<Int(2.0 * fps) {
            if index == 2 { harness.cancelAll() }          // cancel mid-blink
            let frame = harness.renderFrame(at: time)
            track.append(HostEyelid.amount(for: frame))
            time += 1 / fps
        }
        XCTAssertLessThanOrEqual(worstStep(track), 1.0 / 0.055 / fps + 1e-9)
        XCTAssertEqual(track.last ?? 1, 0, accuracy: 1e-9, "the lid ends open, since nothing holds it")
    }

    func testPreemptingWithADifferentRestDuringABlinkIsContinuous() {
        let harness = HostRenderLoopHarness(idleEnabled: true)
        harness.useManualBlinks()
        var time = 0.0
        harness.play(ChoreographySequence(id: "a", steps: [
            ChoreographyStep(.resting, intensity: 0.3, blend: 0.3, hold: 30, label: "a"),
        ]))
        for _ in 0..<Int(3 * fps) { harness.renderFrame(at: time); time += 1 / fps }
        harness.triggerBlinkForTesting(at: time)
        var track: [Double] = []
        for index in 0..<Int(2.0 * fps) {
            if index == 2 {
                harness.play(ChoreographySequence(id: "b", steps: [
                    ChoreographyStep(.resting, intensity: 0.9, blend: 0.3, hold: 30, label: "b"),
                ], priority: .urgent))
            }
            let frame = harness.renderFrame(at: time)
            track.append(HostEyelid.amount(for: frame))
            time += 1 / fps
        }
        XCTAssertLessThanOrEqual(worstStep(track), 1.0 / 0.055 / fps + 1e-9)
        XCTAssertEqual(track.last ?? 0, 0.9, accuracy: 1e-9)
    }

    func testABaseRestAndAnOverlayRestTogetherStillComposeOnce() {
        // 闭眼休息 selected by hand, with a rest sequence on top. The two are
        // combined by `layer` into the one `pose.rest` the renderer reads; the
        // blink is composed with that result and with nothing else.
        let harness = HostRenderLoopHarness(idleEnabled: true)
        harness.useManualBlinks()
        harness.setExpression(.resting, at: 0)
        var time = 0.0
        for _ in 0..<Int(2 * fps) { harness.renderFrame(at: time); time += 1 / fps }
        XCTAssertEqual((harness.frame.expressionPose ?? ExpressionPose()).rest, 1, accuracy: 1e-9)

        harness.play(ChoreographySequence(id: "more.rest", steps: [
            ChoreographyStep(.resting, intensity: 0.5, blend: 0.3, hold: 30, label: "more"),
        ]))
        var track: [Double] = []
        for index in 0..<Int(3 * fps) {
            if index == 24 { harness.triggerBlinkForTesting(at: time) }
            let frame = harness.renderFrame(at: time)
            track.append(HostEyelid.amount(for: frame))
            time += 1 / fps
        }
        // Both requests want the lid down; neither can push it past 1 or open it.
        XCTAssertTrue(track.allSatisfy { $0 >= 1 - 1e-9 && $0 <= 1 + 1e-9 },
                      "two closing requests and a blink must all resolve to fully closed")
        XCTAssertLessThanOrEqual(worstStep(track), 1e-9)
    }

    func testAnExplicitHoldReplacesTheRequestRatherThanScalingIt() {
        // `.hold(0)` still means "this beat asks for no blink", and under `max`
        // that shows the resting lid rather than opening it.
        let harness = HostRenderLoopHarness(idleEnabled: true)
        harness.useManualBlinks()
        harness.play(ChoreographySequence(id: "quiet", steps: [
            ChoreographyStep(.resting, intensity: 0.6, blend: 0.3, hold: 30, blink: .hold(0), label: "quiet"),
        ]))
        var time = 0.0
        for _ in 0..<Int(3 * fps) { harness.renderFrame(at: time); time += 1 / fps }
        harness.triggerBlinkForTesting(at: time)
        var track: [Double] = []
        for _ in 0..<Int(1.2 * fps) {
            let frame = harness.renderFrame(at: time)
            XCTAssertEqual(frame.blink, 0, "the beat asked for no blink")
            track.append(HostEyelid.amount(for: frame))
            time += 1 / fps
        }
        XCTAssertTrue(track.allSatisfy { abs($0 - 0.6) < 1e-9 }, "so the lid just stays where the pose put it")
    }

    func testTheLibraryEyeRestNoLongerNeedsToSuppressTheBlink() {
        // briefEyeRest closes the lid completely, so `max` hides the blink by
        // itself — which is why the explicit hold was dropped in 1.2.0.
        let harness = HostRenderLoopHarness(idleEnabled: true)
        harness.useManualBlinks()
        harness.play(SequenceLibrary.briefEyeRest())
        var time = 0.0, track: [Double] = []
        for index in 0..<Int(2 * fps) {
            if index == 20 { harness.triggerBlinkForTesting(at: time) }
            let frame = harness.renderFrame(at: time)
            track.append(HostEyelid.amount(for: frame))
            time += 1 / fps
        }
        XCTAssertEqual(track.max() ?? 0, 1, accuracy: 1e-9)
        XCTAssertTrue(track.allSatisfy { $0 <= 1 + 1e-9 })
    }

    // MARK: - The documented numbers

    func testTheRungTableIsWhatTheContractDocumentClaims() {
        // travel = 1 - rest, and the frames the closure shows for at 24 fps.
        // Recorded so the contract document and the code cannot drift apart.
        var measured: [(Double, Double, Int)] = []
        for rest in ladder {
            let (final, _, _) = blinkTrack(atRest: rest)
            measured.append((rest, travel(final, from: rest), visibleFrames(final, above: rest)))
        }
        XCTAssertEqual(measured.map { $0.0 }, ladder)
        XCTAssertEqual(measured.map { $0.1 }, ladder.map { 1 - $0 }.map { abs($0) < 1e-12 ? 0 : $0 })
        // The continuous window where blink > rest is 0.22 - 0.15 * rest seconds
        // (5.28 / 4.20 / 3.30 / 2.76 / 0 frames' worth at 24 fps). The frame
        // count is that window sampled on a 24 fps grid, so it lands one higher
        // than the floor depending on where the trigger falls between samples.
        XCTAssertEqual(measured.map { $0.2 }, [5, 4, 4, 3, 0],
                       "visible frames at 24 fps, triggered on a frame boundary")
    }
}
