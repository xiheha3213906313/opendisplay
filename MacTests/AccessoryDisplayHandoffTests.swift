import Foundation
import XCTest

final class AccessoryDisplayHandoffTests: XCTestCase {
    func testDisplayAndDeviceHaveIndependentDeadlines() {
        let start = ContinuousClock.now
        let window = AccessoryDetachWindow(start: start, expectedReenumeration: false)
        XCTAssertFalse(window.shouldWithdrawDisplay(at: start + .milliseconds(1999)))
        XCTAssertTrue(window.acceptsReturn(at: start + .milliseconds(1999)))
        XCTAssertTrue(window.shouldWithdrawDisplay(at: start + .seconds(2)))
        XCTAssertTrue(window.acceptsReturn(at: start + .milliseconds(9999)))
        XCTAssertFalse(window.acceptsReturn(at: start + .seconds(10)))
    }

    func testExpectedReenumerationDoesNotWithdrawTheDisplayEarly() {
        let start = ContinuousClock.now
        let window = AccessoryDetachWindow(start: start, expectedReenumeration: true)
        XCTAssertFalse(window.shouldWithdrawDisplay(at: start + .seconds(3)))
        XCTAssertTrue(window.acceptsReturn(at: start + .seconds(3)))
        XCTAssertFalse(window.acceptsReturn(at: start + .seconds(10)))
    }

    func testANewUnplugGetsItsOwnGenerationAndDeadlines() {
        let start = ContinuousClock.now
        let first = AccessoryDetachWindow(start: start, expectedReenumeration: false)
        let second = AccessoryDetachWindow(start: start + .seconds(5), expectedReenumeration: false)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(first.acceptsReturn(at: start + .seconds(11)))
        XCTAssertTrue(second.acceptsReturn(at: start + .seconds(11)))
    }

    func testWindowServerFallbackDoesNotOverrideTheOriginalPreference() {
        var selection = MainDisplaySelection()
        selection.observe(main: 2, active: [1, 2, 3])
        let revision = selection.selectionRevision
        selection.observe(main: 1, active: [1, 3])
        selection.observe(main: 1, active: [1, 3, 4])
        XCTAssertEqual(selection.selectionRevision, revision)
        selection.observe(main: 4, active: [1, 3, 4], requestedMain: 4)
        XCTAssertEqual(selection.selectionRevision, revision)
    }

    func testUserSwitchBetweenAvailableDisplaysCancelsRestoration() {
        var selection = MainDisplaySelection()
        selection.observe(main: 2, active: [1, 2, 3])
        let revision = selection.selectionRevision
        selection.observe(main: 1, active: [1, 3])
        selection.observe(main: 3, active: [1, 3])
        selection.observe(main: 1, active: [1, 3])
        XCTAssertNotEqual(selection.selectionRevision, revision)
    }

    func testUSBSwitchConfirmationStillDetectsAnOverrideToADifferentDisplay() {
        var selection = MainDisplaySelection()
        selection.observe(main: 1, active: [1, 2, 3])
        let revision = selection.selectionRevision
        selection.observe(main: 3, active: [1, 2, 3], requestedMain: 2)
        XCTAssertNotEqual(selection.selectionRevision, revision)
    }

    func testPromotingTheLeftDisplayMovesTheOldMainOffTheOrigin() {
        let layouts: [UInt32: CGPoint] = [1: .zero, 2: CGPoint(x: -1334, y: 0)]
        let translated = MainDisplaySelection.rebasedOrigins(layouts, main: 2)
        XCTAssertEqual(translated?[2], .zero)
        XCTAssertEqual(translated?[1], CGPoint(x: 1334, y: 0))
    }

    func testRebasingPreservesTheRelativeCoordinatesOfThreeDisplays() {
        let layouts: [UInt32: CGPoint] = [
            1: .zero, 2: CGPoint(x: 1600, y: -300), 3: CGPoint(x: 700, y: 900)
        ]
        let translated = MainDisplaySelection.rebasedOrigins(layouts, main: 2)
        XCTAssertEqual(translated?[2], .zero)
        XCTAssertEqual(translated?[1], CGPoint(x: -1600, y: 300))
        XCTAssertEqual(translated?[3], CGPoint(x: -900, y: 1200))
        XCTAssertNil(MainDisplaySelection.rebasedOrigins(layouts, main: 4))
    }
}
