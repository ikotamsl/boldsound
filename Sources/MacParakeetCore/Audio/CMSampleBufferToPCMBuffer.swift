import AVFoundation
import CoreMedia
import Foundation

enum CMSampleBufferToPCMBufferError: Error, Equatable, LocalizedError {
    case emptySampleBuffer
    case missingFormatDescription
    case invalidAudioFormat
    case pcmCopyFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptySampleBuffer:
            return "Cannot create a PCM buffer from an empty sample buffer."
        case .missingFormatDescription:
            return "Sample buffer is missing its audio format description."
        case .invalidAudioFormat:
            return "Sample buffer has an unsupported audio format."
        case .pcmCopyFailed(let status):
            return "Failed to copy sample-buffer PCM data: \(status)."
        }
    }
}

struct CMSampleBufferToPCMBuffer {
    func makePCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else {
            throw CMSampleBufferToPCMBufferError.emptySampleBuffer
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw CMSampleBufferToPCMBufferError.missingFormatDescription
        }
        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sampleCount)
              ) else {
            throw CMSampleBufferToPCMBufferError.invalidAudioFormat
        }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw CMSampleBufferToPCMBufferError.pcmCopyFailed(status)
        }

        return buffer
    }
}
