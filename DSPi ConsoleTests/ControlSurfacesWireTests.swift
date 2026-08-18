import XCTest
@testable import DSPi_Console

/// Pure-logic tests for the Control Surfaces wire format, capability format v8
/// (control_surfaces_spec.md §2 / §8.2).  Verifies `CsBinding` / `IrCommand`
/// serialization matches the spec's byte-exact hex examples and that every wire
/// struct round-trips at its current size (24-byte binding, 40-byte caps header,
/// 12-byte noun descriptor, 41-byte status packet since v6, 16-byte IR command;
/// v4, v5, v7 and v8 change no size, though v8 does carve the binding's
/// indicator delays out of its reserved tail).  A wrong byte offset here would
/// silently misconfigure real hardware, so these guard the encoding.  No device.
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
    /// (bytes 4-5), 16 slot-status bytes (6-21), then the v3-v5 IR tail
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

    /// v6 widens the IR tail for 16 sub-slots (§11.2): ir_active_mask becomes a
    /// uint16 at 22, pushing ir_learn_state to 24 and ir_cmd_status[16] to
    /// 25-40, for 41 bytes total.  The prefix through byte 21 is unchanged.
    func testStatusPacketV6Decode() {
        var d = Data([PIN_CONFIG_SUCCESS, CS_LAST_SLOT_IR_FLAG | 12, 16, 1, 0x05, 0x02])
        d.append(contentsOf: [UInt8](repeating: 0, count: 16))
        // IR tail: commands 0, 2 and 12 live - bit 12 only exists in the uint16.
        d.append(contentsOf: [0x05, 0x10])   // ir_active_mask = 0x1005
        d.append(CS_IR_LEARN_STATE_ARMED)    // ir_learn_state @24
        var irStatus = [UInt8](repeating: 0, count: 16)
        irStatus[12] = CS_STATUS_INVALID_TARGET
        d.append(contentsOf: irStatus)
        XCTAssertEqual(d.count, Int(CS_STATUS_LEN))
        guard let st = CsStatusPacket.fromData(d) else { return XCTFail("status parse failed") }
        XCTAssertEqual(st.lastSlot, 0x8C)   // IR sub-slot 12's outcome
        XCTAssertTrue(st.dirty)
        XCTAssertEqual(st.activeMask, 0x0205)
        XCTAssertEqual(st.irActiveMask, 0x1005)
        XCTAssertTrue(st.isIrCmdActive(0))
        XCTAssertFalse(st.isIrCmdActive(1))
        XCTAssertTrue(st.isIrCmdActive(2))
        XCTAssertTrue(st.isIrCmdActive(12))   // beyond the old 8-command / u8 limit
        XCTAssertFalse(st.isIrCmdActive(13))
        // Read at the v3 offsets, byte 23 (the mask's high half) would land here.
        XCTAssertEqual(st.irLearnState, CS_IR_LEARN_STATE_ARMED)
        XCTAssertEqual(st.irCmdHealth(12), CS_STATUS_INVALID_TARGET)
        XCTAssertEqual(st.irCmdHealth(0), PIN_CONFIG_SUCCESS)
    }

    /// A v3-v5 device short-reads the v6-length request: the 32-byte packet must
    /// still parse at the old offsets, with sub-slots 8-15 reading back idle.
    func testStatusPacketV5ShortReadStillParses() {
        var d = Data([PIN_CONFIG_SUCCESS, 0, 16, 0, 0x01, 0x00])
        d.append(contentsOf: [UInt8](repeating: 0, count: 16))
        d.append(0x81)                        // ir_active_mask (u8) @22
        d.append(CS_IR_LEARN_STATE_DONE)      // ir_learn_state @23
        var irStatus = [UInt8](repeating: 0, count: 8)
        irStatus[7] = CS_STATUS_INVALID_VALUE
        d.append(contentsOf: irStatus)
        XCTAssertEqual(d.count, 32)
        guard let st = CsStatusPacket.fromData(d) else { return XCTFail("status parse failed") }
        XCTAssertEqual(st.irActiveMask, 0x0081)
        XCTAssertTrue(st.isIrCmdActive(0))
        XCTAssertTrue(st.isIrCmdActive(7))
        XCTAssertFalse(st.isIrCmdActive(8))   // no bits above 7 exist in the u8 mask
        XCTAssertEqual(st.irLearnState, CS_IR_LEARN_STATE_DONE)
        XCTAssertEqual(st.irCmdHealth(7), CS_STATUS_INVALID_VALUE)
        XCTAssertEqual(st.irCmdHealth(8), 0)
    }

    /// v6 leaves the caps header at 40 bytes; only the version and
    /// max_ir_commands move (§11.2).  Hosts size the command list from the
    /// latter rather than assuming 8.
    func testCapsHeaderV6MaxIrCommands() {
        var d = Data([6, 16, 8, 49])   // capsVersion 6, maxBindings, typeCount, nounCount
        for _ in 0..<8 { d.append(contentsOf: [0xBC, 0x02, 1, CS_PINCLASS_ANY]) }
        d.append(contentsOf: [16, 0, 0, 0])
        XCTAssertEqual(d.count, 40)
        guard let caps = CsCapsHeader.fromData(d) else { return XCTFail("caps parse failed") }
        XCTAssertEqual(caps.capsVersion, 6)
        XCTAssertEqual(caps.maxIrCommands, 16)
        XCTAssertEqual(Int(caps.maxIrCommands), CS_MAX_IR_COMMANDS)
    }

    /// A v6 IR command may address sub-slot 15; the record itself is unchanged
    /// at 16 bytes, and its deferred outcome is reported as 0x80 | sub-slot.
    func testIrCommandHighSubSlotOutcomeEncoding() {
        XCTAssertEqual(CS_LAST_SLOT_IR_FLAG | UInt8(15), 0x8F)
        XCTAssertNotEqual(CS_LAST_SLOT_IR_FLAG | UInt8(15), CS_LAST_SLOT_SAVE)
        let c = IrCommand(
            noun: UInt8(CS_NOUN_USER_MUTE), action: UInt8(CS_ACT_TOGGLE),
            proto: CS_IR_PROTO_RC5, code: 0x0000100D)
        XCTAssertEqual(c.toData().count, 16)
        XCTAssertTrue(c.isConfigured)
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
        XCTAssertEqual(CS_MAX_IR_COMMANDS, 16)   // 8 before caps v6 (§11.2)
        XCTAssertEqual(CS_TYPE_IR, 7)
        XCTAssertEqual(CS_CONFIG_VERSION, 2)
        XCTAssertEqual(CS_IR_CONFIG_VERSION, 2)  // CsIrConfig grew to 16 sub-slots
        XCTAssertEqual(CS_STATUS_LEN, 41)
        // Request codes for the v3 additions.
        XCTAssertEqual(REQ_SET_CS_NAME, 0x8B)
        XCTAssertEqual(REQ_GET_CS_NAME, 0x8C)
        XCTAssertEqual(REQ_SET_CS_IR_CMD, 0x8D)
        XCTAssertEqual(REQ_GET_CS_IR_CMD, 0x8E)
        XCTAssertEqual(REQ_CS_IR_LEARN, 0x8F)
        XCTAssertEqual(REQ_CS_SAVE, 0x9D)
        XCTAssertEqual(REQ_CS_REVERT, 0x9E)
    }

    // MARK: - Caps v4 additions (§11.4)

    /// v4 appends nouns 35-48 without renumbering any earlier value, so a
    /// mis-numbered constant would bind the wrong parameter on real hardware.
    func testV4NounNumbering() {
        XCTAssertEqual(CS_NOUN_LG_MUTED, 34)          // last v3 noun, unmoved
        XCTAssertEqual(CS_NOUN_UPMIX, 35)
        XCTAssertEqual(CS_NOUN_UPMIX_CENTER_MODE, 36)
        XCTAssertEqual(CS_NOUN_UPMIX_SURROUND_MODE, 37)
        XCTAssertEqual(CS_NOUN_UPMIX_STRENGTH, 38)
        XCTAssertEqual(CS_NOUN_UPMIX_WIDTH, 39)
        XCTAssertEqual(CS_NOUN_UPMIX_PRESENCE, 40)
        XCTAssertEqual(CS_NOUN_PSYBASS, 41)
        XCTAssertEqual(CS_NOUN_PSYBASS_CUTOFF, 42)
        XCTAssertEqual(CS_NOUN_PSYBASS_HARMONICS, 43)
        XCTAssertEqual(CS_NOUN_PSYBASS_DRIVE, 44)
        XCTAssertEqual(CS_NOUN_PSYBASS_CHARACTER, 45)
        XCTAssertEqual(CS_NOUN_PSYBASS_ORIGINAL, 46)
        XCTAssertEqual(CS_NOUN_OUTPUT_DELAY, 47)
        XCTAssertEqual(CS_NOUN_PRESET_RELOAD, 48)
    }

    /// `CS_UNIT_MS` (5) is 8.8 milliseconds, stepped linearly, with a 0.1 ms
    /// default step rather than the one-unit default of the other linear units.
    func testMsUnitEncoding() {
        XCTAssertEqual(CS_UNIT_MS, 5)
        XCTAssertTrue(csUnitIsFixedPoint(CS_UNIT_MS))
        XCTAssertFalse(csUnitIsLog(CS_UNIT_MS))
        XCTAssertEqual(csUnitSymbol(CS_UNIT_MS), "ms")

        XCTAssertEqual(csEncodeValue(1.0, unit: CS_UNIT_MS), 256)
        XCTAssertEqual(csEncodeValue(21.0, unit: CS_UNIT_MS), 5376)    // RP2040 max
        XCTAssertEqual(csEncodeValue(42.0, unit: CS_UNIT_MS), 10752)   // RP2350 max
        XCTAssertEqual(csDecodeValue(5376, unit: CS_UNIT_MS), 21.0, accuracy: 0.0001)
        // 0.1 ms is not exactly representable in 8.8; it rounds to 26/256.
        XCTAssertEqual(csEncodeStep(0.1, unit: CS_UNIT_MS), 26)
        XCTAssertEqual(csDecodeStep(26, unit: CS_UNIT_MS), 0.1015625, accuracy: 0.0001)

        // Unit defaults for a step field left at 0 (spec §2.1).
        XCTAssertEqual(csDefaultStep(CS_UNIT_MS), 0.1, accuracy: 0.0001)
        XCTAssertEqual(csDefaultStep(CS_UNIT_DB), 1.0, accuracy: 0.0001)
        XCTAssertEqual(csDefaultStep(CS_UNIT_PERCENT), 1.0, accuracy: 0.0001)
        XCTAssertEqual(csDefaultStep(CS_UNIT_NONE), 1.0, accuracy: 0.0001)
        XCTAssertEqual(csDefaultStep(CS_UNIT_HZ), 1.0 / 12.0, accuracy: 0.0001)
        XCTAssertEqual(csDefaultStep(CS_UNIT_Q), 1.0 / 12.0, accuracy: 0.0001)
        XCTAssertTrue(csUnitIsLog(CS_UNIT_HZ))
        XCTAssertTrue(csUnitIsLog(CS_UNIT_Q))
    }

    /// A v4 caps header is byte-identical to v3 apart from the version and the
    /// grown noun count, so the v3 parser must read it unchanged (§11.4).
    func testCapsHeaderV4SameLayout() {
        var d = Data([4, 16, 8, 49]) // capsVersion 4, maxBindings, typeCount, nounCount 49
        for _ in 0..<8 { d.append(contentsOf: [0xBC, 0x02, 1, CS_PINCLASS_ANY]) }
        d.append(contentsOf: [8, 0, 0, 0])
        XCTAssertEqual(d.count, 40)
        guard let caps = CsCapsHeader.fromData(d) else { return XCTFail("caps parse failed") }
        XCTAssertEqual(caps.capsVersion, 4)
        XCTAssertEqual(caps.nounCount, 49)
        XCTAssertEqual(caps.typeCount, 8)
        XCTAssertEqual(caps.maxIrCommands, 8)
    }

    /// A per-output delay binding: continuous, ms-unit, OUTPUT_CH-targeted.
    /// Encoder stepping 0.5 ms per detent onto output 2.
    func testOutputDelayEncoderBinding() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_ENCODER), noun: UInt8(CS_NOUN_OUTPUT_DELAY),
            action: UInt8(CS_ACT_STEP), gpio0: 10, gpio1: 11,
            target: 2,
            step: csEncodeStep(0.5, unit: CS_UNIT_MS))   // 0.5 ms = 128 in 8.8
        XCTAssertEqual(b.step, 128)
        XCTAssertEqual(hex(b.toData()),
                       "04 2f 01 00 0a 0b 00 02 00 00 00 00 80 00 00 00 00 00 00 00 00 00 00 00")
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    /// A psychoacoustic-bass cutoff pot: Hz unit (plain integer), custom
    /// 30..300 Hz span, on ADC GPIO 27.
    func testPsybassCutoffPotBinding() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_POT), noun: UInt8(CS_NOUN_PSYBASS_CUTOFF),
            action: UInt8(CS_ACT_ADJUST), gpio0: 27, gpio1: CS_GPIO_UNUSED,
            rangeMin: csEncodeValue(30, unit: CS_UNIT_HZ),
            rangeMax: csEncodeValue(300, unit: CS_UNIT_HZ))
        XCTAssertEqual(b.rangeMin, 30)
        XCTAssertEqual(b.rangeMax, 300)
        XCTAssertEqual(hex(b.toData()),
                       "03 2a 00 00 1b ff 00 00 00 00 00 00 00 00 1e 00 2c 01 00 00 00 00 00 00")
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    /// `PRESET_RELOAD` is TRIGGER-only: a button that reloads the active preset.
    func testPresetReloadTriggerBinding() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_BUTTON), noun: UInt8(CS_NOUN_PRESET_RELOAD),
            action: UInt8(CS_ACT_TRIGGER), gpio0: 15, gpio1: CS_GPIO_UNUSED,
            event: CS_EVENT_LONG)
        XCTAssertEqual(hex(b.toData()),
                       "01 30 07 00 0f ff 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    // MARK: - Caps v7 additions (§11.1)

    /// v7 appends the two loudness nouns without renumbering anything earlier
    /// and without touching a structure, so only the numbering can go wrong.
    func testV7NounNumbering() {
        XCTAssertEqual(CS_NOUN_PRESET_RELOAD, 48)     // last v4 noun, unmoved
        XCTAssertEqual(CS_NOUN_LOUDNESS_SPL, 49)
        XCTAssertEqual(CS_NOUN_LOUDNESS_INTENSITY, 50)
    }

    /// A v7 caps header is byte-identical to v6 apart from the version and the
    /// grown noun count (51); the parser must read it unchanged (§11.1).
    func testCapsHeaderV7SameLayout() {
        var d = Data([7, 16, 8, 51])   // capsVersion 7, maxBindings, typeCount, nounCount
        for _ in 0..<8 { d.append(contentsOf: [0xBC, 0x02, 1, CS_PINCLASS_ANY]) }
        d.append(contentsOf: [16, 0, 0, 0])
        XCTAssertEqual(d.count, 40)
        guard let caps = CsCapsHeader.fromData(d) else { return XCTFail("caps parse failed") }
        XCTAssertEqual(caps.capsVersion, 7)
        XCTAssertEqual(caps.nounCount, 51)
        XCTAssertEqual(caps.maxIrCommands, 16)
    }

    /// A loudness reference-SPL pot: dB unit, custom 60..90 span of the noun's
    /// 40..100 dB SPL range, on ADC GPIO 26.
    func testLoudnessSplPotBinding() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_POT), noun: UInt8(CS_NOUN_LOUDNESS_SPL),
            action: UInt8(CS_ACT_ADJUST), gpio0: 26, gpio1: CS_GPIO_UNUSED,
            rangeMin: csEncodeValue(60, unit: CS_UNIT_DB),
            rangeMax: csEncodeValue(90, unit: CS_UNIT_DB))
        // The noun's full range fits 8.8 comfortably at both ends.
        XCTAssertEqual(csEncodeValue(40, unit: CS_UNIT_DB), 10240)
        XCTAssertEqual(csEncodeValue(100, unit: CS_UNIT_DB), 25600)
        XCTAssertEqual(hex(b.toData()),
                       "03 31 00 00 1a ff 00 00 00 00 00 00 00 00 00 3c 00 5a 00 00 00 00 00 00")
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    /// A loudness-intensity encoder stepping 5 % per detent.  The noun stops at
    /// 127 % because 8.8 percent has no room for more in an int16: 128 % would
    /// need 32768 and clamps, which is why the bindable span is capped (§11.1).
    func testLoudnessIntensityEncoderBinding() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_ENCODER), noun: UInt8(CS_NOUN_LOUDNESS_INTENSITY),
            action: UInt8(CS_ACT_STEP), gpio0: 12, gpio1: 13,
            step: csEncodeStep(5, unit: CS_UNIT_PERCENT))   // 5 % = 1280 in 8.8
        XCTAssertEqual(b.step, 1280)
        XCTAssertEqual(csEncodeValue(127, unit: CS_UNIT_PERCENT), 32512)
        XCTAssertEqual(csEncodeValue(128, unit: CS_UNIT_PERCENT), Int16.max)
        XCTAssertEqual(hex(b.toData()),
                       "04 32 01 00 0c 0d 00 00 00 00 00 00 00 05 00 00 00 00 00 00 00 00 00 00")
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    // MARK: - Caps v8 additions (§11.1)

    /// v8 appends one noun and renumbers nothing earlier.
    func testV8NounNumbering() {
        XCTAssertEqual(CS_NOUN_LOUDNESS_INTENSITY, 50)   // last v7 noun, unmoved
        XCTAssertEqual(CS_NOUN_INPUT_LEVEL_MAX, 51)
    }

    /// A v8 caps header is byte-identical to v7 apart from the version and the
    /// grown noun count (52).
    func testCapsHeaderV8SameLayout() {
        var d = Data([8, 16, 8, 52])   // capsVersion 8, maxBindings, typeCount, nounCount
        for _ in 0..<8 { d.append(contentsOf: [0xBC, 0x02, 1, CS_PINCLASS_ANY]) }
        d.append(contentsOf: [16, 0, 0, 0])
        XCTAssertEqual(d.count, 40)
        guard let caps = CsCapsHeader.fromData(d) else { return XCTFail("caps parse failed") }
        XCTAssertEqual(caps.capsVersion, 8)
        XCTAssertEqual(caps.nounCount, 52)
        XCTAssertEqual(caps.maxIrCommands, 16)
    }

    /// §8.2g: an amplifier trigger on GPIO 22.  High the moment any channel of
    /// the active input crosses -50 dB, low only after 10 unbroken minutes
    /// below it.  The delays sit at offsets 18 and 20, inside the bytes v7
    /// required to be zero, so a wrong offset here would have the device reject
    /// the binding (or silently time the wrong edge).
    func testAmplifierTriggerExampleBytes() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_LED),                // 0x05
            noun: UInt8(CS_NOUN_INPUT_LEVEL_MAX),    // 0x33
            action: UInt8(CS_ACT_IND_ABOVE),         // 0x0A
            gpio0: 22, gpio1: CS_GPIO_UNUSED,        // 0x16 0xFF
            value: csEncodeValue(-50, unit: CS_UNIT_DB),
            offDelay: csEncodeDelay(600))            // 600 s = 6000 tenths = 0x1770
        XCTAssertEqual(b.value, -12800)              // -50 dB in 8.8
        XCTAssertEqual(b.offDelay, 6000)
        let expected = "05 33 0a 00 16 ff 00 00 00 00 00 ce 00 00 00 00 00 00 00 00 70 17 00 00"
        XCTAssertEqual(hex(b.toData()), expected)
        XCTAssertEqual(b.toData().count, 24)
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    /// Both delays round-trip independently, at their own offsets, across the
    /// full uint16 span.  A byte swap between them would flip which edge waits.
    func testIndicatorDelaysRoundTrip() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_LED_PWM), noun: UInt8(CS_NOUN_SPDIF_LOCK),
            action: UInt8(CS_ACT_IND_EQUALS), gpio0: 10, gpio1: CS_GPIO_UNUSED,
            value: 1, onDelay: 1, offDelay: UInt16.max)
        let d = b.toData()
        XCTAssertEqual(Array(d[18...19]), [0x01, 0x00])
        XCTAssertEqual(Array(d[20...21]), [0xFF, 0xFF])
        XCTAssertEqual(Array(d[22...23]), [0x00, 0x00])   // reserved2 tail stays zero
        XCTAssertEqual(CsBinding.fromData(d), b)
    }

    /// A pre-v8 binding (all-zero tail) decodes as "no delay", which is exactly
    /// v7 behavior, and a delay-free v8 binding is byte-identical to the v7 one.
    func testPreV8BindingDecodesAsNoDelay() {
        let v7Bytes = Data([0x05, 0x03, 0x08, 0x00, 0x14, 0xFF, 0, 0, 0, 0,
                            0x01, 0x00, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0])
        guard let b = CsBinding.fromData(v7Bytes) else { return XCTFail("parse failed") }
        XCTAssertEqual(b.onDelay, 0)
        XCTAssertEqual(b.offDelay, 0)
        XCTAssertEqual(b.toData(), v7Bytes)
    }

    /// Seconds -> 0.1 s units, saturating rather than wrapping at the top of the
    /// uint16 field: an over-long delay must not silently become a short one.
    func testDelayEncoding() {
        XCTAssertEqual(csEncodeDelay(0), 0)
        XCTAssertEqual(csEncodeDelay(0.1), 1)
        XCTAssertEqual(csEncodeDelay(1.5), 15)
        XCTAssertEqual(csEncodeDelay(600), 6000)
        XCTAssertEqual(csEncodeDelay(-5), 0)                    // clamped, not wrapped
        XCTAssertEqual(csEncodeDelay(CS_DELAY_MAX_SECONDS), UInt16.max)
        XCTAssertEqual(csEncodeDelay(99999), UInt16.max)
        XCTAssertEqual(csDecodeDelay(6000), 600, accuracy: 0.001)
        XCTAssertEqual(csDecodeDelay(csEncodeDelay(12.3)), 12.3, accuracy: 0.001)
    }

    /// `fetchControlSurfaces` indexes the descriptor array by noun number, so a
    /// descriptor it cannot read is filled with a default rather than skipped.
    /// That placeholder only behaves if it reads as "unavailable on this
    /// platform" - the actions == 0 convention the picker already honours.
    func testDefaultNounDescReadsAsUnavailable() {
        XCTAssertEqual(CsNounDesc().actions, 0)
    }

    // MARK: - Caps v9: target groups and macros

    /// v9 appends one noun and renumbers nothing earlier.
    func testV9NounNumbering() {
        XCTAssertEqual(CS_NOUN_INPUT_LEVEL_MAX, 51)   // last v8 noun, unmoved
        XCTAssertEqual(CS_NOUN_MACRO, 52)
    }

    /// The three group flags occupy the free high bits, leaving every earlier
    /// flag where it was.  A collision here would silently repurpose an
    /// existing binding's wiring options.
    func testV9FlagBits() {
        XCTAssertEqual(CS_FLAG_GROUP, 0x20)
        XCTAssertEqual(CS_FLAG_LINK_ABS, 0x40)
        XCTAssertEqual(CS_FLAG_GROUP_ALL, 0x80)
        let earlier: [UInt8] = [CS_FLAG_INVERT, CS_FLAG_REVERSE, CS_FLAG_WRAP,
                                CS_FLAG_ACCEL, CS_FLAG_REPEAT]
        for f in earlier {
            XCTAssertEqual(f & (CS_FLAG_GROUP | CS_FLAG_LINK_ABS | CS_FLAG_GROUP_ALL), 0)
        }
    }

    /// The v9 caps header keeps its 40 bytes and carves max_groups / max_macros
    /// / max_macro_steps out of the three bytes after max_ir_commands.
    func testCapsHeaderV9GroupMacroCounts() {
        var d = Data([9, 16, 8, 53])   // capsVersion 9, maxBindings, typeCount, nounCount
        for _ in 0..<8 { d.append(contentsOf: [0xBC, 0x02, 1, CS_PINCLASS_ANY]) }
        d.append(contentsOf: [16, 8, 8, 8])   // max_ir_commands, groups, macros, steps
        XCTAssertEqual(d.count, 40)
        guard let caps = CsCapsHeader.fromData(d) else { return XCTFail("caps parse failed") }
        XCTAssertEqual(caps.capsVersion, 9)
        XCTAssertEqual(caps.nounCount, 53)
        XCTAssertEqual(caps.maxIrCommands, 16)
        XCTAssertEqual(caps.maxGroups, 8)
        XCTAssertEqual(caps.maxMacros, 8)
        XCTAssertEqual(caps.maxMacroSteps, 8)
    }

    /// A v8 header carries zeros where v9 puts the counts, which must read as
    /// "no groups, no macros" rather than tripping the parser - that zero is
    /// the whole reason the app needs no caps-version test for the feature.
    func testCapsHeaderV8ReadsZeroGroupCounts() {
        var d = Data([8, 16, 8, 52])
        for _ in 0..<8 { d.append(contentsOf: [0xBC, 0x02, 1, CS_PINCLASS_ANY]) }
        d.append(contentsOf: [16, 0, 0, 0])
        guard let caps = CsCapsHeader.fromData(d) else { return XCTFail("caps parse failed") }
        XCTAssertEqual(caps.maxIrCommands, 16)
        XCTAssertEqual(caps.maxGroups, 0)
        XCTAssertEqual(caps.maxMacros, 0)
        XCTAssertEqual(caps.maxMacroSteps, 0)
    }

    /// A pre-v3 header stops before the tail entirely; every count must read 0
    /// instead of running off the end.
    func testCapsHeaderShortTailReadsZeros() {
        var d = Data([2, 16, 7, 35])
        for _ in 0..<7 { d.append(contentsOf: [0xBC, 0x02, 1, CS_PINCLASS_ANY]) }
        XCTAssertEqual(d.count, 32)
        guard let caps = CsCapsHeader.fromData(d) else { return XCTFail("caps parse failed") }
        XCTAssertEqual(caps.maxIrCommands, 0)
        XCTAssertEqual(caps.maxGroups, 0)
        XCTAssertEqual(caps.maxMacroSteps, 0)
    }

    /// A 40-byte group: kind, 32-bit member mask, 32-byte name.
    func testGroupRoundTrip() {
        let g = CsGroup(targetKind: CS_TARGET_OUTPUT_CH,
                        memberMask: 0b1010, name: "Front Pair")
        let d = g.toData()
        XCTAssertEqual(d.count, 40)
        XCTAssertEqual(d[0], CS_TARGET_OUTPUT_CH)
        XCTAssertEqual(Array(d[1...3]), [0, 0, 0])              // reserved
        XCTAssertEqual(Array(d[4...7]), [0x0A, 0x00, 0x00, 0x00])   // mask, little-endian
        XCTAssertEqual(d[8], UInt8(ascii: "F"))
        XCTAssertEqual(d[18], 0)                                 // NUL terminator
        XCTAssertEqual(CsGroup.fromData(d), g)
        XCTAssertEqual(g.members, [1, 3])
        XCTAssertEqual(g.memberCount, 2)
    }

    /// The mask is 32 bits wide because the RP2350 DSP channel space runs past
    /// 16; a 16-bit read would drop the top half of a large group.
    func testGroupMaskIsThirtyTwoBit() {
        let g = CsGroup(targetKind: CS_TARGET_DSP_CH, memberMask: 0x8001_0001, name: "Wide")
        let d = g.toData()
        XCTAssertEqual(Array(d[4...7]), [0x01, 0x00, 0x01, 0x80])
        XCTAssertEqual(CsGroup.fromData(d)?.memberMask, 0x8001_0001)
        XCTAssertEqual(CsGroup.fromData(d)?.members, [0, 16, 31])
    }

    /// An empty group slot is the strict all-zero record, like a cleared binding.
    func testEmptyGroupIsAllZero() {
        XCTAssertEqual(CsGroup().toData(), Data(count: 40))
        XCTAssertFalse(CsGroup().isConfigured)
        // A kind with no members is not a usable group either.
        XCTAssertFalse(CsGroup(targetKind: CS_TARGET_DSP_CH, memberMask: 0).isConfigured)
    }

    /// A 12-byte macro step, grouped, with a delay before it runs.
    func testMacroStepRoundTrip() {
        let st = CsMacroStep(noun: UInt8(CS_NOUN_OUTPUT_MUTE), action: UInt8(CS_ACT_SET),
                             flags: CS_FLAG_GROUP, target: 2, value: 1,
                             preDelay: csEncodeStepDelay(1.5))
        let d = st.toData()
        XCTAssertEqual(d.count, 12)
        XCTAssertEqual(st.preDelay, 150)   // 1.5 s in 10 ms units
        XCTAssertEqual(hex(d), "12 05 20 02 00 00 01 00 00 00 96 00")
        XCTAssertEqual(CsMacroStep.fromData(d), st)
        XCTAssertTrue(st.isGrouped)
    }

    /// An all-zero step record is the empty step the sequencer skips.
    func testEmptyMacroStepIsAllZero() {
        XCTAssertEqual(CsMacroStep().toData(), Data(count: 12))
        XCTAssertFalse(CsMacroStep().isConfigured)
    }

    /// The 36-byte header payload: name then step count.  Steps are written
    /// separately, so this is all a macro SET carries.
    func testMacroHeaderPayload() {
        let macro = CsMacro(name: "Movie", stepCount: 3)
        let d = macro.headerData()
        XCTAssertEqual(d.count, 36)
        XCTAssertEqual(String(decoding: d.prefix(5), as: UTF8.self), "Movie")
        XCTAssertEqual(d[5], 0)             // NUL terminator inside the name field
        XCTAssertEqual(d[32], 3)            // step_count
        XCTAssertEqual(Array(d[33...35]), [0, 0, 0])   // reserved
    }

    /// A 132-byte macro GET decodes name, count and all 8 step records at their
    /// 12-byte stride.  A wrong stride would shuffle the sequence.
    func testMacroDecodeFromWire() {
        var d = Data(count: 132)
        for (i, b) in Array("Night".utf8).enumerated() { d[i] = b }
        d[32] = 2
        // Step 0 at offset 36, step 1 at 48.
        let s0 = CsMacroStep(noun: UInt8(CS_NOUN_INPUT_SOURCE), action: UInt8(CS_ACT_SET), value: 1)
        let s1 = CsMacroStep(noun: UInt8(CS_NOUN_PRESET), action: UInt8(CS_ACT_SET),
                             value: 2, preDelay: 50)
        d.replaceSubrange(36..<48, with: s0.toData())
        d.replaceSubrange(48..<60, with: s1.toData())
        guard let macro = CsMacro.fromData(d) else { return XCTFail("macro parse failed") }
        XCTAssertEqual(macro.name, "Night")
        XCTAssertEqual(macro.stepCount, 2)
        XCTAssertEqual(macro.steps[0], s0)
        XCTAssertEqual(macro.steps[1], s1)
        XCTAssertEqual(macro.steps[2], CsMacroStep())
        XCTAssertEqual(Array(macro.activeSteps), [s0, s1])
    }

    /// A macro name is truncated to 31 bytes so the terminator always survives.
    func testMacroNameTruncatesWithTerminator() {
        let long = String(repeating: "x", count: 60)
        let d = CsMacro(name: long).headerData()
        XCTAssertEqual(d[30], UInt8(ascii: "x"))
        XCTAssertEqual(d[31], 0)   // last name byte stays NUL
        XCTAssertEqual(d[32], 0)   // step_count, not overwritten by the name
    }

    /// The 24-byte extended status: limits, sequencer state, and the two
    /// validity tables at offsets 8 and 16.
    func testExtStatusDecode() {
        var d = Data(count: 24)
        d[0] = 8; d[1] = 8; d[2] = 8
        d[3] = 3                    // macro 3 running
        d[4] = 1                    // on its second step
        d[8 + 2] = CS_STATUS_INVALID_GROUP
        d[16 + 5] = CS_STATUS_INVALID_STEP
        guard let st = CsExtStatusPacket.fromData(d) else { return XCTFail("ext status parse failed") }
        XCTAssertEqual(st.maxGroups, 8)
        XCTAssertEqual(st.maxMacroSteps, 8)
        XCTAssertEqual(st.macroRunning, 3)
        XCTAssertEqual(st.macroStep, 1)
        XCTAssertTrue(st.isRunning)
        XCTAssertEqual(st.groupStatus[2], CS_STATUS_INVALID_GROUP)
        XCTAssertEqual(st.macroStatus[5], CS_STATUS_INVALID_STEP)
    }

    /// An idle sequencer reports 0xFF, which is also the MACRO noun's live read
    /// and matches no IND_EQUALS comparand - that is what keeps macro LEDs dark.
    func testExtStatusIdleSentinel() {
        var d = Data(count: 24)
        d[3] = CS_MACRO_NONE
        let st = CsExtStatusPacket.fromData(d)
        XCTAssertEqual(st?.macroRunning, 0xFF)
        XCTAssertEqual(st?.isRunning, false)
        XCTAssertGreaterThan(Int(CS_MACRO_NONE), CS_MAX_MACROS - 1)
    }

    /// Step delays are 10 ms units, ten times finer than the binding's
    /// indicator delays - mixing the two scales would be off by 10x.
    func testStepDelayEncoding() {
        XCTAssertEqual(csEncodeStepDelay(0), 0)
        XCTAssertEqual(csEncodeStepDelay(0.01), 1)
        XCTAssertEqual(csEncodeStepDelay(1), 100)
        XCTAssertEqual(csEncodeStepDelay(-1), 0)
        XCTAssertEqual(csEncodeStepDelay(CS_STEP_DELAY_MAX_SECONDS), UInt16.max)
        XCTAssertEqual(csEncodeStepDelay(99999), UInt16.max)
        XCTAssertEqual(csDecodeStepDelay(150), 1.5, accuracy: 0.0001)
        // The two delay scales are deliberately different; pin that.
        XCTAssertEqual(csEncodeDelay(1), 10)
        XCTAssertEqual(csEncodeStepDelay(1), 100)
    }

    /// The four deferred-outcome tags must stay mutually distinguishable: one
    /// poll of `lastSlot` has to say which kind of SET just landed.
    func testDeferredOutcomeTagsAreDisjoint() {
        let bindingSlots = (0..<CS_MAX_BINDINGS).map { UInt8($0) }
        let groupTags = (0..<CS_MAX_GROUPS).map { CS_LAST_SLOT_GROUP_FLAG | UInt8($0) }
        let macroTags = (0..<CS_MAX_MACROS).map { CS_LAST_SLOT_MACRO_FLAG | UInt8($0) }
        let irTags = (0..<CS_MAX_IR_COMMANDS).map { CS_LAST_SLOT_IR_FLAG | UInt8($0) }
        let all = bindingSlots + groupTags + macroTags + irTags + [CS_LAST_SLOT_SAVE]
        XCTAssertEqual(Set(all).count, all.count, "deferred outcome tags collide")
    }

    /// A grouped binding is byte-identical to an ungrouped one apart from the
    /// flag bit; `target` changes meaning, not position.
    func testGroupedBindingBytes() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_ENCODER), noun: UInt8(CS_NOUN_OUTPUT_GAIN),
            action: UInt8(CS_ACT_STEP), flags: CS_FLAG_GROUP,
            gpio0: 14, gpio1: 15, target: 1,          // group 1, not channel 1
            step: csEncodeStep(1, unit: CS_UNIT_DB))
        XCTAssertEqual(hex(b.toData()),
                       "04 11 01 20 0e 0f 00 01 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00")
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    /// The indicator delays are entered as whole minutes and seconds, so the
    /// editor's ceiling is the whole second below the field's 6553.5 s.  That
    /// value must still land inside the uint16 rather than saturating, or the
    /// top of the range would silently become "as long as possible".
    func testWholeSecondDelayCeiling() {
        let maxWhole = Int(CS_DELAY_MAX_SECONDS)
        XCTAssertEqual(maxWhole, 6553)
        XCTAssertEqual(maxWhole / 60, 109)      // 109 min
        XCTAssertEqual(maxWhole % 60, 13)       // 13 s
        XCTAssertEqual(csEncodeDelay(Float(maxWhole)), 65530)
        XCTAssertLessThan(csEncodeDelay(Float(maxWhole)), UInt16.max)
        // Whole seconds round-trip exactly, so the fields never drift a tenth
        // each time the card is redrawn.
        for seconds in [0, 1, 59, 60, 600, 3600, maxWhole] {
            XCTAssertEqual(csDecodeDelay(csEncodeDelay(Float(seconds))), Float(seconds),
                           accuracy: 0.0001)
        }
    }

    // MARK: - Caps v10: I2C display, IR groups, four new nouns

    /// v10 appends four nouns and one component type, renumbering nothing.
    func testV10Numbering() {
        XCTAssertEqual(CS_NOUN_MACRO, 52)            // last v9 noun, unmoved
        XCTAssertEqual(CS_NOUN_CPU_LOAD, 53)
        XCTAssertEqual(CS_NOUN_DISPLAY_PAGE, 54)
        XCTAssertEqual(CS_NOUN_DISPLAY_EDIT, 55)
        XCTAssertEqual(CS_NOUN_PAGE_VALUE, 56)
        XCTAssertEqual(CS_TYPE_DISPLAY, 8)
    }

    /// The caps header grew 40 -> 44 at v10 because the type table gained a row.
    /// The tail carrying the IR, group and macro counts therefore moves, and a
    /// parser that looked at a fixed offset would report the whole of v9 absent.
    /// This is the check that a v10 header still yields those counts.
    func testCapsHeaderV10TailMovesWithTypeTable() {
        var d = Data([10, 16, 9, 57])   // caps 10, 16 bindings, 9 types, 57 nouns
        for _ in 0..<9 { d.append(contentsOf: [0xBC, 0x02, 1, CS_PINCLASS_ANY]) }
        d.append(contentsOf: [16, 8, 8, 8])
        XCTAssertEqual(d.count, 44)
        guard let caps = CsCapsHeader.fromData(d) else { return XCTFail("caps parse failed") }
        XCTAssertEqual(caps.capsVersion, 10)
        XCTAssertEqual(caps.typeCount, 9)
        XCTAssertEqual(caps.nounCount, 57)
        XCTAssertEqual(caps.maxIrCommands, 16)
        XCTAssertEqual(caps.maxGroups, 8)
        XCTAssertEqual(caps.maxMacros, 8)
        XCTAssertEqual(caps.maxMacroSteps, 8)
        XCTAssertEqual(caps.types.count, 9)
    }

    /// A v9 header (8 types, 40 bytes) must still parse with its tail intact,
    /// so the same build talks to both firmwares.
    func testCapsHeaderV9StillParsesBesideV10() {
        var d = Data([9, 16, 8, 53])
        for _ in 0..<8 { d.append(contentsOf: [0xBC, 0x02, 1, CS_PINCLASS_ANY]) }
        d.append(contentsOf: [16, 8, 8, 8])
        XCTAssertEqual(d.count, 40)
        guard let caps = CsCapsHeader.fromData(d) else { return XCTFail("caps parse failed") }
        XCTAssertEqual(caps.maxGroups, 8)
        XCTAssertEqual(caps.maxMacroSteps, 8)
    }

    /// The display binding is a container: pins, model in `index`, address in
    /// `value`, everything else zero (strict, like the IR receiver).
    func testDisplayBindingBytes() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_DISPLAY),                 // 0x08
            gpio0: 2, gpio1: 3,                           // SDA even, SCL odd
            index: UInt8(CS_DISP_MODEL_SSD1306_128X64),   // 0x06
            value: 0)                                     // model default address
        XCTAssertEqual(hex(b.toData()),
                       "08 00 00 00 02 03 00 00 06 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    /// 12 bytes, timings in 0.1 s units like the indicator delays.
    func testDisplayCfgRoundTrip() {
        let cfg = CsDisplayCfg(mode: CS_DMODE_CYCLE_SELECTED, homePage: 2,
                               dwell: 50, overlayHold: 20, brightness: 128,
                               flags: CS_DCFG_OVERLAY_ANY | CS_DCFG_EDIT_GATED,
                               editTimeout: 100)
        let d = cfg.toData()
        XCTAssertEqual(d.count, 12)
        XCTAssertEqual(hex(d), "01 02 32 00 14 00 80 03 64 00 00 00")
        XCTAssertEqual(CsDisplayCfg.fromData(d), cfg)
    }

    /// The GET response puts a 4-byte limits header before the config, so the
    /// parser has to skip it - reading from offset 0 would take max_pages as
    /// the mode.
    func testDisplayCfgParsesPastTheLimitsHeader() {
        let cfg = CsDisplayCfg(mode: CS_DMODE_FIXED, homePage: 1, dwell: 30,
                               overlayHold: 20, brightness: 0, flags: 0, editTimeout: 100)
        var d = Data([16, 9, 0, 0])          // max_pages, model_count, reserved
        d.append(cfg.toData())
        XCTAssertEqual(d.count, Int(CS_DISPLAY_CFG_GET_LEN))
        XCTAssertEqual(CsDisplayCfg.fromData(d, offset: 4), cfg)
        XCTAssertEqual(d[d.startIndex], 16)  // the limit the page loop uses
    }

    /// 4 bytes; an all-zero record is an empty slot.
    func testDisplayPageRoundTrip() {
        let page = CsDisplayPage(noun: UInt8(CS_NOUN_OUTPUT_GAIN), target: 2, index: 0,
                                 flags: CS_DPAGE_ACTIVE | CS_DPAGE_LARGE)
        XCTAssertEqual(hex(page.toData()), "11 02 00 05")
        XCTAssertEqual(CsDisplayPage.fromData(page.toData()), page)
        XCTAssertTrue(page.isActive)
        XCTAssertTrue(page.isLarge)
        XCTAssertFalse(page.isGrouped)
        XCTAssertEqual(CsDisplayPage().toData(), Data(count: 4))
        XCTAssertFalse(CsDisplayPage().isActive)
    }

    func testDisplayStatusDecode() {
        var d = Data(count: 8)
        d[0] = CS_DISP_STATE_LIVE
        d[1] = 3
        d[2] = CS_DISP_FLAG_OVERLAY | CS_DISP_FLAG_EDIT
        d[3] = UInt8(CS_DISP_MODEL_LCD1602)
        d[4] = 0x2C; d[5] = 0x01      // 300 aborts, little-endian
        guard let st = CsDisplayStatus.fromData(d) else { return XCTFail("status parse failed") }
        XCTAssertTrue(st.isLive)
        XCTAssertEqual(st.currentPage, 3)
        XCTAssertTrue(st.overlayShowing)
        XCTAssertTrue(st.editArmed)
        XCTAssertEqual(st.nakCount, 300)
    }

    /// The display's deferred tags must stay clear of the binding, group, macro
    /// and IR namespaces, or one poll of `lastSlot` would misattribute a result.
    ///
    /// Within the display's own namespace the config and page 0 deliberately
    /// share `0x50` (the firmware tags the config bare and pages `0x50 | page`).
    /// That is only safe because the host never has two display SETs in flight
    /// - `DSPViewModel` serializes them - so the tag is never ambiguous in
    /// practice. This pins both halves of that contract.
    func testDisplayOutcomeTagsAreDisjoint() {
        var display: [UInt8] = [CS_LAST_SLOT_DISPLAY_FLAG]
        for i in 0..<CS_MAX_DISPLAY_PAGES { display.append(CS_LAST_SLOT_DISPLAY_FLAG | UInt8(i)) }
        var others: [UInt8] = [CS_LAST_SLOT_SAVE]
        for i in 0..<CS_MAX_BINDINGS { others.append(UInt8(i)) }
        for i in 0..<CS_MAX_GROUPS { others.append(CS_LAST_SLOT_GROUP_FLAG | UInt8(i)) }
        for i in 0..<CS_MAX_MACROS { others.append(CS_LAST_SLOT_MACRO_FLAG | UInt8(i)) }
        for i in 0..<CS_MAX_IR_COMMANDS { others.append(CS_LAST_SLOT_IR_FLAG | UInt8(i)) }
        XCTAssertTrue(Set(display).isDisjoint(with: Set(others)))
        // 17 tags, 16 distinct: the config and page 0 are the same byte.
        XCTAssertEqual(display.count, 17)
        XCTAssertEqual(Set(display).count, 16)
        XCTAssertEqual(CS_LAST_SLOT_DISPLAY_FLAG, CS_LAST_SLOT_DISPLAY_FLAG | UInt8(0))
    }

    /// An IR command may address a group at v10.  The record is unchanged - the
    /// flag bit is the same one bindings use and `target` is reinterpreted.
    func testGroupedIrCommandBytes() {
        let c = IrCommand(noun: UInt8(CS_NOUN_OUTPUT_GAIN), action: UInt8(CS_ACT_INC),
                          flags: CS_FLAG_GROUP | CS_FLAG_REPEAT, target: 1,
                          proto: CS_IR_PROTO_NEC, step: 256, code: 0xE718FF00)
        XCTAssertEqual(c.toData().count, 16)
        XCTAssertEqual(hex(c.toData()), "11 02 30 01 00 01 00 00 00 01 00 00 00 ff 18 e7")
        XCTAssertEqual(IrCommand.fromData(c.toData()), c)
    }

    /// A display page's model default: the HD44780 backpacks answer on 0x27,
    /// everything else on 0x3C.
    func testDisplayDefaultAddresses() {
        XCTAssertEqual(csDisplayDefaultAddress(CS_DISP_MODEL_LCD1602), 0x27)
        XCTAssertEqual(csDisplayDefaultAddress(CS_DISP_MODEL_LCD2004), 0x27)
        XCTAssertEqual(csDisplayDefaultAddress(CS_DISP_MODEL_CHAR_OLED_16X2), 0x3C)
        XCTAssertEqual(csDisplayDefaultAddress(CS_DISP_MODEL_SSD1306_128X64), 0x3C)
        // Only the graphic panels render a large font.
        XCTAssertFalse(csDisplayIsGraphic(CS_DISP_MODEL_CHAR_OLED_20X4))
        XCTAssertTrue(csDisplayIsGraphic(CS_DISP_MODEL_SSD1306_128X64))
        XCTAssertTrue(csDisplayIsGraphic(CS_DISP_MODEL_SH1106_128X64))
    }

    /// An IR command driving an upmixer mode: INC + WRAP cycles the enum.
    func testUpmixModeIrCommand() {
        let c = IrCommand(
            noun: UInt8(CS_NOUN_UPMIX_SURROUND_MODE), action: UInt8(CS_ACT_INC),
            flags: CS_FLAG_WRAP, proto: CS_IR_PROTO_NEC,
            step: 1, code: 0xE718FF00)
        XCTAssertEqual(c.toData().count, 16)
        XCTAssertEqual(hex(c.toData()),
                       "25 02 04 00 00 01 00 00 01 00 00 00 00 ff 18 e7")
        XCTAssertEqual(IrCommand.fromData(c.toData()), c)
    }

    // MARK: - Caps v11: per-line display alignment

    /// Both alignments are packed into the config's flags byte, alongside the
    /// two booleans already there.  Nothing about the record grows, so the byte
    /// is the whole contract: label in bits 3:2, value in bits 5:4.
    func testDisplayAlignFieldsPackIntoTheFlagsByte() {
        var cfg = CsDisplayCfg(mode: CS_DMODE_FIXED, homePage: 0, dwell: 30,
                               overlayHold: 20, brightness: 0,
                               flags: CS_DCFG_EDIT_GATED, editTimeout: 100)
        cfg.labelAlign = CS_DALIGN_RIGHT     // 2 << 2 = 0x08
        cfg.valueAlign = CS_DALIGN_CENTRE    // 1 << 4 = 0x10
        XCTAssertEqual(cfg.flags, 0x1A)
        XCTAssertEqual(hex(cfg.toData()), "00 00 1e 00 14 00 00 1a 64 00 00 00")
        XCTAssertEqual(CsDisplayCfg.fromData(cfg.toData()), cfg)
        XCTAssertEqual(CsDisplayCfg.fromData(cfg.toData())?.labelAlign, CS_DALIGN_RIGHT)
        XCTAssertEqual(CsDisplayCfg.fromData(cfg.toData())?.valueAlign, CS_DALIGN_CENTRE)
    }

    /// Each field must write only its own two bits: an editor that let one
    /// alignment clear the other, or either clear the pop-up and edit-gate
    /// booleans, would silently undo settings from the row above it.
    func testDisplayAlignFieldsAreIndependent() {
        var cfg = CsDisplayCfg()
        cfg.flags = CS_DCFG_OVERLAY_ANY | CS_DCFG_EDIT_GATED
        for label in [CS_DALIGN_LEFT, CS_DALIGN_CENTRE, CS_DALIGN_RIGHT] {
            for value in [CS_DALIGN_LEFT, CS_DALIGN_CENTRE, CS_DALIGN_RIGHT] {
                cfg.labelAlign = label
                cfg.valueAlign = value
                XCTAssertEqual(cfg.labelAlign, label)
                XCTAssertEqual(cfg.valueAlign, value)
                XCTAssertEqual(cfg.flags & (CS_DCFG_OVERLAY_ANY | CS_DCFG_EDIT_GATED),
                               CS_DCFG_OVERLAY_ANY | CS_DCFG_EDIT_GATED)
                // Encoding 3 is reserved; nothing here may ever produce it.
                XCTAssertLessThanOrEqual(cfg.labelAlign, CS_DALIGN_RIGHT)
                XCTAssertLessThanOrEqual(cfg.valueAlign, CS_DALIGN_RIGHT)
            }
        }
        // A default config leaves both fields left-aligned, which is what a
        // pre-v11 device demands of the bits it still checks are zero.
        XCTAssertEqual(CsDisplayCfg().flags & (CS_DCFG_LABEL_ALIGN | CS_DCFG_VALUE_ALIGN), 0)
    }

    // MARK: - Caps v12: per-LED brightness ceiling

    /// `base_bright` takes byte 9, the binding's last spare, so the struct is
    /// still 24 bytes and every field after it stays put.
    func testLedBrightnessCeilingByte() {
        let b = CsBinding(type: UInt8(CS_TYPE_LED_PWM), noun: UInt8(CS_NOUN_LEVEL),
                          action: UInt8(CS_ACT_IND_LEVEL),
                          gpio0: 11, gpio1: CS_GPIO_UNUSED, target: 1,
                          baseBright: 40)
        XCTAssertEqual(b.toData().count, 24)
        XCTAssertEqual(hex(b.toData()),
                       "06 1c 0b 00 0b ff 00 01 00 28 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    /// Byte 9 is zero on everything the app builds unless a ceiling is set,
    /// which is what keeps the same binding acceptable to a pre-v12 device -
    /// it rejects any non-zero value there outright.
    func testBindingLeavesBrightnessByteZeroByDefault() {
        XCTAssertEqual(CsBinding().toData()[9], 0)
        let led = CsBinding(type: UInt8(CS_TYPE_LED), noun: UInt8(CS_NOUN_USER_MUTE),
                            action: UInt8(CS_ACT_IND_EQUALS),
                            gpio0: 12, gpio1: CS_GPIO_UNUSED, value: 1)
        XCTAssertEqual(led.toData()[9], 0)
        // Full brightness is expressible either way; both must survive a round
        // trip so a device reporting 100 does not read back as unset.
        for raw: UInt8 in [0, 1, 50, CS_LED_BRIGHT_MAX] {
            var b = CsBinding(type: UInt8(CS_TYPE_LED_PWM), gpio0: 11, gpio1: CS_GPIO_UNUSED)
            b.baseBright = raw
            XCTAssertEqual(CsBinding.fromData(b.toData())?.baseBright, raw)
        }
    }

    // MARK: - Caps v13: display level bars

    /// The bar is one more bit in the page's flags byte; the record stays 4
    /// bytes and the flag sits clear of ACTIVE, GROUP and LARGE.
    func testDisplayPageBarFlag() {
        let page = CsDisplayPage(noun: UInt8(CS_NOUN_OUTPUT_GAIN), target: 2, index: 0,
                                 flags: CS_DPAGE_ACTIVE | CS_DPAGE_BAR)
        XCTAssertEqual(hex(page.toData()), "11 02 00 09")
        XCTAssertEqual(CsDisplayPage.fromData(page.toData()), page)
        XCTAssertTrue(page.hasBar)
        XCTAssertFalse(page.isLarge)
        XCTAssertEqual(CS_DPAGE_BAR, 0x08)
        XCTAssertEqual(CS_DPAGE_ACTIVE | CS_DPAGE_GROUP | CS_DPAGE_LARGE | CS_DPAGE_BAR, 0x0F)
        // A bar and a large value are independent: a graphic panel draws both.
        var both = page
        both.flags |= CS_DPAGE_LARGE
        XCTAssertTrue(both.hasBar)
        XCTAssertTrue(both.isLarge)
        XCTAssertFalse(CsDisplayPage().hasBar)
    }
}
