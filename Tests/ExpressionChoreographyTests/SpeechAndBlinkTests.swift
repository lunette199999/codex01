import XCTest
@testable import ExpressionChoreography

final class SpeechAndBlinkTests: XCTestCase {

    func testTheOutputHasNoWayToExpressAMouthShapeAtAll() {
        // The strongest guarantee that the module cannot compete with
        // MouthTimeline or the silent-gap closure is that it has no field for it.
        let mirror = Mirror(reflecting: ChoreographyOutput())
        let names = mirror.children.compactMap(\.label)
        XCTAssertFalse(names.contains { $0.lowercased().contains("mouth") })
        XCTAssertFalse(names.contains { $0.lowercased().contains("wide") })
        XCTAssertFalse(names.contains { $0.lowercased().contains("speech") })
    }

    func testASmileIsStillAllowedToShowWhileASentencePlays() {
        let driver = Driver()
        driver.speechActive = true
        driver.director.play(hold(.softSmile, id: "speakingSmile", blend: 0.3, duration: 1.0))
        driver.run(seconds: 1.0)
        XCTAssertEqual(driver.frames.last!.overlay.smile, 0.32, accuracy: 1e-9)
        XCTAssertEqual(driver.frames.last!.pose.smile, 0.32, accuracy: 1e-9)
    }

    func testTheModuleStopsDrivingThePartedWeightWhileSpeechOwnsTheMouth() {
        let driver = Driver()
        driver.director.play(hold(.partedLips, id: "parted", blend: 0.2, duration: 2.0))
        driver.run(seconds: 0.6)
        XCTAssertEqual(driver.frames.last!.overlay.parted, 0.32, accuracy: 1e-9)

        driver.speechActive = true
        let speaking = driver.step()
        XCTAssertEqual(speaking.overlay.parted, 0)
        XCTAssertEqual(speaking.pose.parted, 0)

        // The host's own RestMouthReturn, not the module, decides how the resting
        // aperture comes back, so the module simply un-masks in one step.
        driver.speechActive = false
        XCTAssertEqual(driver.step().overlay.parted, 0.32, accuracy: 1e-9)
    }

    func testWithTheParedOverlayMaskedTheComposedPoseIsExactlyTheHostBasePose() {
        let driver = Driver()
        driver.base = PoseWeights(smile: 0.2, parted: 0.32)
        driver.speechActive = true
        driver.director.play(hold(.partedLips, id: "parted", blend: 0.2, duration: 1.0))
        driver.run(seconds: 0.8)
        XCTAssertEqual(driver.frames.last?.pose, driver.base,
                       "a fully masked overlay must leave the host's pose untouched")
    }

    func testAStricterMaskCanAlsoHoldBackThePressedLipTexture() {
        let driver = Driver()
        driver.speechActive = true
        driver.director.play(hold(.pressedLips, id: "pressed", blend: 0.2, duration: 1.0,
                                  speechMask: .speechOwnedStrict))
        driver.run(seconds: 0.8)
        XCTAssertEqual(driver.frames.last?.overlay.pressed, 0)
        // The default mask keeps the app's existing behaviour, where a pressed
        // lip selection survives playback.
        let lenient = Driver()
        lenient.speechActive = true
        lenient.director.play(hold(.pressedLips, id: "pressed", blend: 0.2, duration: 1.0))
        lenient.run(seconds: 0.8)
        XCTAssertEqual(lenient.frames.last!.overlay.pressed, 0.85, accuracy: 1e-9)
    }

    func testASilentGapInsideASentenceChangesNothingInTheModule() {
        // A silent gap is still `speechActive`; the module has no opinion about
        // the aperture, so its output is identical either way.
        let loud = Driver()
        let quiet = Driver()
        for driver in [loud, quiet] {
            driver.speechActive = true
            driver.director.play(hold(.softSmile, id: "smile", blend: 0.3, duration: 1.0))
            driver.run(seconds: 1.0)
        }
        XCTAssertEqual(loud.frames.map(\.pose), quiet.frames.map(\.pose))
    }

    func testTheHostBlinkPassesThroughUntouchedByDefault() {
        let driver = Driver()
        driver.baseBlink = 0.7
        let output = driver.step()
        XCTAssertEqual(output.blink, 0.7)
        XCTAssertFalse(output.blinkOverridden)
    }

    func testAStepCanHoldTheEyesOpenThroughItsOwnBeat() {
        let driver = Driver()
        driver.baseBlink = 1
        driver.director.play(hold(.softSmile, id: "noBlink", blend: 0.2, duration: 0.5, blink: .hold(0)))
        driver.run(seconds: 0.5)
        XCTAssertTrue(driver.frames.dropFirst().allSatisfy { $0.blink == 0 && $0.blinkOverridden })
        driver.run(seconds: 1.0)
        XCTAssertEqual(driver.frames.last?.blink, 1, "control returns to the host clock afterwards")
        XCTAssertFalse(driver.frames.last!.blinkOverridden)
    }

    func testAnOverlayThatClosesTheEyesHoldsTheAutomaticBlinkShut() {
        let driver = Driver()
        driver.baseBlink = 0.4
        driver.director.play(hold(.resting, id: "rest", blend: 0.3, duration: 1.0))
        driver.run(seconds: 1.0)
        XCTAssertEqual(driver.frames.last?.blink, 0)
        XCTAssertTrue(driver.frames.last!.blinkOverridden)
        // Early in the blend the eyes are barely closed, so the host still owns them.
        XCTAssertEqual(driver.frames[1].blink, 0.4)
    }

    func testTheSuppressionThresholdCanBeTurnedOff() {
        let configuration = ChoreographyConfiguration(restBlinkSuppressionThreshold: 2, ambient: .disabled)
        let driver = Driver(configuration: configuration)
        driver.baseBlink = 0.4
        driver.director.play(hold(.resting, id: "rest", blend: 0.2, duration: 1.0))
        driver.run(seconds: 1.0)
        XCTAssertEqual(driver.frames.last?.blink, 0.4)
    }

    func testABlinkRequestIsReportedExactlyOnce() {
        let driver = Driver()
        let sequence = ChoreographySequence(id: "wink", steps: [
            ChoreographyStep(.softSmile, blend: 0.2, hold: 0.3, blink: .triggerOnEnter),
            ChoreographyStep(nil, blend: 0.2),
        ])
        driver.director.play(sequence)
        driver.run(seconds: 1.5)
        XCTAssertEqual(driver.frames.filter(\.requestsBlinkTrigger).count, 1)
        XCTAssertEqual(driver.frames.firstIndex(where: \.requestsBlinkTrigger), 0,
                       "the request lands on the frame the step begins")
    }

    func testEachRepeatOfAStepAsksForItsOwnBlink() {
        let driver = Driver()
        var sequence = ChoreographySequence(id: "winks", steps: [
            ChoreographyStep(.softSmile, blend: 0.1, hold: 0.1, blink: .triggerOnEnter),
            ChoreographyStep(nil, blend: 0.1, hold: 0.1),
        ])
        sequence.repeatMode = .count(3)
        driver.director.play(sequence)
        driver.run(seconds: 2)
        XCTAssertEqual(driver.frames.filter(\.requestsBlinkTrigger).count, 3)
    }
}
