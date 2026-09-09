//  LightRig.swift
//  Three-point rig plus ambient, and the uniform block the shader consumes.

import simd

/// Layout must match `RelightUniforms` in Relight.metal exactly.
///
/// Everything is packed into `SIMD4<Float>` on purpose. Metal aligns `float3`
/// to 16 bytes, so a struct mixing `float3` and `float` silently grows padding
/// that Swift and Metal do not always agree about. Packing scalars into the
/// unused `w` lanes keeps the layout unambiguous and the struct at 176 bytes.
/// `RelightKitTests` asserts that size so a stray field cannot drift.
public struct RelightUniforms: Equatable {
    public var keyDir: SIMD4<Float>       // xyz = direction toward light, w = intensity
    public var keyColor: SIMD4<Float>     // rgb = colour,                 w = wrap
    public var fillDir: SIMD4<Float>      // xyz,                          w = intensity
    public var fillColor: SIMD4<Float>    // rgb,                          w = wrap
    public var rimDir: SIMD4<Float>       // xyz,                          w = intensity
    public var rimColor: SIMD4<Float>     // rgb,                          w = power
    public var ambientColor: SIMD4<Float> // rgb,                          w = intensity
    public var sssColor: SIMD4<Float>     // rgb,                          w = intensity
    public var params: SIMD4<Float>       // sssPower, specIntensity, specGloss, exposure
    public var layer: SIMD4<Float>        // layerParallax, parallaxScale, coverageSlot, opacity
    public var parallax: SIMD4<Float>     // xy = parallax input in NDC
}

/// The tunable lighting state. Mirrors `LightRig` in tools/relight_reference.py;
/// the defaults are the same numbers so a render here matches a render there.
public struct LightRig: Equatable, Codable, Sendable {

    // Directions point *toward* the light, in view space: +X right, +Y up,
    // +Z toward the viewer. A rim light therefore has negative Z.
    public var keyDirection = SIMD3<Float>(-0.45, 0.35, 0.82)
    public var keyColor = SIMD3<Float>(1.00, 0.96, 0.90)
    public var keyIntensity: Float = 1.05

    public var fillDirection = SIMD3<Float>(0.55, -0.10, 0.83)
    public var fillColor = SIMD3<Float>(0.72, 0.80, 0.95)
    public var fillIntensity: Float = 0.32

    public var rimDirection = SIMD3<Float>(0.30, 0.55, -0.78)
    public var rimColor = SIMD3<Float>(1.00, 0.94, 0.86)
    public var rimIntensity: Float = 0.55
    public var rimPower: Float = 2.6

    public var ambientColor = SIMD3<Float>(0.34, 0.38, 0.46)
    public var ambientIntensity: Float = 0.55

    /// Higher values bend light further around the terminator. This is what
    /// keeps skin from reading as hard plastic; 0 is plain Lambert.
    public var keyWrap: Float = 0.45
    public var fillWrap: Float = 0.70

    public var sssColor = SIMD3<Float>(0.62, 0.20, 0.14)
    public var sssIntensity: Float = 0.42
    public var sssPower: Float = 2.2

    public var specIntensity: Float = 0.18
    public var specGloss: Float = 28.0

    /// Overall stop adjustment, applied last. The environment model drives this
    /// so a bright afternoon and a dim room differ in level, not just in hue.
    public var exposure: Float = 1.0

    public init() {}

    /// Builds the uniform block for one layer.
    ///
    /// - Parameters:
    ///   - layer: which layer is being drawn, for its parallax weight and
    ///     coverage channel.
    ///   - parallax: view offset in NDC, typically driven by idle motion or
    ///     pointer position. Small values: ±0.02 is already a strong effect.
    ///   - parallaxScale: global multiplier, so the effect can be dialled down
    ///     without re-authoring per-layer weights.
    public func uniforms(
        for layer: PortraitLayer,
        parallax: SIMD2<Float> = .zero,
        parallaxScale: Float = 1.0
    ) -> RelightUniforms {
        RelightUniforms(
            keyDir: SIMD4(normalizedSafe(keyDirection), keyIntensity),
            keyColor: SIMD4(keyColor, keyWrap),
            fillDir: SIMD4(normalizedSafe(fillDirection), fillIntensity),
            fillColor: SIMD4(fillColor, fillWrap),
            rimDir: SIMD4(normalizedSafe(rimDirection), rimIntensity),
            rimColor: SIMD4(rimColor, rimPower),
            ambientColor: SIMD4(ambientColor, ambientIntensity),
            sssColor: SIMD4(sssColor, sssIntensity),
            params: SIMD4(sssPower, specIntensity, specGloss, exposure),
            layer: SIMD4(layer.parallax, parallaxScale, Float(layer.coverageSlot), layer.opacity),
            parallax: SIMD4(parallax.x, parallax.y, 0, 0)
        )
    }
}

/// `simd_normalize` returns NaN for a zero vector, which then propagates through
/// the whole frame as black. A rig arriving from JSON or a slider is not
/// guaranteed non-zero, so normalise defensively.
@inline(__always)
func normalizedSafe(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let lengthSquared = simd_length_squared(v)
    return lengthSquared > 1e-12 ? v / lengthSquared.squareRoot() : SIMD3<Float>(0, 0, 1)
}
