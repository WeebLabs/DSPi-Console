import XCTest
@testable import DSPi_Console

/// Pure-logic tests for the Control Surfaces wire format, capability format v3
/// (control_surfaces_spec.md §2 / §8.2).  Verifies `CsBinding` / `IrCommand`
/// serialization matches the spec's byte-exact hex examples and that every wire
/// struct round-trips at the v3 sizes (24-byte binding, 40-byte caps header,
/// 12-byte noun descriptor, 32-byte status packet, 16-byte IR command).  A
/// wrong byte offset here would silently misconfigure real hardware, so these
/// guard the encoding.  No device.
final class ControlSurfacesWireTests: XCTestCase {

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    // MARK: - Byte-exact spec examples (§8.2)

    /// §8.2a: rotary encoder on GPIO 27/28, master volume, 1 dB/detent, accelerated.
    func testEncoderMasterVolumeExampleBytes() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_ENCODER),       // 0x04
            noun: UInt8(CS_NOUN_MASTER_VOLUME), // 0x01
            action: UInt8(CS_ACT_STEP),         // 0x01
            flags: CS_FLAG_ACCEL,               // 0x08
            gpio0: 27, gpio1: 28,               // 0x1B 0x1C
            step: 256)                          // 1.0 dB in 8.8, at offset 12
        let expected = "04 01 01 08 1b 1c 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00"
        XCTAssertEqual(hex(b.toData()), expected)
        XCTAssertEqual(b.toData().count, 24)
        XCTAssertEqual(csDbToQ8(1.0), 256)
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    /// §8.2b: LED on GPIO 20 indicating loudness is on.
    func testLedLoudnessExampleBytes() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_LED),          // 0x05
            noun: UInt8(CS_NOUN_LOUDNESS),      // 0x03
            action: UInt8(CS_ACT_IND_EQUALS),   // 0x08
            gpio0: 20, gpio1: CS_GPIO_UNUSED,   // 0x14 0xFF
            value: 1)                           // lit while loudness == 1, at offset 10
        let expected = "05 03 08 00 14 ff 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00"
        XCTAssertEqual(hex(b.toData()), expected)
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    /// §8.2c: one button (GPIO 16), three functions distinguished by gesture.
    func testButtonSharedGpioMultiFunctionBytes() {
        // Slot A: short press toggles user mute.
        let a = CsBinding(type: UInt8(CS_TYPE_BUTTON), noun: UInt8(CS_NOUN_USER_MUTE),
                          action: UInt8(CS_ACT_TOGGLE), gpio0: 16, gpio1: CS_GPIO_UNUSED,
                          event: CS_EVENT_PRESS)
        XCTAssertEqual(hex(a.toData()),
            "01 02 04 00 10 ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        // Slot B: long press = next occupied preset, wrap.
        let bnd = CsBinding(type: UInt8(CS_TYPE_BUTTON), noun: UInt8(CS_NOUN_PRESET),
                            action: UInt8(CS_ACT_INC), flags: CS_FLAG_WRAP,
                            gpio0: 16, gpio1: CS_GPIO_UNUSED, event: CS_EVENT_LONG)
        XCTAssertEqual(hex(bnd.toData()),
            "01 06 02 04 10 ff 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        // Slot C: double press cycles the input source, wrap.
        let c = CsBinding(type: UInt8(CS_TYPE_BUTTON), noun: UInt8(CS_NOUN_INPUT_SOURCE),
                          action: UInt8(CS_ACT_INC), flags: CS_FLAG_WRAP,
                          gpio0: 16, gpio1: CS_GPIO_UNUSED, event: CS_EVENT_DOUBLE)
        XCTAssertEqual(hex(c.toData()),
            "01 07 02 04 10 ff 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
    }

    /// §8.2d: sub-crossover frequency pot on GPIO 26, 40..200 Hz, DSP channel 12,
    /// crossover band 20.  Exercises target + index + Hz (plain-int) range fields.
    func testSubCrossoverPotExampleBytes() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_POT), noun: UInt8(CS_NOUN_FILTER_FREQ),
            action: UInt8(CS_ACT_ADJUST), gpio0: 26, gpio1: CS_GPIO_UNUSED,
            target: 12, index: 20,
            rangeMin: 40, rangeMax: 200)        // Hz encodes as a plain integer
        let expected = "03 14 00 00 1a ff 00 0c 14 00 00 00 00 00 28 00 c8 00 00 00 00 00 00 00"
        XCTAssertEqual(hex(b.toData()), expected)
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
        // Hz value is plain-integer encoded (spec §2.1).
        XCTAssertEqual(csEncodeValue(40, unit: CS_UNIT_HZ), 40)
        XCTAssertEqual(csEncodeValue(200, unit: CS_UNIT_HZ), 200)
    }

    /// §8.2e: PWM meter LED on GPIO 21 following output 1's level (DSP channel 8).
    func testPwmMeterLedExampleBytes() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_LED_PWM), noun: UInt8(CS_NOUN_LEVEL),
            action: UInt8(CS_ACT_IND_LEVEL), gpio0: 21, gpio1: CS_GPIO_UNUSED,
            target: 8)
        let expected = "06 1c 0b 00 15 ff 00 08 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"
        XCTAssertEqual(hex(b.toData()), expected)
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    /// §8.2f: hold-to-test momentary siggen button on GPIO 17.
    func testMomentarySiggenExampleBytes() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_BUTTON), noun: UInt8(CS_NOUN_SIGGEN),
            action: UInt8(CS_ACT_MOMENTARY), gpio0: 17, gpio1: CS_GPIO_UNUSED,
            value: 1)
        let expected = "01 19 09 00 11 ff 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00"
        XCTAssertEqual(hex(b.toData()), expected)
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    /// §8.3: a cleared slot is an all-zero 24-byte blob.
    func testClearedBindingIsAllZero() {
        let b = CsBinding()
        XCTAssertEqual(hex(b.toData()), Array(repeating: "00", count: 24).joined(separator: " "))
        XCTAssertEqual(b.toData().count, 24)
        XCTAssertFalse(b.isConfigured)
        XCTAssertEqual(b.gpio1, 0)   // configured single-pin bindings set 0xFF explicitly
    }

    // MARK: - Unit encoding (§2.1)

    func testUnitEncodingRoundTrips() {
        // dB / Q / percent are 8.8 fixed point; Hz / none are plain integers.
        XCTAssertEqual(csEncodeValue(-45.0, unit: CS_UNIT_DB), -11520)
        XCTAssertEqual(csEncodeValue(0.707, unit: CS_UNIT_Q), 181)   // Q 0.707 = 181
        XCTAssertEqual(csEncodeValue(50.0, unit: CS_UNIT_PERCENT), 12800)
        XCTAssertEqual(csEncodeValue(1000.0, unit: CS_UNIT_HZ), 1000)
        XCTAssertEqual(csEncodeValue(2.0, unit: CS_UNIT_NONE), 2)

        XCTAssertEqual(csDecodeValue(181, unit: CS_UNIT_Q), 0.70703125, accuracy: 0.0001)
        XCTAssertEqual(csDecodeValue(1000, unit: CS_UNIT_HZ), 1000, accuracy: 0.0001)

        // Log-unit steps carry octaves in 8.8; the enum step is a plain count.
        XCTAssertEqual(csEncodeStep(1.0, unit: CS_UNIT_HZ), 256)       // one octave
        XCTAssertEqual(csEncodeStep(1.0, unit: CS_UNIT_DB), 256)       // one dB
        XCTAssertEqual(csEncodeStep(3.0, unit: CS_UNIT_NONE), 3)       // three positions
    }

    func testSignedFixedPointRoundTrip() {
        XCTAssertEqual(csDbToQ8(-20.0), Int16(bitPattern: 0xEC00)) // -5120
        XCTAssertEqual(csDbToQ8(-0.5), -128)
        XCTAssertEqual(csQ8ToDb(-5120), -20.0)

        let b = CsBinding(
            type: UInt8(CS_TYPE_POT), noun: UInt8(CS_NOUN_MASTER_VOLUME),
            action: UInt8(CS_ACT_ADJUST), flags: CS_FLAG_REVERSE,
            gpio0: 26, gpio1: CS_GPIO_UNUSED,
            rangeMin: csDbToQ8(-30.0), rangeMax: csDbToQ8(0.0))
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    // MARK: - Caps / noun / status structs (v3 sizes)

    /// The v3 caps header is 4-byte head + 8 CsTypeDesc + a 4-byte tail = 40
    /// bytes; the tail's max_ir_commands sits at offset 4 + 4*type_count.
    func testCapsHeaderRoundTrip() {
        var d = Data([3, 16, 8, 35]) // capsVersion, maxBindings, typeCount, nounCount
        let types: [(UInt16, UInt8, UInt8)] = [
            (0x0000, 0, CS_PINCLASS_ANY),  // NONE
            (0x02BC, 1, CS_PINCLASS_ANY),  // BUTTON
            (0x0040, 1, CS_PINCLASS_ANY),  // SWITCH
            (0x0001, 1, CS_PINCLASS_ADC),  // POT
            (0x0002, 2, CS_PINCLASS_ANY),  // ENCODER
            (0x0500, 1, CS_PINCLASS_ANY),  // LED
            (0x0D00, 1, CS_PINCLASS_ANY),  // LED_PWM
            (0x02BC, 1, CS_PINCLASS_ANY),  // IR (container; its command action set)
        ]
        for (actions, pinCount, pinClass) in types {
            d.append(UInt8(actions & 0xFF)); d.append(UInt8((actions >> 8) & 0xFF))
            d.append(pinCount); d.append(pinClass)
        }
        d.append(contentsOf: [8, 0, 0, 0])   // max_ir_commands + reserved[3]
        XCTAssertEqual(d.count, 40)
        guard let caps = CsCapsHeader.fromData(d) else { return XCTFail("caps parse failed") }
        XCTAssertEqual(caps.capsVersion, 3)
        XCTAssertEqual(caps.maxBindings, 16)
        XCTAssertEqual(caps.typeCount, 8)
        XCTAssertEqual(caps.nounCount, 35)
        XCTAssertEqual(caps.types.count, 8)
        XCTAssertEqual(caps.maxIrCommands, 8)
        XCTAssertEqual(caps.types[Int(CS_TYPE_POT)].pinClass, CS_PINCLASS_ADC)
        XCTAssertEqual(caps.types[Int(CS_TYPE_ENCODER)].pinCount, 2)
        // The PWM LED can drive the level indicator.
        XCTAssertEqual(caps.types[Int(CS_TYPE_LED_PWM)].actions & CS_ACT_BIT(CS_ACT_IND_LEVEL),
                       CS_ACT_BIT(CS_ACT_IND_LEVEL))
        // The IR container's action mask advertises the button repertoire.
        XCTAssertEqual(caps.types[Int(CS_TYPE_IR)].actions, 0x02BC)
    }

    /// A shorter v2 header (7 types, no tail) still parses; max_ir_commands
    /// reads back 0 so IR is treated as unavailable.
    func testCapsHeaderV2CompatNoIrTail() {
        var d = Data([2, 16, 7, 35])
        for _ in 0..<7 { d.append(contentsOf: [0, 0, 1, 0]) }
        XCTAssertEqual(d.count, 32)
        guard let caps = CsCapsHeader.fromData(d) else { return XCTFail("caps parse failed") }
        XCTAssertEqual(caps.typeCount, 7)
        XCTAssertEqual(caps.maxIrCommands, 0)
    }

    /// The v2 noun descriptor is 12 bytes: adds unit / target_kind / target_count
    /// / dflags.  Model a targeted, deferred noun (per-output filter frequency).
    func testNounDescRoundTrip() {
        var d = Data([CS_KIND_CONTINUOUS, 0]) // kind, enumCount
        let actions: UInt16 = 0x0C2F          // CONT-RW
        d.append(UInt8(actions & 0xFF)); d.append(UInt8((actions >> 8) & 0xFF))
        // min 20 Hz, max 20000 Hz (plain integers for CS_UNIT_HZ).
        for v in [Int16(20), Int16(20000)] {
            let u = UInt16(bitPattern: v)
            d.append(UInt8(u & 0xFF)); d.append(UInt8((u >> 8) & 0xFF))
        }
        d.append(CS_UNIT_HZ)          // unit
        d.append(CS_TARGET_DSP_BAND)  // target_kind
        d.append(17)                  // target_count (RP2350 total channels)
        d.append(CS_NDF_DEFERRED)     // dflags
        XCTAssertEqual(d.count, 12)
        guard let nd = CsNounDesc.fromData(d) else { return XCTFail("noun parse failed") }
        XCTAssertEqual(nd.kind, CS_KIND_CONTINUOUS)
        XCTAssertEqual(nd.actions, 0x0C2F)
        XCTAssertEqual(nd.minQ8, 20)
        XCTAssertEqual(nd.maxQ8, 20000)
        XCTAssertEqual(nd.unit, CS_UNIT_HZ)
        XCTAssertEqual(nd.targetKind, CS_TARGET_DSP_BAND)
        XCTAssertEqual(nd.targetCount, 17)
        XCTAssertEqual(nd.dflags, CS_NDF_DEFERRED)
        XCTAssertTrue(nd.isTargeted)
        XCTAssertTrue(nd.hasBand)
    }

    /// The v3 status packet is 32 bytes: byte 3 = dirty, uint16 active_mask
    /// (bytes 4-5), 16 slot-status bytes (6-21), then the IR tail
    /// (ir_active_mask @22, ir_learn_state @23, ir_cmd_status[8] @24-31).
    func testStatusPacketDecode() {
        // lastStatus=SUCCESS, lastSlot=9, maxBindings=16, dirty=1,
        // active_mask = 0x0205 (bits 0, 2, 9 set).
        var d = Data([PIN_CONFIG_SUCCESS, 9, 16, 1, 0x05, 0x02])
        var slots = [UInt8](repeating: 0, count: 16)
        slots[1] = PIN_CONFIG_PIN_IN_USE   // slot 1 kept down by a pin collision
        d.append(contentsOf: slots)
        // IR tail: commands 0 and 2 live, learn state DONE, command 3 failed.
        d.append(0x05)                       // ir_active_mask
        d.append(CS_IR_LEARN_STATE_DONE)     // ir_learn_state
        var irStatus = [UInt8](repeating: 0, count: 8)
        irStatus[3] = CS_STATUS_INVALID_TARGET
        d.append(contentsOf: irStatus)
        XCTAssertEqual(d.count, 32)
        guard let st = CsStatusPacket.fromData(d) else { return XCTFail("status parse failed") }
        XCTAssertEqual(st.lastSlot, 9)
        XCTAssertEqual(st.maxBindings, 16)
        XCTAssertTrue(st.dirty)
        XCTAssertEqual(st.activeMask, 0x0205)
        XCTAssertTrue(st.isSlotActive(0))
        XCTAssertFalse(st.isSlotActive(1))
        XCTAssertTrue(st.isSlotActive(2))
        XCTAssertTrue(st.isSlotActive(9))   // beyond the old 8-slot / u8 limit
        XCTAssertFalse(st.isSlotActive(10))
        XCTAssertEqual(st.slotHealth(1), PIN_CONFIG_PIN_IN_USE)
        // IR tail.
        XCTAssertEqual(st.irActiveMask, 0x05)
        XCTAssertTrue(st.isIrCmdActive(0))
        XCTAssertFalse(st.isIrCmdActive(1))
        XCTAssertTrue(st.isIrCmdActive(2))
        XCTAssertEqual(st.irLearnState, CS_IR_LEARN_STATE_DONE)
        XCTAssertEqual(st.irCmdHealth(3), CS_STATUS_INVALID_TARGET)
    }

    /// A shorter v2 status packet (22 bytes, no IR tail) still parses; the IR
    /// fields read back zero and `dirty` reflects the (previously reserved) byte.
    func testStatusPacketV2CompatNoIrTail() {
        var d = Data([PIN_CONFIG_SUCCESS, 0, 16, 0, 0x01, 0x00])
        d.append(contentsOf: [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(d.count, 22)
        guard let st = CsStatusPacket.fromData(d) else { return XCTFail("status parse failed") }
        XCTAssertFalse(st.dirty)
        XCTAssertTrue(st.isSlotActive(0))
        XCTAssertEqual(st.irActiveMask, 0)
        XCTAssertFalse(st.isIrCmdActive(0))
    }

    // MARK: - IR commands (§2.7) and learn results (§3.6.1)

    /// §8.5: volume-up NEC command, sub-slot 0, INC + repeat, 1 dB step,
    /// code 0xE718FF00.  The IR command is 16 bytes, little-endian.
    func testIrCommandVolumeUpBytes() {
        let c = IrCommand(
            noun: UInt8(CS_NOUN_USER_VOLUME),   // 0x00
            action: UInt8(CS_ACT_INC),          // 0x02
            flags: CS_FLAG_REPEAT,              // 0x10
            proto: CS_IR_PROTO_NEC,             // 0x01, at offset 5
            step: 256,                          // 1.0 dB in 8.8, at offset 8
            code: 0xE718FF00)                   // LE at offset 12
        let expected = "00 02 10 00 00 01 00 00 00 01 00 00 00 ff 18 e7"
        XCTAssertEqual(hex(c.toData()), expected)
        XCTAssertEqual(c.toData().count, 16)
        XCTAssertEqual(IrCommand.fromData(c.toData()), c)
        XCTAssertTrue(c.isConfigured)
    }

    /// An empty sub-slot is all-zero (protocol NONE); clearing sends 16 zeros.
    func testIrCommandEmptyIsAllZero() {
        let c = IrCommand()
        XCTAssertEqual(hex(c.toData()), Array(repeating: "00", count: 16).joined(separator: " "))
        XCTAssertFalse(c.isConfigured)
        XCTAssertEqual(c.proto, CS_IR_PROTO_NONE)
    }

    /// A targeted IR command (per-output mute toggle) round-trips its target/code.
    func testIrCommandTargetedRoundTrip() {
        let c = IrCommand(
            noun: UInt8(CS_NOUN_OUTPUT_MUTE), action: UInt8(CS_ACT_TOGGLE),
            target: 3, proto: CS_IR_PROTO_RC5, value: 1, code: 0x0000_1234)
        XCTAssertEqual(IrCommand.fromData(c.toData()), c)
        XCTAssertEqual(c.toData().count, 16)
    }

    /// The 8-byte learn result: {state, protocol, 0, 0, code_le32}.
    func testIrLearnResultDecode() {
        let d = Data([CS_IR_LEARN_STATE_DONE, CS_IR_PROTO_NEC, 0, 0, 0x00, 0xFF, 0x18, 0xE7])
        guard let r = CsIrLearnResult.fromData(d) else { return XCTFail("learn parse failed") }
        XCTAssertTrue(r.isDone)
        XCTAssertFalse(r.isTimeout)
        XCTAssertEqual(r.proto, CS_IR_PROTO_NEC)
        XCTAssertEqual(r.code, 0xE718FF00)

        let timeout = CsIrLearnResult.fromData(Data([CS_IR_LEARN_STATE_TIMEOUT, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(timeout?.isTimeout, true)
        XCTAssertEqual(timeout?.code, 0)
    }

    // MARK: - Status codes (§3.3) and versions

    func testV3StatusCodeValues() {
        XCTAssertEqual(CS_STATUS_INVALID_TARGET, 0x17)
        XCTAssertEqual(CS_STATUS_INVALID_EVENT, 0x18)
        XCTAssertEqual(CS_STATUS_PWM_CONFLICT, 0x19)
        XCTAssertEqual(CS_STATUS_EVENT_IN_USE, 0x1A)
        XCTAssertEqual(CS_STATUS_BUSY, 0x1B)
        XCTAssertEqual(CS_STATUS_FLASH_ERROR, 0x1C)
        XCTAssertEqual(CS_STATUS_IR_IN_USE, 0x1D)
        XCTAssertEqual(CS_STATUS_NO_IR, 0x1E)
        XCTAssertEqual(CS_MAX_BINDINGS, 16)
        XCTAssertEqual(CS_MAX_IR_COMMANDS, 8)
        XCTAssertEqual(CS_TYPE_IR, 7)
        XCTAssertEqual(CS_CONFIG_VERSION, 2)
        XCTAssertEqual(CS_IR_CONFIG_VERSION, 1)
        // Request codes for the v3 additions.
        XCTAssertEqual(REQ_SET_CS_NAME, 0x8B)
        XCTAssertEqual(REQ_GET_CS_NAME, 0x8C)
        XCTAssertEqual(REQ_SET_CS_IR_CMD, 0x8D)
        XCTAssertEqual(REQ_GET_CS_IR_CMD, 0x8E)
        XCTAssertEqual(REQ_CS_IR_LEARN, 0x8F)
        XCTAssertEqual(REQ_CS_SAVE, 0x9D)
        XCTAssertEqual(REQ_CS_REVERT, 0x9E)
    }
}
