import AVFoundation
import Foundation

enum CaptureAudioReadFailure {
    // AudioFile.h OSStatus values are stable, but AudioToolbox cannot be imported on watchOS.
    private enum FileStatus: Int {
        case unsupportedFileType = 0x7479703F
        case unsupportedDataFormat = 0x666D743F
        case invalidChunk = 0x63686B3F
        case invalidPacketOffset = 0x70636B3F
        case invalidPacketDependency = 0x6465703F
        case invalidFile = 0x6474613F
        case endOfFile = -39
        case fileNotFound = -43
    }

    static func requiresRepair(_ error: any Error) -> Bool {
        if let error = error as? AVError {
            switch error.code {
            case .invalidSourceMedia, .fileFormatNotRecognized, .fileFailedToParse, .undecodableMediaData: return true
            default: return false
            }
        }
        let native = error as NSError
        guard native.domain == NSOSStatusErrorDomain || native.domain == "com.apple.coreaudio.avfaudio" else { return false }
        return FileStatus(rawValue: native.code) != nil
    }
}
