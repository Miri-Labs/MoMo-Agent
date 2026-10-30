// swift-tools-version: 6.2
// Offline harness: transcribes corpus WAVs with Apple's on-device SpeechAnalyzer + SpeechTranscriber
// (macOS 26) and writes the run format that Tools/ASRCodeSwitchEval/score.py consumes.
// See Sources/AppleSpeechEval/main.swift.
import PackageDescription

let package = Package(
    name: "AppleSpeechEval",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "AppleSpeechEval", swiftSettings: [.swiftLanguageMode(.v5)])]
)
