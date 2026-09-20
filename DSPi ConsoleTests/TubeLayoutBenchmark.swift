import XCTest
import SwiftUI
import Combine
@testable import DSPi_Console

/// Measures what one parameter update costs the Tube Modeller window on the
/// main thread. A slider drag delivers an update per mouse event, so this
/// number has to stay well under a frame, or the drag drops frames and the
/// RTA graphs (which draw on the main thread) stall with it.
///
/// It publishes through the view model, which re-runs the whole window body
/// as well as its layout, so it is an upper bound on the drag path; the
/// profile showed the body itself is negligible and layout is the cost.
final class TubeLayoutBenchmark: XCTestCase {
    @MainActor
    func testAdvancedModeUpdateCost() throws {
        let defaults = UserDefaults.standard
        let hadAdvanced = defaults.object(forKey: "tubeModellerAdvanced")
        defaults.set(true, forKey: "tubeModellerAdvanced")
        defer { if let hadAdvanced { defaults.set(hadAdvanced, forKey: "tubeModellerAdvanced") }
                else { defaults.removeObject(forKey: "tubeModellerAdvanced") } }

        let vm = AppState.shared.viewModel
        vm.firmwareWireFormatVersion = 31
        let controller = TubeModellerWindowController()
        controller.show(vm: vm)
        let window = try XCTUnwrap(NSApp.windows.first { $0.delegate === controller })
        defer { window.close() }
        func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        spin(0.6)   // first layout, window fit

        let n = 200
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<n {
            vm.tube.driveDB = Float(i % 30) - 6
            // One run-loop turn: SwiftUI update, layout and the display cycle.
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(n)
        print(String(format: "TUBE_BENCH advanced: %.2f ms per update (%d updates)", ms, n))
        XCTAssertLessThan(ms, 100, "a committed parameter update should stay well under 100 ms")
    }

    /// The drag path itself: mouse events posted to the window so the real
    /// `NSSlider` tracking loop runs, timed per event. Everything the user feels
    /// as stutter is in this number.
    @MainActor
    func testSyntheticDragCost() throws {
        let defaults = UserDefaults.standard
        let hadAdvanced = defaults.object(forKey: "tubeModellerAdvanced")
        defaults.set(true, forKey: "tubeModellerAdvanced")
        defer { if let hadAdvanced { defaults.set(hadAdvanced, forKey: "tubeModellerAdvanced") }
                else { defaults.removeObject(forKey: "tubeModellerAdvanced") } }

        let vm = AppState.shared.viewModel
        vm.firmwareWireFormatVersion = 31
        let wasConnected = vm.isDeviceConnected
        defer { vm.isDeviceConnected = wasConnected }
        let controller = TubeModellerWindowController()
        controller.show(vm: vm)
        let window = try XCTUnwrap(NSApp.windows.first { $0.delegate === controller })
        defer { window.close() }
        func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        spin(0.8)
        // The rows disable their sliders while no device is connected. Set the
        // flag after the window has settled so a late USB scan cannot undo it.
        vm.isDeviceConnected = true
        // A test-hosted app starts in the background; AppKit tracking wants an
        // active app and a key window, as a real drag would have.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        spin(0.3)

        func sliders(in v: NSView) -> [NSSlider] {
            (v as? NSSlider).map { [$0] } ?? [] + v.subviews.flatMap(sliders(in:))
        }
        let all = sliders(in: try XCTUnwrap(window.contentView))
        let slider = try XCTUnwrap(all.first, "no NSSlider found in the window")
        XCTAssertTrue(slider.isEnabled, "slider must be enabled for the drag")
        let knob = try XCTUnwrap(slider.cell as? NSSliderCell).knobRect(flipped: slider.isFlipped)
        let origin = slider.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)

        var number = 1
        func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            number += 1
            return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: number, clickCount: 1, pressure: 1)!
        }
        // Do exactly what NSSliderCell does inside its tracking loop: begin
        // tracking (SwiftUI's cell subclass raises onEditingChanged(true)
        // there), then for each drag event set the value and fire the action,
        // then end tracking (onEditingChanged(false)). That reaches SwiftUI's
        // binding and our row precisely as a real drag does, without needing
        // the event queue. The run loop is turned once per event, as the real
        // loop does between events, so any SwiftUI commit the event provokes
        // is paid for inside the measurement.
        //
        // Run twice: as a tracked drag (the path the fix creates) and as bare
        // actions with no tracking, which commits every value through the
        // model - the path every event took before. The model's publish count
        // says which path ran; the time says what it cost.
        let cell = try XCTUnwrap(slider.cell as? NSSliderCell)
        let knobCentre = NSPoint(x: knob.midX, y: knob.midY)

        func measure(tracked: Bool, n: Int) -> (ms: Double, publishesDuring: Int, publishesAfter: Int) {
            var during = 0, after = 0
            var inLoop = true
            let sub = vm.tube.$driveDB.dropFirst().sink { _ in if inLoop { during += 1 } else { after += 1 } }
            defer { sub.cancel() }
            if tracked { XCTAssertTrue(cell.startTracking(at: knobCentre, in: slider), "cell refused to start tracking") }
            let start = CFAbsoluteTimeGetCurrent()
            for i in 1...n {
                // SwiftUI's NSSlider runs 0...1; sweep it up and down, ending mid-way.
                let phase = i % 100
                slider.doubleValue = Double(phase < 50 ? phase : 100 - phase) / 50
                slider.sendAction(slider.action, to: slider.target)
                RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.001))
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            if tracked { cell.stopTracking(last: knobCentre, current: knobCentre, in: slider, mouseIsUp: true) }
            inLoop = false
            spin(0.3)
            return (elapsed * 1000 / Double(n), during, after)
        }

        let drag = measure(tracked: true, n: 300)
        print(String(format: "TUBE_BENCH drag path:   %.3f ms per event, model published %d times during, %d after release (drive now %.1f dB)",
                     drag.ms, drag.publishesDuring, drag.publishesAfter, vm.tube.driveDB))
        let commit = measure(tracked: false, n: 40)
        print(String(format: "TUBE_BENCH commit path: %.3f ms per event, model published %d times during, %d after",
                     commit.ms, commit.publishesDuring, commit.publishesAfter))

        // Release is raised by SwiftUI's cell from its trackMouse wrapper, which
        // this harness does not go through, so the release commit is covered by
        // a real drag rather than asserted here.
        // At most one: SwiftUI raises onEditingChanged(true) from its first
        // update after tracking starts, and this harness provides no update
        // until the first value's deferred commit provokes one. Inside a real
        // tracking loop the run loop turns before the first drag event is
        // dequeued, so the deferral in ParameterRow covers it.
        XCTAssertLessThanOrEqual(drag.publishesDuring, 1, "a drag must not publish through the model per event")
        XCTAssertLessThan(drag.ms, 5, "a drag event must cost well under a frame")
        XCTAssertGreaterThan(commit.publishesDuring, 0, "the untracked path should publish per event")
        XCTAssertGreaterThan(commit.ms, drag.ms * 3, "the drag path should be far cheaper than committing per event")
    }

    /// The live label must occupy exactly the field's frame, so the digits do
    /// not move at grab or release and the row does not change height.
    @MainActor
    func testLiveLabelCoincidesWithField() throws {
        let defaults = UserDefaults.standard
        let hadAdvanced = defaults.object(forKey: "tubeModellerAdvanced")
        defaults.set(true, forKey: "tubeModellerAdvanced")
        defer { if let hadAdvanced { defaults.set(hadAdvanced, forKey: "tubeModellerAdvanced") }
                else { defaults.removeObject(forKey: "tubeModellerAdvanced") } }
        let vm = AppState.shared.viewModel
        vm.firmwareWireFormatVersion = 31
        let controller = TubeModellerWindowController()
        controller.show(vm: vm)
        let window = try XCTUnwrap(NSApp.windows.first { $0.delegate === controller })
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        func all<T: NSView>(_ type: T.Type, in v: NSView) -> [T] {
            (v as? T).map { [$0] } ?? [] + v.subviews.flatMap { all(type, in: $0) }
        }
        let root = try XCTUnwrap(window.contentView)
        let labels = all(LiveValueLabelView.self, in: root)
        XCTAssertGreaterThan(labels.count, 5, "expected a live label per parameter row")
        let fields = all(NSTextField.self, in: root).filter { !($0 is LiveValueLabelView) }
        var checked = 0
        for label in labels {
            let lf = label.convert(label.bounds, to: nil)
            guard let field = fields.first(where: { $0.convert($0.bounds, to: nil).intersects(lf) }) else {
                XCTFail("no text field under a live label at \(lf)"); continue
            }
            let ff = field.convert(field.bounds, to: nil)
            XCTAssertEqual(lf.origin.x, ff.origin.x, accuracy: 0.5, "x")
            XCTAssertEqual(lf.origin.y, ff.origin.y, accuracy: 0.5, "y")
            XCTAssertEqual(lf.size.width, ff.size.width, accuracy: 0.5, "width")
            XCTAssertEqual(lf.size.height, ff.size.height, accuracy: 0.5, "height")
            XCTAssertEqual(label.font?.pointSize, field.font?.pointSize, "font size")
            checked += 1
        }
        print("LIVE_LABEL checked \(checked) labels; first label \(labels.first.map { $0.convert($0.bounds, to: nil) } ?? .zero)")
    }
}
