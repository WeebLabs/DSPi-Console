import XCTest
@testable import DSPi_Console

/// Live-device tests for File > Import / Export Device Configuration.
///
/// The document is captured from the connected device, mutated, applied, and
/// then read back with INDEPENDENT raw control transfers - so a bug shared
/// between capture and apply cannot make the round trip falsely pass.  The
/// original document is applied again on the way out, restoring whatever the
/// device was set to.
///
/// SKIPs cleanly when no DSPi is attached.
final class PresetDocumentHardwareTests: XCTestCase {

    /// Applies a document and waits for it to finish.  The apply drives its
    /// steps through the main queue, which the XCTest wait spins, so this is a
    /// genuine wait rather than a sleep.
    @discardableResult
    private func apply(_ doc: PresetDocument, to vm: DSPViewModel,
                       options: PresetApplyOptions = PresetApplyOptions(),
                       file: StaticString = #filePath, line: UInt = #line) throws -> PresetApplyReport {
        let finished = expectation(description: "configuration applied")
        var report: PresetApplyReport?
        PresetDocumentApply.apply(doc, to: vm, options: options) {
            report = $0
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        return try XCTUnwrap(report, "apply never reported", file: file, line: line)
    }

    /// Capture, change one value in each block that has a raw read-back, apply,
    /// and confirm the device took all of them.
    func testDocumentRoundTripsThroughTheDevice() throws {
        let usb = try HardwareTest.requireDevice()
        let vm = AppState.shared.viewModel

        let original = PresetDocument.capture(from: vm)
        XCTAssertFalse(original.channels.isEmpty, "captured no channels")
        defer { _ = try? apply(original, to: vm) }

        var modified = original
        modified.global.inputPreampsDb[0] = -7.5

        // Input 0's first band and output 0's gain, found by the same channel
        // refs an import would resolve.
        let platform = vm.platformName
        guard let inputIndex = modified.channels.firstIndex(where: { $0.ref(platform: platform) == .input(0) }),
              let outputIndex = modified.channels.firstIndex(where: { $0.ref(platform: platform) == .output(0) })
        else { return XCTFail("captured document is missing input 0 or output 0") }

        var band = PresetDocument.BandBlock(FilterParams(type: .peaking, freq: 137.0, q: 2.5, gain: -3.5))
        band.bypass = false
        if modified.channels[inputIndex].eq.isEmpty {
            modified.channels[inputIndex].eq = [band]
        } else {
            modified.channels[inputIndex].eq[0] = band
        }
        modified.channels[outputIndex].gainDb = -5.5
        modified.channels[outputIndex].outputDelayMs = 3

        let report = try apply(modified, to: vm)
        XCTAssertGreaterThan(report.channelsApplied, 0, "nothing was applied")

        XCTAssertEqual(HardwareTest.readFloat(usb, REQ_GET_PREAMP_CH, value: 0) ?? .nan, -7.5,
                       accuracy: 0.05, "input preamp did not land on the device")

        // REQ_GET_EQ_PARAM wValue: channel << 8 | band << 3 | param (1 = freq).
        let freqValue = UInt16((0 << 8) | (0 << 3) | 1)
        XCTAssertEqual(HardwareTest.readFloat(usb, REQ_GET_EQ_PARAM, value: freqValue) ?? .nan, 137.0,
                       accuracy: 0.05, "EQ band frequency did not land on the device")

        XCTAssertEqual(HardwareTest.readFloat(usb, REQ_GET_OUTPUT_GAIN, value: 0, index: 2) ?? .nan, -5.5,
                       accuracy: 0.05, "output gain did not land on the device")

        XCTAssertEqual(HardwareTest.readFloat(usb, REQ_GET_OUTPUT_DELAY, value: 0, index: 2) ?? .nan, 3,
                       accuracy: 0.05, "output delay did not land on the device")
    }

    /// Re-applying an untouched capture must leave the device where it was.
    /// This is the case a user hits by exporting and immediately importing, and
    /// it catches any value that capture reads from one place and apply writes
    /// to another.
    func testReapplyingACaptureIsANoOp() throws {
        let usb = try HardwareTest.requireDevice()
        let vm = AppState.shared.viewModel

        let before = PresetDocument.capture(from: vm)
        let gainBefore = HardwareTest.readFloat(usb, REQ_GET_OUTPUT_GAIN, value: 0, index: 2)
        let preampBefore = HardwareTest.readFloat(usb, REQ_GET_PREAMP_CH, value: 0)

        _ = try apply(before, to: vm)

        XCTAssertEqual(HardwareTest.readFloat(usb, REQ_GET_OUTPUT_GAIN, value: 0, index: 2) ?? .nan,
                       gainBefore ?? .nan, accuracy: 0.05, "output gain moved on a no-op apply")
        XCTAssertEqual(HardwareTest.readFloat(usb, REQ_GET_PREAMP_CH, value: 0) ?? .nan,
                       preampBefore ?? .nan, accuracy: 0.05, "input preamp moved on a no-op apply")

        // And the capture itself must be stable: encoding the device twice in a
        // row has to produce the same bytes apart from the timestamp.
        var after = PresetDocument.capture(from: vm)
        after.meta.savedUtc = before.meta.savedUtc
        after.meta.name = before.meta.name
        XCTAssertEqual(try PresetDocumentFile.encode(before), try PresetDocumentFile.encode(after),
                       "two captures of an unchanged device differ")
    }

    /// A document whose channels this device doesn't have is reported rather
    /// than quietly dropped, and the channels it does have still apply.
    func testChannelsThisDeviceLacksAreReported() throws {
        _ = try HardwareTest.requireDevice()
        let vm = AppState.shared.viewModel

        let original = PresetDocument.capture(from: vm)
        defer { _ = try? apply(original, to: vm) }

        var modified = original
        var ghost = PresetDocument.ChannelBlock()
        ghost.channelId = 99            // no platform has this
        ghost.name = "Ghost channel"
        ghost.isOutput = true
        modified.channels.append(ghost)

        let report = try apply(modified, to: vm)
        XCTAssertTrue(report.missingChannels.contains("Ghost channel"),
                      "a channel this device lacks should be named in the report")
        XCTAssertGreaterThan(report.channelsApplied, 0, "the real channels should still have applied")
    }
}
