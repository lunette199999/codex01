import XCTest
import simd
import Metal
@testable import RelightKit

final class UniformLayoutTests: XCTestCase {

    /// The shader reads this struct by offset. If a field is added, reordered,
    /// or changed from SIMD4, Metal keeps reading the old offsets and the
    /// symptom is a subtly wrong image rather than a crash - so pin the size.
    func testUniformStrideMatchesShader() {
        XCTAssertEqual(MemoryLayout<RelightUniforms>.stride, 11 * 16)
        XCTAssertEqual(MemoryLayout<RelightUniforms>.alignment, 16)
    }

    func testLayerPackingReachesTheRightChannel() {
        var layer = PortraitLayer(
            name: "hair_front", index: 4, base: 0.78,
            relief: 0.08, normalStrength: 2.0, parallax: 1.0
        )
        layer.coverageSlot = 3
        layer.opacity = 0.5

        let uniforms = LightRig().uniforms(
            for: layer,
            parallax: SIMD2(0.01, -0.02),
            parallaxScale: 2.0
        )

        XCTAssertEqual(uniforms.layer.x, 1.0, accuracy: 1e-6)   // layerParallax
        XCTAssertEqual(uniforms.layer.y, 2.0, accuracy: 1e-6)   // parallaxScale
        XCTAssertEqual(uniforms.layer.z, 3.0, accuracy: 1e-6)   // coverageSlot
        XCTAssertEqual(uniforms.layer.w, 0.5, accuracy: 1e-6)   // opacity
        XCTAssertEqual(uniforms.parallax.x, 0.01, accuracy: 1e-6)
        XCTAssertEqual(uniforms.parallax.y, -0.02, accuracy: 1e-6)
    }

    func testDirectionsAreNormalisedIntoUniforms() {
        var rig = LightRig()
        rig.keyDirection = SIMD3(0, 0, 5)   // deliberately not unit length

        let uniforms = rig.uniforms(for: .test)
        XCTAssertEqual(simd_length(SIMD3(uniforms.keyDir.x, uniforms.keyDir.y, uniforms.keyDir.z)),
                       1.0, accuracy: 1e-5)
        XCTAssertEqual(uniforms.keyDir.w, rig.keyIntensity, accuracy: 1e-6)
    }

    /// A zero direction from a slider at rest would produce NaN through
    /// simd_normalize and blacken the entire frame.
    func testZeroDirectionDoesNotProduceNaN() {
        var rig = LightRig()
        rig.keyDirection = .zero
        let d = rig.uniforms(for: .test).keyDir
        XCTAssertFalse(d.x.isNaN || d.y.isNaN || d.z.isNaN)
        XCTAssertEqual(simd_length(SIMD3(d.x, d.y, d.z)), 1.0, accuracy: 1e-5)
    }
}

final class ColorTemperatureTests: XCTestCase {

    func testWarmerIsRedderThanCooler() {
        let warm = EnvironmentLight.kelvinToRGB(2200)
        let cool = EnvironmentLight.kelvinToRGB(9000)
        XCTAssertGreaterThan(warm.x / max(warm.z, 1e-4), cool.x / max(cool.z, 1e-4))
    }

    func testOutputIsNormalisedAndInRange() {
        for kelvin in stride(from: Float(1200), through: 20000, by: 400) {
            let rgb = EnvironmentLight.kelvinToRGB(kelvin)
            XCTAssertEqual(rgb.max(), 1.0, accuracy: 1e-4, "not normalised at \(kelvin)K")
            XCTAssertGreaterThanOrEqual(rgb.min(), 0.0, "negative channel at \(kelvin)K")
        }
    }
}

