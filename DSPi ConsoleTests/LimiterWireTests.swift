import XCTest
@testable import DSPi_Console

/// Wire-format and behaviour tests for the Output Limiter (output_limiter_spec.md).
/// The pure-logic tests need no device; the live-device tests SKIP (never fail)
/// when no DSPi is attached, and restore every parameter they touch.
final class LimiterWireTests: XCTestCase {

    // MARK: - Constants (spec §3, §4)

    func testRequestCodeAndIndices() {
        XCTAssertEqual(REQ_LIMITER, 0x81)
        XCTAssertEqual(LIMITER_PARAM_ENABLED, 0)
        XCTAssertEqual(LIMITER_PARAM_THRESHOLD_DB, 1)
        XCTAssertEqual(LIMITER_PARAM_RELEASE_MS, 2)
        XCTAssertEqual(LIMITER_PARAM_LINK_GROUP, 3)
        XCTAssertEqual(LIMITER_NUM_PARAMS, 4)
        XCTAssertEqual(LIMITER_GET_METER, 0x80)
        XCTAssertEqual(LIMITER_GET_STATUS, 0x81)
        XCTAssertEqual(LIMITER_ALL_OUTPUTS, 0xFF)
    }

    func testRangesAndDefaults() {
        XCTAssertEqual(LIMITER_THRESHOLD_MIN, -30)
        XCTAssertEqual(LIMITER_THRESHOLD_MAX, 0)
        XCTAssertEqual(LIMITER_RELEASE_MIN, 10)
        XCTAssertEqual(LIMITER_RELEASE_MAX, 1000)
        XCTAssertEqual(LIMITER_LINK_GROUP_MAX, 4)
        let d = LimiterOutputSettings()
        XCTAssertFalse(d.enabled)
        XCTAssertEqual(d.thresholdDB, -1)
        XCTAssertEqual(d.releaseMs, 100)
        XCTAssertEqual(d.linkGroup, 0)
        XCTAssertEqual(LimiterParameters().outputs.count, WIRE_MAX_OUTPUT_CHANNELS)
    }

    // MARK: - Wire layout (spec §5)

    /// V32 appends WireLimiterParams (9 x 12 bytes) as the final section at
    /// 6028, taking the flat layout to 6136 bytes.
    func testWireFormatSizing() {
        XCTAssertEqual(WIRE_FORMAT_VERSION, 32)
        XCTAssertEqual(BULK_PARAMS_SIZE, 6136)
        XCTAssertEqual(BULK_LIMITER_OFFSET, 6028)
        XCTAssertEqual(WIRE_LIMITER_OUTPUT_SIZE, 12)
        XCTAssertEqual(WIRE_LIMITER_PARAMS_SIZE, 108)
        XCTAssertEqual(BULK_TUBE_OFFSET + WIRE_TUBE_PARAMS_SIZE, BULK_LIMITER_OFFSET)
        XCTAssertEqual(BULK_LIMITER_OFFSET + WIRE_LIMITER_PARAMS_SIZE, Int(BULK_PARAMS_SIZE))
    }

    /// Encodes one record and decodes it at the offsets `fetchAllParams` uses.
    func testBulkRecordRoundTrip() {
        var record = Data(count: WIRE_LIMITER_OUTPUT_SIZE)
        record[0] = 0x01                        // enabled
        record[1] = 3                           // link_group
        var t: Float = -6.5, r: Float = 250
        withUnsafeBytes(of: &t) { record.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: &r) { record.replaceSubrange(8..<12, with: $0) }

        func f(_ off: Int) -> Float { record.withUnsafeBytes { $0.load(fromByteOffset: off, as: Float.self) } }
        XCTAssertTrue(record[0] != 0)
        XCTAssertEqual(Int(record[1]), 3)
        XCTAssertEqual(record[2], 0)   // reserved
        XCTAssertEqual(record[3], 0)
        XCTAssertEqual(f(4), -6.5)
        XCTAssertEqual(f(8), 250)
    }

    // MARK: - App-side mirror

    func testFeatureDetectionThreshold() {
        let vm = DSPViewModel()
        vm.firmwareWireFormatVersion = 31
        XCTAssertFalse(vm.firmwareSupportsLimiter)
        vm.firmwareWireFormatVersion = 32
        XCTAssertTrue(vm.firmwareSupportsLimiter)
    }

