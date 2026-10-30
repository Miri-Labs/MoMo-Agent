import AVFoundation
import Darwin
import Foundation
import Testing
@testable import MoMoRecording

@Test func audioReadErrorClassificationUsesStatusCodesAndPreservesIOFailures() {
    for domain in [NSOSStatusErrorDomain, "com.apple.coreaudio.avfaudio"] {
        #expect(CaptureAudioReadFailure.requiresRepair(NSError(domain: domain, code: 1_685_348_671)))
        #expect(CaptureAudioReadFailure.requiresRepair(NSError(domain: domain, code: 0x63686B3F)))
        #expect(!CaptureAudioReadFailure.requiresRepair(NSError(domain: domain, code: 0x70726D3F))) // permissions
        #expect(!CaptureAudioReadFailure.requiresRepair(NSError(domain: domain, code: -34))) // disk full
        #expect(!CaptureAudioReadFailure.requiresRepair(NSError(domain: domain, code: -50))) // invalid argument
        #expect(!CaptureAudioReadFailure.requiresRepair(NSError(domain: domain, code: 0x7768743F))) // unspecified
    }
    #expect(CaptureAudioReadFailure.requiresRepair(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.fileFailedToParse.rawValue)))
    #expect(!CaptureAudioReadFailure.requiresRepair(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue)))
    #expect(!CaptureAudioReadFailure.requiresRepair(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decoderTemporarilyUnavailable.rawValue)))
    #expect(!CaptureAudioReadFailure.requiresRepair(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    #expect(!CaptureAudioReadFailure.requiresRepair(NSError(domain: "unrelated", code: 1_685_348_671)))
}
