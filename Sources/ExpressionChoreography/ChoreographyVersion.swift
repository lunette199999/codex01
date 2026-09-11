import Foundation

/// The module's own version, so a host can prove which core it linked.
///
/// This exists because nothing else in the API is a reliable version signal:
/// `ChoreographyBridge.swift` was byte-identical across 1.0.0 and 1.1.0 and
/// compiled cleanly against either core, so neither a file comparison nor a
/// successful build said anything about which core was in the binary.
///
/// Referencing `ChoreographyVersion.current` fails to compile against any core
/// older than 1.2.0, and returns the exact version at runtime.
public enum ChoreographyVersion {
    /// Bumped whenever core behaviour changes.
    ///
    /// * `1.0.0` — first delivery.
    /// * `1.1.0` — pre-mask layering reservation, host-level speech mask,
    ///   proportional blink fade under a rest overlay.
    /// * `1.2.0` — the blink fade is removed: it was a second composition point
    ///   for eyelid closure and hid the blink for every `rest >= 0.5`.
    public static let current = "1.2.0"
}
