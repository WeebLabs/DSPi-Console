import XCTest
@testable import DSPi_Console

/// Bench checks of the multi-pin apply routine (PinIOApply) on a real board,
/// through the same view-model adapter the app uses.  They move live pins and
/// restart outputs, so they are opt-in: run with TEST_RUNNER_DSPI_PIN_BENCH=1.
/// Each test restores what it changed and checks the board read back as before.
final class PinIOApplyBenchTests: XCTestCase {

    private var vm: DSPViewModel { AppState.shared.viewModel }
    private var transport: DeviceTransport { AppState.shared.transport }

    private func requireBench() throws -> USBDevice {
        guard ProcessInfo.processInfo.environment["DSPI_PIN_BENCH"] == "1" else {
            throw XCTSkip("Opt-in: run with TEST_RUNNER_DSPI_PIN_BENCH=1.")
        }
        let usb = try HardwareTest.requireDevice()
        guard usb.getData(VC.SYS.PIN_STATE, length: PinStateReply.size) != nil else {
            throw XCTSkip("Firmware predates the pin availability queries")
        }
        return usb
    }

    private func u8(_ c: VendorCommand, _ addr: UInt16 = 0) -> UInt8? {
        transport.getData(c, value: addr, length: 1)?.first
    }

    private func avail(_ c: VendorCommand, _ addr: UInt16 = 0) -> PinAvailability? {
        transport.getData(c, value: addr, length: PinAvailability.maxReplySize).flatMap(PinAvailability.decode)
    }

    private var claimed: Set<UInt8> {
        let r = transport.getData(VC.SYS.PIN_CLAIMS, length: PinClaimsReply.requestSize).flatMap(PinClaimsReply.decode)
        return Set(r?.claims.map(\.gpio) ?? [])
    }

    /// The output and clock part of the board's configuration, read raw so the
    /// routine starts from the device's state, not the app's.
    private func outputsAndClocks() throws -> PinIOConfig {
        let slots = vm.numOutputSlots
        var c = PinIOConfig()
        c.slotTypes = try (0..<slots).map { try XCTUnwrap(u8(VC.OUTPUT.TYPE, UInt16($0))) }
        c.outputPins = try (0...slots).map { try XCTUnwrap(u8(VC.OUTPUT.PIN, UInt16($0))) }
        c.bckPins = try [0, 1].map { try XCTUnwrap(u8(VC.CLOCK.I2S_BCK_PIN, $0)) }
        c.clockPinMode = u8(VC.CLOCK.I2S_CLOCK_PIN_MODE)
        c.clockMode = u8(VC.CLOCK.I2S_CLOCK_MODE)
        return c
    }

    private func run(_ current: PinIOConfig, _ target: PinIOConfig, label: String) -> PinIOApply {
        let started = Date()
        let r = PinIOApply(device: ViewModelPinIODevice(vm), current: current, target: target)
        r.run()
        print("[bench] \(label): \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms, problems \(r.problems), notes \(r.notes)")
        return r
    }

    /// Slot 1 running I2S, then the clock pair moved under it.  The routine
    /// parks the slot on S/PDIF, waits for that switch to land, moves the pair
    /// and brings the slot back to I2S.
    func testClockPairMovesUnderRunningI2S() throws {
        _ = try requireBench()
        let original = try outputsAndClocks()
        defer {
            let r = PinIOApply(device: ViewModelPinIODevice(vm), current: (try? outputsAndClocks()) ?? original,
                               target: original)
            r.run()
            XCTAssertEqual(try? outputsAndClocks(), original, "the board is back as it was: \(r.problems)")
        }

        // 1. Slot 1 to I2S on the current pair.
        var i2s = original
        i2s.slotTypes![0] = 1
        let start = run(original, i2s, label: "slot 1 to I2S")
        guard start.problems.isEmpty else {
            throw XCTSkip("Could not start I2S on the current clock pair: \(start.problems)")
        }
        XCTAssertEqual(u8(VC.OUTPUT.TYPE, 0), 1)

        // 2. Move the pair to a free one while the slot runs.
        let bck = try XCTUnwrap(avail(VC.CLOCK.I2S_BCK_PIN_AVAIL, 0))
        XCTAssertEqual(bck.status, VC_ERR_STATE_STATUS, "the pair the outputs run on refuses a direct move")
        let taken = claimed
        guard let newBck = bck.validPins().first(where: { p in
            p != original.bckPins![0] && !taken.contains(p) && !taken.contains(p &+ 1)
        }) else { throw XCTSkip("No free clock pair to move to") }
        var moved = i2s
        moved.bckPins![0] = newBck
        let r = run(try outputsAndClocks(), moved, label: "move BCK to \(newBck) under I2S")
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(u8(VC.CLOCK.I2S_BCK_PIN, 0), newBck)
        XCTAssertEqual(u8(VC.OUTPUT.TYPE, 0), 1, "the slot is back on I2S")
    }

