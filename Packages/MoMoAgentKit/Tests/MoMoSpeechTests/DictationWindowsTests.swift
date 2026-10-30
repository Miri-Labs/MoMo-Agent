import Testing
@testable import MoMoSpeech

@Test func dictationWindowsMergePaddingAndCoverLongUtterancesWithoutDuplicates() {
    let windows = DictationWindows.make([0..<1_000, 1_050..<4_000, 8_000..<9_900],
        sampleCount: 10_000, maximumFrames: 2_000, padding: 100)
    #expect(windows == [0..<2_000, 2_000..<4_000, 4_000..<4_100, 7_900..<9_900, 9_900..<10_000])
    #expect(windows.allSatisfy { $0.count <= 2_000 })
}

@Test func dictationWindowsIgnoreSilenceAndClampFinalVADPadding() {
    #expect(DictationWindows.make([], sampleCount: 16_000, maximumFrames: 320_000, padding: 4_800).isEmpty)
    #expect(DictationWindows.make([100..<16_384], sampleCount: 16_000,
        maximumFrames: 320_000, padding: 4_800) == [0..<16_000])
}
