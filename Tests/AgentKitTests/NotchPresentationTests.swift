import Foundation
import XCTest
@testable import AgentKit

final class NotchPresentationTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testStartsAsCharacterWithoutTimer() {
        let machine = NotchPresentationMachine()
        XCTAssertEqual(machine.state, .character)
        XCTAssertNil(machine.nextDeadline)
    }

    func testHoverExpandsAfterDelay() {
        var machine = NotchPresentationMachine()
        machine.mouseEntered(at: at(0))
        XCTAssertEqual(machine.state, .character)
        XCTAssertEqual(machine.nextDeadline, at(0.12))

        machine.tick(at: at(0.05))  // 早すぎる tick は無視
        XCTAssertEqual(machine.state, .character)

        machine.tick(at: at(0.12))
        XCTAssertEqual(machine.state, .expanded)
        XCTAssertNil(machine.nextDeadline)
    }

    func testPassingThroughDoesNotExpand() {
        var machine = NotchPresentationMachine()
        machine.mouseEntered(at: at(0))
        machine.mouseExited(at: at(0.05))
        XCTAssertNil(machine.nextDeadline)
        machine.tick(at: at(1))
        XCTAssertEqual(machine.state, .character)
    }

    func testLeavingCollapsesAfterDelay() {
        var machine = expanded()
        machine.mouseExited(at: at(1))
        XCTAssertEqual(machine.state, .expanded)
        XCTAssertEqual(machine.nextDeadline, at(1.6))
        machine.tick(at: at(1.6))
        XCTAssertEqual(machine.state, .character)
    }

    func testReturningBeforeCollapseKeepsExpanded() {
        var machine = expanded()
        machine.mouseExited(at: at(1))
        machine.mouseEntered(at: at(1.3))
        XCTAssertNil(machine.nextDeadline)
        machine.tick(at: at(2))
        XCTAssertEqual(machine.state, .expanded)
    }

    func testNoticeShowsPeekAndCollapsesBackToPeek() {
        var machine = NotchPresentationMachine()
        machine.setNotice(true, at: at(0))
        XCTAssertEqual(machine.state, .peek)

        machine.mouseEntered(at: at(1))
        machine.tick(at: at(1.2))
        XCTAssertEqual(machine.state, .expanded)

        machine.mouseExited(at: at(2))
        machine.tick(at: at(2.6))
        XCTAssertEqual(machine.state, .peek)

        machine.setNotice(false, at: at(3))
        XCTAssertEqual(machine.state, .character)
    }

    func testNoticeChangeWhileExpandedAffectsCollapseTarget() {
        var machine = expanded()
        machine.mouseExited(at: at(1))
        machine.setNotice(true, at: at(1.1))
        XCTAssertEqual(machine.state, .expanded)
        machine.tick(at: at(1.6))
        XCTAssertEqual(machine.state, .peek)
    }

    func testNoticeChangeWhileExpandingDoesNotCancelExpansion() {
        var machine = NotchPresentationMachine()
        machine.mouseEntered(at: at(0))
        machine.setNotice(true, at: at(0.05))
        XCTAssertEqual(machine.state, .peek)
        machine.tick(at: at(0.12))
        XCTAssertEqual(machine.state, .expanded)
    }

    func testCollapseIsImmediate() {
        var machine = expanded()
        machine.collapse()
        XCTAssertEqual(machine.state, .character)
        XCTAssertNil(machine.nextDeadline)
    }

    func testRepeatedEnterIsIgnored() {
        var machine = NotchPresentationMachine()
        machine.mouseEntered(at: at(0))
        machine.mouseEntered(at: at(0.1))
        XCTAssertEqual(machine.nextDeadline, at(0.12))
    }

    func testZeroDelayTransitionsImmediately() {
        var machine = NotchPresentationMachine(configuration: .init(expandDelay: 0, collapseDelay: 0))
        machine.mouseEntered(at: at(0))
        XCTAssertEqual(machine.state, .expanded)
        machine.mouseExited(at: at(1))
        XCTAssertEqual(machine.state, .character)
    }

    func testPinExpandsImmediatelyAndIgnoresLeaving() {
        var machine = NotchPresentationMachine()
        machine.pin()
        XCTAssertEqual(machine.state, .expanded)
        XCTAssertNil(machine.nextDeadline)
        machine.mouseEntered(at: at(0))
        machine.mouseExited(at: at(1))
        XCTAssertNil(machine.nextDeadline)
        machine.tick(at: at(5))
        XCTAssertEqual(machine.state, .expanded)
    }

    func testPinCancelsPendingCollapse() {
        var machine = expanded()
        machine.mouseExited(at: at(1))
        XCTAssertNotNil(machine.nextDeadline)
        machine.pin()
        XCTAssertNil(machine.nextDeadline)
        machine.tick(at: at(5))
        XCTAssertEqual(machine.state, .expanded)
    }

    func testUnpinCollapsesOnlyWhenNotHovering() {
        var machine = NotchPresentationMachine()
        machine.pin()
        machine.setNotice(true, at: at(0))
        machine.unpin(at: at(1))
        XCTAssertEqual(machine.nextDeadline, at(1.6))
        machine.tick(at: at(1.6))
        XCTAssertEqual(machine.state, .peek)

        var hovering = expanded()
        hovering.pin()
        hovering.unpin(at: at(1))
        XCTAssertNil(hovering.nextDeadline)
        XCTAssertEqual(hovering.state, .expanded)
        hovering.unpin(at: at(2))  // 留めていなければ何もしない
        XCTAssertNil(hovering.nextDeadline)
    }

    func testCollapseReleasesPin() {
        var machine = NotchPresentationMachine()
        machine.pin()
        machine.collapse()
        XCTAssertFalse(machine.isPinned)
        XCTAssertEqual(machine.state, .character)
    }

    private func expanded() -> NotchPresentationMachine {
        var machine = NotchPresentationMachine()
        machine.mouseEntered(at: at(0))
        machine.tick(at: at(0.12))
        XCTAssertEqual(machine.state, .expanded)
        return machine
    }
}
