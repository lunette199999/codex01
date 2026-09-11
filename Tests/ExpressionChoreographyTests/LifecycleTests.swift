import XCTest
@testable import ExpressionChoreography

final class LifecycleTests: XCTestCase {

    func testHidingDropsTheOverlayInTheSameCallBecauseNothingIsOnScreen() {
        let driver = Driver()
        driver.director.play(hold(.smile, id: "running", blend: 0.2, duration: 3))
        driver.run(seconds: 0.5)
        XCTAssertEqual(driver.frames.last!.overlay.smile, 0.8, accuracy: 1e-9)

        driver.director.setPresentation(.hidden)
        let hidden = driver.step()
        XCTAssertEqual(hidden.overlay, .identity)
        XCTAssertFalse(hidden.needsContinuousUpdates)
        XCTAssertEqual(hidden.notices.last?.kind.cancelReason, .presentationChanged)
    }

    func testWhileHiddenTheComposedPoseIsExactlyWhateverTheHostIsShowing() {
        let driver = Driver()
        driver.base = PoseWeights(smile: 0.32)
        driver.director.setPresentation(.hidden)
        driver.run(seconds: 1)
        XCTAssertTrue(driver.frames.allSatisfy { $0.pose == driver.base && $0.overlay == .identity })
    }

    func testASequenceSubmittedWhileHiddenIsRefusedRatherThanBanked() {
        let driver = Driver()
        driver.director.setPresentation(.hidden)
        XCTAssertEqual(driver.director.play(SequenceLibrary.warmSmile()), .rejected(.notVisible))
        driver.run(seconds: 0.5)
        driver.director.setPresentation(.visible)
        driver.run(seconds: 3)
        XCTAssertTrue(driver.frames.allSatisfy { $0.overlay == .identity }, "nothing may replay on resume")
    }

    func testResumingStartsFromTheHostPoseAndAsksForNoFramesOfItsOwn() {
        let driver = Driver()
        driver.director.play(hold(.smile, id: "running", blend: 0.2, duration: 5))
        driver.run(seconds: 0.5)
        driver.director.setPresentation(.suspended)
        driver.run(seconds: 0.2)
        driver.skip(seconds: 600)           // the machine slept for ten minutes
        driver.director.setPresentation(.visible)
        driver.base = PoseWeights(smile: 0.32)
        let first = driver.step()
        XCTAssertEqual(first.pose, driver.base)
        XCTAssertEqual(first.overlay, .identity)
        XCTAssertFalse(first.needsContinuousUpdates)
        XCTAssertNil(first.timeAnomaly, "a resume is re-synchronised, not reported as a stall")
    }

    func testIdleBehaviourDoesNotFireImmediatelyAfterAResume() {
        let configuration = ChoreographyConfiguration(seed: 4, ambient: AmbientConfiguration())
        let driver = Driver(configuration: configuration)
        driver.run(seconds: 40)
        XCTAssertTrue(driver.notices().contains { $0.kind.isStarted })
        driver.director.setPresentation(.hidden)
        driver.run(seconds: 1)
        driver.director.setPresentation(.visible)
        let resumed = Driver(configuration: configuration)
        _ = resumed
        let framesAfterResume = driver.run(seconds: 5)
        XCTAssertFalse(framesAfterResume.contains { output in output.notices.contains { $0.kind.isStarted } },
                       "the countdown restarts from the resume, it does not fire what it missed")
    }