    /// The app clamps and rounds exactly as the firmware does, since it never
    /// hears its own writes echoed back.
    func testSettersClampLikeTheFirmware() {
        let vm = DSPViewModel()
        vm.setLimiterThreshold(output: 0, 6)
        XCTAssertEqual(vm.limiter.outputs[0].thresholdDB, LIMITER_THRESHOLD_MAX)
        vm.setLimiterThreshold(output: 0, -99)
        XCTAssertEqual(vm.limiter.outputs[0].thresholdDB, LIMITER_THRESHOLD_MIN)
        vm.setLimiterRelease(output: 0, 1)
        XCTAssertEqual(vm.limiter.outputs[0].releaseMs, LIMITER_RELEASE_MIN)
        vm.setLimiterRelease(output: 0, 5000)
        XCTAssertEqual(vm.limiter.outputs[0].releaseMs, LIMITER_RELEASE_MAX)
        vm.setLimiterLinkGroup(output: 0, 9)
        XCTAssertEqual(vm.limiter.outputs[0].linkGroup, LIMITER_LINK_GROUP_MAX)
        // NaN is ignored by the firmware and never stored; the app agrees.
        vm.setLimiterThreshold(output: 0, .nan)
        XCTAssertEqual(vm.limiter.outputs[0].thresholdDB, LIMITER_THRESHOLD_MIN)
        // An output this platform does not have is ignored.
        vm.setLimiterEnabled(output: vm.numOutputChannels, true)
        XCTAssertFalse(vm.limiter.anyEnabled)
    }

    /// Copying writes threshold, release and enable everywhere and leaves the
    /// link groups alone, which would otherwise all end up in one group.
    func testCopyToAllLeavesLinkGroups() {
        let vm = DSPViewModel()
        vm.setLimiterLinkGroup(output: 1, 2)
        vm.setLimiterThreshold(output: 0, -4)
        vm.setLimiterRelease(output: 0, 300)
        vm.setLimiterEnabled(output: 0, true)
        vm.copyLimiterToAllOutputs(from: 0)
        for k in 0..<vm.numOutputChannels {
            XCTAssertTrue(vm.limiter.outputs[k].enabled)
            XCTAssertEqual(vm.limiter.outputs[k].thresholdDB, -4)
            XCTAssertEqual(vm.limiter.outputs[k].releaseMs, 300)
        }
        XCTAssertEqual(vm.limiter.outputs[1].linkGroup, 2)
        XCTAssertEqual(vm.limiter.outputs[0].linkGroup, 0)
    }

    // MARK: - Live device (skip when no DSPi is attached)

    private func getParam(_ usb: USBDevice, output: Int, _ index: UInt8) -> Float? {
        guard let d = usb.getControlRequest(request: REQ_LIMITER, value: (UInt16(output) << 8) | UInt16(index),
                                            index: 0, length: 4),
              d.count >= 4 else { return nil }
        return d.withUnsafeBytes { $0.load(as: Float.self) }
    }

    private func setParam(_ usb: USBDevice, output: UInt8, _ index: UInt8, _ value: Float) {
        var v = value
        usb.sendControlRequest(request: REQ_LIMITER, value: (UInt16(output) << 8) | UInt16(index),
                               index: 0, data: Data(bytes: &v, count: 4))
    }

    private func status(_ usb: USBDevice) -> Data? {
        guard let d = usb.getControlRequest(request: REQ_LIMITER, value: UInt16(LIMITER_GET_STATUS),
                                            index: 0, length: 4), d.count >= 4 else { return nil }
        return d
    }

    /// Returns the device and its output count, from the status block.
    private func requireLimiter() throws -> (USBDevice, Int) {
        let usb = try HardwareTest.requireDevice()
        guard let s = status(usb) else {
            throw XCTSkip("Firmware has no output limiter (REQ_LIMITER status block STALLed).")
        }
        return (usb, Int(s[3]))
    }

    /// Every parameter of every output, so a test can put the device back.
    private func snapshot(_ usb: USBDevice, outputs: Int) -> [[Float?]] {
        (0..<outputs).map { k in (0..<LIMITER_NUM_PARAMS).map { getParam(usb, output: k, $0) } }
    }

    /// Enables go last, so restoring never briefly engages a limiter on a
    /// setting it did not have.
    private func restore(_ usb: USBDevice, _ snap: [[Float?]]) {
        let order: [UInt8] = [LIMITER_PARAM_THRESHOLD_DB, LIMITER_PARAM_RELEASE_MS,
                              LIMITER_PARAM_LINK_GROUP, LIMITER_PARAM_ENABLED]
        for index in order {
            for (k, params) in snap.enumerated() {
                if let v = params[Int(index)] { setParam(usb, output: UInt8(k), index, v) }
            }
        }
    }

    /// The fixed geometry the spec promises, and an output count that matches
    /// the platform.
    func testStatusBlock() throws {
        let (usb, outputs) = try requireLimiter()
        let s = try XCTUnwrap(status(usb))
        XCTAssertLessThanOrEqual(s[0], 1)
        XCTAssertEqual(Int(s[1]), LIMITER_LOOKAHEAD_SAMPLES)
        XCTAssertEqual(Int(s[2]), LIMITER_BLOCK_SAMPLES)
        XCTAssertTrue(outputs == 5 || outputs == 9, "outputs = \(outputs)")
    }

