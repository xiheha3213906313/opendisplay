import XCTest

final class AudioWireTests: XCTestCase {
    // Same two signed stereo frames as AudioWireTest.kt.
    private let stereo = Data([0x34, 0x12, 0xfe, 0xff, 0x00, 0x80, 0xff, 0x7f])

    func testStereoPacketMatchesAndroidFixture() {
        let header = Data([0x41, 0x55, 0x44, 0x31, 1, 2, 0xbb, 0x80, 0, 0, 0, 2])
        XCTAssertEqual(AudioWire.pack(stereo), header + stereo)
    }

    func testInvalidPcmSizesCannotBeSent() {
        XCTAssertNil(AudioWire.pack(Data()))
        XCTAssertNil(AudioWire.pack(stereo.dropLast()))
        XCTAssertNil(AudioWire.pack(Data(count: 961 * 4)))
        XCTAssertNotNil(AudioWire.pack(Data(count: 960 * 4)))
    }

    func testLegacyAndMonoOffersCannotEnableStereo() {
        XCTAssertFalse(AudioWire.isOffered(by: [:]))
        XCTAssertFalse(AudioWire.isOffered(by: ["audio": 1]))
        XCTAssertFalse(AudioWire.isOffered(by: ["audioFormat": 1]))
        XCTAssertTrue(AudioWire.isOffered(by: ["audioFormat": AudioWire.format]))
    }

    func testHALFloatSamplesKeepChannelsAndClampToTheWireFormat() {
        let samples: [Float] = [0.5, -0.5, -2, 2, .nan, .infinity]
        let input = samples.withUnsafeBytes { Data($0) }
        let expected = Data([0x41, 0x55, 0x44, 0x31, 1, 2, 0xbb, 0x80, 0, 0, 0, 3,
                             0, 0x40, 0, 0xc0, 0, 0x80, 0xff, 0x7f, 0, 0, 0, 0])
        XCTAssertEqual(AudioWire.packHALSamples(input), expected)
        XCTAssertNil(AudioWire.packHALSamples(input.dropLast()))
    }
}
