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
    /// Cached transport once connected, so only the first live-device test pays
    /// the connection wait and the rest return instantly.
    private static var connectedUSB: USBDevice?
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
        if let usb = connectedUSB { return usb }
        if probedAbsent {
            throw XCTSkip("No DSPi connected (VID 0x2E8B / PID 0xFEAA) - skipping live-device tests.")
        }

        let usb = AppState.shared.usb
        let deadline = Date().addingTimeInterval(timeout)
        while !usb.isConnected && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard usb.isConnected else {
            probedAbsent = true
            throw XCTSkip("No DSPi connected (VID 0x2E8B / PID 0xFEAA) - skipping live-device tests.")
        }
        // Let the app's initial fetch-all settle so we read steady state.
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        connectedUSB = usb
        return usb
    }

    /// Synchronous little-endian `Float` read of a vendor GET request. This is
    /// an INDEPENDENT decode path - it does not route through the app's
    /// `fetch*`/parse code - so a shared encode/decode bug cannot make a
    /// round-trip falsely pass.
    static func readFloat(_ usb: USBDevice, _ request: UInt8,
                          value: UInt16, index: UInt16 = 0) -> Float? {
        guard let d = usb.getControlRequest(request: request, value: value, index: index, length: 4),
              d.count == 4 else { return nil }
        return d.withUnsafeBytes { $0.load(as: Float.self) }
    }

    /// Synchronous unsigned-32 read (EQ type / bypass words are 4-byte ints).
    static func readU32(_ usb: USBDevice, _ request: UInt8,
                        value: UInt16, index: UInt16 = 0) -> UInt32? {
        guard let d = usb.getControlRequest(request: request, value: value, index: index, length: 4),
              d.count == 4 else { return nil }
        return d.withUnsafeBytes { $0.load(as: UInt32.self) }
    }

    /// REQ_GET_EQ_PARAM wValue: bits[15:8]=channel, bits[7:3]=band, bits[2:0]=param
    /// (0=type, 1=freq, 2=Q, 3=gain, 4=bypass).
    static func eqWValue(ch: Int, band: Int, param: Int) -> UInt16 {
        UInt16((ch << 8) | (band << 3) | param)
    }
}
