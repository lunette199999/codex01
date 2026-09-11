import XCTest
@testable import ExpressionChoreography

final class RobustnessTests: XCTestCase {

    func testANonFiniteHostClockNeitherCorruptsStateNorReachesTheOutput() {
        let driver = Driver()
        driver.director.play(hold(.smile, id: "running", blend: 0.4, duration: 1))
        driver.run(seconds: 0.2)
        let before = driver.frames.last!.overlay

        let poisoned = driver.director.update(time: .nan, input: ChoreographyInput())
        XCTAssertEqual(poisoned.timeAnomaly, .nonFinite)
        XCTAssertEqual(poisoned.overlay, before, "a bad clock freezes, it does not jump")
        XCTAssertTrue(poisoned.pose.isFiniteAndBounded)

        driver.run(seconds: 2.5)
        XCTAssertEqual(driver.frames.last?.overlay, .identity, "and the sequence still completes afterwards")
    }

    func testANonFiniteBasePoseOrBlinkIsNeutralisedRatherThanPropagated() {
        let driver = Driver()
        driver.base = PoseWeights(smile: .nan, rest: .infinity, pressed: -1, parted: 12)
        driver.baseBlink = .nan
        let output = driver.step()
        XCTAssertTrue(output.pose.isFiniteAndBounded)
        XCTAssertEqual(output.blink, 0)
    }

    func testAHostClockThatGoesBackwardsIsAbsorbed() {
        let driver = Driver()
        driver.director.play(hold(.softSmile, id: "running", blend: 0.4, duration: 1))
        driver.run(seconds: 0.3)
        let before = driver.frames.last!.overlay
        let rewound = driver.director.update(time: -5_000, input: ChoreographyInput())
        XCTAssertEqual(rewound.timeAnomaly, .wentBackwards)
        XCTAssertEqual(rewound.overlay, before)
        XCTAssertTrue(rewound.pose.isFiniteAndBounded)
    }

    func testEveryFrameOfAHostileRunStaysFiniteAndInsideTheRendererBudget() {
        var generator = SeededGenerator(seed: 0xBADF_00D)
        let configuration = ChoreographyConfiguration(seed: 3, ambient: AmbientConfiguration())
        let director = ChoreographyDirector(configuration: configuration)
        let poses = ExpressionKey.allCases
        var time = 0.0

        for frame in 0..<6_000 {
            switch generator.nextIndex(below: 24) {
            case 0:
                var sequence = hold(poses[generator.nextIndex(below: poses.count)],
                                    id: "fuzz\(generator.nextIndex(below: 5))",
                                    intensity: generator.next(in: -1...2),
                                    blend: generator.next(in: -1...2),
                                    duration: generator.next(in: -1...3),
                                    priority: ChoreographyPriority(generator.nextIndex(below: 120)))
                sequence.admission = [.preempt, .rejectIfBusy, .enqueue][generator.nextIndex(below: 3)]
                director.play(sequence)
            case 1: director.cancelAll()
            case 2: director.cancel(id: "fuzz\(generator.nextIndex(below: 5))")
            case 3: director.setIdleEnabled(generator.nextIndex(below: 2) == 0)
            case 4: director.setPresentation([.visible, .hidden, .suspended][generator.nextIndex(below: 3)])
            default: break
            }

            switch generator.nextIndex(below: 40) {
            case 0: time = .nan
            case 1: time = -Double(frame)
            case 2: time += generator.next(in: 0...600)
            default: time += 1.0 / 24
            }

            let base = PoseWeights(smile: generator.next(in: -1...2),
                                   rest: generator.next(in: -1...2),
                                   pressed: generator.next(in: -1...2),
                                   parted: generator.next(in: -1...2))
            let output = director.update(time: time,
                                         input: ChoreographyInput(basePose: base,
                                                                  baseBlink: generator.next(in: -1...2),
                                                                  isSpeechActive: generator.nextIndex(below: 3) == 0))
            XCTAssertTrue(output.overlay.isFiniteAndBounded, "overlay escaped its range on frame \(frame)")
            XCTAssertTrue(output.blink.isFinite && output.blink >= 0 && output.blink <= 1)
            XCTAssertTrue(output.clock.isFinite && output.clock >= 0)
            for value in [output.pose.smile, output.pose.rest, output.pose.pressed, output.pose.parted] {
                XCTAssertTrue(value.isFinite && value >= 0 && value <= 1, "pose escaped its range on frame \(frame)")
            }
            // The fuzz feeds base poses the host could never produce (all four
            // weights at once). The module cannot repair those, but it must never
            // make the budget worse than the base already was.
            let clampedBase = PoseWeights(smile: base.smile, rest: base.rest, pressed: base.pressed, parted: base.parted)
            XCTAssertLessThanOrEqual(output.pose.total, max(clampedBase.total, 1) + 1e-9,
                                     "weight budget made worse on frame \(frame)")
        }
    }

