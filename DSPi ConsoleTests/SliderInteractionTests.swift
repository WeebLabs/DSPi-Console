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

    @MainActor
    func testNativeControlAcceptsExternalAndKeyboardValues() {
        let slider = ParameterSlider(frame: NSRect(x: 0, y: 0, width: 300, height: 16))
        var values: [Float] = []
        slider.configure(value: 12, range: 0...24, enabled: true, onValue: { values.append($0) })
        XCTAssertEqual(slider.floatValue, 12)
        XCTAssertTrue(slider.isContinuous)
        // Keyboard/accessibility actions have no pointer-tracking loop and
        // must commit immediately rather than wait for a mouse-up event.
        slider.floatValue = 13.5
        slider.sendAction(slider.action, to: slider.target)
        XCTAssertEqual(values, [13.5])
        slider.configure(value: 7, range: 0...24, enabled: true, onValue: { values.append($0) })
        XCTAssertEqual(slider.floatValue, 7)
        slider.configure(value: 7, range: 0...24, enabled: false, onValue: { values.append($0) })
        XCTAssertFalse(slider.isEnabled)
        slider.floatValue = 10
        slider.sendAction(slider.action, to: slider.target)
        XCTAssertEqual(values, [13.5], "A disabled control sent a value")
    }
}
