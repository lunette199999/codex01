import XCTest
@testable import ExpressionChoreography

final class SequenceValidationTests: XCTestCase {

    private func failure(_ sequence: ChoreographySequence) -> ChoreographyValidationError? {
        if case .failure(let error) = sequence.validated() { return error }
        return nil
    }

    private func success(_ sequence: ChoreographySequence) -> ChoreographySequence? {
        if case .success(let clean) = sequence.validated() { return clean }
        return nil
    }

    func testStructuralProblemsAreRefusedRatherThanGuessedAt() {
        XCTAssertEqual(failure(ChoreographySequence(id: "  ", steps: [ChoreographyStep(.smile)])), .emptyIdentifier)
        XCTAssertEqual(failure(ChoreographySequence(id: "empty", steps: [])), .noSteps)
        XCTAssertEqual(failure(ChoreographySequence(id: String(repeating: "x", count: 200), steps: [ChoreographyStep(.smile)])),
                       .identifierTooLong(200))
        let many = (0..<40).map { _ in ChoreographyStep(.smile, blend: 0.1) }
        XCTAssertEqual(failure(ChoreographySequence(id: "many", steps: many)), .tooManySteps(40))
    }

    func testNonFiniteTimingIsRefusedInsteadOfSilentlyBecomingZero() {
        let sequence = ChoreographySequence(id: "poisoned", steps: [
            ChoreographyStep(.smile, blend: 0.2),
            ChoreographyStep(.natural, blend: .nan),
        ])
        XCTAssertEqual(failure(sequence), .nonFiniteStep(index: 1))
        XCTAssertEqual(failure(ChoreographySequence(id: "p2", steps: [ChoreographyStep(.smile, intensity: .infinity)])),
                       .nonFiniteStep(index: 0))
    }

    func testOutOfRangeNumbersAreClampedIntoTheDocumentedLimits() {
        let sequence = ChoreographySequence(id: "  loud  ", steps: [
            ChoreographyStep(.smile, intensity: 4, blend: 900, hold: -3, blink: .hold(9), label: String(repeating: "L", count: 200)),
        ])
        guard let clean = success(sequence) else { return XCTFail("expected clamping, not rejection") }
        XCTAssertEqual(clean.id, "loud")
        XCTAssertEqual(clean.steps[0].intensity, 1)
        XCTAssertEqual(clean.steps[0].blend, ChoreographyLimits.maximumStepBlend)
        XCTAssertEqual(clean.steps[0].hold, 0)
        XCTAssertEqual(clean.steps[0].blink, .hold(1))
        XCTAssertEqual(clean.steps[0].label.count, ChoreographyLimits.maximumLabelLength)
    }

    func testAnOverlongSequenceIsRefused() {
        let long = (0..<20).map { _ in ChoreographyStep(.smile, blend: 10, hold: 30) }
        XCTAssertEqual(failure(ChoreographySequence(id: "long", steps: long)), .durationTooLong(800))
    }

    func testAZeroLengthEndlessSequenceIsRefusedBecauseItCouldNotAdvance() {
        let sequence = ChoreographySequence(id: "spin",
                                            steps: [ChoreographyStep(.smile, blend: 0, hold: 0)],
                                            repeatMode: .forever)
        XCTAssertEqual(failure(sequence), .zeroLengthRepeat)
    }

    func testRepeatCountAndJitterRangesAreClamped() {
        var sequence = hold(.smile, id: "repeat", duration: 0.2)
        sequence.repeatMode = .count(10_000)
        // Reversed and non-finite bounds are repaired rather than trapping, which
        // is why the bounds are stored as numbers instead of a ClosedRange.
        sequence.jitter = StepJitter(minimumBlendScale: 9, maximumBlendScale: -4,
                                     minimumHoldScale: .nan, maximumHoldScale: .infinity)
        guard let clean = success(sequence) else { return XCTFail("expected clamping") }
        XCTAssertEqual(clean.iterationCount, ChoreographyLimits.maximumRepeatCount)
        XCTAssertEqual(clean.jitter?.minimumBlendScale, 0)
        XCTAssertEqual(clean.jitter?.maximumBlendScale, 4)
        // A non-finite bound falls back to "no jitter" rather than to a limit,
        // so a typo cannot silently triple a hold.
        XCTAssertEqual(clean.jitter?.minimumHoldScale, 1)
        XCTAssertEqual(clean.jitter?.maximumHoldScale, 1)
    }

    func testTheDirectorRefusesAnInvalidSequenceAtSubmissionTime() {
        let director = ChoreographyDirector(configuration: ChoreographyConfiguration(ambient: .disabled))
        XCTAssertEqual(director.play(ChoreographySequence(id: "", steps: [])), .invalid(.emptyIdentifier))
        XCTAssertEqual(director.update(time: 0, input: ChoreographyInput()).notices.count, 0)
    }

    func testStepDurationIsBlendPlusHold() {
        XCTAssertEqual(ChoreographyStep(.smile, blend: 0.3, hold: 0.7).duration, 1.0, accuracy: 1e-12)
        XCTAssertEqual(SequenceLibrary.softSmileGreeting().nominalDuration, 0.38 + 0.90 + 0.45, accuracy: 1e-12)
    }
}
