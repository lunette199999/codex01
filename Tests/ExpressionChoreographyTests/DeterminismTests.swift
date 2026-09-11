import XCTest
@testable import ExpressionChoreography

final class DeterminismTests: XCTestCase {

    private func recordAmbientRun(seed: UInt64, seconds: Double = 90) -> [String] {
        let configuration = ChoreographyConfiguration(seed: seed, ambient: AmbientConfiguration())
        let driver = Driver(configuration: configuration)
        driver.run(seconds: seconds)
        return driver.frames.flatMap { frame in
            frame.notices.map { "\(String(format: "%.5f", $0.clock))|\($0.sequenceID)|\($0.kind)" }
        }
    }

    private func recordPoseRun(seed: UInt64, seconds: Double = 90) -> [String] {
        let configuration = ChoreographyConfiguration(seed: seed, ambient: AmbientConfiguration())
        let driver = Driver(configuration: configuration)
        driver.run(seconds: seconds)
        return driver.frames.map { String(format: "%.9f/%.9f/%.9f/%.9f", $0.pose.smile, $0.pose.rest, $0.pose.pressed, $0.pose.parted) }
    }

    func testTheSameSeedAndTheSameTimeStepsReproduceEveryFrame() {
        XCTAssertEqual(recordPoseRun(seed: 12_345), recordPoseRun(seed: 12_345))
        XCTAssertEqual(recordAmbientRun(seed: 12_345), recordAmbientRun(seed: 12_345))
    }

    func testADifferentSeedProducesADifferentIdleSchedule() {
        XCTAssertNotEqual(recordAmbientRun(seed: 1), recordAmbientRun(seed: 2))
    }

    func testIdleBehaviourActuallyFiresSoTheDeterminismCheckIsNotVacuous() {
        let started = recordAmbientRun(seed: 12_345).filter { $0.contains("started") }
        XCTAssertGreaterThanOrEqual(started.count, 2)
    }

    func testTheGeneratorIsStableAcrossProcessesAndNotTheStandardLibraryHash() {
        var generator = SeededGenerator(seed: 42)
        let sample = (0..<4).map { _ in generator.next() }
        XCTAssertEqual(sample, [13_679_457_532_755_275_413,
                                2_949_826_092_126_892_291,
                                5_139_283_748_462_763_858,
                                6_349_198_060_258_255_764])
        // FNV-1a is fixed by the algorithm; `String.hashValue` would change each run.
        XCTAssertEqual(StableHash.fnv1a(""), 0xCBF2_9CE4_8422_2325)
        XCTAssertEqual(StableHash.fnv1a("a"), 0xAF63_DC4C_8601_EC8C)
        XCTAssertEqual(StableHash.fnv1a("ambient.microSmile"), StableHash.fnv1a("ambient.microSmile"))
    }

    func testUnitIntervalStaysInsideItsRange() {
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<10_000 {
            let value = generator.nextUnitInterval()
            XCTAssertTrue(value >= 0 && value < 1)
        }
    }

    func testARangeWithBadBoundsDegradesInsteadOfTrapping() {
        var generator = SeededGenerator(seed: 7)
        XCTAssertEqual(generator.next(in: 5...5), 5)
        XCTAssertEqual(generator.nextIndex(below: 0), 0)
    }

    func testJitterIsSeededSoARepeatedSequenceStillReproduces() {
        func track(seed: UInt64) -> [Double] {
            var sequence = hold(.softSmile, id: "jittered", blend: 0.4, duration: 0.4)
            sequence.repeatMode = .count(4)
            sequence.jitter = StepJitter(blend: 0.5...1.5, hold: 0.5...1.5)
            let driver = Driver(configuration: ChoreographyConfiguration(seed: seed, ambient: .disabled))
            driver.director.play(sequence)
            driver.run(seconds: 6)
            return driver.overlaySmileTrack
        }
        XCTAssertEqual(track(seed: 99), track(seed: 99))
        XCTAssertNotEqual(track(seed: 99), track(seed: 100))
    }
}