    /// The meter is one uint16 per output.
    func testMeterLength() throws {
        let (usb, outputs) = try requireLimiter()
        let d = try XCTUnwrap(usb.getControlRequest(request: REQ_LIMITER, value: UInt16(LIMITER_GET_METER),
                                                     index: 0, length: UInt16(outputs * 2)))
        XCTAssertEqual(d.count, outputs * 2)
    }

    /// A bad index or output STALLs a GET.
    func testBadIndexAndOutputStall() throws {
        let (usb, outputs) = try requireLimiter()
        XCTAssertNil(getParam(usb, output: 0, LIMITER_NUM_PARAMS))
        XCTAssertNil(getParam(usb, output: outputs, LIMITER_PARAM_ENABLED))
    }

    /// The bulk section agrees with the indexed GETs for every output.
    func testBulkAgreesWithIndexedGets() throws {
        let (usb, outputs) = try requireLimiter()
        guard let all = usb.getControlRequest(request: REQ_GET_ALL_PARAMS, value: 0, index: 2, length: BULK_PARAMS_SIZE),
              all.count >= Int(BULK_PARAMS_SIZE), Int(all[0]) == WIRE_FORMAT_VERSION else {
            throw XCTSkip("Bulk image is not the current wire format.")
        }
        let snap = snapshot(usb, outputs: outputs)
        for k in 0..<outputs {
            let o = BULK_LIMITER_OFFSET + k * WIRE_LIMITER_OUTPUT_SIZE
            func bf(_ off: Int) -> Float { all.withUnsafeBytes { $0.load(fromByteOffset: o + off, as: Float.self) } }
            XCTAssertEqual(snap[k][Int(LIMITER_PARAM_ENABLED)], all[o] != 0 ? 1 : 0, "out \(k) enabled")
            XCTAssertEqual(snap[k][Int(LIMITER_PARAM_LINK_GROUP)], Float(all[o + 1]), "out \(k) link")
            XCTAssertEqual(snap[k][Int(LIMITER_PARAM_THRESHOLD_DB)], bf(4), "out \(k) threshold")
            XCTAssertEqual(snap[k][Int(LIMITER_PARAM_RELEASE_MS)], bf(8), "out \(k) release")
        }
        // Slots past the device's outputs are zero.
        for k in outputs..<WIRE_MAX_OUTPUT_CHANNELS {
            let o = BULK_LIMITER_OFFSET + k * WIRE_LIMITER_OUTPUT_SIZE
            XCTAssertTrue(all[o..<(o + WIRE_LIMITER_OUTPUT_SIZE)].allSatisfy { $0 == 0 }, "slot \(k)")
        }
    }

    /// Out-of-range values read back clamped, the group rounded.  Leaves every
    /// limiter off, so it cannot trigger the engage fade.
    func testClampsOnDevice() throws {
        let (usb, outputs) = try requireLimiter()
        let snap = snapshot(usb, outputs: outputs)
        defer { restore(usb, snap) }

        setParam(usb, output: 0, LIMITER_PARAM_THRESHOLD_DB, 6)
        XCTAssertEqual(getParam(usb, output: 0, LIMITER_PARAM_THRESHOLD_DB), LIMITER_THRESHOLD_MAX)
        setParam(usb, output: 0, LIMITER_PARAM_THRESHOLD_DB, -99)
        XCTAssertEqual(getParam(usb, output: 0, LIMITER_PARAM_THRESHOLD_DB), LIMITER_THRESHOLD_MIN)
        setParam(usb, output: 0, LIMITER_PARAM_RELEASE_MS, 1)
        XCTAssertEqual(getParam(usb, output: 0, LIMITER_PARAM_RELEASE_MS), LIMITER_RELEASE_MIN)
        setParam(usb, output: 0, LIMITER_PARAM_RELEASE_MS, 9999)
        XCTAssertEqual(getParam(usb, output: 0, LIMITER_PARAM_RELEASE_MS), LIMITER_RELEASE_MAX)
        setParam(usb, output: 0, LIMITER_PARAM_LINK_GROUP, 2.4)
        XCTAssertEqual(getParam(usb, output: 0, LIMITER_PARAM_LINK_GROUP), 2)
        setParam(usb, output: 0, LIMITER_PARAM_LINK_GROUP, 17)
        XCTAssertEqual(getParam(usb, output: 0, LIMITER_PARAM_LINK_GROUP), Float(LIMITER_LINK_GROUP_MAX))
    }

    /// Output 0xFF sets the parameter on every output.
    func testAllOutputsSet() throws {
        let (usb, outputs) = try requireLimiter()
        let snap = snapshot(usb, outputs: outputs)
        defer { restore(usb, snap) }

        setParam(usb, output: LIMITER_ALL_OUTPUTS, LIMITER_PARAM_RELEASE_MS, 420)
        for k in 0..<outputs {
            XCTAssertEqual(getParam(usb, output: k, LIMITER_PARAM_RELEASE_MS), 420, "out \(k)")
        }
    }
}
