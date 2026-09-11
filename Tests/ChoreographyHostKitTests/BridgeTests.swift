import XCTest
import ExpressionChoreography
@testable import ChoreographyHostKit

/// Checks the adapter against the app's own declarations, using the compile
/// shim in `integrations/ChoreographyHostKit/MotionHostShim.swift`.
final class BridgeTests: XCTestCase {

    func testTheVocabularyComesFromTheAppsOwnTargetTable() {
        // If the app ever retunes a pose, the module follows without an edit here.
        let vocabulary = ChoreographyBridge.hostVocabulary()
        for expression in Expression.allCases {
            let key = ChoreographyBridge.key(for: expression)
            let expected = ExpressionPose.target(expression)
            XCTAssertEqual(vocabulary.weights(for: key),
                           PoseWeights(smile: expected.smile, rest: expected.rest,
                                       pressed: expected.pressed, parted: expected.parted),
                           "\(expression.rawValue) disagrees with the app's own table")
        }
    }

    func testTheBundledFallbackTableStillMatchesTheApp() {
        // The core ships a copy so it can be tested alone; this is the check that
        // the copy has not drifted from the snapshot it was taken from.
        for expression in Expression.allCases {
            let key = ChoreographyBridge.key(for: expression)
            XCTAssertEqual(PoseVocabulary.version0_3_4.weights(for: key),
                           ChoreographyBridge.hostVocabulary().weights(for: key))
        }
    }

    func testEveryExpressionBridgesBothWaysWithNoSilentFallback() {
        XCTAssertEqual(Expression.allCases.count, ExpressionKey.allCases.count)
        for expression in Expression.allCases {
            let key = ChoreographyBridge.key(for: expression)
            XCTAssertEqual(key.rawValue, expression.rawValue)
            XCTAssertEqual(ChoreographyBridge.expression(for: key), expression)
        }
        for key in ExpressionKey.allCases {
            XCTAssertEqual(ChoreographyBridge.key(for: ChoreographyBridge.expression(for: key)), key)
        }
    }

    func testPoseConversionIsExactInBothDirections() {
        let pose = ExpressionPose(smile: 0.31, rest: 0.12, pressed: 0.5, parted: 0.07)
        XCTAssertEqual(ChoreographyBridge.pose(from: ChoreographyBridge.weights(from: pose)), pose)
    }

    func testABrokenHostPoseIsNeutralisedOnTheWayIn() {
        let poisoned = ExpressionPose(smile: .nan, rest: 4, pressed: -1, parted: .infinity)
        let weights = ChoreographyBridge.weights(from: poisoned)
        XCTAssertEqual(weights, PoseWeights(rest: 1))
    }

    func testTheTimerFlagOnlyReportsAChangeOnTheFrameItChanges() {
        let bridge = ChoreographyBridge(configuration: ChoreographyBridge.defaultConfiguration(ambient: .disabled))
        var time = 0.0
        func step() -> ChoreographyFrame {
            let frame = bridge.update(basePose: ExpressionPose(), baseBlink: 0, speechActive: false, at: time)
            time += 1.0 / 24
            return frame
        }
        XCTAssertFalse(step().timerConditionChanged)
        bridge.play(SequenceLibrary.consideration())
        XCTAssertTrue(step().timerConditionChanged)
        XCTAssertFalse(step().timerConditionChanged)
        var changes = 0
        for _ in 0..<80 where step().timerConditionChanged { changes += 1 }
        XCTAssertEqual(changes, 1, "exactly one more change: the sequence ending")
        XCTAssertFalse(bridge.needsContinuousUpdates)
    }
}
