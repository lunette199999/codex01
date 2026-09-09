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
