import Foundation

/// Schedules, blends, arbitrates and cancels expression sequences on top of the
/// pose the host app is already showing.
///
/// Ownership, stated once so nothing is driven twice:
///
/// * The host owns the base expression, its `ExpressionTransition`, the
///   `BlinkClock`, the mouth (`MouthTimeline`, `MouthEnvelope`, silent-gap
///   closure), `RestMouthReturn`, `HairPhysics`, body movement, all timers, and
///   the window lifecycle.
/// * The director owns exactly one thing: a transient overlay on the four
///   expression weights, plus the blink directives a step asks for. The overlay
///   always returns to zero, so nothing it does becomes hidden persistent state.
///
/// The director never reads a clock, never starts a timer or a thread, never
/// touches the screen and never reaches the network. It is not thread-safe by
/// design: call it from whichever thread already drives `renderFrame()`.
public final class ChoreographyDirector {

    // MARK: - State

    public private(set) var configuration: ChoreographyConfiguration
    public private(set) var presentation: Presentation = .visible

    private var timeGate = TimeGate()
    private var overlay: PoseWeights = .identity
    private var active: ActiveSequence?
    private var release: ReleaseState?
    private var queue: [ChoreographySequence] = []
    private var inbox: [ChoreographyEvent] = []
    private var deferredNotices: [ChoreographyNotice] = []
    private var ambient: AmbientScheduler
    private var instanceCounter: UInt64 = 0
    private var pendingBlinkTrigger = false

    public init(configuration: ChoreographyConfiguration = ChoreographyConfiguration()) {
        self.configuration = configuration
        self.ambient = AmbientScheduler(configuration: configuration.ambient, seed: configuration.seed)
        self.ambient.arm(at: 0, first: true)
    }

    /// True while the module may start idle behaviour of its own. Mirrors the
    /// app's "自然待机动作" switch.
    public var isIdleEnabled: Bool { configuration.ambient.isEnabled }

    /// The sequence currently driving the overlay, if any.
    public var activeSequenceID: String? { active?.sequence.id }

    /// The module's monotonic clock. Only ever advances by a capped delta.
    public var clock: Double { timeGate.clock }

    // MARK: - Commands

    /// Buffers an event. Structural problems are reported straight away;
    /// arbitration against whatever is running happens on the next `update`.
    @discardableResult
    public func submit(_ event: ChoreographyEvent) -> SubmissionResult {
        switch event {
        case .play(let sequence):
            guard presentation == .visible else { return .rejected(.notVisible) }
            switch sequence.validated() {
            case .failure(let error):
                return .invalid(error)
            case .success(let clean):
                if clean.isAmbient && !configuration.ambient.isEnabled { return .rejected(.ambientDisabled) }
                inbox.append(.play(clean))
                return .accepted
            }
        case .cancel, .cancelAll:
            inbox.append(event)
            return .accepted
        }
    }

    /// Convenience for the common case.
    @discardableResult
    public func play(_ sequence: ChoreographySequence) -> SubmissionResult {
        submit(.play(sequence))
    }

    @discardableResult
    public func cancel(id: String) -> SubmissionResult { submit(.cancel(id: id)) }

    @discardableResult
    public func cancelAll() -> SubmissionResult { submit(.cancelAll) }

    /// Hide, sleep and resume contract.
    ///
    /// Leaving `visible` drops the running sequence, the queue and anything
    /// submitted but not yet applied, and clears the overlay in the same call —
    /// nothing is banked. Returning to `visible` starts from a zero overlay, so
    /// the first frame back equals the host's own base pose and can never pop
    /// into an exaggerated state, and the idle countdown is re-armed from the
    /// moment of the resume.
    public func setPresentation(_ next: Presentation) {
        guard next != presentation else { return }
        presentation = next
        switch next {
        case .hidden, .suspended:
            if let current = active {
                deferredNotices.append(notice(.cancelled(.presentationChanged), for: current))
                active = nil
            }
            for waiting in queue {
                deferredNotices.append(ChoreographyNotice(kind: .cancelled(.presentationChanged),
                                                          sequenceID: waiting.id, clock: timeGate.clock))
            }
            queue.removeAll()
            inbox.removeAll()
            release = nil
            overlay = .identity
            pendingBlinkTrigger = false
            ambient.disarm()
            timeGate.resynchronise()
        case .visible:
            overlay = .identity
            release = nil
            pendingBlinkTrigger = false
            timeGate.resynchronise()
            ambient.arm(at: timeGate.clock, first: true)
        }
    }

