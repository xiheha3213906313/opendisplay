import Foundation

/// The AOA v2 bulk stream can restart after a receiver process dies in the
/// middle of a transfer. A zero delimiter cannot occur within a COBS record.
enum AccessoryRecords {
    static let preface = Data("ODU2".utf8)
    static let chunkSize = 15 * 1024
    static let ready: UInt8 = 1
    static let bytes: UInt8 = 2
    static let epochSize = 16
    static let limit = 16 * 1024

    static func encode(kind: UInt8, epoch: Data, payload: Data = Data()) -> Data {
        var source = Data([kind])
        source.append(epoch)
        source.append(payload)
        var encoded = Data([0, 0])
        var codeIndex = 1
        var run: UInt8 = 1
        for byte in source {
            if byte != 0 {
                encoded.append(byte)
                run += 1
            }
            if byte == 0 || run == 255 {
                encoded[codeIndex] = run
                codeIndex = encoded.count
                encoded.append(0)
                run = 1
            }
        }
        encoded[codeIndex] = run
        encoded.append(0)
        return encoded
    }

    struct Decoder {
        private var buffer = Data()
        private var discarding = false

        mutating func append(_ bytes: Data) -> [Data] {
            var records: [Data] = []
            for byte in bytes {
                if byte == 0 {
                    if !discarding, let decoded = decode(buffer) { records.append(decoded) }
                    buffer.removeAll(keepingCapacity: true)
                    discarding = false
                } else if !discarding {
                    if buffer.count < AccessoryRecords.limit { buffer.append(byte) }
                    else { discarding = true }
                }
            }
            return records
        }

        private func decode(_ encoded: Data) -> Data? {
            guard !encoded.isEmpty else { return nil }
            var result = Data()
            var offset = 0
            while offset < encoded.count {
                let run = Int(encoded[offset])
                offset += 1
                let end = offset + run - 1
                guard run > 0, end <= encoded.count else { return nil }
                result.append(encoded[offset..<end])
                offset = end
                if run != 255 && offset < encoded.count { result.append(0) }
            }
            guard result.count >= 1 + AccessoryRecords.epochSize else { return nil }
            return result
        }
    }
}
