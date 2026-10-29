import Foundation

enum ReplayCodec: String, Codable, Sendable { case aac, pcm }

struct ReplayOptions: Sendable {
    static let sampleRate: Int64 = 16_000
    static let blockFrames = 512
    static let segmentFrames: Int64 = 960_000
    static let usage = """
    Usage:
      CaptureReplay verify-storage --output <new-directory>
      CaptureReplay replay --duration <seconds> --speed <1-or-greater> [--codec aac|pcm] --output <new-directory>
    Speed 1 uses real-time pacing; speed > 1 requests accelerated pacing. All input is generated fixture audio.
    """
    let duration: Double
    let speed: Double
    let codec: ReplayCodec
    let output: URL
    let plannedFrames: Int64

    init(arguments: [String]) throws {
        guard arguments.count.isMultiple(of: 2) else { throw VerificationFailure(description: Self.usage) }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index]
            guard ["--duration", "--speed", "--codec", "--output"].contains(key), values[key] == nil else {
                throw VerificationFailure(description: "Unknown or repeated option: \(key).\n\(Self.usage)")
            }
            values[key] = arguments[index + 1]
        }
        guard let duration = values["--duration"].flatMap(Double.init), duration.isFinite, duration > 0,
              let speed = values["--speed"].flatMap(Double.init), speed.isFinite, speed >= 1,
              let codec = ReplayCodec(rawValue: values["--codec"] ?? "aac"),
              let path = values["--output"], !path.isEmpty else { throw VerificationFailure(description: Self.usage) }
        let frames = duration * Double(Self.sampleRate)
        guard frames.isFinite, frames >= 1, frames < Double(Int64.max / 4),
              abs(frames.rounded() - frames) < 0.000_001 else {
            throw VerificationFailure(description: "Duration must resolve to whole 16 kHz frames and fit the disk-budget calculation.")
        }
        self.duration = duration; self.speed = speed; self.codec = codec
        output = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        plannedFrames = Int64(frames.rounded())
    }
}