    /// Turns the module's own idle behaviour on and off. Explicit sequences are
    /// unaffected: with idle off a submitted sequence still blends normally and
    /// still stops the host timer when it ends.
    public func setIdleEnabled(_ enabled: Bool) {
        guard enabled != configuration.ambient.isEnabled else { return }
        configuration.ambient.isEnabled = enabled
        if !enabled {
            queue.removeAll { $0.isAmbient }
            inbox.removeAll {
                if case .play(let sequence) = $0 { return sequence.isAmbient }
                return false
            }
            if let current = active, current.sequence.isAmbient {
                var notices: [ChoreographyNotice] = []
                cancelActive(reason: .idleDisabled, notices: &notices, startsRelease: true)
                deferredNotices.append(contentsOf: notices)
            }
        }
        ambient.apply(configuration.ambient, at: timeGate.clock)
    }

    /// Replaces the whole configuration. The idle countdown is re-armed so a new
    /// interval never fires retroactively.
    public func apply(_ configuration: ChoreographyConfiguration) {
        self.configuration = configuration
        ambient.apply(configuration.ambient, at: timeGate.clock)
    }

    /// Drops everything and returns to a clean overlay without a fade. Intended
    /// for teardown, not for an on-screen cancel.
    public func reset() {
        if let current = active { deferredNotices.append(notice(.cancelled(.reset), for: current)) }
        active = nil
        release = nil
        queue.removeAll()
        inbox.removeAll()
        overlay = .identity
        pendingBlinkTrigger = false
        instanceCounter = 0
        timeGate = TimeGate()
        ambient = AmbientScheduler(configuration: configuration.ambient, seed: configuration.seed)
        ambient.arm(at: 0, first: true)
    }

    // MARK: - Frame

    /// Advances one frame using the host's clock and the host's current state.
    public func update(time: Double, input: ChoreographyInput) -> ChoreographyOutput {
        let advance = timeGate.advance(to: time, maximumStep: configuration.maximumTimeStep)
        var notices = deferredNotices
        deferredNotices.removeAll()

        guard presentation == .visible else {
            inbox.removeAll()
            return ChoreographyOutput(pose: input.basePose,
                                      overlay: .identity,
                                      blink: ChoreographyLimits.clamp(input.baseBlink, 0, 1, fallback: 0),
                                      blinkOverridden: false,
                                      requestsBlinkTrigger: false,
                                      needsContinuousUpdates: false,
                                      notices: notices,
                                      timeAnomaly: advance.anomaly,
                                      clock: timeGate.clock)
        }

        // A gap frame cancels and starts a fade, but animates nothing itself.
        // Consuming the capped delta here would collapse the whole fade into the
        // very frame the stall ended on, which is the pop this is meant to avoid.
        // `HairPhysics` takes the same shape: on an oversized delta it resets and
        // returns without integrating.
        let gapped = advance.anomaly == .largeStep
        if gapped { handleTimeGap(notices: &notices) }

        drainInbox(notices: &notices)
        updateAmbient(input: input, notices: &notices)

        var remaining = gapped ? 0 : advance.delta
        var guardCounter = 0
        while remaining > 0 && guardCounter < 8 {
            guardCounter += 1
            if active != nil {
                remaining = advanceActive(by: remaining, notices: &notices)
            } else if release != nil {
                remaining = advanceRelease(by: remaining)
            } else {
                break
            }
        }

        // Recomputing from state keeps a zero-length blend and a zero delta
        // honest: the overlay is always a pure function of where the sequence is.
        if let current = active {
            overlay = overlayValue(for: current)
        } else if let releasing = release {
            overlay = releasing.value()
        } else {
            overlay = .identity
        }

        let mask = speechMask(isSpeechActive: input.isSpeechActive)
        let maskedOverlay = overlay.masking(mask)
        // The reservation is sized on the unmasked overlay, so withholding the
        // mouth component does not hand headroom back to the base and step the
        // smile in the same frame.
        let composed = PoseWeights.layer(base: input.basePose, overlay: maskedOverlay, claiming: overlay.total)

        var blink = ChoreographyLimits.clamp(input.baseBlink, 0, 1, fallback: 0)
        var overridden = false
        if let current = active, case .hold(let value) = current.sequence.steps[current.stepIndex].blink {
            // An explicit hold is the author's decision and takes effect at once.
            blink = ChoreographyLimits.clamp(value, 0, 1, fallback: 0)
            overridden = true
        } else if configuration.blinkFadesUnderRestOverlay && maskedOverlay.rest > 0 {
            // Proportional rather than a threshold: a blink under an eyelid the
            // overlay has already closed is invisible, and fading keeps the
            // blink channel continuous as the pose comes and goes.
            blink *= 1 - maskedOverlay.rest
            overridden = true
        }

        let trigger = pendingBlinkTrigger
        pendingBlinkTrigger = false

        return ChoreographyOutput(pose: composed,
                                  overlay: maskedOverlay,
                                  blink: blink,
                                  blinkOverridden: overridden,
                                  requestsBlinkTrigger: trigger,
                                  needsContinuousUpdates: active != nil || release != nil || !queue.isEmpty,
                                  activeSequenceID: active?.sequence.id,
                                  activeStepLabel: activeLabel(),
                                  notices: notices,
                                  timeAnomaly: advance.anomaly,
                                  clock: timeGate.clock)
    }

