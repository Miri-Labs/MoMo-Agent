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

@Test func xASRDictationSharesUpToOneSecondOfSilenceBetweenPhrases() {
    let ranges: [Range<Int64>] = [0..<32_000, 48_000..<64_000, 80_001..<96_000]
    for model in [SpeechModelChoice.senseVoice, .funASRNano, .xASR] {
        let windows = DictationWindows.make(ranges, sampleCount: 96_000,
            maximumFrames: 320_000, padding: 4_800, model: model)
        let separate = [0..<36_800, 43_200..<68_800, 75_201..<96_000]
        #expect(windows == (model == .xASR ? [0..<68_800, 75_201..<96_000] : separate))
    }
}

@Test func xASRDictationKeepsTheNextPhraseIntactWhenItCannotFit() {
    let windows = DictationWindows.make([0..<270_000, 282_000..<339_000, 352_000..<368_000],
        sampleCount: 368_000, maximumFrames: 320_000, padding: 4_800, model: .xASR)
    #expect(windows == [0..<274_800, 277_200..<368_000])
}
