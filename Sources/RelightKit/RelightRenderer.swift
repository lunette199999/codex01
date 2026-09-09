//  RelightRenderer.swift
//  Draws a PortraitMaps set, one quad per layer, back to front.

import Foundation
import Metal
import simd

public enum RelightError: Error, CustomStringConvertible {
    case shaderSourceMissing
    case functionMissing(String)

    public var description: String {
        switch self {
        case .shaderSourceMissing:
            return "Relight.metal was not found in the RelightKit bundle"
        case .functionMissing(let name):
            return "shader function '\(name)' missing from the compiled library"
        }
    }
}

public final class RelightRenderer {

    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    /// Current lighting state. Assign from `EnvironmentLight` each frame, or
    /// drive directly for manual control.
    public var rig = LightRig()

    /// View offset in NDC. Small numbers: ±0.02 is already pronounced. Drive it
    /// from pointer position, head idle motion, or `IdleParallax`.
    public var parallax = SIMD2<Float>.zero

    /// Global multiplier over the per-layer parallax weights, so the whole
    /// effect can be dialled back without re-authoring the asset.
    public var parallaxScale: Float = 1.0

    /// Gaussian width, in UV, over which one strand's motion blends into its
    /// neighbours. Too narrow and each strand drags a visible column of pixels;
    /// too wide and the whole layer moves as one again.
    public var hairBlendSigma: Float = 0.16

    /// One solver per hair layer, built by `prepare(maps:)`.
    public private(set) var hairSolvers: [String: HairSolver] = [:]

    private static let maxStrands = 12      // must match kMaxStrands in Relight.metal
    private static let maxNodes = 6         // must match kMaxNodes
    private static let hairSlotCount = maxStrands + (maxStrands * maxNodes) / 2 + 1

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        let library = try Self.makeLibrary(device: device)

        guard let vertexFunction = library.makeFunction(name: "relightVertex") else {
            throw RelightError.functionMissing("relightVertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "relightFragment") else {
            throw RelightError.functionMissing("relightFragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction

        // Premultiplied alpha. The fragment shader already multiplies colour by
        // coverage, which is what a transparent always-on-top window needs -
        // straight alpha would fringe against the desktop behind it.
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw RelightError.functionMissing("sampler")
        }
        self.sampler = sampler
    }

    /// Builds the hair solvers for a character. Call once after loading maps.
    public func prepare(maps: PortraitMaps, params: HairParams = HairParams()) {
        hairSolvers = maps.strands.reduce(into: [:]) { result, entry in
            let (layer, specs) = entry
            guard !specs.isEmpty else { return }
            result[layer] = HairSolver(
                strands: Array(specs.prefix(Self.maxStrands)),
                nodeCount: min(maps.strandNodes, Self.maxNodes),
                params: params
            )
        }
    }

    /// Advances every hair chain. `headOffset` is the head's motion in UV -
    /// feed it the same signal that drives parallax so the hair follows the
    /// head rather than drifting independently of it.
    public func advanceHair(delta: Float, headOffset: SIMD2<Float>) {
        for solver in hairSolvers.values {
            solver.step(delta: delta, headOffset: headOffset)
        }
    }

    /// Packs one layer's strand state for the shader.
    ///
    /// Laid out to match `HairUniforms` in Relight.metal: the strand table,
    /// then node offsets packed two per float4, then the parameter word. A
    /// layer with no solver returns an all-zero block, whose `params.w` of 0
    /// disables displacement entirely - which is what keeps the face rigid.
    private func hairUniforms(for layer: PortraitLayer) -> [SIMD4<Float>] {
        var slots = [SIMD4<Float>](repeating: .zero, count: Self.hairSlotCount)

        guard layer.hair,
              let solver = hairSolvers[layer.name],
              !solver.strands.isEmpty
        else { return slots }

        let strandCount = min(solver.strands.count, Self.maxStrands)
        let nodeCount = min(solver.nodeCount, Self.maxNodes)
        let offsets = solver.offsets()

        for s in 0..<strandCount {
            let spec = solver.strands[s]
            slots[s] = SIMD4(spec.rootU, spec.rootV, spec.tipV, 0)
        }

        for s in 0..<strandCount {
            for k in 0..<nodeCount {
                let flat = s * Self.maxNodes + k
                let slot = Self.maxStrands + flat / 2
                let offset = offsets[s * solver.nodeCount + k]
                if flat % 2 == 0 {
                    slots[slot].x = offset.x
                    slots[slot].y = offset.y
                } else {
                    slots[slot].z = offset.x
                    slots[slot].w = offset.y
                }
            }
        }

        slots[Self.hairSlotCount - 1] = SIMD4(
            Float(strandCount), Float(nodeCount), hairBlendSigma, 1
        )
        return slots
    }

    /// Encodes every layer into an existing pass.
    ///
    /// Layers are drawn back to front with blending on rather than sorted by a
    /// depth buffer: they are flat quads at the same Z, and their ordering is
    /// already known from the manifest. A depth buffer would only reintroduce
    /// the hard edges the coverage map exists to avoid.
    public func encode(maps: PortraitMaps, into encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentTexture(maps.albedo, index: 0)
        encoder.setFragmentTexture(maps.normal, index: 1)
        encoder.setFragmentTexture(maps.ao, index: 2)
        encoder.setFragmentTexture(maps.coverage, index: 3)

        let stride = MemoryLayout<RelightUniforms>.stride
        for layer in maps.layers {
            var uniforms = rig.uniforms(
                for: layer,
                parallax: parallax,
                parallaxScale: parallaxScale
            )
            encoder.setVertexBytes(&uniforms, length: stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: stride, index: 0)

            var hair = hairUniforms(for: layer)
            encoder.setFragmentBytes(
                &hair,
                length: MemoryLayout<SIMD4<Float>>.stride * hair.count,
                index: 1
            )

            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Convenience for a standalone pass into any texture (an MTKView drawable
    /// or an offscreen target for preview export).
    public func render(
        maps: PortraitMaps,
        to target: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encode(maps: maps, into: encoder)
        encoder.endEncoding()
    }

    // MARK: - Shader loading

    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        // In an Xcode target the .metal file is compiled ahead of time into the
        // default library. Prefer that when it is there.
        if let library = try? device.makeDefaultLibrary(bundle: Bundle.module),
           library.makeFunction(name: "relightVertex") != nil {
            return library
        }

        // Under SwiftPM the .metal ships as a resource instead, so compile it at
        // launch. It is a small shader; this costs a few milliseconds once.
        guard
            let url = Bundle.module.url(forResource: "Relight", withExtension: "metal"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw RelightError.shaderSourceMissing
        }
        return try device.makeLibrary(source: source, options: nil)
    }
}

/// Gentle drifting parallax, so the character is never perfectly still.
///
/// A companion that holds a frozen pose between animations reads as a
/// screenshot no matter how good the lighting is. Two out-of-phase sine pairs
/// at incommensurable periods give slow motion that never visibly loops.
public struct IdleParallax {
    public var amplitude: Float = 0.012
    public var speed: Float = 0.35
    private var time: Float = 0

    public init() {}

    public mutating func advance(by delta: Float) -> SIMD2<Float> {
        time += delta * speed
        let x = sin(time * 0.37) * 0.6 + sin(time * 0.83) * 0.4
        let y = sin(time * 0.29 + 1.7) * 0.5 + sin(time * 0.61 + 0.4) * 0.3
        return SIMD2(x, y) * amplitude
    }
}