    // MARK: - Internals

    private struct ResolvedStep {
        var blend: Double
        var hold: Double
        var total: Double
    }

    private struct ActiveSequence {
        var sequence: ChoreographySequence
        var instance: UInt64
        var rng: SeededGenerator
        var stepIndex: Int
        var iteration: Int
        var elapsedInStep: Double
        var entryPose: PoseWeights
        var resolved: [ResolvedStep]
    }

    private struct ReleaseState {
        var from: PoseWeights
        var duration: Double
        var elapsed: Double

        func value() -> PoseWeights {
            guard duration > 0 else { return .identity }
            return from.blended(to: .identity, progress: Easing.smoothStep.apply(elapsed / duration))
        }
    }

    private func resolve(_ sequence: ChoreographySequence, rng: inout SeededGenerator) -> [ResolvedStep] {
        var result: [ResolvedStep] = []
        result.reserveCapacity(sequence.steps.count)
        for step in sequence.steps {
            var blend = step.blend
            var hold = step.hold
            if let jitter = sequence.jitter {
                blend *= rng.next(between: jitter.minimumBlendScale, and: jitter.maximumBlendScale)
                hold *= rng.next(between: jitter.minimumHoldScale, and: jitter.maximumHoldScale)
            }
            blend = ChoreographyLimits.clamp(blend, 0, ChoreographyLimits.maximumStepBlend, fallback: 0)
            hold = ChoreographyLimits.clamp(hold, 0, ChoreographyLimits.maximumStepHold, fallback: 0)
            result.append(ResolvedStep(blend: blend, hold: hold, total: blend + hold))
        }
        return result
    }

    private func overlayValue(for current: ActiveSequence) -> PoseWeights {
        let step = current.sequence.steps[current.stepIndex]
        let resolved = current.resolved[current.stepIndex]
        let target = step.target(in: configuration.vocabulary)
        guard resolved.blend > 0 else { return target }
        return current.entryPose.blended(to: target, progress: step.easing.apply(current.elapsedInStep / resolved.blend))
    }

    private func activeLabel() -> String? {
        guard let current = active else { return nil }
        let label = current.sequence.steps[current.stepIndex].label
        return label.isEmpty ? nil : label
    }

    private func notice(_ kind: ChoreographyNotice.Kind, for current: ActiveSequence) -> ChoreographyNotice {
        let label = current.sequence.steps[current.stepIndex].label
        return ChoreographyNotice(kind: kind,
                                  sequenceID: current.sequence.id,
                                  stepLabel: label.isEmpty ? nil : label,
                                  clock: timeGate.clock)
    }

    private func speechMask(isSpeechActive: Bool) -> PoseComponents {
        isSpeechActive ? configuration.speechMask : []
    }

    // MARK: - Scheduling

