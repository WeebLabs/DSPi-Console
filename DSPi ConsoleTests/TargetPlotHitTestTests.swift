import XCTest
@testable import DSPi_Console

/// Covers what the pointer is over on the target plot.
///
/// These rules decide whether a control can be grabbed at all, which is
/// exactly the class of bug that only shows up when someone tries to use it.
final class TargetPlotHitTestTests: XCTestCase {

    private let pointA = UUID()
    private let pointB = UUID()

    private func tester(radius: CGFloat = 11) -> TargetPlotHitTester {
        TargetPlotHitTester(
            points: [
                (.anchor(pointA), CGPoint(x: 100, y: 100)),
                (.anchor(pointB), CGPoint(x: 300, y: 60)),
                (.bassShelf, CGPoint(x: 60, y: 120)),
                (.trebleShelf, CGPoint(x: 500, y: 80)),
            ],
            verticals: [(.lowCurtain, 40), (.highCurtain, 560)],
            grabRadius: radius)
    }

    // MARK: - Points

    func testAPointIsGrabbedWithinTheRadius() {
        XCTAssertEqual(tester().handle(at: CGPoint(x: 100, y: 100)), .anchor(pointA))
        XCTAssertEqual(tester().handle(at: CGPoint(x: 107, y: 106)), .anchor(pointA))
    }

    func testJustOutsideTheRadiusIsNotAGrab() {
        // Otherwise a click meant to add a point silently drags a nearby one.
        XCTAssertNil(tester().handle(at: CGPoint(x: 100, y: 130)))
    }

    func testTheNearestOfTwoOverlappingPointsWins() {
        // Points can be dragged close together, and the one under the pointer
        // should be the one that moves.
        let close = TargetPlotHitTester(
            points: [(.anchor(pointA), CGPoint(x: 100, y: 100)),
                     (.anchor(pointB), CGPoint(x: 108, y: 100))],
            verticals: [])
        XCTAssertEqual(close.handle(at: CGPoint(x: 101, y: 100)), .anchor(pointA))
        XCTAssertEqual(close.handle(at: CGPoint(x: 107, y: 100)), .anchor(pointB))
    }

    // MARK: - Shelf handles

    func testShelfHandlesAreGrabbable() {
        // The bug the user hit: these were drawn but felt unreachable, so the
        // rule is worth pinning rather than assuming.
        XCTAssertEqual(tester().handle(at: CGPoint(x: 60, y: 120)), .bassShelf)
        XCTAssertEqual(tester().handle(at: CGPoint(x: 503, y: 84)), .trebleShelf)
    }

    // MARK: - Curtains

    func testACurtainIsGrabbedAnywhereAlongItsHeight() {
        // It is a full-height line, so only the horizontal distance matters.
        for y in [CGFloat(0), 75, 200] {
            XCTAssertEqual(tester().handle(at: CGPoint(x: 40, y: y)), .lowCurtain,
                           "at y = \(y)")
        }
        XCTAssertEqual(tester().handle(at: CGPoint(x: 566, y: 10)), .highCurtain)
    }

    func testAPointOnACurtainStillWins() {
        // A point dragged onto the curtain line would otherwise be unreachable,
        // since the curtain is grabbable at every height.
        let overlapping = TargetPlotHitTester(
            points: [(.anchor(pointA), CGPoint(x: 40, y: 100))],
            verticals: [(.lowCurtain, 40)])
        XCTAssertEqual(overlapping.handle(at: CGPoint(x: 40, y: 100)), .anchor(pointA))
        // And the curtain is still grabbable away from the point.
        XCTAssertEqual(overlapping.handle(at: CGPoint(x: 40, y: 250)), .lowCurtain)
    }

    // MARK: - Empty space

    func testEmptyPlotReturnsNothing() {
        // This is what lets a click add a point rather than move one.
        XCTAssertNil(tester().handle(at: CGPoint(x: 220, y: 200)))
        XCTAssertNil(tester().handle(at: CGPoint(x: 400, y: 30)))
    }

    func testATesterWithNothingInItIsAllEmptySpace() {
        let empty = TargetPlotHitTester(points: [], verticals: [])
        XCTAssertNil(empty.handle(at: CGPoint(x: 10, y: 10)))
    }

    func testTheGrabRadiusIsHonoured() {
        let generous = tester(radius: 40)
        XCTAssertEqual(generous.handle(at: CGPoint(x: 100, y: 130)), .anchor(pointA),
                       "30 points away is inside a 40 point radius")
    }
}
