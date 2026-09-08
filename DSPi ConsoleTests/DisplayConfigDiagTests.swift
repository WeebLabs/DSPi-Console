import XCTest
@testable import DSPi_Console

/// Live-device check of the display config round trip, added to answer whether
/// "Pop Up Any Control" fails on the app side or the firmware side.
///
/// It drives the same code the Settings toggle drives - `CsDisplayCfg.toData`,
/// `setCsDisplayCfg`, `fetchCsDisplayCfg` - so a pass means the app encodes the
/// flag, the device accepts it, and it survives a read back. Skips with no DSPi.
final class DisplayConfigDiagTests: XCTestCase {

    /// Reads the display config, flips CS_DCFG_OVERLAY_ANY, reads it back, and
    /// restores whatever was there. Reports the outcome status either way.
    /// Lets the view model's main-thread updates land.  Every fetch publishes
    /// via `DispatchQueue.main.async`, and this test runs on the main thread,
    /// so without yielding here the state it reads is whatever the model was
    /// constructed with.
    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testOverlayAnyFlagRoundTripsThroughTheDevice() throws {
        let usb = try HardwareTest.requireDevice()
        let vm = DSPViewModel(transport: usb)
        vm.fetchControlSurfaces()
        settle(1.0)

        // The whole feature is caps v10; without it there is nothing to test.
        try XCTSkipUnless(vm.csCaps.typeCount > UInt8(CS_TYPE_DISPLAY),
                          "Device predates caps v10 (type_count \(vm.csCaps.typeCount)) - no display component.")

        let pages = vm.fetchCsDisplayCfg()
        settle()
        let original = vm.csDisplayCfg
        print("[diag] caps v\(vm.csCaps.capsVersion) types \(vm.csCaps.typeCount) maxPages \(pages)")
        print("[diag] cfg before: mode \(original.mode) hold \(original.overlayHold) flags 0x\(String(original.flags, radix: 16))")

        // A display must be bound for the config to mean anything, but the
        // config record itself is device-global and settable regardless.
        print("[diag] display slot: \(String(describing: vm.csDisplaySlot))")
        print("[diag] display status: state \(vm.csDisplayStatus.initState) model \(vm.csDisplayStatus.model) naks \(vm.csDisplayStatus.nakCount)")

        // What is actually wired up, and what has a page: the flag only widens
        // control-surface dispatches, so with no non-display control bound
        // there is nothing for it to pop.
        for slot in 0..<min(Int(vm.csCaps.maxBindings), CS_MAX_BINDINGS) {
            let b = vm.csBindings[slot]
            guard b.isConfigured else { continue }
            print("[diag] binding \(slot): type \(b.type) noun \(b.noun) action \(b.action) target \(b.target) gpio \(b.gpio0)/\(b.gpio1) active \(vm.csStatus.isSlotActive(slot))")
        }
        for i in 0..<min(Int(pages), CS_MAX_DISPLAY_PAGES) {
            let p = vm.csDisplayPages[i]
            if p.isActive { print("[diag] page \(i): noun \(p.noun) target \(p.target) flags 0x\(String(p.flags, radix: 16))") }
        }
        // Read the first few page slots straight off the wire, to tell "the
        // device has no pages" apart from "the app fails to read them".
        for i in 0..<4 {
            let raw = usb.getControlRequest(request: REQ_GET_CS_DISPLAY_PAGE, value: UInt16(i),
                                            index: 2, length: CS_DISPLAY_PAGE_LEN)
            let bytes = raw.map { $0.map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "nil"
            print("[diag] raw page \(i): [\(bytes)]")
        }

        var wanted = original
        wanted.flags |= CS_DCFG_OVERLAY_ANY
        // The overlay must be on at all, or the flag has nothing to widen.
        if wanted.overlayHold == 0 { wanted.overlayHold = 20 }

        let status = vm.setCsDisplayCfg(wanted)
        print("[diag] set status: 0x\(String(status, radix: 16))")
        XCTAssertEqual(status, PIN_CONFIG_SUCCESS,
                       "device rejected the config write")

        _ = vm.fetchCsDisplayCfg()
        settle()
        let after = vm.csDisplayCfg
        print("[diag] cfg after: mode \(after.mode) hold \(after.overlayHold) flags 0x\(String(after.flags, radix: 16))")

        XCTAssertNotEqual(after.flags & CS_DCFG_OVERLAY_ANY, 0,
                          "OVERLAY_ANY did not stick on the device")

        // Put it back the way it was.
        _ = vm.setCsDisplayCfg(original)
    }
}