    private func start(_ sequence: ChoreographySequence, notices: inout [ChoreographyNotice]) {
        instanceCounter &+= 1
        // The seed is derived from the sequence name and the instance counter,
        // never from a per-process hash, so a run is reproducible.
        var rng = SeededGenerator(seed: configuration.seed ^ StableHash.fnv1a(sequence.id) &+ instanceCounter)
        let resolved = resolve(sequence, rng: &rng)
        // Starting from the visible overlay is what keeps an interruption from
        // snapping back to natural before it moves on.
        let current = ActiveSequence(sequence: sequence,
                                     instance: instanceCounter,
                                     rng: rng,
                                     stepIndex: 0,
                                     iteration: 0,
                                     elapsedInStep: 0,
                                     entryPose: overlay,
                                     resolved: resolved)
        release = nil
        active = current
        notices.append(notice(.started, for: current))
        armBlink(for: current)
    }

    private func armBlink(for current: ActiveSequence) {
        if case .triggerOnEnter = current.sequence.steps[current.stepIndex].blink {
            pendingBlinkTrigger = true
        }
    }

    private func cancelActive(reason: CancelReason, notices: inout [ChoreographyNotice], startsRelease: Bool) {
        guard let current = active else { return }
        active = nil
        notices.append(notice(.cancelled(reason), for: current))
        guard startsRelease else { return }
        switch current.sequence.cancelBehavior {
        case .immediate:
            overlay = .identity
            release = nil
        case .release(let blend):
            beginRelease(blend: blend)
        }
    }

    private func beginRelease(blend: Double) {
        let duration = ChoreographyLimits.clamp(blend, 0, ChoreographyLimits.maximumStepBlend, fallback: 0)
        guard duration > 0, !overlay.isIdentity else {
            overlay = .identity
            release = nil
            return
        }
        release = ReleaseState(from: overlay, duration: duration, elapsed: 0)
    }

    private func insertQueued(_ sequence: ChoreographySequence) {
        let index = queue.firstIndex { $0.priority < sequence.priority } ?? queue.count
        queue.insert(sequence, at: index)
    }

    private func drainInbox(notices: inout [ChoreographyNotice]) {
        guard !inbox.isEmpty else { return }
        let events = inbox
        inbox.removeAll()
        for event in events {
            switch event {
            case .cancelAll:
                for waiting in queue {
                    notices.append(ChoreographyNotice(kind: .cancelled(.explicit), sequenceID: waiting.id, clock: timeGate.clock))
                }
                queue.removeAll()
                cancelActive(reason: .explicit, notices: &notices, startsRelease: true)
            case .cancel(let id):
                queue.removeAll { waiting in
                    guard waiting.id == id else { return false }
                    notices.append(ChoreographyNotice(kind: .cancelled(.explicit), sequenceID: id, clock: timeGate.clock))
                    return true
                }
                if active?.sequence.id == id {
                    cancelActive(reason: .explicit, notices: &notices, startsRelease: true)
                }
            case .play(let sequence):
                admit(sequence, notices: &notices)
            }
        }
    }

    private func admit(_ sequence: ChoreographySequence, notices: inout [ChoreographyNotice]) {
        guard let current = active else {
            start(sequence, notices: &notices)
            return
        }
        switch sequence.admission {
        case .preempt:
            // Equal priority hands the channel to the newer request, so two
            // events at the same rank resolve in a stated order instead of
            // taking turns nudging the same weight.
            if sequence.priority >= current.sequence.priority {
                cancelActive(reason: .preempted, notices: &notices, startsRelease: false)
                start(sequence, notices: &notices)
            } else {
                notices.append(ChoreographyNotice(kind: .rejected(.lowerPriority), sequenceID: sequence.id, clock: timeGate.clock))
            }
        case .rejectIfBusy:
            notices.append(ChoreographyNotice(kind: .rejected(.channelBusy), sequenceID: sequence.id, clock: timeGate.clock))
        case .enqueue:
            if queue.count >= configuration.maximumQueueDepth {
                notices.append(ChoreographyNotice(kind: .rejected(.queueFull), sequenceID: sequence.id, clock: timeGate.clock))
            } else {
                insertQueued(sequence)
            }
        }
    }

