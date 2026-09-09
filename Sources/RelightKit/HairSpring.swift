//  HairSpring.swift
//  Per-strand hair chains. Port of tools/hair_spring.py.

import Foundation
import simd

/// Where one strand hangs, in UV space. Derived from the hair mask offline and
/// carried in the `.maps.json` sidecar.
public struct StrandSpec: Equatable, Codable, Sendable {
    public let rootU: Float
    public let rootV: Float
    public let tipV: Float
    public let layer: String
}

public struct HairParams: Equatable, Codable, Sendable {
    public var gravity: Float = 0.42        // UV units per second squared
    public var damping: Float = 0.010       // velocity lost per substep

    /// Applied once per constraint iteration per substep, so the effective time
    /// constant is roughly `1 / (substepHz * iterations * bend)`. These values
    /// put the upper chain near 0.15s and the tip near 0.6s, which is what makes
    /// the ends trail and settle last. An intuitively-sized value like 0.3 here
    /// is about 12x too stiff and the chain moves as a rigid rod.
    public var bend: Float = 0.0278
    public var bendDecay: Float = 0.707

    public var constraintIterations = 2

    /// How far a root follows head motion. Below 1.0 the scalp slides slightly
    /// under the hair, which is what actually happens.
    public var rootFollow: Float = 0.85

    /// UV clamp against the rest pose, so an unstable step can never throw
    /// strands across the screen.
    public var maxOffset: Float = 0.075

    public init() {}
}

/// Verlet chains hanging from strand roots.
///
/// Node 0 is pinned to its root and driven directly by head motion. Below it,
/// two constraints do the work:
///
/// - A hard **length** constraint, solved root outward. This is what carries
///   motion down the chain: moving the root physically drags every node after
///   it within the same step. A soft spring along the segment axis instead lets
///   the segment stretch and swallow the motion, so the tip never moves and the
///   ends go dead exactly where hair should be liveliest.
/// - A soft **bend** constraint pulling each segment back toward hanging
///   straight down, weakening toward the tip. This is the spring-back, and its
///   weakness at the ends is what makes them trail.
///
/// Verlet rather than explicit velocity so positional constraints feed back into
/// momentum for free: a node dragged by the length constraint keeps the speed
/// that drag gave it, which is where the follow-through comes from.
public final class HairSolver {

    public static let substepHz: Float = 120

    public let strands: [StrandSpec]
    public let nodeCount: Int
    public var params: HairParams

    private var rest: [SIMD2<Float>]
    private var position: [SIMD2<Float>]
    private var previous: [SIMD2<Float>]
    private var restLength: [Float]
    private var nodeBend: [Float]
    private var accumulator: Float = 0

    public init(strands: [StrandSpec], nodeCount: Int = 5, params: HairParams = HairParams()) {
        self.strands = strands
        self.nodeCount = max(nodeCount, 2)
        self.params = params

        var rest: [SIMD2<Float>] = []
        rest.reserveCapacity(strands.count * self.nodeCount)
        for strand in strands {
            let span = strand.tipV - strand.rootV
            for k in 0..<self.nodeCount {
                let t = Float(k) / Float(self.nodeCount - 1)
                rest.append(SIMD2(strand.rootU, strand.rootV + span * t))
            }
        }
        self.rest = rest
        self.position = rest
        self.previous = rest

        var lengths: [Float] = []
        lengths.reserveCapacity(strands.count * (self.nodeCount - 1))
        for s in 0..<strands.count {
            for k in 1..<self.nodeCount {
                let a = rest[s * self.nodeCount + k - 1]
                let b = rest[s * self.nodeCount + k]
                lengths.append(simd_distance(a, b))
            }
        }
        self.restLength = lengths

        self.nodeBend = (0..<self.nodeCount).map {
            params.bend * pow(params.bendDecay, Float($0))
        }
    }

    @inline(__always)
    private func index(_ strand: Int, _ node: Int) -> Int { strand * nodeCount + node }

    @inline(__always)
    private func lengthIndex(_ strand: Int, _ segment: Int) -> Int {
        strand * (nodeCount - 1) + segment
    }

    public func reset() {
        position = rest
        previous = rest
        accumulator = 0
    }

    /// Advances by `delta` seconds in fixed substeps.
    ///
    /// The substep rate is fixed so motion is identical at 24, 30 or 60 fps.
    /// A variable-dt spring changes its effective stiffness with frame rate,
    /// and hair that stiffens whenever the app gets busy is very noticeable.
    public func step(delta: Float, headOffset: SIMD2<Float> = .zero) {
        accumulator += max(delta, 0)
        let dt = 1 / Self.substepHz

        // Bound catch-up so a stalled frame cannot spend seconds solving.
        let maxSteps = 16
        var steps = 0
        while accumulator >= dt && steps < maxSteps {
            substep(dt: dt, headOffset: headOffset)
            accumulator -= dt
            steps += 1
        }
        if steps == maxSteps { accumulator = 0 }
    }

    private func substep(dt: Float, headOffset: SIMD2<Float>) {
        let offset = headOffset * params.rootFollow
        let gravity = SIMD2<Float>(0, params.gravity)

        // 1. Verlet integration; velocity is implicit in (position - previous).
        for i in 0..<position.count {
            let velocity = (position[i] - previous[i]) * (1 - params.damping)
            previous[i] = position[i]
            position[i] += velocity + gravity * dt * dt
        }

        // 2. Roots are driven, not simulated.
        for s in 0..<strands.count {
            position[index(s, 0)] = rest[index(s, 0)] + offset
        }

        for _ in 0..<max(params.constraintIterations, 1) {
            // 3. Bend first, pulling each segment back toward vertical. This
            //    moves a node off its correct radius, which is fine because...
            for s in 0..<strands.count {
                for k in 1..<nodeCount {
                    let parent = position[index(s, k - 1)]
                    let hanging = SIMD2(parent.x, parent.y + restLength[lengthIndex(s, k - 1)])
                    let i = index(s, k)
                    position[i] += (hanging - position[i]) * nodeBend[k]
                }
            }

            // 4. ...length is solved last, root outward, so the pose that leaves
            //    this function always satisfies the hard constraint exactly.
            //    Solving bend afterwards instead leaves a length error behind,
            //    and Verlet reads that error back as velocity next step: the
            //    chain pumps its own energy and the tip rings louder every swing
            //    instead of settling.
            for s in 0..<strands.count {
                for k in 1..<nodeCount {
                    let i = index(s, k)
                    let delta = position[i] - position[index(s, k - 1)]
                    let distance = simd_length(delta)
                    guard distance > 1e-9 else { continue }
                    let target = restLength[lengthIndex(s, k - 1)]
                    position[i] -= delta * (1 - target / distance)
                }
            }
        }

        // 5. Clamp against the rest pose: cap and stay plausible rather than let
        //    an unstable step throw strands across the screen.
        for i in 0..<position.count {
            let delta = position[i] - rest[i]
            let magnitude = simd_length(delta)
            if magnitude > params.maxOffset {
                position[i] = rest[i] + delta * (params.maxOffset / magnitude)
                previous[i] = position[i]
            }
        }
    }

    /// Per-node displacement from rest, strand-major.
    public func offsets() -> [SIMD2<Float>] {
        zip(position, rest).map(-)
    }
}
