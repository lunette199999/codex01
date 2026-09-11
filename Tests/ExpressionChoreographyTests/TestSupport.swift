import XCTest
@testable import ExpressionChoreography

/// Drives a director the way the app's 24 fps timer would, so a test reads as a
/// description of what is on screen rather than a list of method calls.
final class Driver {
    let director: ChoreographyDirector
    let fps: Double
    private(set) var time: Double
    private(set) var frames: [ChoreographyOutput] = []

    init(configuration: ChoreographyConfiguration = ChoreographyConfiguration(ambient: .disabled),
         fps: Double = 24,
         start: Double = 0) {
        director = ChoreographyDirector(configuration: configuration)
        self.fps = fps
        self.time = start
    }

    var base = PoseWeights.identity
    var baseBlink = 0.0
    var speechActive = false

    @discardableResult
    func step() -> ChoreographyOutput {
        let output = director.update(time: time,
                                     input: ChoreographyInput(basePose: base, baseBlink: baseBlink, isSpeechActive: speechActive))
        frames.append(output)
        time += 1 / fps
        return output
    }

    @discardableResult
    func run(seconds: Double) -> [ChoreographyOutput] {
        let count = max(0, Int((seconds * fps).rounded()))
        var produced: [ChoreographyOutput] = []
        for _ in 0..<count { produced.append(step()) }
        return produced
    }

    /// Advances the host clock without rendering, to simulate a stall.
    func skip(seconds: Double) { time += seconds }

    var overlaySmileTrack: [Double] { frames.map(\.overlay.smile) }

    /// Largest single-frame change in any weight of the composed pose. A jump
    /// here is exactly the "snaps back to natural first" defect.
    func largestPoseJump(from index: Int = 1) -> Double {
        guard frames.count > 1 else { return 0 }
        var worst = 0.0
        for i in max(1, index)..<frames.count {
            worst = max(worst, frames[i].pose.maximumDifference(from: frames[i - 1].pose))
        }
        return worst
    }

    func notices() -> [ChoreographyNotice] { frames.flatMap(\.notices) }

    func noticeKinds(for id: String) -> [ChoreographyNotice.Kind] {
        notices().filter { $0.sequenceID == id }.map(\.kind)
    }
}

extension ChoreographyNotice.Kind {
    var isStarted: Bool { if case .started = self { return true }; return false }
    var isFinished: Bool { if case .finished = self { return true }; return false }
    var cancelReason: CancelReason? { if case .cancelled(let reason) = self { return reason }; return nil }
    var rejectionReason: RejectionReason? { if case .rejected(let reason) = self { return reason }; return nil }
}

extension PoseWeights {
    var isFiniteAndBounded: Bool {
        let values = [smile, rest, pressed, parted]
        return values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } && total <= 1 + 1e-9
    }
}

/// A single-step sequence, the shape most tests need.
func hold(_ key: ExpressionKey?,
          id: String,
          intensity: Double = 1,
          blend: Double = 0.4,
          duration: Double = 1.0,
          priority: ChoreographyPriority = .standard,
          admission: Admission = .preempt,
          blink: StepBlink = .inherit,
          speechMask: PoseComponents = .speechOwned) -> ChoreographySequence {
    ChoreographySequence(id: id,
                         steps: [ChoreographyStep(key, intensity: intensity, blend: blend, hold: duration, blink: blink, label: id)],
                         priority: priority,
                         admission: admission,
                         speechMask: speechMask)
}

/// The largest per-frame change a smooth-step of `amplitude` over `blend`
/// seconds can produce at `fps`.
///
/// `t*t*(3-2*t)` peaks at 1.5× the average rate, so anything at or below this is
/// the blend doing its job and anything above it is a step the blend did not ask
/// for — which is exactly the "snapped back to natural first" defect.
func smoothStepFrameLimit(amplitude: Double, blend: Double, fps: Double = 24, tolerance: Double = 1.05) -> Double {
    guard blend > 0 else { return .infinity }
    return 1.5 * amplitude / blend / fps * tolerance
}