    func testARealisticHostBasePoseAlwaysKeepsTheBudgetUnderOne() {
        // Every pose the app can actually hand over is a target value or a
        // cross-fade between two of them, and for those the bound is absolute.
        var generator = SeededGenerator(seed: 0xC0FFEE)
        let vocabulary = PoseVocabulary.version0_3_4
        let configuration = ChoreographyConfiguration(seed: 8, ambient: AmbientConfiguration())
        let director = ChoreographyDirector(configuration: configuration)
        var time = 0.0
        for frame in 0..<3_000 {
            if generator.nextIndex(below: 30) == 0 {
                director.play(hold(ExpressionKey.allCases[generator.nextIndex(below: 6)],
                                   id: "fuzz\(generator.nextIndex(below: 3))",
                                   blend: generator.next(in: 0...1),
                                   duration: generator.next(in: 0...2),
                                   priority: ChoreographyPriority(generator.nextIndex(below: 100))))
            }
            time += 1.0 / 24
            let a = vocabulary.weights(for: ExpressionKey.allCases[generator.nextIndex(below: 6)])
            let b = vocabulary.weights(for: ExpressionKey.allCases[generator.nextIndex(below: 6)])
            let base = a.blended(to: b, progress: generator.nextUnitInterval())
            let output = director.update(time: time,
                                         input: ChoreographyInput(basePose: base,
                                                                  baseBlink: generator.nextUnitInterval(),
                                                                  isSpeechActive: generator.nextIndex(below: 3) == 0))
            XCTAssertLessThanOrEqual(output.pose.total, 1 + 1e-9, "weight budget broken on frame \(frame)")
            XCTAssertTrue(output.pose.isFiniteAndBounded)
        }
    }

    func testZeroLengthStepsResolveInOneFrameWithoutSpinning() {
        let driver = Driver()
        let sequence = ChoreographySequence(id: "instant", steps: [
            ChoreographyStep(.smile, blend: 0, hold: 0, label: "a"),
            ChoreographyStep(.pressedLips, blend: 0, hold: 0, label: "b"),
            ChoreographyStep(nil, blend: 0, hold: 0, label: "c"),
        ])
        driver.director.play(sequence)
        driver.run(seconds: 0.3)
        XCTAssertTrue(driver.noticeKinds(for: "instant").contains { $0.isFinished })
        XCTAssertEqual(driver.frames.last?.overlay, .identity)
    }

    func testAZeroBlendStepAppliesItsPoseOnTheFrameItStarts() {
        let driver = Driver()
        driver.director.play(hold(.smile, id: "snap", blend: 0, duration: 0.5))
        let first = driver.step()
        XCTAssertEqual(first.overlay.smile, 0.8, accuracy: 1e-9)
    }

    func testRepeatedUpdatesAtTheSameTimestampAreIdempotent() {
        let driver = Driver()
        driver.director.play(hold(.softSmile, id: "running", blend: 0.4, duration: 1))
        driver.run(seconds: 0.2)
        let time = driver.time
        let first = driver.director.update(time: time, input: ChoreographyInput())
        let second = driver.director.update(time: time, input: ChoreographyInput())
        XCTAssertEqual(first.overlay, second.overlay, "a duplicated frame must not advance the sequence")
    }

    func testTheDirectorHasNoClockOfItsOwn() {
        // Two directors given the same scripted timestamps must agree, whatever
        // the wall clock did in between.
        let first = Driver()
        let second = Driver()
        first.director.play(SequenceLibrary.warmSmile())
        second.director.play(SequenceLibrary.warmSmile())
        first.run(seconds: 3)
        Thread.sleep(forTimeInterval: 0.05)
        second.run(seconds: 3)
        XCTAssertEqual(first.frames.map(\.overlay), second.frames.map(\.overlay))
    }
}