    /// Outputs 1 and 2 swap pins: an output-only swap, broken through a pin
    /// nothing claims, then swapped back.
    func testOutputSwapThroughFreePin() throws {
        _ = try requireBench()
        let original = try outputsAndClocks()
        var swapped = original
        swapped.outputPins!.swapAt(0, 1)
        let r = run(original, swapped, label: "swap outputs 1 and 2")
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(u8(VC.OUTPUT.PIN, 0), original.outputPins![1])
        XCTAssertEqual(u8(VC.OUTPUT.PIN, 1), original.outputPins![0])
        XCTAssertTrue(r.notes.contains { $0.contains("routed through GPIO") })

        let back = run(try outputsAndClocks(), original, label: "swap back")
        XCTAssertEqual(back.problems, [])
        XCTAssertEqual(try outputsAndClocks(), original)
    }

    /// How long the device takes to apply a DAC mute config, against the
    /// 150 ms the app waits before it reads the config back.
    func testDacMuteApplyTime() throws {
        _ = try requireBench()
        let raw = try XCTUnwrap(transport.getData(VC.OUTPUT.DAC_MUTE_CONFIG, length: 16))
        let original = try XCTUnwrap(DacHwMuteConfig.fromData(raw))
        defer {
            _ = transport.setAndWait(VC.OUTPUT.DAC_MUTE_CONFIG, data: original.toData())
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline,
                  transport.getData(VC.OUTPUT.DAC_MUTE_CONFIG, length: 16).flatMap(DacHwMuteConfig.fromData) != original {
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTAssertEqual(transport.getData(VC.OUTPUT.DAC_MUTE_CONFIG, length: 16).flatMap(DacHwMuteConfig.fromData),
                           original, "DAC mute restored")
        }
        let mute = try XCTUnwrap(avail(VC.OUTPUT.DAC_MUTE_PIN_AVAIL))
        let taken = claimed
        guard let pin = mute.freePins().first(where: { !taken.contains($0) && $0 != original.pin }) else {
            throw XCTSkip("No free pin for the DAC mute")
        }
        var test = original
        test.enabled = true
        test.pin = pin
        if test.holdMs < DAC_HW_MUTE_HOLD_MIN_MS { test.holdMs = 5 }   // the firmware refuses 0

        var samples: [Double] = []
        for _ in 0..<5 {
            // Off first, so each pass measures one enable.
            var off = test; off.enabled = false
            _ = transport.setAndWait(VC.OUTPUT.DAC_MUTE_CONFIG, data: off.toData())
            Thread.sleep(forTimeInterval: 0.3)
            let started = Date()
            XCTAssertEqual(transport.setAndWait(VC.OUTPUT.DAC_MUTE_CONFIG, data: test.toData()), .ok)
            var landed: Double?
            while Date().timeIntervalSince(started) < 2 {
                if transport.getData(VC.OUTPUT.DAC_MUTE_CONFIG, length: 16).flatMap(DacHwMuteConfig.fromData) == test {
                    landed = Date().timeIntervalSince(started) * 1000
                    break
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            samples.append(try XCTUnwrap(landed, "the config never read back"))
        }
        print("[bench] DAC mute apply ms: \(samples.map { String(format: "%.1f", $0) }), max \(String(format: "%.1f", samples.max()!))")
        XCTAssertLessThan(samples.max()!, 150, "the app reads back after 150 ms")
    }
}
