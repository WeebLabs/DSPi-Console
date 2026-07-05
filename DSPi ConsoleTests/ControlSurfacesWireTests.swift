import XCTest
@testable import DSPi_Console

/// Pure-logic tests for the Control Surfaces wire format (control_surfaces_spec.md
/// §2 / §8.2). Verifies `CsBinding` serialization matches the spec's byte-exact
/// hex examples and that every wire struct round-trips. A wrong byte offset here
/// would silently misconfigure real hardware, so these guard the encoding. No
/// device required.
final class ControlSurfacesWireTests: XCTestCase {

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Spec §8.2a: rotary encoder on GPIO 27/28, master volume, 1 dB/detent.
    /// Expected bytes: 04 01 01 00 1B 1C 00 00 00 00 00 01 00 00 00 00
    func testEncoderMasterVolumeExampleBytes() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_ENCODER),      // 0x04
            noun: UInt8(CS_NOUN_MASTER_VOLUME), // 0x01
            action: UInt8(CS_ACT_STEP),         // 0x01
            flags: 0,
            gpio0: 27, gpio1: 28,
            value: 0,
            step: 256,                          // 1.0 dB in 8.8 (bytes 00 01)
            rangeMin: 0, rangeMax: 0)
        let expected = "04 01 01 00 1b 1c 00 00 00 00 00 01 00 00 00 00"
        XCTAssertEqual(hex(b.toData()), expected)
        XCTAssertEqual(b.toData().count, 16)
        // 1 dB in 8.8 fixed point.
        XCTAssertEqual(csDbToQ8(1.0), 256)
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    /// Spec §8.2b: LED on GPIO 20 indicating loudness is on.
    /// Expected bytes: 05 03 08 00 14 FF 00 00 01 00 00 00 00 00 00 00
    func testLedLoudnessExampleBytes() {
        let b = CsBinding(
            type: UInt8(CS_TYPE_LED),          // 0x05
            noun: UInt8(CS_NOUN_LOUDNESS),      // 0x03
            action: UInt8(CS_ACT_IND_EQUALS),   // 0x08
            flags: 0,
            gpio0: 20, gpio1: CS_GPIO_UNUSED,   // 14 FF
            value: 1,                           // lit while loudness == 1 (bytes 01 00)
            step: 0, rangeMin: 0, rangeMax: 0)
        let expected = "05 03 08 00 14 ff 00 00 01 00 00 00 00 00 00 00"
        XCTAssertEqual(hex(b.toData()), expected)
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    /// Spec §8.3: a cleared slot is an all-zero blob.
    func testClearedBindingIsAllZero() {
        let b = CsBinding()
        XCTAssertEqual(hex(b.toData()), "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        XCTAssertFalse(b.isConfigured)
        // A default (cleared) binding is the all-zero blob the device stores;
        // configured single-pin bindings set gpio1 to CS_GPIO_UNUSED explicitly.
        XCTAssertEqual(b.gpio1, 0)
    }

    /// Negative dB operands must survive the 8.8 signed round-trip.
    func testSignedFixedPointRoundTrip() {
        XCTAssertEqual(csDbToQ8(-20.0), Int16(bitPattern: 0xEC00)) // -5120
        XCTAssertEqual(csDbToQ8(-0.5), -128)
        XCTAssertEqual(csQ8ToDb(-5120), -20.0)

        // A pot spanning -30..0 dB (custom range) round-trips byte-for-byte.
        let b = CsBinding(
            type: UInt8(CS_TYPE_POT), noun: UInt8(CS_NOUN_MASTER_VOLUME),
            action: UInt8(CS_ACT_ADJUST), flags: CS_FLAG_REVERSE,
            gpio0: 26, gpio1: CS_GPIO_UNUSED,
            value: 0, step: 0,
            rangeMin: csDbToQ8(-30.0), rangeMax: csDbToQ8(0.0))
        XCTAssertEqual(CsBinding.fromData(b.toData()), b)
    }

    /// The caps header parser reads the version-1 layout: 4-byte head + N type
    /// descriptors. Build the spec's version-1 table and parse it back.
    func testCapsHeaderRoundTrip() {
        var d = Data([1, 8, 6, 9]) // capsVersion, maxBindings, typeCount, nounCount
        // Six CsTypeDesc entries (actions LE u16, pinCount, pinClass) per §4.2.
        let types: [(UInt16, UInt8, UInt8)] = [
            (0x0000, 0, CS_PINCLASS_ANY),  // NONE
            (0x00BC, 1, CS_PINCLASS_ANY),  // BUTTON
            (0x0040, 1, CS_PINCLASS_ANY),  // SWITCH
            (0x0001, 1, CS_PINCLASS_ADC),  // POT
            (0x0002, 2, CS_PINCLASS_ANY),  // ENCODER
            (0x0100, 1, CS_PINCLASS_ANY),  // LED
        ]
        for (actions, pinCount, pinClass) in types {
            d.append(UInt8(actions & 0xFF))
            d.append(UInt8((actions >> 8) & 0xFF))
            d.append(pinCount)
            d.append(pinClass)
        }
        XCTAssertEqual(d.count, 28)
        guard let caps = CsCapsHeader.fromData(d) else { return XCTFail("caps parse failed") }
        XCTAssertEqual(caps.capsVersion, 1)
        XCTAssertEqual(caps.maxBindings, 8)
        XCTAssertEqual(caps.typeCount, 6)
        XCTAssertEqual(caps.nounCount, 9)
        XCTAssertEqual(caps.types.count, 6)
        XCTAssertEqual(caps.types[Int(CS_TYPE_POT)].pinClass, CS_PINCLASS_ADC)
        XCTAssertEqual(caps.types[Int(CS_TYPE_ENCODER)].pinCount, 2)
        // The encoder's only action is STEP.
        XCTAssertEqual(caps.types[Int(CS_TYPE_ENCODER)].actions & CS_ACT_BIT(CS_ACT_STEP),
                       CS_ACT_BIT(CS_ACT_STEP))
    }

    /// CsNounDesc: master volume is a continuous -127..0 dB noun (§4.3).
    func testNounDescRoundTrip() {
        var d = Data([CS_KIND_CONTINUOUS, 0]) // kind, enumCount
        let actions: UInt16 = 0x002F          // ADJUST,STEP,INC,DEC,SET
        d.append(UInt8(actions & 0xFF)); d.append(UInt8((actions >> 8) & 0xFF))
        let minQ8 = csDbToQ8(-127.0), maxQ8 = csDbToQ8(0.0)
        for v in [minQ8, maxQ8] {
            let u = UInt16(bitPattern: v)
            d.append(UInt8(u & 0xFF)); d.append(UInt8((u >> 8) & 0xFF))
        }
        XCTAssertEqual(d.count, 8)
        guard let nd = CsNounDesc.fromData(d) else { return XCTFail("noun parse failed") }
        XCTAssertEqual(nd.kind, CS_KIND_CONTINUOUS)
        XCTAssertEqual(nd.actions, 0x002F)
        XCTAssertEqual(csQ8ToDb(nd.minQ8), -127.0)
        XCTAssertEqual(csQ8ToDb(nd.maxQ8), 0.0)
    }

    /// CsStatusPacket: active mask + per-slot health decode.
    func testStatusPacketDecode() {
        // lastStatus=SUCCESS, lastSlot=2, maxBindings=8, activeMask=0b0000_0101
        var d = Data([PIN_CONFIG_SUCCESS, 2, 8, 0x05])
        // slot_status[8]: slot 1 kept down by a pin-in-use collision.
        d.append(contentsOf: [0, PIN_CONFIG_PIN_IN_USE, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(d.count, 12)
        guard let st = CsStatusPacket.fromData(d) else { return XCTFail("status parse failed") }
        XCTAssertEqual(st.lastSlot, 2)
        XCTAssertTrue(st.isSlotActive(0))
        XCTAssertFalse(st.isSlotActive(1))
        XCTAssertTrue(st.isSlotActive(2))
        XCTAssertEqual(st.slotHealth(1), PIN_CONFIG_PIN_IN_USE)
    }
}
