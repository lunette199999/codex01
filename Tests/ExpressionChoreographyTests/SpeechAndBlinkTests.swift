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

    func testWithNothingRunningTheComposedPoseIsTheHostPoseBitForBit() {
        let driver = Driver()
        driver.base = PoseWeights(smile: 0.2, parted: 0.32)
        driver.speechActive = true
        driver.run(seconds: 0.5)
        XCTAssertTrue(driver.frames.allSatisfy { $0.pose == driver.base })
    }

    func testARunningSequenceHoldsItsShareOfTheBudgetWhetherOrNotSpeechWithholdsIt() {
        // The reservation is what keeps a mask from stepping the other
        // components: it is sized on what the sequence asked for, not on what
        // survives the mask, so it does not change when a sentence starts.
        let driver = Driver()
        driver.base = PoseWeights(smile: 0.2, parted: 0.32)
        driver.director.play(hold(.partedLips, id: "parted", blend: 0.2, duration: 4))
        driver.run(seconds: 0.6)
        let quiet = driver.frames.last!.pose
        driver.speechActive = true
        let speaking = driver.step()
        XCTAssertEqual(speaking.pose.smile, quiet.smile, accuracy: 1e-12,
                       "the smile must not brighten because the mouth was withheld")
        XCTAssertEqual(speaking.pose.parted, driver.base.parted * (1 - 0.32), accuracy: 1e-12,
                       "what is left is the host's own parted, scaled by the reservation")
        XCTAssertEqual(speaking.overlay.parted, 0, "and the module contributes none of its own")
    }

    func testAStricterMaskCanAlsoHoldBackThePressedLipTexture() {
        let strict = ChoreographyConfiguration(speechMask: .speechOwnedStrict, ambient: .disabled)
        let driver = Driver(configuration: strict)
        driver.speechActive = true
        driver.director.play(hold(.pressedLips, id: "pressed", blend: 0.2, duration: 1.0))
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

    func testTheBlinkRequestIsNotScaledByAnyRestOverlay() {
        // `blink` and `pose.rest` are two requests for the same quantity, and the
        // renderer resolves them once with `max`. Scaling one by the other here
        // would be a second composition point — it is what hid the blink for
        // every `rest >= 0.5`. The final eyelid value is asserted in
        // ChoreographyHostKitTests/EyelidCompositionTests, against the
        // renderer's own function.
        let driver = Driver()
        driver.baseBlink = 0.4
        driver.director.play(hold(.resting, id: "rest", blend: 0.3, duration: 1.0))
        driver.run(seconds: 1.0)
        XCTAssertTrue(driver.frames.allSatisfy { $0.blink == 0.4 && !$0.blinkOverridden },
                      "the host's own blink value must reach the frame untouched")
        XCTAssertEqual(driver.frames.last!.overlay.rest, 1, accuracy: 1e-9,
                       "even with the overlay holding the lid fully closed")
    }

    func testTheBlinkChannelIsFlatWhenTheHostBlinkIsFlat() {
        // With nothing scaling it, a steady request produces a steady channel
        // whatever the pose does around it.
        let driver = Driver()
        driver.baseBlink = 1
        driver.director.play(hold(.resting, id: "rest", blend: 1.0, duration: 0.5))
        driver.run(seconds: 3)
        let steps = zip(driver.frames, driver.frames.dropFirst()).map { abs($1.blink - $0.blink) }
        XCTAssertEqual(steps.max() ?? 1, 0, accuracy: 1e-12)
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
