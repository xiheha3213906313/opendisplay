import XCTest

final class AudioOutputRoutingTests: XCTestCase {
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
}
