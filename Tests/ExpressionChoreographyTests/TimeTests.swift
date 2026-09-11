import XCTest
@testable import ExpressionChoreography

final class TimeTests: XCTestCase {

    func testFirstFrameEstablishesTheOriginInsteadOfJumping() {
        var gate = TimeGate()
        let first = gate.advance(to: 9_999, maximumStep: 0.5)
        XCTAssertEqual(first.delta, 0)
        XCTAssertNil(first.anomaly)
        XCTAssertEqual(gate.clock, 0)
    }

    func testOrdinaryFramesAccumulateExactly() {
        var gate = TimeGate()
        _ = gate.advance(to: 100, maximumStep: 0.5)
        for i in 1...24 { _ = gate.advance(to: 100 + Double(i) / 24, maximumStep: 0.5) }
        XCTAssertEqual(gate.clock, 1, accuracy: 1e-12)
    }

    func testNonFiniteTimeIsRefusedWithoutDisturbingTheClock() {
        var gate = TimeGate()
        _ = gate.advance(to: 10, maximumStep: 0.5)
        _ = gate.advance(to: 10.25, maximumStep: 0.5)
        let poisoned = gate.advance(to: .nan, maximumStep: 0.5)
        XCTAssertEqual(poisoned.delta, 0)
        XCTAssertEqual(poisoned.anomaly, .nonFinite)
        XCTAssertEqual(gate.clock, 0.25, accuracy: 1e-12)
        // The clock survives: the next sane frame continues from where it was.
        let resumed = gate.advance(to: 10.5, maximumStep: 0.5)
        XCTAssertEqual(resumed.delta, 0.25, accuracy: 1e-12)
        XCTAssertNil(resumed.anomaly)
    }

    func testInfiniteTimeIsTreatedTheSameWay() {
        var gate = TimeGate()
        _ = gate.advance(to: 1, maximumStep: 0.5)
        XCTAssertEqual(gate.advance(to: .infinity, maximumStep: 0.5).anomaly, .nonFinite)
        XCTAssertEqual(gate.clock, 0)
    }

    func testBackwardsTimeNeverProducesANegativeStep() {
        var gate = TimeGate()
        _ = gate.advance(to: 50, maximumStep: 0.5)
        _ = gate.advance(to: 50.2, maximumStep: 0.5)
        let rewound = gate.advance(to: 3, maximumStep: 0.5)
        XCTAssertEqual(rewound.delta, 0)
        XCTAssertEqual(rewound.anomaly, .wentBackwards)
        XCTAssertEqual(gate.clock, 0.2, accuracy: 1e-12)
        // Re-synchronised on the rewound value, so the next frame is normal.
        let next = gate.advance(to: 3.1, maximumStep: 0.5)
        XCTAssertEqual(next.delta, 0.1, accuracy: 1e-12)
    }

    func testAnOversizedStepIsCappedAndReported() {
        var gate = TimeGate()
        _ = gate.advance(to: 0, maximumStep: 0.5)
        let jump = gate.advance(to: 45, maximumStep: 0.5)
        XCTAssertEqual(jump.delta, 0.5)
        XCTAssertEqual(jump.anomaly, .largeStep)
        XCTAssertEqual(gate.clock, 0.5, accuracy: 1e-12)
    }

    func testResynchroniseKeepsTheClockButForgetsTheReference() {
        var gate = TimeGate()
        _ = gate.advance(to: 0, maximumStep: 0.5)
        _ = gate.advance(to: 0.5, maximumStep: 0.5)
        gate.resynchronise()
        let afterPause = gate.advance(to: 900, maximumStep: 0.5)
        XCTAssertEqual(afterPause.delta, 0)
        XCTAssertNil(afterPause.anomaly, "a resume must not look like a stall")
        XCTAssertEqual(gate.clock, 0.5, accuracy: 1e-12)
    }

    func testAnInvalidMaximumStepFallsBackToTheDefaultCap() {
        var gate = TimeGate()
        _ = gate.advance(to: 0, maximumStep: .nan)
        XCTAssertEqual(gate.advance(to: 90, maximumStep: .nan).delta, 0.5)
    }
}
