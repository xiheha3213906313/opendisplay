import AVFAudio
import CoreAudio
import Foundation

/// Owns the single system-audio tap. HAL setup and teardown can block while
/// macOS asks for permission, so both run on the same queue off the main actor.
final class FallbackAudioCapture {
    private let queue = DispatchQueue(label: "sender.fallback-audio")
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var running = false
    private var healthCheck: DispatchSourceTimer?
    private var activeCapture: UUID?

    @available(macOS 14.2, *)
    func start(mailbox: AudioOutputMailbox, status: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            self.tearDown()
            let capture = UUID()
            self.activeCapture = capture
            do {
                try self.setUp(mailbox: mailbox) { [weak self] error in
                    guard let self else { return }
                    self.queue.async { self.fail(error, capture: capture, status: status) }
                }
                let healthCheck = DispatchSource.makeTimerSource(queue: self.queue)
                healthCheck.schedule(deadline: .now() + 1, repeating: 1)
                healthCheck.setEventHandler { [weak self] in
                    guard let self, self.activeCapture == capture else { return }
                    do {
                        let alive: UInt32 = try self.property(self.device, kAudioDevicePropertyDeviceIsAlive, 0)
                        let running: UInt32 = try self.property(self.device, kAudioDevicePropertyDeviceIsRunning, 0)
                        guard alive != 0, running != 0 else { throw TapError.stopped }
                    } catch {
                        self.fail(error, capture: capture, status: status)
                    }
                }
                self.healthCheck = healthCheck
                healthCheck.resume()
                status(.success(()))
            } catch {
                self.fail(error, capture: capture, status: status)
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        queue.async {
            self.tearDown()
            completion?()
        }
    }

    @available(macOS 14.2, *)
    private func setUp(mailbox: AudioOutputMailbox, onError: @escaping (Error) -> Void) throws {
        var pid = getpid()
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let translated = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                      UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process)
        // Core Audio only lists processes that have used audio. OpenDisplay
        // can be absent if it has never played anything during this run.
        let excluded: [AudioObjectID] = translated == noErr && process != kAudioObjectUnknown ? [process] : []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "OpenDisplay System Audio"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tap), "create system audio tap")

        var streamFormat = try property(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &streamFormat) else { throw TapError.format }
        let samples = try FallbackAudioSamples(format: format, mailbox: mailbox, onError: onError)
        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: description.name,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]]
        ]
        try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &device), "create capture device")
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, nil) { _, input, _, _, _ in
            samples.receive(input)
        }, "attach audio callback")
        guard let ioProc else { throw TapError.stopped }
        try check(AudioDeviceStart(device, ioProc), "start system audio capture")
        running = true
    }

    private func fail(_ error: Error, capture: UUID, status: (Result<Void, Error>) -> Void) {
        guard activeCapture == capture else { return }
        tearDown()
        status(.failure(error))
    }

    private func tearDown() {
        activeCapture = nil
        healthCheck?.cancel()
        healthCheck = nil
        if let ioProc {
            if running { AudioDeviceStop(device, ioProc) }
            AudioDeviceDestroyIOProcID(device, ioProc)
            self.ioProc = nil
        }
        running = false
        if device != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(device)
            device = AudioObjectID(kAudioObjectUnknown)
        }
        if #available(macOS 14.2, *), tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             _ initialValue: T) throws -> T {
        var value = initialValue
        var size = UInt32(MemoryLayout<T>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
        }
        try check(status, "read capture device property")
        return value
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw TapError.hal(operation, status) }
    }
}

private enum TapError: LocalizedError {
    case hal(String, OSStatus)
    case format
    case stopped

    var errorDescription: String? {
        switch self {
        case let .hal(operation, status): return "Could not \(operation) (Core Audio \(status))."
        case .format: return "Unsupported system audio capture format."
        case .stopped: return "The system audio capture device stopped."
        }
    }
}

/// The HAL callback only copies into a preallocated slot. Conversion and
/// packetization run elsewhere; a busy slot drops the incoming block.
private final class FallbackAudioSamples {
    private let slot = DispatchSemaphore(value: 1)
    private let queue = DispatchQueue(label: "sender.fallback-audio.samples", qos: .userInitiated)
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let converter: AVAudioConverter
    private let mailbox: AudioOutputMailbox
    private let onError: (Error) -> Void
    private let inputBytesPerFrame: Int

    init(format: AVAudioFormat, mailbox: AudioOutputMailbox, onError: @escaping (Error) -> Void) throws {
        let capacity: AVAudioFrameCount = 4096
        guard (8_000...192_000).contains(format.sampleRate),
              let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: Double(AudioWire.sampleRate),
                                             channels: AVAudioChannelCount(AudioWire.channels), interleaved: true),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let converter = AVAudioConverter(from: format, to: wireFormat) else { throw TapError.format }
        let convertedCapacity = AVAudioFrameCount(ceil(Double(capacity) * wireFormat.sampleRate / format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: convertedCapacity) else {
            throw TapError.format
        }
        converter.primeMethod = .none
        self.input = input
        self.output = output
        self.converter = converter
        self.mailbox = mailbox
        self.onError = onError
        inputBytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard inputBytesPerFrame > 0 else { throw TapError.format }
    }

    func receive(_ buffers: UnsafePointer<AudioBufferList>) {
        guard slot.wait(timeout: .now()) == .success else { return }
        let capturedAt = DispatchTime.now()
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffers))
        let target = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let count = Int(source.first?.mDataByteSize ?? 0)
        let frames = count / inputBytesPerFrame
        guard frames > 0 else {
            slot.signal()
            return
        }
        guard frames <= input.frameCapacity, source.count == target.count, count % inputBytesPerFrame == 0,
              source.indices.allSatisfy({
                  source[$0].mNumberChannels == target[$0].mNumberChannels
                      && source[$0].mDataByteSize == count && source[$0].mData != nil
              }) else {
            onError(TapError.format)
            slot.signal()
            return
        }
        input.frameLength = AVAudioFrameCount(frames)
        for index in source.indices {
            memcpy(target[index].mData!, source[index].mData!, count)
        }
        queue.async {
            defer { self.slot.signal() }
            self.convert(capturedAt: capturedAt)
        }
    }

    private func convert(capturedAt: DispatchTime) {
        var supplied = false
        var error: NSError?
        output.frameLength = 0
        let result = converter.convert(to: output, error: &error) { _, status in
            status.pointee = supplied ? .noDataNow : .haveData
            defer { supplied = true }
            return supplied ? nil : self.input
        }
        if result == .error {
            onError(error ?? TapError.format)
            return
        }
        guard let samples = output.audioBufferList.pointee.mBuffers.mData else { return }
        let frameCount = Int(output.frameLength)
        // The sender permits four audio writes in flight. Keep the newest
        // four packets if a device delivers an unusually large IO block.
        let firstFrame = max(0, frameCount - 4 * AudioWire.maxFrames)
        let packets = stride(from: firstFrame, to: frameCount, by: AudioWire.maxFrames).compactMap { frame in
            let count = min(AudioWire.maxFrames, frameCount - frame) * AudioWire.bytesPerFrame
            let pcm = Data(bytes: samples.advanced(by: frame * AudioWire.bytesPerFrame), count: count)
            return AudioWire.pack(pcm)
        }
        if !packets.isEmpty { mailbox.offer(packets, capturedAt: capturedAt) }
    }
}
