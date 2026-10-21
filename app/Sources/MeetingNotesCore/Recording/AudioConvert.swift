// PCM buffer conversion helpers shared by the capture paths (Recording).

import AVFoundation
import CoreMedia

public enum AudioConvert {
    /// Copies any PCM buffer (float32 / int16 / int32, interleaved or not) into a new mono float32 buffer.
    public static func monoFloat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let source = buffer.format
        let frames = Int(buffer.frameLength)
        let channels = Int(source.channelCount)
        guard frames > 0, channels > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate, channels: 1, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData?[0] else { return nil }
        output.frameLength = AVAudioFrameCount(frames)

        // Fast path: mono float32, deinterleaved.
        if source.commonFormat == .pcmFormatFloat32, channels == 1, let data = buffer.floatChannelData {
            destination.update(from: data[0], count: frames)
            return output
        }

        let stride = buffer.stride
        let interleaved = source.isInterleaved
        let scale = 1 / Float(channels)

        func mix(_ read: (_ channel: Int, _ frame: Int) -> Float) {
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += read(c, i) }
                destination[i] = sum * scale
            }
        }

        switch source.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return nil }
            if interleaved { mix { c, i in data[0][i * stride + c] } } else { mix { c, i in data[c][i] } }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return nil }
            let k: Float = 1 / 32768
            if interleaved { mix { c, i in Float(data[0][i * stride + c]) * k } } else { mix { c, i in Float(data[c][i]) * k } }
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return nil }
            let k: Float = 1 / 2_147_483_648
            if interleaved { mix { c, i in Float(data[0][i * stride + c]) * k } } else { mix { c, i in Float(data[c][i]) * k } }
        default:
            return nil
        }
        return output
    }

    /// Copies the PCM payload of a ScreenCaptureKit audio sample buffer.
    public static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
