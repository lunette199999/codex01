import XCTest
@testable import ExpressionChoreography

final class ArbitrationTests: XCTestCase {

    func testAThreeBeatSequenceReachesItsPoseAndReturnsToTheBase() {
        let driver = Driver()
        driver.director.play(SequenceLibrary.softSmileGreeting())
        driver.run(seconds: 2.5)
        let peak = driver.frames.map(\.pose.smile).max() ?? 0
        XCTAssertEqual(peak, 0.32, accuracy: 1e-9)
        XCTAssertEqual(driver.frames.last?.pose, .identity)
        XCTAssertEqual(driver.frames.last?.needsContinuousUpdates, false)
        XCTAssertLessThan(driver.largestPoseJump(),
                          smoothStepFrameLimit(amplitude: 0.32, blend: 0.38),
                          "the blend must not step")
    }

    func testAnInterruptionContinuesFromTheVisiblePoseInsteadOfSnappingToNatural() {
        let driver = Driver()
        driver.director.play(hold(.smile, id: "first", blend: 1.0, duration: 1.0))
        driver.run(seconds: 0.5)
        let visible = driver.frames.last!.overlay.smile
        XCTAssertGreaterThan(visible, 0.05)
        XCTAssertLessThan(visible, 0.75, "the first blend should still be in flight")

        driver.director.play(hold(.pressedLips, id: "second", blend: 0.4, duration: 0.5, priority: .urgent))
        let resumed = driver.step()
        XCTAssertEqual(resumed.overlay.smile, visible,
                       accuracy: smoothStepFrameLimit(amplitude: 0.85, blend: 0.4),
                       "the new sequence must start from what is on screen")
        driver.run(seconds: 1.4)
        XCTAssertLessThan(driver.largestPoseJump(),
                          max(smoothStepFrameLimit(amplitude: 0.8, blend: 1.0),
                              smoothStepFrameLimit(amplitude: 0.85, blend: 0.4)))
    }

    func testReversingBackToTheOriginalPoseMidBlendIsAlsoContinuous() {
        let driver = Driver()
        driver.director.play(hold(.resting, id: "close", blend: 0.8, duration: 0.4))
        driver.run(seconds: 0.4)
        let halfway = driver.frames.last!.overlay.rest
        XCTAssertGreaterThan(halfway, 0.1)
        driver.director.play(hold(nil, id: "reopen", blend: 0.5, duration: 0.2))
        let next = driver.step()
        XCTAssertEqual(next.overlay.rest, halfway,
                       accuracy: smoothStepFrameLimit(amplitude: 1.0, blend: 0.5))
        driver.run(seconds: 1.0)
        XCTAssertEqual(driver.frames.last?.overlay, .identity)
        XCTAssertLessThan(driver.largestPoseJump(),
                          max(smoothStepFrameLimit(amplitude: 1.0, blend: 0.8),
                              smoothStepFrameLimit(amplitude: 0.5, blend: 0.5)))
    }

    func testALowerPriorityRequestIsRefusedRatherThanTakingTurns() {
        let driver = Driver()
        driver.director.play(hold(.smile, id: "important", duration: 1.0, priority: .urgent))
        driver.run(seconds: 0.5)
        driver.director.play(hold(.pressedLips, id: "minor", duration: 1.0, priority: .ambient))
        let output = driver.step()
        XCTAssertEqual(output.activeSequenceID, "important")
        XCTAssertEqual(output.notices.first?.kind.rejectionReason, .lowerPriority)
        driver.run(seconds: 1.5)
        XCTAssertFalse(driver.noticeKinds(for: "minor").contains { $0.isStarted })
    }

    func testEqualPriorityHandsTheChannelToTheNewerRequest() {
        let driver = Driver()
        driver.director.play(hold(.smile, id: "older", duration: 1.0))
        driver.run(seconds: 0.3)
        driver.director.play(hold(.pressedLips, id: "newer", duration: 1.0))
        let output = driver.step()
        XCTAssertEqual(output.activeSequenceID, "newer")
        XCTAssertEqual(driver.noticeKinds(for: "older").last?.cancelReason, .preempted)
    }

    func testRejectIfBusyNeverInterrupts() {
        let driver = Driver()
        driver.director.play(hold(.smile, id: "running", duration: 1.0, priority: .ambient))
        driver.run(seconds: 0.3)
        driver.director.play(hold(.resting, id: "polite", duration: 0.5, priority: .urgent, admission: .rejectIfBusy))
        let output = driver.step()
        XCTAssertEqual(output.activeSequenceID, "running")
        XCTAssertEqual(output.notices.first?.kind.rejectionReason, .channelBusy)
    }

    func testAQueuedSequenceWaitsAndThenStartsFromTheVisiblePose() {
        let driver = Driver()
        driver.director.play(hold(.smile, id: "first", blend: 0.3, duration: 0.4))
        var queued = hold(.pressedLips, id: "queued", blend: 0.3, duration: 0.4)
        queued.admission = .enqueue
        driver.director.play(queued)
        driver.run(seconds: 0.4)
        XCTAssertEqual(driver.frames.last?.activeSequenceID, "first")
        XCTAssertTrue(driver.frames.last!.needsContinuousUpdates)
        driver.run(seconds: 1.6)
        XCTAssertTrue(driver.noticeKinds(for: "queued").contains { $0.isStarted })
        XCTAssertEqual(driver.frames.last?.overlay, .identity)
        XCTAssertLessThan(driver.largestPoseJump(),
                          max(smoothStepFrameLimit(amplitude: 0.85, blend: 0.3),
                              smoothStepFrameLimit(amplitude: 0.8, blend: 0.3)))
    }

