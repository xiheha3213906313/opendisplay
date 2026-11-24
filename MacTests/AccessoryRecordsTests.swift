import Foundation
import XCTest

final class AccessoryRecordsTests: XCTestCase {
    func testRecoversAtDelimiterAndPreservesEmbeddedZeroes() {
        let epoch = Data(repeating: 1, count: 16)
        let payload = Data([0, 1, 0, 2])
        let wire = AccessoryRecords.encode(kind: AccessoryRecords.bytes, epoch: epoch, payload: payload)
        XCTAssertEqual(wire, Data([0, 18, 2] + Array(repeating: 1, count: 16) + [2, 1, 2, 2, 0]))
        var decoder = AccessoryRecords.Decoder()
        XCTAssertTrue(decoder.append(Data([4, 7])).isEmpty)
        XCTAssertTrue(decoder.append(Data(wire.prefix(8))).isEmpty)
        XCTAssertEqual(decoder.append(Data(wire.dropFirst(8))), [Data([2]) + epoch + payload])
    }

    func testOversizedRecordDoesNotAffectNextRecord() {
        let epoch = Data(repeating: 9, count: 16)
        var decoder = AccessoryRecords.Decoder()
        XCTAssertTrue(decoder.append(Data(repeating: 1, count: 20_000)).isEmpty)
        XCTAssertEqual(decoder.append(AccessoryRecords.encode(kind: AccessoryRecords.ready, epoch: epoch)),
                       [Data([1]) + epoch])
    }
}
