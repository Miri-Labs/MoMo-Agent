import XCTest
@testable import MoMoAgent

final class HistoryDrawerInteractionTests: XCTestCase {
    func testOpeningRequiresAnInwardHorizontalPanFromTheLeftEdge() {
        XCTAssertTrue(HistoryDrawerInteraction.accepts(isPresented: false, startX: 8, velocity: .init(x: 300, y: 20)))
        XCTAssertFalse(HistoryDrawerInteraction.accepts(isPresented: false, startX: 80, velocity: .init(x: 300, y: 20)))
        XCTAssertFalse(HistoryDrawerInteraction.accepts(isPresented: false, startX: 8, velocity: .init(x: -300, y: 20)))
        XCTAssertFalse(HistoryDrawerInteraction.accepts(isPresented: false, startX: 8, velocity: .init(x: 100, y: 300)))
        XCTAssertFalse(HistoryDrawerInteraction.accepts(isPresented: true, startX: 80, velocity: .init(x: -50, y: -300)))
        XCTAssertTrue(HistoryDrawerInteraction.accepts(isPresented: true, startX: 80, velocity: .init(x: -300, y: 20)))
    }

    func testDragFollowsTheFingerAndClampsAtBothEdges() {
        XCTAssertEqual(HistoryDrawerInteraction.visibleWidth(isPresented: false, translation: 75, width: 300), 75)
        XCTAssertEqual(HistoryDrawerInteraction.visibleWidth(isPresented: true, translation: -75, width: 300), 225)
        XCTAssertEqual(HistoryDrawerInteraction.visibleWidth(isPresented: false, translation: -75, width: 300), 0)
        XCTAssertEqual(HistoryDrawerInteraction.visibleWidth(isPresented: true, translation: 75, width: 300), 300)
        XCTAssertEqual(HistoryDrawerInteraction.visibleWidth(isPresented: false, translation: 500, width: 300), 300)
    }

    func testReleaseUsesDistanceAndVelocityIncludingReversingDirection() {
        XCTAssertFalse(HistoryDrawerInteraction.shouldOpen(isPresented: false, translation: 60, velocity: 0, width: 300))
        XCTAssertTrue(HistoryDrawerInteraction.shouldOpen(isPresented: false, translation: 180, velocity: 0, width: 300))
        XCTAssertTrue(HistoryDrawerInteraction.shouldOpen(isPresented: false, translation: 60, velocity: 800, width: 300))
        XCTAssertFalse(HistoryDrawerInteraction.shouldOpen(isPresented: true, translation: -60, velocity: -800, width: 300))
        XCTAssertTrue(HistoryDrawerInteraction.shouldOpen(isPresented: true, translation: -60, velocity: 0, width: 300))
        XCTAssertFalse(HistoryDrawerInteraction.shouldOpen(isPresented: false, translation: 200, velocity: -800, width: 300))
        XCTAssertTrue(HistoryDrawerInteraction.shouldOpen(isPresented: true, translation: -200, velocity: 800, width: 300))
    }
}
