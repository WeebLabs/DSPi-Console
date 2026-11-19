import XCTest
@testable import DSPi_Console

/// Byte-exact decoding of the pin availability replies
/// (pin_availability_query_spec.md section 8).  No device needed.
final class PinAvailabilityWireTests: XCTestCase {

    private func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
    private func bit(_ pins: UInt8...) -> UInt64 { pins.reduce(0) { $0 | (1 << UInt64($1)) } }

    private func header(status: UInt8 = 0, flags: UInt8 = 0, g: UInt8, r: UInt8, gen: UInt32 = 7) -> [UInt8] {
        [status, flags, g, r] + le(UInt64(gen), 4)
    }

    func testCommandIDs() {
        XCTAssertEqual(VC.SYS.PIN_STATE.id, 0x0150)
        XCTAssertEqual(VC.SYS.PIN_CLAIMS.id, 0x0151)
        XCTAssertEqual(VC.INPUT.SPDIF_RX_PIN_AVAIL.id, 0x0325)
        XCTAssertEqual(VC.INPUT.I2S_RX_PIN_AVAIL.id, 0x0333)
        XCTAssertEqual(VC.INPUT.ADAT_RX_PIN_AVAIL.id, 0x0344)
        XCTAssertEqual(VC.OUTPUT.PIN_AVAIL.id, 0x0412)
        XCTAssertEqual(VC.OUTPUT.ADAT_TX_PIN_AVAIL.id, 0x0433)
        XCTAssertEqual(VC.OUTPUT.DAC_MUTE_PIN_AVAIL.id, 0x0442)
        XCTAssertEqual(VC.CS.BINDING_PIN_AVAIL.id, 0x0A22)
        XCTAssertEqual(VC.XPORT.UART_PIN_AVAIL.id, 0x0B13)
        XCTAssertEqual(VC.XPORT.I2C_PIN_AVAIL.id, 0x0B14)
        XCTAssertEqual(VC.CLOCK.I2S_BCK_PIN_AVAIL.id, 0x0C14)
        XCTAssertEqual(VC.CLOCK.MCK_PIN_AVAIL.id, 0x0C23)
        XCTAssertEqual(VendorCommandRegistry.info(for: VC.CS.BINDING_PIN_AVAIL)?.address, .csSlotType)
    }

    /// A 24-byte single-pin reply.
    func testSinglePinReply() throws {
        let bytes = header(status: 0x18, flags: 0x09, g: 1, r: 1, gen: 0x01020304)
            + le(bit(5, 6, 7), 8) + le(bit(6), 8)
        let a = try XCTUnwrap(PinAvailability.decode(Data(bytes)))
        XCTAssertEqual(a.status, 0x18)
        XCTAssertEqual(a.flags, [.inUse, .startOK])
        XCTAssertEqual(a.generation, 0x01020304)
        XCTAssertEqual(a.groupCount, 1)
        XCTAssertEqual(a.roleCount, 1)
        XCTAssertEqual(a.validPins(), [5, 6, 7])
        XCTAssertEqual(a.freePins(), [6])
        XCTAssertTrue(a.isValid(5))
        XCTAssertFalse(a.isFree(5))
        XCTAssertNil(PinAvailability.decode(Data(bytes.prefix(23))))
    }

    /// The XPORT replies: G = 2, R = 2 (72 bytes), or G = 1 on a platform build (40 bytes).
    func testTwoGroupTwoRoleReply() throws {
        let uart0TX = bit(0, 12), uart0RX = bit(1, 13), uart1TX = bit(4, 8), uart1RX = bit(5, 9)
        var bytes = header(g: 2, r: 2)
        for m in [uart0TX, uart0TX, uart0RX, uart0RX & ~bit(13), uart1TX, uart1TX, uart1RX, uart1RX] { bytes += le(m, 8) }
        XCTAssertEqual(bytes.count, 72)
        let a = try XCTUnwrap(PinAvailability.decode(Data(bytes)))
        XCTAssertEqual(a.groupCount, 2)
        XCTAssertEqual(a.validPins(role: 0), [0, 4, 8, 12])
        XCTAssertEqual(a.freePins(role: 1, group: 0), [1])
        XCTAssertEqual(a.group(of: 9, role: 1), 1)
        XCTAssertTrue(a.pairValid(0, 13))
        XCTAssertFalse(a.pairValid(0, 9), "TX and RX from different instances")
        XCTAssertNil(PinAvailability.decode(Data(bytes.prefix(71))))

        var single = header(g: 1, r: 2)
        for m in [uart0TX, uart0TX, uart0RX, uart0RX] { single += le(m, 8) }
        XCTAssertEqual(single.count, 40)
        let p = try XCTUnwrap(PinAvailability.decode(Data(single)))
        XCTAssertEqual(p.groupCount, 1)
        XCTAssertEqual(p.freePins(role: 1), [1, 13])
    }

