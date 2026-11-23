import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Adapted from gprot42/android-opendisplay's AUD1 packer (GPL-3.0).
enum AudioWire {
    static let format = "AUD1-s16le-48000-stereo"
    static let sampleRate = 48_000
    static let channels = 2
    static let bytesPerFrame = channels * MemoryLayout<Int16>.size
    static let maxFrames = 960

    static func isOffered(by hello: [String: Any]) -> Bool {
        hello["audioFormat"] as? String == format
    }

    static func pack(_ pcm: Data) -> Data? {
        guard !pcm.isEmpty, pcm.count <= maxFrames * bytesPerFrame,
              pcm.count.isMultiple(of: bytesPerFrame) else { return nil }
        var output = Data([0x41, 0x55, 0x44, 0x31, 1, UInt8(channels)])
        var rate = UInt16(sampleRate).bigEndian
        var count = UInt32(pcm.count / bytesPerFrame).bigEndian
        withUnsafeBytes(of: &rate) { output.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { output.append(contentsOf: $0) }
        output.append(pcm)
        return output
    }
}

/// Adapted from targetBridge's SBAudioConverter (MIT, see Audio-attribution.md).
/// Each instance is confined to the sender's serial queue.
private final class SBAudioConverter {
    var converter: AVAudioConverter?
    var inputFormat: AVAudioFormat?
    let outputFormat: AVAudioFormat

    init() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        self.outputFormat = AVAudioFormat(streamDescription: &asbd)!
    }

    func convert(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        let inputASBD = asbdPointer.pointee

        var mutableASBD = inputASBD
        guard inputASBD.mSampleRate > 0, inputASBD.mChannelsPerFrame > 0,
              let inFormat = AVAudioFormat(streamDescription: &mutableASBD) else { return nil }
        if inputFormat != inFormat {
            self.inputFormat = inFormat
            self.converter = AVAudioConverter(from: inFormat, to: outputFormat)
        }

        guard let converter = self.converter, let inFormat = self.inputFormat else { return nil }

        let frameCount = sampleBuffer.numSamples
        guard (1...48_000).contains(frameCount) else { return nil }
        let audioFrameCount = AVAudioFrameCount(frameCount)

        // Create input buffer
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: audioFrameCount) else { return nil }
        inputBuffer.frameLength = audioFrameCount

        // Extract audio data from sampleBuffer into inputBuffer
        let channelCount = Int(inFormat.channelCount)
        let bufferListSize = MemoryLayout<AudioBufferList>.size + (channelCount - 1) * MemoryLayout<AudioBuffer>.size
        let bufferListRaw = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListRaw.deallocate() }

        let ablPointer = bufferListRaw.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPointer,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return nil }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(ablPointer)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        // ScreenCaptureKit may supply either one interleaved buffer or one
        // buffer per channel. Copy the actual AudioBufferList layout rather
        // than assuming a non-interleaved Float32 input.
        for index in 0..<sourceBuffers.count {
            let source = sourceBuffers[index]
            let destination = destinationBuffers[index]
            guard let sourceData = source.mData, let destinationData = destination.mData else {
                return nil
            }

            let destinationByteCount = Int(destination.mDataByteSize)
            let byteCount = min(Int(source.mDataByteSize), destinationByteCount)
            guard byteCount > 0 else { return nil }
            memcpy(destinationData, sourceData, byteCount)
            if byteCount < destinationByteCount {
                memset(destinationData.advanced(by: byteCount), 0, destinationByteCount - byteCount)
            }
        }

        // Perform conversion to outputFormat
        let outputCapacity = AVAudioFrameCount(ceil(Double(frameCount) * outputFormat.sampleRate / inFormat.sampleRate)) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else { return nil }

        var error: NSError?
        var inputConsumed = false
        let convertStatus = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if convertStatus == .error || error != nil {
            return nil
        }

        guard outputBuffer.frameLength > 0, let channels = outputBuffer.int16ChannelData else { return nil }
        let dataSize = Int(outputBuffer.frameLength) * 4 // 2 channels * 2 bytes = 4 bytes per frame
        let rawPointer = UnsafeRawPointer(channels.pointee)
        return Data(bytes: rawPointer, count: dataSize)
    }
}

/// Like targetBridge's auxiliary capture, this stream has only an audio output.
/// Its permission or lifecycle errors can be handled independently of video.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue: DispatchQueue
    private let converter = SBAudioConverter()
    private let onStarted: () -> Void
    private let onPCM: (Data) -> Void
    private let onFailure: (Error) -> Void
    private var stream: SCStream?

    init(queue: DispatchQueue, onStarted: @escaping () -> Void,
         onPCM: @escaping (Data) -> Void, onFailure: @escaping (Error) -> Void) {
        self.queue = queue
        self.onStarted = onStarted
        self.onPCM = onPCM
        self.onFailure = onFailure
    }

    func start(display: SCDisplay) throws {
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 1
        config.showsCursor = false
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = AudioWire.sampleRate
        config.channelCount = AudioWire.channels
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        stream.startCapture { [weak self, queue] error in
            queue.async {
                guard let self, self.stream === stream else {
                    if error == nil { stream.stopCapture { _ in } }
                    return
                }
                if let error { self.onFailure(error) } else { self.onStarted() }
            }
        }
    }

    func stop() {
        let previous = stream
        stream = nil
        previous?.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.onFailure(error)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard stream === self.stream, type == .audio, CMSampleBufferIsValid(sample) else { return }
        let age = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), sample.presentationTimeStamp).seconds
        guard !age.isFinite || age < 0.15 else { return }
        guard let pcm = converter.convert(sampleBuffer: sample) else { return }
        onPCM(pcm)
    }
}
