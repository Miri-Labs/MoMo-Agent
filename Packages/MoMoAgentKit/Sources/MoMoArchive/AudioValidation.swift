import Foundation
import AVFoundation
import MoMoContracts

func validateAudio(at url: URL, manifest: ChunkManifest) throws {
    let file = try AVAudioFile(forReading: url)
    guard file.processingFormat.sampleRate == manifest.sampleRate,
          file.processingFormat.channelCount == manifest.channels,
          file.length == manifest.decodedFrameCount,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { throw ArchiveError.invalidInbox }
    let stream = file.fileFormat.streamDescription.pointee
    switch manifest.codec {
    case .aac:
        guard stream.mFormatID == kAudioFormatMPEG4AAC else { throw ArchiveError.invalidInbox }
    case .pcmInt16:
        guard stream.mFormatID == kAudioFormatLinearPCM, stream.mBitsPerChannel == 16,
              stream.mFormatFlags & kAudioFormatFlagIsFloat == 0 else { throw ArchiveError.invalidInbox }
    case .pcmFloat32:
        guard stream.mFormatID == kAudioFormatLinearPCM, stream.mBitsPerChannel == 32,
              stream.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { throw ArchiveError.invalidInbox }
    }
    var decoded: Int64 = 0
    while file.framePosition < file.length {
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { throw ArchiveError.invalidInbox }
        decoded += Int64(buffer.frameLength)
    }
    guard decoded == manifest.decodedFrameCount else { throw ArchiveError.invalidInbox }
}