    /// The CS reply is always 80 bytes with stride 2, and carries the shareable mask.
    func testControlSurfacesReply() throws {
        // A button: G = 1, R = 1; slot pairs 1..3 unused.
        var bytes = header(status: 0, flags: 0x04, g: 1, r: 1)
        bytes += le(bit(2, 3, 4), 8) + le(bit(2), 8)
        bytes += [UInt8](repeating: 0, count: 48)
        bytes += le(bit(3), 8)
        XCTAssertEqual(bytes.count, 80)
        let a = try XCTUnwrap(PinAvailability.decodeCS(Data(bytes)))
        XCTAssertEqual(a.flags, [.unassigned])
        XCTAssertEqual(a.freePins(), [2])
        XCTAssertTrue(a.isShareable(3))
        XCTAssertFalse(a.isShareable(2))
        XCTAssertNil(PinAvailability.decodeCS(Data(bytes.prefix(79))))

        // A display: G = 2, R = 2, group 1 pairs at offsets 40 and 56.
        var disp = header(g: 2, r: 2)
        for m in [bit(4), bit(4), bit(5), bit(5), bit(6), 0, bit(7), 0] { disp += le(m, 8) }
        disp += le(0, 8)
        let d = try XCTUnwrap(PinAvailability.decodeCS(Data(disp)))
        XCTAssertEqual(d.freePins(role: 0, group: 1), [])
        XCTAssertEqual(d.group(of: 7, role: 1), 1)
    }

    func testPinState() throws {
        let bytes = le(42, 4) + [30, 12] + le(UInt64(1 << 1 | 1 << 4), 2)
            + le(0x3C7F_FFFF, 8) + le(0, 8)
        let s = try XCTUnwrap(PinStateReply.decode(Data(bytes)))
        XCTAssertEqual(s.generation, 42)
        XCTAssertEqual(s.gpioCount, 30)
        XCTAssertEqual(s.claimCount, 12)
        XCTAssertEqual(s.substitutedFunctions, [.output, .mck])
        XCTAssertEqual(s.gpios.count, 23 + 4)
        XCTAssertTrue(s.gpios.contains(29))
        XCTAssertFalse(s.gpios.contains(23))
    }

    func testPinClaims() throws {
        // GPIO 6 active output 0; GPIO 13 stored MCK; GPIO 20 CS slot 3 button (type 1), role 0.
        let bytes = le(9, 4) + [3, 0, 0, 0]
            + [6, 1, 0, 0x00]
            + [13, 4, 0, 0x01]
            + [20, 12, 3, 0x10]
        let r = try XCTUnwrap(PinClaimsReply.decode(Data(bytes)))
        XCTAssertEqual(r.generation, 9)
        XCTAssertEqual(r.claims.count, 3)
        XCTAssertTrue(r.claims[0].isOwned(by: .output, index: 0))
        XCTAssertTrue(r.claims[0].active)
        XCTAssertFalse(r.claims[1].active)
        XCTAssertEqual(r.claims[1].function, .mck)
        XCTAssertEqual(r.claims[2].csType, 1)
        XCTAssertEqual(r.claims[2].function, .controlSurface)
        XCTAssertNil(PinClaimsReply.decode(Data(bytes.dropLast())))
    }

    /// A reply sliced out of a larger buffer still decodes (non-zero startIndex).
    func testSlicedData() throws {
        let bytes: [UInt8] = [0xAA] + header(g: 1, r: 1) + le(bit(1), 8) + le(bit(1), 8)
        let slice = Data(bytes)[1...]
        XCTAssertEqual(try XCTUnwrap(PinAvailability.decode(slice)).freePins(), [1])
    }
}
