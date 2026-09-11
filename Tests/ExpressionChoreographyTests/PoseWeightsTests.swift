import XCTest
@testable import ExpressionChoreography

final class PoseWeightsTests: XCTestCase {

    func testNonFiniteAndOutOfRangeInputsAreNeutralised() {
        let poisoned = PoseWeights(smile: .nan, rest: .infinity, pressed: -3, parted: 7)
        XCTAssertEqual(poisoned, PoseWeights(smile: 0, rest: 0, pressed: 0, parted: 1))
        XCTAssertTrue(poisoned.isFiniteAndBounded)
    }

    func testBlendRejectsNonFiniteProgressInsteadOfPropagatingIt() {
        let from = PoseWeights(smile: 0.4)
        XCTAssertEqual(from.blended(to: PoseWeights(rest: 1), progress: .nan), from)
        XCTAssertEqual(from.blended(to: PoseWeights(rest: 1), progress: 2), PoseWeights(rest: 1))
        XCTAssertEqual(from.blended(to: PoseWeights(rest: 1), progress: -1), from)
    }

    func testLayeringKeepsTheRendererWeightBudgetForEveryPairOfExpressions() {
        // The shipped self-test asserts `smile + pressed <= 1` halfway through a
        // cross-fade. Layering must not be the thing that breaks that.
        let vocabulary = PoseVocabulary.version0_3_4
        for base in ExpressionKey.allCases {
            for overlayKey in ExpressionKey.allCases {
                for amount in stride(from: 0.0, through: 1.0, by: 0.05) {
                    let overlay = vocabulary.weights(for: overlayKey).scaled(by: amount)
                    let result = PoseWeights.layer(base: vocabulary.weights(for: base), overlay: overlay)
                    XCTAssertTrue(result.isFiniteAndBounded,
                                  "\(base) under \(overlayKey) at \(amount) produced \(result)")
                }
            }
        }
    }

    func testAFullStrengthOverlayIsACrossFadeRatherThanAnAddition() {
        let base = PoseVocabulary.version0_3_4.weights(for: .pressedLips)
        let overlay = PoseVocabulary.version0_3_4.weights(for: .resting)
        XCTAssertEqual(PoseWeights.layer(base: base, overlay: overlay), overlay)
    }

    func testAZeroOverlayLeavesTheBaseExactlyAsItWas() {
        let base = PoseVocabulary.version0_3_4.weights(for: .softSmile)
        XCTAssertEqual(PoseWeights.layer(base: base, overlay: .identity), base)
    }

    func testLayeringIsContinuousSoARampCannotProduceAVisibleStep() {
        let base = PoseVocabulary.version0_3_4.weights(for: .partedLips)
        let target = PoseVocabulary.version0_3_4.weights(for: .smile)
        var previous = PoseWeights.layer(base: base, overlay: .identity)
        for i in 1...200 {
            let overlay = target.scaled(by: Double(i) / 200)
            let current = PoseWeights.layer(base: base, overlay: overlay)
            XCTAssertLessThan(current.maximumDifference(from: previous), 0.02)
            previous = current
        }
    }

    func testMaskingZeroesOnlyTheNamedComponents() {
        let weights = PoseWeights(smile: 0.5, rest: 0.2, pressed: 0.1, parted: 0.2)
        let masked = weights.masking(.speechOwned)
        XCTAssertEqual(masked.parted, 0)
        XCTAssertEqual(masked.smile, 0.5)
        XCTAssertEqual(masked.pressed, 0.1)
        XCTAssertEqual(weights.masking([]), weights)
        XCTAssertEqual(weights.masking(.all), .identity)
    }

    func testBundledVocabularyMatchesTheShippedTargetTable() {
        // Guards the copy in the core against drift. The adapter test proves the
        // app's own table agrees with it.
        let vocabulary = PoseVocabulary.version0_3_4
        XCTAssertEqual(vocabulary.weights(for: .natural), PoseWeights())
        XCTAssertEqual(vocabulary.weights(for: .softSmile), PoseWeights(smile: 0.32))
        XCTAssertEqual(vocabulary.weights(for: .smile), PoseWeights(smile: 0.8))
        XCTAssertEqual(vocabulary.weights(for: .pressedLips), PoseWeights(pressed: 0.85))
        XCTAssertEqual(vocabulary.weights(for: .partedLips), PoseWeights(parted: 0.32))
        XCTAssertEqual(vocabulary.weights(for: .resting), PoseWeights(rest: 1))
    }

    func testEasingMatchesTheShippedSmoothStepShape() {
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(Easing.smoothStep.apply(t), t * t * (3 - 2 * t), accuracy: 1e-12)
        }
        XCTAssertEqual(Easing.smoothStep.apply(.nan), 0)
        XCTAssertEqual(Easing.linear.apply(3), 1)
    }
}
