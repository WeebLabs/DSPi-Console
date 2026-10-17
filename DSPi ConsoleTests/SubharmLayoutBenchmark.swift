import XCTest
import SwiftUI
@testable import DSPi_Console

/// What a sub-meter publish costs the Subharmonic window. The meter is polled
/// while the window is open, so this is paid at the poll rate with no user
/// input at all, and any drag rides on top of it.
final class SubharmLayoutBenchmark: XCTestCase {
    @MainActor
    func testMeterPublishCost() throws {
        let vm = AppState.shared.viewModel
        vm.firmwareWireFormatVersion = 31
        let controller = SubharmonicSynthWindowController()
        controller.show(vm: vm)
        let window = try XCTUnwrap(NSApp.windows.first { $0.delegate === controller })
        defer { window.close() }
        func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        spin(0.8)

        let n = 100
        let outs = max(1, vm.numOutputChannels)
        var tPublish = 0.0, tRunLoop = 0.0, tLayout = 0.0, tDisplay = 0.0
        func lap(_ into: inout Double, _ work: () -> Void) {
            let t = CFAbsoluteTimeGetCurrent(); work(); into += CFAbsoluteTimeGetCurrent() - t
        }
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<n {
            lap(&tPublish) { vm.subharm.meter.levels = (0..<outs).map { Float(($0 + i) % 10) / 10 } }
            lap(&tRunLoop) { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001)) }
            lap(&tLayout) { window.contentView?.layoutSubtreeIfNeeded() }
            lap(&tDisplay) { window.displayIfNeeded() }
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(n)
        print(String(format: "SUBHARM_BENCH meter publish: %.2f ms per update (%d outputs): publish %.2f, runloop %.2f, layout %.2f, display %.2f",
                     ms, outs, tPublish * 1000 / Double(n), tRunLoop * 1000 / Double(n), tLayout * 1000 / Double(n), tDisplay * 1000 / Double(n)))
    }

    /// Same question for the Upmixer, whose telemetry the poll timer publishes
    /// at about 16 Hz while its window is open.
    @MainActor
    func testUpmixTelemetryPublishCost() throws {
        let vm = AppState.shared.viewModel
        vm.firmwareWireFormatVersion = 31
        vm.platformName = "RP2350"
        let controller = UpmixerWindowController()
        controller.show(vm: vm)
        let window = try XCTUnwrap(NSApp.windows.first { $0.delegate === controller })
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let n = 100
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<n {
            vm.upmix.telemetry.corr = Float(i % 20) / 10 - 1
            vm.upmix.telemetry.centerGain = Float(i % 10) / 10
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(n)
        print(String(format: "UPMIX_BENCH telemetry publish: %.2f ms per update", ms))
    }
}
