import Foundation

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

extension AudioWire {
    /// Core Audio supplies native Float32 stereo frames. AUD1 carries the same
    /// channels as signed little-endian PCM, with clipping at full scale.
    static func packHALSamples(_ samples: Data) -> Data? {
        let stride = MemoryLayout<Float>.stride
        guard samples.count <= maxFrames * channels * stride,
              samples.count.isMultiple(of: channels * stride) else { return nil }
        var pcm = Data(capacity: samples.count / 2)
        samples.withUnsafeBytes { buffer in
            for offset in Swift.stride(from: 0, to: buffer.count, by: stride) {
                let sample = buffer.loadUnaligned(fromByteOffset: offset, as: Float.self)
                let normalized = sample.isFinite ? max(-1, min(sample, 1)) : 0
                let scaled = (normalized * 32768).rounded()
                var value = Int16(clamping: Int(scaled)).littleEndian
                withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
            }
        }
        return pack(pcm)
    }
}