    func testTheQueueOrdersByPriorityAndThenByArrival() {
        let driver = Driver()
        driver.director.play(hold(.smile, id: "running", blend: 0.2, duration: 0.3))
        for (id, priority) in [("low", ChoreographyPriority.ambient), ("high", .urgent), ("mid", .standard)] {
            var queued = hold(.pressedLips, id: id, blend: 0.1, duration: 0.1, priority: priority)
            queued.admission = .enqueue
            driver.director.play(queued)
        }
        driver.run(seconds: 3)
        let order = driver.notices().filter { $0.kind.isStarted }.map(\.sequenceID)
        XCTAssertEqual(order, ["running", "high", "mid", "low"])
    }

    func testTheQueueIsBoundedAndSaysSoRatherThanGrowing() {
        let configuration = ChoreographyConfiguration(maximumQueueDepth: 2, ambient: .disabled)
        let driver = Driver(configuration: configuration)
        driver.director.play(hold(.smile, id: "running", duration: 2))
        for index in 0..<5 {
            var queued = hold(.pressedLips, id: "queued\(index)", duration: 0.1)
            queued.admission = .enqueue
            driver.director.play(queued)
        }
        let output = driver.step()
        let refused = output.notices.filter { $0.kind.rejectionReason == RejectionReason.queueFull }
        XCTAssertEqual(refused.count, 3)
    }

    func testCancellingReleasesFromTheVisiblePoseAndNeverViaNaturalFirst() {
        let driver = Driver()
        driver.director.play(hold(.smile, id: "held", blend: 0.3, duration: 2.0))
        driver.run(seconds: 0.8)
        let visible = driver.frames.last!.overlay.smile
        XCTAssertEqual(visible, 0.8, accuracy: 1e-6)
        driver.director.cancel(id: "held")
        let first = driver.step()
        XCTAssertEqual(first.overlay.smile, visible,
                       accuracy: smoothStepFrameLimit(amplitude: 0.8, blend: 0.38),
                       "the release starts from what is on screen, it does not drop")
        XCTAssertEqual(driver.noticeKinds(for: "held").last?.cancelReason, .explicit)
        driver.run(seconds: 0.6)
        XCTAssertEqual(driver.frames.last?.overlay, .identity)
        // Monotone decay: it must not dip to zero and come back, or overshoot.
        let tail = driver.frames.suffix(14).map(\.overlay.smile)
        XCTAssertEqual(tail, tail.sorted(by: >))
    }

    func testCancelAllClearsTheRunningSequenceAndTheQueue() {
        let driver = Driver()
        driver.director.play(hold(.smile, id: "running", duration: 2))
        var queued = hold(.resting, id: "waiting", duration: 1)
        queued.admission = .enqueue
        driver.director.play(queued)
        driver.run(seconds: 0.5)
        driver.director.cancelAll()
        driver.run(seconds: 1.0)
        XCTAssertNil(driver.frames.last?.activeSequenceID)
        XCTAssertEqual(driver.frames.last?.needsContinuousUpdates, false)
        XCTAssertEqual(driver.noticeKinds(for: "waiting").last?.cancelReason, .explicit)
        XCTAssertFalse(driver.noticeKinds(for: "waiting").contains { $0.isStarted })
    }

    func testASequenceNeverLeavesAStandingOverlayBehind() {
        // A sequence that ends on a pose still hands the expression back to the
        // host, so the base expression stays the only persistent state.
        let driver = Driver()
        driver.director.play(hold(.pressedLips, id: "endsOnPose", blend: 0.2, duration: 0.2))
        driver.run(seconds: 2)
        XCTAssertEqual(driver.frames.last?.overlay, .identity)
        XCTAssertEqual(driver.frames.last?.needsContinuousUpdates, false)
        XCTAssertTrue(driver.noticeKinds(for: "endsOnPose").contains { $0.isFinished })
    }

    func testTheTimerTermIsTrueOnlyWhileTheModuleHasSomethingToDo() {
        let driver = Driver()
        XCTAssertFalse(driver.step().needsContinuousUpdates)
        driver.director.play(SequenceLibrary.consideration())
        XCTAssertTrue(driver.step().needsContinuousUpdates)
        driver.run(seconds: 2)
        XCTAssertFalse(driver.frames.last!.needsContinuousUpdates)
        let flips = zip(driver.frames, driver.frames.dropFirst())
            .filter { $0.needsContinuousUpdates != $1.needsContinuousUpdates }
        XCTAssertEqual(flips.count, 2, "it turns on once and off once; it must not oscillate")
    }

    func testRepeatedSequencesRunTheStatedNumberOfTimes() {
        let driver = Driver()
        var sequence = hold(.softSmile, id: "thrice", blend: 0.1, duration: 0.1)
        sequence.repeatMode = .count(3)
        driver.director.play(sequence)
        driver.run(seconds: 2)
        XCTAssertEqual(driver.noticeKinds(for: "thrice").filter { $0.isFinished }.count, 1)
        let peaks = driver.frames.map(\.overlay.smile).filter { abs($0 - 0.32) < 1e-9 }
        XCTAssertGreaterThan(peaks.count, 3)
    }

    func testAnEndlessSequenceKeepsRunningUntilSomethingStopsIt() {
        let driver = Driver()
        var sequence = ChoreographySequence(id: "mood",
                                            steps: [ChoreographyStep(.softSmile, blend: 0.3, hold: 0.2),
                                                    ChoreographyStep(nil, blend: 0.3, hold: 0.2)],
                                            priority: .background)
        sequence.repeatMode = .forever
        driver.director.play(sequence)
        driver.run(seconds: 5)
        XCTAssertEqual(driver.frames.last?.activeSequenceID, "mood")
        driver.director.cancelAll()
        driver.run(seconds: 1)
        XCTAssertNil(driver.frames.last?.activeSequenceID)
    }
}