    func testALargeTimeStepCancelsWorkAndFadesBackWithoutAJumpOrABacklog() {
        let driver = Driver()
        driver.director.play(hold(.smile, id: "running", blend: 0.2, duration: 30))
        driver.run(seconds: 0.5)
        var queued = hold(.resting, id: "waiting", duration: 1)
        queued.admission = .enqueue
        driver.director.play(queued)
        driver.run(seconds: 0.2)

        driver.skip(seconds: 45)
        let gapFrame = driver.step()
        XCTAssertEqual(gapFrame.timeAnomaly, .largeStep)
        XCTAssertEqual(gapFrame.overlay.smile, 0.8, accuracy: 1e-9,
                       "the stall frame itself must not animate")
        XCTAssertTrue(gapFrame.notices.contains { $0.kind.cancelReason == .timeGap })

        driver.run(seconds: 1.0)
        XCTAssertEqual(driver.frames.last?.overlay, .identity)
        XCTAssertFalse(driver.frames.last!.needsContinuousUpdates)
        XCTAssertFalse(driver.noticeKinds(for: "waiting").contains { $0.isStarted })
        // No single frame may drop more than a normal fade would.
        let tail = driver.frames.suffix(25)
        var worst = 0.0
        for (previous, current) in zip(tail, tail.dropFirst()) {
            worst = max(worst, current.overlay.maximumDifference(from: previous.overlay))
        }
        XCTAssertLessThan(worst, smoothStepFrameLimit(amplitude: 0.8, blend: 0.38))
    }

    func testTurningIdleOffStopsSelfScheduledBehaviourButNotExplicitCommands() {
        let configuration = ChoreographyConfiguration(seed: 4, ambient: AmbientConfiguration())
        let driver = Driver(configuration: configuration)
        driver.director.setIdleEnabled(false)
        driver.run(seconds: 120)
        XCTAssertFalse(driver.notices().contains { $0.kind.isStarted }, "no idle behaviour with idle off")

        driver.director.play(SequenceLibrary.consideration())
        driver.run(seconds: 0.5)
        XCTAssertEqual(driver.frames.last?.activeSequenceID, "mood.consideration")
        XCTAssertTrue(driver.frames.last!.needsContinuousUpdates)
        driver.run(seconds: 2)
        XCTAssertEqual(driver.frames.last?.overlay, .identity)
        XCTAssertFalse(driver.frames.last!.needsContinuousUpdates,
                       "an explicit sequence still lets the host timer stop")
    }

    func testTurningIdleOffReleasesAnIdleSequenceThatIsAlreadyRunning() {
        let configuration = ChoreographyConfiguration(seed: 4, ambient: AmbientConfiguration())
        let driver = Driver(configuration: configuration)
        driver.run(seconds: 40)
        guard driver.frames.contains(where: { $0.activeSequenceID?.hasPrefix("ambient.") == true }) else {
            return XCTFail("expected idle behaviour to have started")
        }
        // Advance to a frame where it is actually running.
        while driver.frames.last?.activeSequenceID == nil && driver.time < 200 { driver.step() }
        driver.director.setIdleEnabled(false)
        let stopped = driver.step()
        XCTAssertNil(stopped.activeSequenceID)
        XCTAssertTrue(driver.notices().contains { $0.kind.cancelReason == .idleDisabled })
        driver.run(seconds: 2)
        XCTAssertEqual(driver.frames.last?.overlay, .identity)
    }

    func testAnAmbientSequenceIsRefusedOutrightWhileIdleIsOff() {
        let driver = Driver()
        driver.director.setIdleEnabled(false)
        XCTAssertEqual(driver.director.play(SequenceLibrary.ambientMicroSmile()), .rejected(.ambientDisabled))
    }

    func testIdleBehaviourStaysOutOfTheWayWhileASentencePlays() {
        let configuration = ChoreographyConfiguration(seed: 4, ambient: AmbientConfiguration())
        let driver = Driver(configuration: configuration)
        driver.speechActive = true
        driver.run(seconds: 180)
        XCTAssertFalse(driver.notices().contains { $0.kind.isStarted })
        driver.speechActive = false
        let after = driver.run(seconds: 3)
        XCTAssertFalse(after.contains { output in output.notices.contains { $0.kind.isStarted } },
                       "and it does not pounce the instant the sentence ends")
    }

    func testResetLeavesACleanDirector() {
        let driver = Driver()
        driver.director.play(hold(.smile, id: "running", duration: 5))
        driver.run(seconds: 0.5)
        driver.director.reset()
        let output = driver.step()
        XCTAssertEqual(output.overlay, .identity)
        XCTAssertNil(output.activeSequenceID)
        XCTAssertFalse(output.needsContinuousUpdates)
        XCTAssertTrue(output.notices.contains { $0.kind.cancelReason == .reset })
    }
}
