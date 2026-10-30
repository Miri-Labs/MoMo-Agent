import Testing
@testable import MoMoArchive

@Test(arguments: [
    "明天下午三点开会，不要改到上午。",
    "Meet at three tomorrow afternoon, not in the morning.",
    "明日の午後3時に会議です。午前には変更しないでください。",
    "내일 오후 3시에 회의합니다. 오전으로 바꾸지 마세요.",
    "请联系山田さん和김민수，review the draft tomorrow."
])
func fourLanguagesAndMixedNamesRemainReadableTranscriptText(text: String) {
    #expect(TranscriptText.hasContent(text))
}
