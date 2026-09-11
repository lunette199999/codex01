import Foundation

struct MouthPose: Equatable {
    var open: Double = 0
    var wide: Double = 0
}

struct MouthTimeline: Decodable {
    struct Key: Decodable { let t: Double; let open: Double; let wide: Double }
    struct Interval: Decodable { let start: Double; let end: Double }
    let audio: String
    let sample_rate: Int
    let frames: [Key]
    let fallback_intervals: [Interval]?

    static func load(for audioURL: URL, duration: Double) -> MouthTimeline? {
        let sidecar = audioURL.deletingPathExtension().appendingPathExtension("mouth.json")
        guard let size = try? sidecar.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 2_000_000, let data = try? Data(contentsOf: sidecar),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.isValid(audioName: audioURL.lastPathComponent, duration: duration) else { return nil }
        return value
    }

    func isValid(audioName: String, duration: Double) -> Bool {
        guard audio == audioName, sample_rate > 0, duration.isFinite, duration > 0,
              !frames.isEmpty, frames.count <= 20_000 else { return false }
        var previous = -Double.infinity
        for key in frames {
            guard key.t.isFinite, key.open.isFinite, key.wide.isFinite,
                  key.t >= 0, key.t <= duration + 0.1, key.t > previous,
                  (0...1).contains(key.open), (-1...1).contains(key.wide) else { return false }
            previous = key.t
        }
        return (fallback_intervals ?? []).allSatisfy {
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 0.1
        }
    }

    /// Nil requests the existing loudness fallback for an unsupported token.
    func pose(at time: Double) -> MouthPose? {
        guard time.isFinite, let first = frames.first, let last = frames.last,
              time >= first.t, time < last.t else { return MouthPose() }
        if (fallback_intervals ?? []).contains(where: { time >= $0.start && time < $0.end }) { return nil }
        var low = 0, high = frames.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if frames[middle].t <= time { low = middle } else { high = middle }
        }
        let a = frames[low], b = frames[high]
        let f = max(0, min(1, (time - a.t) / (b.t - a.t)))
        return MouthPose(open: a.open + (b.open - a.open) * f,
                         wide: a.wide + (b.wide - a.wide) * f)
    }
}
