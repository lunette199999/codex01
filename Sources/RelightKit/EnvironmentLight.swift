//  EnvironmentLight.swift
//  Drives the LightRig from the world the character is nominally sitting in.

import Foundation
import simd

#if canImport(CoreImage)
import CoreImage
#endif

/// Where the light is nominally coming from.
public enum LightingEnvironment: Equatable, Sendable {
    /// Sun position solved for a time and place.
    case daylight(date: Date, latitude: Double, longitude: Double)
    /// A fixed artificial source.
    case indoor(IndoorPreset)
}

public enum IndoorPreset: String, CaseIterable, Codable, Sendable {
    case tungsten      // warm domestic bulb, low and to one side
    case office        // flat cool overhead
    case eveningLamp   // low, strong, very warm
    /// The monitor lighting the subject. For a character living on the desktop
    /// this is the physically honest default: at night the screen genuinely is
    /// the brightest thing in front of them.
    case screenGlow

    var kelvin: Float {
        switch self {
        case .tungsten: return 2700
        case .office: return 4200
        case .eveningLamp: return 2200
        case .screenGlow: return 6800
        }
    }

    var keyDirection: SIMD3<Float> {
        switch self {
        case .tungsten: return SIMD3(-0.55, 0.42, 0.72)
        case .office: return SIMD3(0.05, 0.88, 0.47)
        case .eveningLamp: return SIMD3(-0.72, 0.18, 0.67)
        case .screenGlow: return SIMD3(0.0, 0.12, 0.99)
        }
    }

    var intensity: Float {
        switch self {
        case .tungsten: return 0.85
        case .office: return 0.95
        case .eveningLamp: return 0.78
        case .screenGlow: return 0.70
        }
    }

    var exposure: Float {
        switch self {
        case .tungsten: return 0.92
        case .office: return 1.0
        case .eveningLamp: return 0.80
        case .screenGlow: return 0.86
        }
    }
}

/// Builds a `LightRig` from an environment, optionally tinted by whatever is
/// on screen behind the window.
public struct EnvironmentLight {

    /// Starting point. Anything the environment does not set is inherited.
    public var baseRig = LightRig()

    /// Average colour of the desktop behind the window, linear RGB. Set this
    /// from a screen sample to have the character pick up the room; leave nil
    /// to skip. See `averageColor(of:)`.
    public var ambientSample: SIMD3<Float>?

    /// How strongly the sampled colour pulls the ambient term. Past about 0.5
    /// the character starts to look like it is lit by a disco floor.
    public var ambientInfluence: Float = 0.35

    /// Which compass bearing the user's window faces, in degrees from north.
    /// A preference, not a measurement - it decides whether morning sun rakes
    /// the character from the left or the right, and there is no way to know it
    /// from the machine.
    public var windowBearing: Double = 180

    public init() {}

    public func rig(for environment: LightingEnvironment) -> LightRig {
        var rig = baseRig

        switch environment {
        case .indoor(let preset):
            rig.keyDirection = preset.keyDirection
            rig.keyColor = Self.kelvinToRGB(preset.kelvin)
            rig.keyIntensity = preset.intensity
            rig.exposure = preset.exposure
            rig.ambientColor = simd_mix(rig.ambientColor, Self.kelvinToRGB(preset.kelvin), SIMD3(repeating: 0.35))

        case .daylight(let date, let latitude, let longitude):
            let sun = SolarPosition(date: date, latitude: latitude, longitude: longitude)
            rig.keyDirection = sun.viewSpaceDirection(windowBearing: windowBearing)
            rig.keyColor = Self.kelvinToRGB(sun.colorTemperature)
            rig.keyIntensity = sun.keyIntensity
            rig.exposure = sun.exposure

            // Sky fill is blue and comes from above; at night it collapses to a
            // dim cool ambient with almost no directional component.
            rig.fillColor = Self.kelvinToRGB(sun.elevation > 0 ? 11000 : 8000)
            rig.fillIntensity = sun.elevation > 0 ? 0.34 : 0.16
            rig.ambientIntensity = sun.elevation > 0 ? 0.55 : 0.30
        }

        if let sample = ambientSample {
            let influence = SIMD3<Float>(repeating: max(0, min(ambientInfluence, 1)))
            rig.ambientColor = simd_mix(rig.ambientColor, sample, influence)
        }

        return rig
    }

    /// Colour temperature to linear RGB, normalised so the brightest channel is
    /// 1.0. Helland's piecewise fit to the blackbody curve - not colorimetric,
    /// but continuous and monotonic, which is what matters when it is being
    /// swept across a day.
    public static func kelvinToRGB(_ kelvin: Float) -> SIMD3<Float> {
        let t = max(1000, min(kelvin, 40000)) / 100

        let r: Float = t <= 66 ? 255 : 329.698_73 * pow(t - 60, -0.133_204_76)
        let g: Float = t <= 66
            ? 99.470_80 * log(t) - 161.119_57
            : 288.122_17 * pow(t - 60, -0.075_514_85)
        let b: Float = t >= 66 ? 255 : (t <= 19 ? 0 : 138.517_73 * log(t - 10) - 305.044_79)

        var rgb = SIMD3<Float>(r, g, b) / 255
        rgb = simd_clamp(rgb, SIMD3(repeating: 0), SIMD3(repeating: 1))
        let peak = max(rgb.max(), 1e-4)
        return rgb / peak
    }