final class SolarPositionTests: XCTestCase {

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: iso)!
    }

    func testEquinoxNoonAtEquatorIsOverhead() {
        let position = SolarPosition(
            date: date("2026-03-20T12:00:00Z"),
            latitude: 0, longitude: 0,
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertGreaterThan(position.elevation, 85)
    }

    func testMidnightIsBelowHorizon() {
        let position = SolarPosition(
            date: date("2026-06-21T00:00:00Z"),
            latitude: 40, longitude: 0,
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertLessThan(position.elevation, 0)
    }

    /// The key must keep some forward component or the face goes fully black
    /// when the sun is behind the notional window.
    func testKeyStaysInFrontOfTheSubject() {
        for hour in 0...23 {
            let position = SolarPosition(
                date: date(String(format: "2026-06-21T%02d:00:00Z", hour)),
                latitude: 35, longitude: 139,
                timeZone: TimeZone(identifier: "UTC")!
            )
            let direction = position.viewSpaceDirection(windowBearing: 180)
            XCTAssertGreaterThan(direction.z, 0, "key fell behind the subject at \(hour):00")
        }
    }

    func testNightIsCoolerAndDimmerThanNoon() {
        let noon = SolarPosition(date: date("2026-06-21T12:00:00Z"),
                                 latitude: 35, longitude: 0,
                                 timeZone: TimeZone(identifier: "UTC")!)
        let night = SolarPosition(date: date("2026-06-21T00:00:00Z"),
                                  latitude: 35, longitude: 0,
                                  timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertGreaterThan(night.colorTemperature, noon.colorTemperature)
        XCTAssertLessThan(night.keyIntensity, noon.keyIntensity)
        XCTAssertLessThan(night.exposure, noon.exposure)
    }
}

final class IdleParallaxTests: XCTestCase {

    func testStaysWithinAmplitudeAndKeepsMoving() {
        var idle = IdleParallax()
        var samples: [SIMD2<Float>] = []
        for _ in 0..<600 { samples.append(idle.advance(by: 1.0 / 60.0)) }

        for sample in samples {
            XCTAssertLessThanOrEqual(abs(sample.x), idle.amplitude * 1.01)
            XCTAssertLessThanOrEqual(abs(sample.y), idle.amplitude * 1.01)
        }
        // Ten seconds in, it must not have settled into a fixed point.
        XCTAssertGreaterThan(simd_distance(samples[300], samples[599]), 1e-4)
    }
}

private extension PortraitLayer {
    static var test: PortraitLayer {
        PortraitLayer(name: "face", index: 3, base: 0.55,
                      relief: 0.22, normalStrength: 2.4, parallax: 0.55)
    }
}

final class HairSolverTests: XCTestCase {

    private var specs: [StrandSpec] {
        [
            StrandSpec(rootU: 0.30, rootV: 0.15, tipV: 0.60, layer: "hair_front"),
            StrandSpec(rootU: 0.70, rootV: 0.15, tipV: 0.60, layer: "hair_front"),
        ]
    }

    @discardableResult
    private func sway(_ solver: HairSolver, seconds: Float = 2.0,
                      fps: Float = 120, swayUntil: Float = 1.4) -> [[SIMD2<Float>]] {
        let dt = 1 / fps
        var trace: [[SIMD2<Float>]] = []
        for i in 0..<Int(seconds * fps) {
            let t = Float(i) * dt
            let offset = t < swayUntil ? sin(t * 4.2) * 0.02 : 0
            solver.step(delta: dt, headOffset: SIMD2(offset, 0))
            trace.append(solver.offsets())
        }
        return trace
    }

    /// Regression: with a soft spring along the segment axis the segment
    /// stretches and swallows the motion, so the tip never moves - the ends go
    /// dead exactly where hair should be liveliest.
    func testMotionReachesTheTip() {
        let solver = HairSolver(strands: specs, nodeCount: 5)
        let trace = sway(solver)

        let root = trace.map { abs($0[0].x) }.max() ?? 0
        let tip = trace.map { abs($0[4].x) }.max() ?? 0
        XCTAssertGreaterThan(tip, root, "motion is not propagating down the chain")
        XCTAssertGreaterThan(tip / max(root, 1e-9), 1.5, "tip should overshoot the root")
    }

    func testChainReturnsToRest() {
        let solver = HairSolver(strands: specs, nodeCount: 5)
        sway(solver, seconds: 8.0)
        let settled = solver.offsets().map { simd_length($0) }.max() ?? 0
        XCTAssertLessThan(settled, 2e-3)
    }

    /// The length constraint is solved last, so the pose leaving the solver must
    /// satisfy it exactly.
    func testSegmentLengthsArePreserved() {
        let solver = HairSolver(strands: specs, nodeCount: 5)
        sway(solver, seconds: 1.5)

        let offsets = solver.offsets()
        // Rebuild absolute positions from rest + offset to measure segments.
        for s in 0..<specs.count {
            let span = specs[s].tipV - specs[s].rootV
            let restLength = span / 4
            for k in 1..<5 {
                let a = SIMD2(specs[s].rootU, specs[s].rootV + span * Float(k - 1) / 4)
                    + offsets[s * 5 + k - 1]
                let b = SIMD2(specs[s].rootU, specs[s].rootV + span * Float(k) / 4)
                    + offsets[s * 5 + k]
                XCTAssertEqual(simd_distance(a, b), restLength, accuracy: restLength * 0.05)
            }
        }
    }

    /// Fixed 120 Hz substeps. Compared at the settled steady state: a frame rate
    /// that does not divide the substep rate evenly simulates a few milliseconds
    /// more or less over a given span, so sampling a still-ringing chain catches
    /// different phases and says nothing about the solver.
    func testMotionIsFrameRateIndependent() {
        var results: [SIMD2<Float>] = []
        for fps in [Float(24), 30, 60, 120] {
            let solver = HairSolver(strands: specs, nodeCount: 5)
            let dt = 1 / fps
            for _ in 0..<Int(6.0 * fps) {
                solver.step(delta: dt, headOffset: SIMD2(0.02, 0))
            }
            results.append(solver.offsets()[4])
        }
        for other in results.dropFirst() {
            XCTAssertEqual(simd_distance(results[0], other), 0, accuracy: 1e-5)
        }
    }

    func testOffsetsAreClamped() {
        var params = HairParams()
        params.maxOffset = 0.02
        let solver = HairSolver(strands: specs, nodeCount: 5, params: params)
        for _ in 0..<200 {
            solver.step(delta: 1.0 / 120, headOffset: SIMD2(0.5, 0.5))
        }
        let peak = solver.offsets().map { simd_length($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, params.maxOffset * 1.01)
    }

    func testEmptyStrandListIsHarmless() {
        let solver = HairSolver(strands: [], nodeCount: 5)
        solver.step(delta: 1.0 / 60, headOffset: SIMD2(0.01, 0))
        XCTAssertTrue(solver.offsets().isEmpty)
    }
}


/// The character must read as front-facing with the head and neck upright.
/// These pin the two structural properties that guarantee it.
final class FrontFacingInvariantTests: XCTestCase {

    private func layer(_ name: String, index: Int, hair: Bool) -> PortraitLayer {
        PortraitLayer(name: name, index: index, base: 0.5, relief: 0.1,
                      normalStrength: 2.0, parallax: 0.5, hair: hair)
    }

    /// Only hair moves. The face and body cannot be deformed by the strand
    /// system under any parameter values, because a non-hair layer's uniform
    /// block is all zeros and a zero `params.w` disables displacement in the
    /// shader.
    func testNonHairLayersReceiveNoDisplacement() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(),
                                   "no Metal device; skipping")
        let renderer = try RelightRenderer(device: device)

        let strands = [StrandSpec(rootU: 0.5, rootV: 0.2, tipV: 0.7, layer: "face")]
        renderer.hairSolvers["face"] = HairSolver(strands: strands, nodeCount: 5)
        renderer.hairSolvers["face"]?.step(delta: 0.5, headOffset: SIMD2(0.05, 0))

        // Even with a solver deliberately registered under its name, a layer
        // flagged non-hair must come back disabled.
        let face = renderer.hairUniforms(for: layer("face", index: 3, hair: false))
        XCTAssertEqual(face.last?.w, 0, "face layer is receiving hair displacement")
        XCTAssertTrue(face.allSatisfy { $0 == .zero })

        let hair = renderer.hairUniforms(for: layer("hair_front", index: 4, hair: true))
        XCTAssertEqual(hair.last?.w, 0, "no solver registered for hair_front, expected disabled")
    }

    /// The pipeline is translation-only. Parallax offsets a layer's quad; the
    /// hair field offsets sample coordinates. Neither carries a rotation term,
    /// so no combination of settings can tilt the head - the constraint holds
    /// structurally rather than by tuning.
    func testParallaxIsTranslationOnly() {
        let rig = LightRig()
        let uniforms = rig.uniforms(
            for: layer("face", index: 3, hair: false),
            parallax: SIMD2(0.03, -0.02),
            parallaxScale: 2.0
        )
        // The parallax lane carries exactly the two translation components and
        // nothing else; there is no angle anywhere in the uniform block.
        XCTAssertEqual(uniforms.parallax.x, 0.03, accuracy: 1e-6)
        XCTAssertEqual(uniforms.parallax.y, -0.02, accuracy: 1e-6)
        XCTAssertEqual(uniforms.parallax.z, 0)
        XCTAssertEqual(uniforms.parallax.w, 0)
    }
}
