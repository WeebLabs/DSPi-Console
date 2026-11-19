import XCTest
@testable import DSPi_Console

/// The Console's reading of the pin map on a real board.  The firmware's own
/// consistency suite (`dspi_test paged_pins`) checks masks against SETs; this
/// checks that the app decodes what the board sends and reacts to a stored
/// pin the way the plan expects.  Skips with no device, and on firmware that
/// predates the queries.
final class PinMapLiveTests: XCTestCase {

    private func requirePinMap() throws -> USBDevice {
        let usb = try HardwareTest.requireDevice()
        if case .failure(.vcUnknown) = usb.get(VC.SYS.PIN_STATE, length: PinStateReply.size) {
            throw XCTSkip("Firmware predates the pin availability queries")
        }
        return usb
    }

    func testRepliesDecodeAndAgree() throws {
        let usb = try requirePinMap()
        let state = try XCTUnwrap(usb.getData(VC.SYS.PIN_STATE, length: PinStateReply.size).flatMap(PinStateReply.decode))
        let claims = try XCTUnwrap(usb.getData(VC.SYS.PIN_CLAIMS, length: PinClaimsReply.requestSize).flatMap(PinClaimsReply.decode))
        XCTAssertEqual(claims.claims.count, Int(state.claimCount))
        XCTAssertEqual(claims.claims.map(\.gpio), claims.claims.map(\.gpio).sorted(), "sorted by GPIO")
        XCTAssertTrue(claims.claims.allSatisfy { $0.function != nil }, "every function ID is known")

        let rp2350 = usb.getData(VC.SYS.PLATFORM, length: 7)?.first == 1
        let shape = PinMapShape(pinOutputs: rp2350 ? 5 : 3, spdifInputs: 1, i2sPairs: 1, csTypes: [])
        for key in shape.keys {
            let result = usb.get(key.command, value: key.address, length: PinAvailability.maxReplySize)
            if case .failure(.vcUnknown) = result, !rp2350, key == .adatTx || key == .adatRx { continue }
            guard case .success(let data) = result else { XCTFail("\(key): \(result)"); continue }
            let a = try XCTUnwrap(PinAvailability.decode(data), "\(key) did not decode (\(data.count) bytes)")
            for row in a.masks {
                for m in row {
                    XCTAssertEqual(m.free & ~m.valid, 0, "\(key): free outside valid")
                    XCTAssertEqual(m.valid & ~state.gpioMask, 0, "\(key): valid outside the GPIO mask")
                }
            }
        }
    }

    /// A disabled optional S/PDIF input: a pin another function holds is
    /// accepted as a stored preference, the reply says a start would be
    /// refused, the enable is refused with the input left off, and the
    /// generation moves.
    func testStoredHeldPinAndRefusedStart() throws {
        let usb = try requirePinMap()
        guard let index = (1...3).first(where: { i in
            usb.getData(VC.INPUT.SPDIF_RX_ENABLE, value: UInt16(i), length: 1)?.first == 0
        }), let pinData = usb.getData(VC.INPUT.SPDIF_RX_PIN, value: UInt16(index), length: 1) else {
            throw XCTSkip("No optional S/PDIF input is disabled")
        }
        let original = pinData[0]
        func avail() throws -> PinAvailability {
            try XCTUnwrap(usb.getData(VC.INPUT.SPDIF_RX_PIN_AVAIL, value: UInt16(index), length: PinAvailability.maxReplySize)
                .flatMap(PinAvailability.decode))
        }
        let before = try avail()
        XCTAssertFalse(before.flags.contains(.inUse))
        guard let held = before.validPins().first(where: { !before.isFree($0) && $0 != original }) else {
            throw XCTSkip("No valid pin is held by another function")
        }
        defer { _ = usb.setAndWait(VC.INPUT.SPDIF_RX_PIN, value: UInt16(index), data: Data([original])) }

        XCTAssertEqual(usb.setAndWait(VC.INPUT.SPDIF_RX_PIN, value: UInt16(index), data: Data([held])), .ok,
                       "a stored pin never conflicts")
        let after = try avail()
        XCTAssertFalse(after.flags.contains(.startOK))
        XCTAssertNotEqual(after.generation, before.generation)

        XCTAssertEqual(usb.setAndWait(VC.INPUT.SPDIF_RX_ENABLE, value: UInt16(index), data: Data([1])), .vcPinInUse)
        XCTAssertEqual(usb.getData(VC.INPUT.SPDIF_RX_ENABLE, value: UInt16(index), length: 1)?.first, 0,
                       "a refused start leaves the input off")
    }
}
