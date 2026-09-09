//  PortraitMaps.swift
//  Loads the map set produced by tools/portrait_maps.py.

import Foundation
import Metal
import MetalKit
import simd

/// One depth band of the portrait. Decoded from the `.maps.json` sidecar, so
/// the layer table lives with the asset rather than being hardcoded here.
public struct PortraitLayer: Equatable, Codable, Sendable {
    public let name: String
    public let index: Int
    public let base: Float
    public let relief: Float
    public let normalStrength: Float

    /// How far this layer slides per unit of parallax input. Front hair moves
    /// most, background hair moves slightly the other way. The spread between
    /// these is the depth cue; the absolute values matter much less.
    public let parallax: Float

    /// Which channel of coverage.png belongs to this layer. Resolved from the
    /// sidecar's `coverageChannels` at load time.
    public internal(set) var coverageSlot: Int = 0

    /// Hair layers get strand chains and a per-pixel displacement field; the
    /// face and body stay rigid so features never wobble.
    public let hair: Bool

    /// Runtime fade, e.g. for dissolving a layer during an expression change.
    public var opacity: Float = 1.0

    private enum CodingKeys: String, CodingKey {
        case name, index, base, relief, parallax, hair
        case normalStrength = "normal_strength"
    }
}

/// The sidecar written next to the maps.
public struct PortraitManifest: Codable, Sendable {
    public let width: Int
    public let height: Int
    public let layers: [PortraitLayer]
    public let coverageChannels: [String]
    public let reliefSource: String?
    public let source: String?
    public let strands: [StrandSpec]?
    public let strandNodes: Int?
}

public enum PortraitMapsError: Error, CustomStringConvertible {
    case missingFile(String)
    case emptyLayerTable
    case unknownCoverageChannel(String)

    public var description: String {
        switch self {
        case .missingFile(let name):
            return "portrait map '\(name)' not found next to the manifest"
        case .emptyLayerTable:
            return "manifest lists no layers; re-run tools/portrait_maps.py"
        case .unknownCoverageChannel(let name):
            return "layer '\(name)' has no channel in the manifest's coverageChannels"
        }
    }
}

/// A loaded character: four textures and the layer table that orders them.
public struct PortraitMaps {
    public let albedo: MTLTexture
    public let normal: MTLTexture
    public let ao: MTLTexture
    public let coverage: MTLTexture

    /// Back to front. Draw order.
    public let layers: [PortraitLayer]
    public let size: SIMD2<Int>

    /// Strand roots grouped by the layer they belong to.
    public let strands: [String: [StrandSpec]]
    public let strandNodes: Int

    /// Loads a map set by basename, e.g. `load(name: "mannequin", in: assetsURL)`
    /// for `mannequin.albedo.png` and friends.
    ///
    /// `depth.png` is deliberately not loaded. Nothing in the current shader
    /// samples it - normals were baked from it offline. It stays on disk for
    /// tooling and for effects that will want it later (depth-of-field on the
    /// background, contact shadow against a scene).
    public static func load(
        name: String,
        in directory: URL,
        device: MTLDevice
    ) throws -> PortraitMaps {
        let manifestURL = directory.appendingPathComponent("\(name).maps.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw PortraitMapsError.missingFile("\(name).maps.json")
        }
        let manifest = try JSONDecoder().decode(PortraitManifest.self, from: data)
        guard !manifest.layers.isEmpty else { throw PortraitMapsError.emptyLayerTable }

        // Resolve each layer to its coverage channel.
        var layers: [PortraitLayer] = []
        for var layer in manifest.layers {
            guard let slot = manifest.coverageChannels.firstIndex(of: layer.name) else {
                throw PortraitMapsError.unknownCoverageChannel(layer.name)
            }
            layer.coverageSlot = slot
            layers.append(layer)
        }
        layers.sort { $0.index < $1.index }   // back to front

        let loader = MTKTextureLoader(device: device)
        func texture(_ suffix: String) throws -> MTLTexture {
            let url = directory.appendingPathComponent("\(name).\(suffix).png")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PortraitMapsError.missingFile("\(name).\(suffix).png")
            }
            // SRGB is false everywhere on purpose: normal, ao and coverage are
            // data rather than colour, and albedo is decoded explicitly in the
            // shader so the Metal and Python paths agree bit for bit.
            return try loader.newTexture(URL: url, options: [
                .SRGB: false,
                .origin: MTKTextureLoader.Origin.topLeft,
                .generateMipmaps: false,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
            ])
        }

        var strandsByLayer: [String: [StrandSpec]] = [:]
        for spec in manifest.strands ?? [] {
            strandsByLayer[spec.layer, default: []].append(spec)
        }

        return PortraitMaps(
            albedo: try texture("albedo"),
            normal: try texture("normal"),
            ao: try texture("ao"),
            coverage: try texture("coverage"),
            layers: layers,
            size: SIMD2(manifest.width, manifest.height),
            strands: strandsByLayer,
            strandNodes: manifest.strandNodes ?? 5
        )
    }
}
