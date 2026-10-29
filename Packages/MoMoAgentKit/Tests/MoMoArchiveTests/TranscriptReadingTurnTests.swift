import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct TranscriptReadingTurnTests {
    @Test func shortPauseMergesButSpeakerSwitchGapAndEpochDoNot() throws {
        let session = UUID(), epoch = UUID(), cluster = UUID()
        let base = Date(timeIntervalSince1970: 1_000)
        func paragraph(_ start: Double, _ end: Double, _ text: String, boundary: Bool = false,
                       person: UUID = cluster, sourceEpoch: UUID = epoch) throws -> TimelineParagraph {
            TimelineParagraph(source: .init(sessionID: session, spanID: UUID(), transcriptVersion: 1, generation: 1),
                text: text, recordedAt: base.addingTimeInterval(start), audioAvailable: true, speaker: "说话人",
                attribution: .init(clusterID: person, personID: nil, isUser: false, confirmed: false, canLearn: true),
                audioSource: .init(sessionID: session, generation: 1, epochID: sourceEpoch,
                    frames: try FrameRange(start: Int64(start * 16_000), count: Int64((end - start) * 16_000)),
                    timebaseHz: 16_000, wallClockAnchor: base), startsNewSpeakerTurn: boundary)
        }
        let a = try paragraph(0, 3, "我觉得"), b = try paragraph(3.8, 6, "应该放在一起。")
        let joined = TranscriptReadingTurn.group([a, b])
        #expect(joined.count == 1)
        #expect(joined[0].text == "我觉得应该放在一起。")
        #expect(joined[0].id == a.id)
        #expect(joined[0].sources == [a.source, b.source])
        #expect(TranscriptReadingTurn.group([a, b], breaks: [base.addingTimeInterval(3.5)]).count == 2)
        #expect(TranscriptReadingTurn.group([a, try paragraph(3.1, 5, "换人", boundary: true)]).count == 2)
        #expect(TranscriptReadingTurn.group([a, try paragraph(3.1, 5, "别人", person: UUID())]).count == 2)
        #expect(TranscriptReadingTurn.group([a, try paragraph(5.1, 7, "稍后")]).count == 2)
        #expect(TranscriptReadingTurn.group([a, try paragraph(3.1, 5, "新录音", sourceEpoch: UUID())]).count == 2)
        let ongoing = try paragraph(0, 46, "这句话还没有说完，")
        #expect(TranscriptReadingTurn.group([ongoing, try paragraph(46, 49, "接着说完。")]).count == 1)
        let finished = try paragraph(0, 35, "已经说完一段。")
        #expect(TranscriptReadingTurn.group([finished, try paragraph(35, 40, "接下来。")]).count == 2)
        #expect(TranscriptReadingTurn.group([try paragraph(0, 90, "很长"), try paragraph(90, 95, "继续")]).count == 2)
    }
}