    private func updateAmbient(input: ChoreographyInput, notices: inout [ChoreographyNotice]) {
        guard configuration.ambient.isEnabled, !configuration.ambient.library.isEmpty else { return }
        let busy = active != nil || release != nil || !queue.isEmpty
        let speaking = configuration.ambient.pausesDuringSpeech && input.isSpeechActive
        if busy || speaking {
            // Push the countdown back instead of banking it, so idle behaviour
            // never pounces the instant a sentence ends.
            ambient.postpone(at: timeGate.clock)
            return
        }
        guard let sequence = ambient.due(at: timeGate.clock) else { return }
        start(sequence, notices: &notices)
    }

    /// Cancels running and queued work after a gap in the host clock.
    ///
    /// The advance is already capped by `TimeGate`, so nothing fast-forwards
    /// through the middle of a sequence; dropping the work and fading back to
    /// the host's base pose is what stops a resume from landing on an
    /// exaggerated frame.
    private func handleTimeGap(notices: inout [ChoreographyNotice]) {
        for waiting in queue {
            notices.append(ChoreographyNotice(kind: .cancelled(.timeGap), sequenceID: waiting.id, clock: timeGate.clock))
        }
        queue.removeAll()
        cancelActive(reason: .timeGap, notices: &notices, startsRelease: true)
        ambient.postpone(at: timeGate.clock)
    }

    /// Returns the part of `delta` the finished sequence did not consume.
    private func advanceActive(by delta: Double, notices: inout [ChoreographyNotice]) -> Double {
        guard var current = active else { return delta }
        var remaining = max(0, delta)
        var guardCounter = 0

        while true {
            guardCounter += 1
            if guardCounter > ChoreographyLimits.maximumStepsPerFrame {
                // Safety valve for a pathological all-zero-length loop. Finishing
                // is the safe outcome: it releases the overlay and lets the host
                // timer stop rather than spinning every frame.
                overlay = current.sequence.steps[current.stepIndex].target(in: configuration.vocabulary)
                return finish(current, remaining: remaining, notices: &notices)
            }

            let total = current.resolved[current.stepIndex].total
            let left = total - current.elapsedInStep
            if remaining < left {
                current.elapsedInStep += remaining
                remaining = 0
                overlay = overlayValue(for: current)
                active = current
                return 0
            }

            remaining -= max(0, left)
            current.elapsedInStep = total
            let completed = current.sequence.steps[current.stepIndex].target(in: configuration.vocabulary)

            if current.stepIndex + 1 < current.sequence.steps.count {
                current.stepIndex += 1
                current.elapsedInStep = 0
                current.entryPose = completed
                active = current
                notices.append(notice(.stepChanged(index: current.stepIndex), for: current))
                armBlink(for: current)
                continue
            }

            if let limit = current.sequence.iterationCount, current.iteration + 1 >= limit {
                overlay = completed
                return finish(current, remaining: remaining, notices: &notices)
            }

            current.iteration += 1
            current.stepIndex = 0
            current.elapsedInStep = 0
            current.entryPose = completed
            current.resolved = resolve(current.sequence, rng: &current.rng)
            active = current
            notices.append(notice(.stepChanged(index: 0), for: current))
            armBlink(for: current)
        }
    }

    private func finish(_ current: ActiveSequence, remaining: Double, notices: inout [ChoreographyNotice]) -> Double {
        active = nil
        notices.append(ChoreographyNotice(kind: .finished, sequenceID: current.sequence.id, clock: timeGate.clock))
        if !queue.isEmpty {
            let next = queue.removeFirst()
            start(next, notices: &notices)
            return remaining
        }
        // A sequence is not allowed to leave a standing overlay behind: whatever
        // it ends on fades back to the host's base pose over
        // `configuration.releaseBlend`, so the base expression stays the only
        // persistent expression state in the app. (`cancelBehavior` describes an
        // early stop; this is the ordinary end of the last beat.)
        if !overlay.isIdentity {
            beginRelease(blend: configuration.releaseBlend)
        }
        return remaining
    }

    /// Returns the part of `delta` left over once the release has finished.
    private func advanceRelease(by delta: Double) -> Double {
        guard var releasing = release else { return delta }
        let step = max(0, delta)
        let left = releasing.duration - releasing.elapsed
        if step < left {
            releasing.elapsed += step
            release = releasing
            overlay = releasing.value()
            return 0
        }
        release = nil
        overlay = .identity
        return step - max(0, left)
    }
}
