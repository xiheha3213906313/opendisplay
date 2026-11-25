import XCTest

final class AudioOutputRoutingTests: XCTestCase {
    func testFallbackFavorsTheMainDisplayOverEarlierConnections() {
        let first = UUID()
        let main = UUID()
        XCTAssertEqual(FallbackAudioRouting.preferredOffer(mainDisplay: 2, candidates: [
            .init(offer: first, displayID: 1),
            .init(offer: main, displayID: 2)
        ]), main)
    }

    func testFallbackSkipsAnUnsupportedOrFailedMainDisplayThenUsesTheMac() {
        let first = UUID()
        let second = UUID()
        let unavailableMain = FallbackAudioRouting.Candidate(offer: nil, displayID: 3)
        let firstReceiver = FallbackAudioRouting.Candidate(offer: first, displayID: 1)
        let secondReceiver = FallbackAudioRouting.Candidate(offer: second, displayID: 2)
        XCTAssertEqual(FallbackAudioRouting.preferredOffer(mainDisplay: 3, candidates: [
            unavailableMain, firstReceiver, secondReceiver
        ]), first)
        XCTAssertEqual(FallbackAudioRouting.preferredOffer(mainDisplay: 3, candidates: [
            unavailableMain, secondReceiver
        ]), second)
        XCTAssertNil(FallbackAudioRouting.preferredOffer(mainDisplay: 3, candidates: [unavailableMain]))
    }

    func testFallbackReconsidersTheMainDisplayOnAReconnectedOffer() {
        let other = UUID()
        let restoredMain = UUID()
        XCTAssertEqual(FallbackAudioRouting.preferredOffer(mainDisplay: 3, candidates: [
            .init(offer: other, displayID: 2),
            .init(offer: restoredMain, displayID: 3)
        ]), restoredMain)
    }

    func testFirstOutputWinsAndFailoverUsesTheEarliestRemainingOutput() {
        var routing = AudioOutputRouting()
        routing.observe("headphones", isAndroid: false)
        XCTAssertEqual(routing.nextOutput(current: "headphones", ready: ["a", "b"], isAndroid: false), "a")
        routing.didSwitch(to: "a", isAndroid: true)
        XCTAssertNil(routing.nextOutput(current: "a", ready: ["a", "b"], isAndroid: true))
        XCTAssertEqual(routing.nextOutput(current: "a", ready: ["b", "c"], isAndroid: true), "b")
        routing.didSwitch(to: "b", isAndroid: true)
        XCTAssertEqual(routing.nextOutput(current: "b", ready: [], isAndroid: true), "headphones")
    }

    func testManualLocalOutputWinsOverLateDevicesAndReconnect() {
        var routing = AudioOutputRouting()
        routing.observe("headphones", isAndroid: false)
        routing.didSwitch(to: "a", isAndroid: true)
        routing.observe("speakers", isAndroid: false)
        XCTAssertTrue(routing.userSelectedLocal)
        XCTAssertNil(routing.nextOutput(current: "speakers", ready: ["a", "b"], isAndroid: false))
        XCTAssertNil(routing.nextOutput(current: "speakers", ready: ["b"], isAndroid: false))
        routing.observe("b", isAndroid: true)
        XCTAssertEqual(routing.nextOutput(current: "b", ready: [], isAndroid: true), "speakers")
    }

    func testAutomaticLocalFallbackAllowsAReconnectedOutput() {
        var routing = AudioOutputRouting()
        routing.observe("headphones", isAndroid: false)
        routing.didSwitch(to: "a", isAndroid: true)
        routing.didSwitch(to: "speakers", isAndroid: false)
        routing.observe("speakers", isAndroid: false)
        XCTAssertEqual(routing.nextOutput(current: "speakers", ready: ["a"], isAndroid: false), "a")
    }

    func testUSBReturningOutputCanReclaimAnAutomaticFallback() {
        var selection = AudioOutputSelection()
        selection.observe("tablet", automatic: false)
        let saved = USBOutputReturn(selectedUID: "tablet", selectionRevision: selection.revision)
        selection.observe("speakers", automatic: true)
        XCTAssertTrue(saved.mayRestore("tablet", currentRevision: selection.revision))
        XCTAssertFalse(saved.mayRestore("different-install", currentRevision: selection.revision))
    }

    func testUSBReturningOutputPreservesAManualChoice() {
        var selection = AudioOutputSelection()
        selection.observe("tablet", automatic: false)
        let saved = USBOutputReturn(selectedUID: "tablet", selectionRevision: selection.revision)
        selection.observe("other-android", automatic: true)
        selection.observe("headphones", automatic: false)
        XCTAssertFalse(saved.mayRestore("tablet", currentRevision: selection.revision))
    }

    func testMainDisplayReturnDoesNotAutomaticallySelectItsUnselectedAudioRoute() {
        var routing = AudioOutputRouting()
        let saved = USBOutputReturn(selectedUID: nil, selectionRevision: 0)
        XCTAssertFalse(saved.mayRestore("tablet", currentRevision: 0))
        routing.preserveLocalOutput("speakers")
        XCTAssertNil(routing.nextOutput(current: "speakers", ready: ["tablet"], isAndroid: false))
    }
}
