import XCTest

final class RemoteAudioVolumeTests: XCTestCase {
    private let start = DispatchTime(uptimeNanoseconds: 10_000_000_000)

    private var settled: DispatchTime { start + .milliseconds(500) }

    private func phone(_ index: Int, muted: Bool = false, sequence: Int? = nil,
                       fixed: Bool = false) -> AndroidVolumeState {
        var fields: [String: Any] = ["min": 0, "max": 10, "index": index, "muted": muted,
                                     "canVolume": !fixed, "canMute": !fixed]
        fields["sequence"] = sequence
        return AndroidVolumeState(fields)!
    }

    private func hal(_ volume: Float, revision: Int = 0, muted: Bool = false, muteRevision: Int = 0,
                     native: Bool = true) -> HALVolumeState {
        HALVolumeState(["volume": volume, "volumeRevision": revision, "muted": muted,
                        "muteRevision": muteRevision, "nativeVolume": native])!
    }

    func testInitialStateAndPhoneKeysDoNotWriteBackToAndroid() {
        var volume = RemoteAudioVolume(phone: phone(4))
        let initial = volume.poll(hal(1, native: false), selected: false, now: start)
        XCTAssertNil(initial.command)
        XCTAssertEqual(initial.update["volume"] as? Float, 0.4)
        XCTAssertEqual(initial.update["nativeVolume"] as? Bool, true)
        volume.receive(phone(6))
        let moved = volume.poll(hal(0.4), selected: true, now: start)
        XCTAssertNil(moved.command)
        XCTAssertEqual(moved.update["volume"] as? Float, 0.6)
    }

    func testBecomingDefaultDoesNotSendRestoredMacSettings() {
        var volume = RemoteAudioVolume(phone: phone(4))
        _ = volume.poll(hal(1, native: false), selected: false, now: start)
        let startup = volume.poll(hal(1, revision: 1, native: false), selected: true, now: start)
        XCTAssertNil(startup.command)
        XCTAssertEqual(startup.update["volume"] as? Float, 0.4)
        XCTAssertNil(volume.poll(hal(0.4, revision: 2), selected: true, now: settled).command)
    }

    func testDelayedAcknowledgementCannotOverwriteNewerEdit() {
        var volume = RemoteAudioVolume(phone: phone(4))
        _ = volume.poll(hal(0.4), selected: true, now: start)
        XCTAssertEqual(volume.poll(hal(0.5, revision: 1), selected: true, now: settled).command?.index, 5)
        XCTAssertNil(volume.poll(hal(0.8, revision: 2), selected: true, now: settled).command)
        volume.receive(phone(5, sequence: 1))
        let latest = volume.poll(hal(0.8, revision: 2), selected: true, now: settled)
        XCTAssertEqual(latest.command?.index, 8)
        XCTAssertNil(latest.update["volume"])
        volume.receive(phone(2, sequence: 1))
        XCTAssertNil(volume.poll(hal(0.8, revision: 2), selected: true, now: settled).update["volume"])
    }

    func testTimeoutReturnsToSoftwareWithoutDisablingRemoteMute() {
        var volume = RemoteAudioVolume(phone: phone(4))
        _ = volume.poll(hal(0.4), selected: true, now: start)
        XCTAssertNotNil(volume.poll(hal(0.5, revision: 1), selected: true, now: settled).command)
        let timeout = volume.poll(hal(0.5, revision: 1), selected: true, now: start + .seconds(2))
        XCTAssertEqual(timeout.update["nativeVolume"] as? Bool, false)
        volume.receive(phone(5, sequence: 1))
        let mute = volume.poll(hal(0.6, revision: 2, muted: true, muteRevision: 1, native: false),
                               selected: true, now: start + .seconds(2))
        XCTAssertNil(mute.command?.index)
        XCTAssertEqual(mute.command?.muted, true)
    }

    func testMismatchAndFixedVolumeKeepSoftwareControl() {
        var fixed = RemoteAudioVolume(phone: phone(2, fixed: true))
        let initial = fixed.poll(hal(0.5), selected: true, now: start)
        XCTAssertEqual(initial.update["nativeVolume"] as? Bool, false)
        XCTAssertNil(initial.command)

        var volume = RemoteAudioVolume(phone: phone(4))
        _ = volume.poll(hal(0.4), selected: true, now: start)
        _ = volume.poll(hal(0.8, revision: 1), selected: true, now: settled)
        volume.receive(phone(6, sequence: 1))
        let rejected = volume.poll(hal(0.8, revision: 1), selected: true, now: settled)
        XCTAssertEqual(rejected.update["nativeVolume"] as? Bool, false)
        XCTAssertNil(rejected.update["volume"])
    }
}
