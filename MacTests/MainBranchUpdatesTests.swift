import Foundation
import XCTest

final class MainBranchUpdatesTests: XCTestCase {
    private let manifest = Data(#"{"version":"1.31.0","senderBuild":8,"receiverBuild":7}"#.utf8)

    func testUsesMainAndTheRightInstaller() throws {
        let sender = try XCTUnwrap(MainBranchUpdates.available(in: manifest, product: .sender,
                                                              version: "1.31.0", build: 7))
        XCTAssertEqual(sender.url.absoluteString,
                       "https://raw.githubusercontent.com/xiheha3213906313/opendisplay/main/downloads/macos/OpenDisplay.dmg?version=1.31.0&build=8")
        let receiver = try XCTUnwrap(MainBranchUpdates.available(in: manifest, product: .receiver,
                                                                version: "1.30.9", build: 50))
        XCTAssertEqual(receiver.url.lastPathComponent, "OpenDisplayReceiver.dmg")
    }

    func testSameOrOlderBuildIsNotOffered() throws {
        XCTAssertNil(try MainBranchUpdates.available(in: manifest, product: .sender, version: "1.31.0", build: 8))
        XCTAssertNil(try MainBranchUpdates.available(in: manifest, product: .receiver, version: "1.31.0", build: 7))
        XCTAssertNil(try MainBranchUpdates.available(in: manifest, product: .sender, version: "1.32.0", build: 1))
    }

    func testRejectsInvalidManifest() {
        let invalid = Data(#"{"version":"../bad","senderBuild":8,"receiverBuild":7}"#.utf8)
        XCTAssertThrowsError(try MainBranchUpdates.available(in: invalid, product: .sender, version: "1.31.0", build: 7))
    }
}
