import XCTest
@testable import DSPi_Console

/// Shared helpers for the DSPi app test suite.
///
/// The suite has two layers:
///  - **pure-logic** tests (`DSPMathTests`, `PresetSnapshotTests`) that need no
///    device and gate cleanly in a device-less CI, and
///  - **live-device** integration tests (`HardwareIntegrationTests`) that drive
///    the real USB command layer against a connected DSPi.
///
/// Live-device tests SKIP (never fail) when no DSPi is attached.
enum HardwareTest {
    /// Set once we've waited the full timeout without a device, so a device-less
    /// run skips the remaining tests immediately instead of re-waiting each time.
    private static var probedAbsent = false

    /// Returns the shared USB transport once it reports a live connection, or
    /// throws `XCTSkip` if no device appears within `timeout` seconds.
    ///
    /// The host app's USB hot-plug connection can take ~15 s to establish under
    /// `xcodebuild test`, so the timeout is generous; the result is cached so
    /// the cost is paid at most once per run. The run loop is spun while waiting
    /// because IOKit hot-plug notifications are delivered on the main run loop.
    static func requireDevice(timeout: TimeInterval = 30.0) throws -> USBDevice {
        if probedAbsent {
            throw XCTSkip("No DSPi connected (VID 0x2E8B / PID 0xFEAA) - skipping live-device tests.")
        }

        let usb = AppState.shared.usb
        let transport = AppState.shared.transport

        // "Connected" has to be proven, not read off the published flags.  A test
        // that builds its own view model bounces the device (the init reconnects):
        // the handle closes at once while the flags flip later on the main run
        // loop, so a flag check passes on a device that cannot answer.  The probe
        // is a raw read that only succeeds on an open handle; the transport flag
        // covers the hub re-attaching a few ms after USB reopens.  The run loop
        // is spun while waiting because the reopen arrives through IOKit
        // notifications on the main run loop.
        func linkIsLive() -> Bool {
            usb.isConnected && transport.isConnected
                && usb.getData(VC.SYS.PLATFORM, length: 7) != nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !linkIsLive() && !usb.protocolState.isSettledUnattachable && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        // A board on 1.1.6 or older never attaches and refuses every paged
        // request, so the live suites cannot run against it.
        if usb.protocolState.isSettledUnattachable {
            throw XCTSkip("The connected DSPi runs old firmware (not the 1.1.7 paged protocol) - skipping live-device tests.")
        }
        guard linkIsLive() else {
            probedAbsent = true
            throw XCTSkip("No DSPi connected (VID 0x2E8B / PID 0xFEAA) - skipping live-device tests.")
        }
        guard usb.protocolState.isPaged else {
            throw XCTSkip("The connected DSPi runs old firmware (not the 1.1.7 paged protocol) - skipping live-device tests.")
        }
        // Let the app's initial fetch-all settle so we read steady state.
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        return usb
    }

    /// Wait until every write the view model has issued so far has reached the
    /// device.  The view model writes through the DSPi Link hub, whose router
    /// executes the local session's commands in order, so one cheap GET through
    /// the same transport returns only after all earlier writes have run.  The
    /// raw reads below call this first; without it a raw read on the USB serial
    /// queue can overtake a write still crossing the router's queues.
    static func settle() {
        _ = AppState.shared.transport.getData(VC.SYS.PLATFORM, length: 7)
    }

    /// Synchronous little-endian `Float` read of a vendor GET. This is an
    /// INDEPENDENT decode path - it does not route through the app's
    /// `fetch*`/parse code - so a shared encode/decode bug cannot make a
    /// round-trip falsely pass.  Ordered after the view model's writes by
    /// `settle()`.
    static func readFloat(_ usb: USBDevice, _ command: VendorCommand, value: UInt16 = 0) -> Float? {
        settle()
        guard let d = usb.getData(command, value: value, length: 4), d.count == 4 else { return nil }
        return d.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }

    /// Synchronous unsigned-32 read, decoded the same independent way.
    static func readU32(_ usb: USBDevice, _ command: VendorCommand, value: UInt16 = 0) -> UInt32? {
        settle()
        guard let d = usb.getData(command, value: value, length: 4), d.count == 4 else { return nil }
        return d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    /// One FILTER.BAND record, read raw: type u8 @0, bypass u8 @1, Qp x 512
    /// u16 @2, then frequency @4, Q @8 and gain @12 as f32.
    struct BandRecord {
        let type: UInt8
        let bypass: UInt8
        let qp: UInt16
        let freq: Float
        let q: Float
        let gain: Float
    }

    /// FILTER.BAND GET at `(ch << 8) | band`, decoded independently of the
    /// app's band parser.  nil on a refused or short read.
    static func readBand(_ usb: USBDevice, ch: Int, band: Int) -> BandRecord? {
        settle()
        guard let d = usb.getData(VC.FILTER.BAND, value: UInt16((ch << 8) | band), length: 16),
              d.count == 16 else { return nil }
        return d.withUnsafeBytes { b in
            BandRecord(type: b[0], bypass: b[1],
                       qp: b.loadUnaligned(fromByteOffset: 2, as: UInt16.self),
                       freq: b.loadUnaligned(fromByteOffset: 4, as: Float.self),
                       q: b.loadUnaligned(fromByteOffset: 8, as: Float.self),
                       gain: b.loadUnaligned(fromByteOffset: 12, as: Float.self))
        }
    }
}