    #if canImport(CoreImage)
    /// Average colour of an image, for feeding `ambientSample`.
    ///
    /// Capture the desktop region behind the window (ScreenCaptureKit, or
    /// `CGWindowListCreateImage` below the window level), pass it here, and the
    /// character picks up the room. Sample at a low rate - a few times a second
    /// is plenty, and the value should be smoothed before use or the lighting
    /// will flicker every time a window scrolls.
    public static func averageColor(of image: CIImage, context: CIContext) -> SIMD3<Float>? {
        let extent = CIVector(cgRect: image.extent)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: extent,
        ]), let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        // Approximate sRGB -> linear; the rig works in linear throughout.
        func linear(_ v: UInt8) -> Float {
            let c = Float(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return SIMD3(linear(pixel[0]), linear(pixel[1]), linear(pixel[2]))
    }
    #endif
}

/// Sun elevation and azimuth for a time and place.
///
/// The NOAA low-precision algorithm: good to roughly a tenth of a degree, which
/// is far better than a light rig needs. No atmospheric refraction, so
/// elevations within a degree of the horizon are slightly off - irrelevant
/// here, since that band is already being crossfaded into night.
public struct SolarPosition: Equatable, Sendable {

    /// Degrees above the horizon. Negative at night.
    public let elevation: Double
    /// Degrees clockwise from north.
    public let azimuth: Double

    public init(date: Date, latitude: Double, longitude: Double, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let components = calendar.dateComponents([.dayOfYear, .hour, .minute, .second], from: date)
        let dayOfYear = Double(components.dayOfYear ?? 1)
        let hour = Double(components.hour ?? 12)
        let minute = Double(components.minute ?? 0)
        let second = Double(components.second ?? 0)

        let gamma = 2 * .pi / 365 * (dayOfYear - 1 + (hour - 12) / 24)

        let declination = 0.006918
            - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.001480 * sin(3 * gamma)

        let equationOfTime = 229.18 * (0.000075
            + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))

        let utcOffsetHours = Double(timeZone.secondsFromGMT(for: date)) / 3600
        let timeOffset = equationOfTime + 4 * longitude - 60 * utcOffsetHours
        let trueSolarTime = hour * 60 + minute + second / 60 + timeOffset
        let hourAngle = (trueSolarTime / 4 - 180) * .pi / 180

        let latitudeRadians = latitude * .pi / 180

        let cosZenith = sin(latitudeRadians) * sin(declination)
            + cos(latitudeRadians) * cos(declination) * cos(hourAngle)
        let zenith = acos(max(-1, min(1, cosZenith)))

        elevation = 90 - zenith * 180 / .pi

        // Measured from south, positive westward, then rotated to a compass bearing.
        let azimuthFromSouth = atan2(
            sin(hourAngle),
            cos(hourAngle) * sin(latitudeRadians) - tan(declination) * cos(latitudeRadians)
        )
        azimuth = (azimuthFromSouth * 180 / .pi + 180).truncatingRemainder(dividingBy: 360)
    }

    /// Sunlight gets redder as it takes a longer path through the atmosphere.
    /// The horizon end is deliberately not pushed below ~1800K; real golden
    /// hour is warm, but a fully red key on a face reads as a fire alarm.
    public var colorTemperature: Float {
        if elevation <= 0 { return 8000 }              // moonlight/skylight, cool
        let t = min(elevation / 35, 1)
        return Float(1900 + t * (6200 - 1900))
    }

    public var keyIntensity: Float {
        // Fade the direct sun out through civil twilight rather than snapping
        // it off at the horizon.
        let fade = max(0, min((elevation + 6) / 12, 1))
        return Float(0.15 + fade * 1.05)
    }

    public var exposure: Float {
        let fade = max(0, min((elevation + 6) / 18, 1))
        return Float(0.68 + fade * 0.42)
    }

    /// Maps the sun onto the view-space rig.
    ///
    /// The character faces the viewer, so this is a convention rather than a
    /// measurement: `windowBearing` says which way the room's light comes in,
    /// and the sun's bearing relative to that becomes left/right. Elevation
    /// becomes height, and the light is kept at least slightly in front so the
    /// face never goes fully black at midday.
    public func viewSpaceDirection(windowBearing: Double) -> SIMD3<Float> {
        let relative = (azimuth - windowBearing) * .pi / 180
        let elevationRadians = max(elevation, -8) * .pi / 180

        let x = sin(relative) * cos(elevationRadians)
        let y = sin(elevationRadians)
        let z = max(cos(relative) * cos(elevationRadians), 0.25)

        return normalizedSafe(SIMD3(Float(x), Float(y), Float(z)))
    }
}
