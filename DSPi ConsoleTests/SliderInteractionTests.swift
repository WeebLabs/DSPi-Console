import XCTest
import AppKit
@testable import DSPi_Console

final class SliderInteractionTests: XCTestCase {
    @MainActor
    func testRapidDragCoalescesValuesAndCommitsExactRelease() {
        let delivery = SliderValueDelivery(interval: 60)
        var sent: [Float] = []
        delivery.onValue = { sent.append($0) }
        delivery.synchronize(to: 0)
        for value in 1...1000 { delivery.submit(Float(value)) }
        XCTAssertEqual(sent, [1])
        delivery.finish(999.125)
        XCTAssertEqual(sent, [1, 999.125])
        delivery.finish(999.125)
        XCTAssertEqual(sent.count, 2, "Release must not resend an unchanged value")
    }

    @MainActor
    func testPendingLatestValueIsDeliveredInMouseTrackingMode() {
        let delivery = SliderValueDelivery(interval: 0.01)
        var sent: [Float] = []
        delivery.onValue = { sent.append($0) }
        delivery.synchronize(to: 0)
        delivery.submit(1)
        delivery.submit(2)
        delivery.submit(3)
        let limit = Date().addingTimeInterval(1)
        while sent.count < 2 && Date() < limit {
            RunLoop.main.run(mode: .eventTracking, before: limit)
        }
        XCTAssertEqual(sent, [1, 3], "Holding the thumb still must still deliver its latest value")
        delivery.cancel()
    }

    @MainActor
    func testCancellationAndExternalChangesDiscardStaleValues() {
        let delivery = SliderValueDelivery(interval: 0.01)
        var sent: [Float] = []
        delivery.onValue = { sent.append($0) }
        delivery.submit(1)
        delivery.submit(2)
        delivery.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        XCTAssertEqual(sent, [1])
        delivery.submit(3)
        delivery.submit(4)
        delivery.synchronize(to: 10)
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        XCTAssertEqual(sent, [1, 3])
        delivery.finish(11)
        XCTAssertEqual(sent, [1, 3, 11])
    }
}
