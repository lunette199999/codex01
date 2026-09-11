import Foundation

/// Decides when the module may start one of its own idle sequences.
///
/// The countdown runs on the director's internal clock, which only advances by
/// capped deltas. A long pause therefore cannot bank up several firings, and a
/// resume re-arms from the moment of the resume rather than replaying a backlog.
struct AmbientScheduler {
    private var configuration: AmbientConfiguration
    private var rng: SeededGenerator
    private var nextFire: Double?

    init(configuration: AmbientConfiguration, seed: UInt64) {
        self.configuration = configuration
        self.rng = SeededGenerator(seed: seed ^ 0xA43B_1C7D_5E90_2F11)
    }

    mutating func apply(_ configuration: AmbientConfiguration, at clock: Double) {
        let wasEnabled = self.configuration.isEnabled
        self.configuration = configuration
        if !configuration.isEnabled { nextFire = nil; return }
        if !wasEnabled || nextFire == nil { arm(at: clock, first: true) }
    }

    /// Schedules the next firing. `first` uses the longer settling delay used
    /// after becoming visible or turning idle back on.
    mutating func arm(at clock: Double, first: Bool = false) {
        guard configuration.isEnabled, !configuration.library.isEmpty else {
            nextFire = nil
            return
        }
        let range = first ? configuration.firstDelay : configuration.interval
        nextFire = clock + rng.next(in: range)
    }

    mutating func disarm() { nextFire = nil }

    var isArmed: Bool { nextFire != nil }

    /// Pushes the countdown back without firing, used when the channel is busy
    /// or a sentence is playing so idle behaviour never pounces the instant the
    /// portrait becomes free.
    mutating func postpone(at clock: Double) {
        guard nextFire != nil else { return }
        arm(at: clock)
    }

    /// Returns a sequence when one is due, and re-arms the countdown.
    mutating func due(at clock: Double) -> ChoreographySequence? {
        guard configuration.isEnabled, !configuration.library.isEmpty, let fire = nextFire, clock >= fire else {
            return nil
        }
        let choice = configuration.library[rng.nextIndex(below: configuration.library.count)]
        arm(at: clock)
        return choice
    }
}
