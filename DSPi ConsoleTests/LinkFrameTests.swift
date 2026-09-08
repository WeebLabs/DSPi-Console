import XCTest
@testable import DSPi_Console

/// Byte-exact tests for the DSPi Link binary data plane
/// (dspi_link_protocol_spec.md section 8), including the two worked examples
/// of section 11.  These are the bytes every other Link implementation has
/// to agree with, so they are asserted literally rather than derived.
final class LinkFrameTests: XCTestCase {

    // MARK: - Helpers

    private func bytes(_ hex: String) -> Data {
        let parts = hex.split(whereSeparator: { $0 == " " || $0 == "\n" })
        return Data(parts.map { UInt8($0, radix: 16)! })
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: - Worked example 11.1, set master volume

    func testWorkedExampleSetMasterVolumeRequest() throws {
        let wire = bytes("01 00 07 00 00 00 D2 00 00 00 02 00 04 00 00 00 A0 C1")
        guard case .cmdRequest(let f) = try LinkFrame.decode(wire) else {
            return XCTFail("expected a CMD request")
        }
        XCTAssertEqual(f.tag, 7)
        XCTAssertEqual(f.handle, 0)
        XCTAssertEqual(f.direction, .set)
        XCTAssertEqual(f.bRequest, 0xD2)
        XCTAssertEqual(f.wValue, 0)
        XCTAssertEqual(f.wIndex, 2)
        XCTAssertEqual(f.wLength, 4)
        XCTAssertEqual(f.payload, bytes("00 00 A0 C1"))
        XCTAssertEqual(f.payload.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }, -20.0)
        XCTAssertEqual(hex(LinkFrame.cmdRequest(f).encode()), hex(wire))
    }

    func testWorkedExampleSetMasterVolumeResponse() throws {
        let wire = bytes("81 00 07 00 00 00 00 00")
        guard case .cmdResponse(let f) = try LinkFrame.decode(wire) else {
            return XCTFail("expected a CMD response")
        }
        XCTAssertEqual(f.tag, 7)
        XCTAssertEqual(f.status, .ok)
        XCTAssertEqual(f.payload.count, 0)
        XCTAssertEqual(hex(LinkFrame.cmdResponse(f).encode()), hex(wire))
    }

    // MARK: - Worked example 11.2, read the platform

    func testWorkedExampleGetPlatform() throws {
        let request = bytes("01 00 08 00 00 01 7F 00 00 00 02 00 06 00")
        guard case .cmdRequest(let req) = try LinkFrame.decode(request) else {
            return XCTFail("expected a CMD request")
        }
        XCTAssertEqual(req.tag, 8)
        XCTAssertEqual(req.direction, .get)
        XCTAssertEqual(req.bRequest, 0x7F)
        XCTAssertEqual(req.wIndex, 2)
        XCTAssertEqual(req.wLength, 6)
        XCTAssertTrue(req.payload.isEmpty, "a GET carries no payload")
        XCTAssertEqual(hex(LinkFrame.cmdRequest(req).encode()), hex(request))

        let response = bytes("81 00 08 00 00 00 06 00 01 01 17 09 01 07")
        guard case .cmdResponse(let resp) = try LinkFrame.decode(response) else {
            return XCTFail("expected a CMD response")
        }
        XCTAssertEqual(resp.tag, 8)
        XCTAssertEqual(resp.status, .ok)
        XCTAssertEqual(resp.payload, bytes("01 01 17 09 01 07"))
        XCTAssertEqual(hex(LinkFrame.cmdResponse(resp).encode()), hex(response))
    }

    /// Section 11.3: one tick of a peak-meter subscription on slot 0.
    func testWorkedExamplePollFrame() throws {
        let payload = Data((0 ..< 27).map { UInt8($0) })
        let wire = bytes("03 00 2A 00 00 00 1B 00") + payload
        guard case .poll(let f) = try LinkFrame.decode(wire) else {
            return XCTFail("expected a POLL frame")
        }
        XCTAssertEqual(f.tag, 0x002A)
        XCTAssertEqual(f.handle, 0)
        XCTAssertEqual(f.slot, 0)
        XCTAssertEqual(f.payload, payload)
        XCTAssertEqual(LinkFrame.poll(f).encode(), wire)
    }

    // MARK: - Round trips

    func testCmdRequestSetRoundTrip() throws {
        let f = LinkCmdRequest(tag: 0x1234, handle: 3, direction: .set, bRequest: 0x42,
                               wValue: 0x0102, wIndex: 2, payload: Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(f.wLength, 5, "wLength must count the payload on a SET")
        let decoded = try LinkFrame.decode(LinkFrame.cmdRequest(f).encode())
        XCTAssertEqual(decoded, .cmdRequest(f))
    }

    /// A SET whose wLength was set by hand still ships the real payload
    /// length, so a hub never reads past the frame.
    func testCmdRequestSetIgnoresLyingLength() throws {
        var f = LinkCmdRequest(tag: 1, handle: 0, direction: .set, bRequest: 0x42,
                               payload: Data([1, 2]))
        f.wLength = 99
        guard case .cmdRequest(let back) = try LinkFrame.decode(LinkFrame.cmdRequest(f).encode()) else {
            return XCTFail("expected a CMD request")
        }
        XCTAssertEqual(back.wLength, 2)
        XCTAssertEqual(back.payload, Data([1, 2]))
    }

    func testCmdRequestGetRoundTrip() throws {
        let f = LinkCmdRequest(tag: 9, handle: 1, direction: .get, bRequest: 0x50,
                               wValue: 9, wIndex: 2, wLength: 27)
        let decoded = try LinkFrame.decode(LinkFrame.cmdRequest(f).encode())
        XCTAssertEqual(decoded, .cmdRequest(f))
    }

    func testCmdResponseRoundTripCarriesStatus() throws {
        for status in [LinkStatus.ok, .busy, .denied, .locked, .badFrame] {
            let f = LinkCmdResponse(tag: 5, status: status, payload: status == .ok ? Data([7, 8]) : Data())
            let decoded = try LinkFrame.decode(LinkFrame.cmdResponse(f).encode())
            XCTAssertEqual(decoded, .cmdResponse(f))
        }
    }

    func testNotifyRoundTrip() throws {
        // A v2 PARAM_CHANGED-shaped packet: version byte first, verbatim.
        let packet = Data([0x02, 0x02, 0x00, 0x11, 0x00, 0x00, 0x00, 0x00, 0x01])
        let f = LinkNotifyFrame(tag: 0xBEEF, handle: 2, origin: 12, packet: packet)
        let decoded = try LinkFrame.decode(LinkFrame.notify(f).encode())
        XCTAssertEqual(decoded, .notify(f))
        guard case .notify(let back) = decoded else { return XCTFail("expected NOTIFY") }
        XCTAssertEqual(back.packet.first, 0x02)
        XCTAssertEqual(back.origin, 12)
    }

    func testPollRoundTrip() throws {
        let f = LinkPollFrame(tag: 77, handle: 0, slot: 15, payload: Data(repeating: 0xA5, count: 80))
        XCTAssertEqual(try LinkFrame.decode(LinkFrame.poll(f).encode()), .poll(f))
    }

    func testFwDataRoundTrip() throws {
        let f = LinkFwDataFrame(tag: 3, offset: 0x0001_0000, data: Data(repeating: 0x5A, count: 256))
        XCTAssertEqual(try LinkFrame.decode(LinkFrame.fwData(f).encode()), .fwData(f))
    }

    func testFwDataAckRoundTrip() throws {
        let f = LinkFwDataAck(tag: 3, offset: 0x0001_0000, status: .ok)
        let wire = LinkFrame.fwDataAck(f).encode()
        XCTAssertEqual(wire.count, 9, "header, offset, status")
        XCTAssertEqual(try LinkFrame.decode(wire), .fwDataAck(f))
    }

    func testResyncRoundTrip() throws {
        let f = LinkResyncFrame(handle: 1, reason: LinkResyncFrame.Reason.deviceReattached.rawValue)
        let wire = LinkFrame.resync(f).encode()
        XCTAssertEqual(wire, Data([0x05, 0x00, 0x00, 0x00, 0x01, 0x01]))
        XCTAssertEqual(try LinkFrame.decode(wire), .resync(f))
        guard case .resync(let back) = try LinkFrame.decode(wire) else { return XCTFail("expected RESYNC") }
        XCTAssertEqual(back.knownReason, .deviceReattached)
    }

    /// A reason from a later minor version still decodes; only its meaning
    /// is unknown.
    func testResyncKeepsUnknownReason() throws {
        guard case .resync(let f) = try LinkFrame.decode(Data([0x05, 0x00, 0x00, 0x00, 0x02, 0x63])) else {
            return XCTFail("expected RESYNC")
        }
        XCTAssertEqual(f.reason, 0x63)
        XCTAssertNil(f.knownReason)
    }

    func testEveryFrameTypeRoundTrips() throws {
        let frames: [LinkFrame] = [
            .cmdRequest(LinkCmdRequest(tag: 1, handle: 0, direction: .set, bRequest: 0xD2,
                                       wValue: 0, wIndex: 2, payload: Data([0, 0, 0xA0, 0xC1]))),
            .cmdResponse(LinkCmdResponse(tag: 1, status: .ok)),
            .notify(LinkNotifyFrame(tag: 2, handle: 0, origin: 4, packet: Data([0x02, 0x01]))),
            .poll(LinkPollFrame(tag: 3, handle: 0, slot: 1, payload: Data([9]))),
            .fwData(LinkFwDataFrame(tag: 4, offset: 8, data: Data([1, 2, 3]))),
            .fwDataAck(LinkFwDataAck(tag: 4, offset: 8, status: .ok)),
            .resync(LinkResyncFrame(handle: 0, reason: 0)),
        ]
        XCTAssertEqual(Set(frames.map { $0.type.rawValue }).count, 7, "one of each type")
        for frame in frames {
            XCTAssertEqual(try LinkFrame.decode(frame.encode()), frame, "round trip of \(frame.type)")
        }
    }

    // MARK: - Flags and reserved bytes

    func testReservedBytesAreZeroAndIgnored() throws {
        let f = LinkCmdRequest(tag: 1, handle: 0, direction: .get, bRequest: 0x7F, wLength: 6)
        let wire = LinkFrame.cmdRequest(f).encode()
        XCTAssertEqual(wire[1], 0, "flags are sent as 0")
        XCTAssertEqual(wire[7], 0, "the byte after bRequest is reserved")

        // Set flags and the reserved byte: the decode must be unchanged.
        var noisy = wire
        noisy[1] = 0xFF
        noisy[7] = 0xFF
        XCTAssertEqual(try LinkFrame.decode(noisy), .cmdRequest(f))
    }

    // MARK: - Errors

    func testUnknownFrameTypeThrowsDistinctError() {
        for raw: UInt8 in [0x00, 0x06, 0x7F, 0x85, 0xFF] {
            XCTAssertThrowsError(try LinkFrame.decode(Data([raw, 0, 0, 0, 0, 0]))) { error in
                XCTAssertEqual(error as? LinkFrameError, .unknownType(raw))
            }
        }
    }

    func testTruncatedHeaderThrows() {
        for count in 0 ..< 4 {
            let data = Data([0x01, 0x00, 0x07, 0x00].prefix(count))
            XCTAssertThrowsError(try LinkFrame.decode(data)) { error in
                XCTAssertEqual(error as? LinkFrameError, .truncated)
            }
        }
    }

    func testTruncatedBodyThrows() {
        let full = bytes("01 00 07 00 00 00 D2 00 00 00 02 00 04 00 00 00 A0 C1")
        for count in 4 ..< full.count {
            XCTAssertThrowsError(try LinkFrame.decode(full.prefix(count))) { error in
                XCTAssertEqual(error as? LinkFrameError, .truncated, "at length \(count)")
            }
        }
    }

    func testTruncatedResponsePayloadThrows() {
        // length says 6, only 2 bytes follow.
        let wire = bytes("81 00 08 00 00 00 06 00 01 01")
        XCTAssertThrowsError(try LinkFrame.decode(wire)) { error in
            XCTAssertEqual(error as? LinkFrameError, .truncated)
        }
    }

    func testUnknownStatusAndDirectionThrow() {
        XCTAssertThrowsError(try LinkFrame.decode(bytes("81 00 01 00 7A 00 00 00"))) { error in
            XCTAssertEqual(error as? LinkFrameError, .unknownStatus(0x7A))
        }
        XCTAssertThrowsError(try LinkFrame.decode(bytes("01 00 01 00 00 09 42 00 00 00 02 00 00 00"))) { error in
            XCTAssertEqual(error as? LinkFrameError, .unknownDirection(0x09))
        }
    }

    /// The decoder must index relative to startIndex, since a WebSocket read
    /// commonly hands out a slice of a larger buffer.
    func testDecodesFromANonZeroBasedSlice() throws {
        let padded = Data([0xEE, 0xEE, 0xEE]) + bytes("81 00 07 00 00 00 00 00")
        let slice = padded[3...]
        XCTAssertNotEqual(slice.startIndex, 0)
        guard case .cmdResponse(let f) = try LinkFrame.decode(slice) else {
            return XCTFail("expected a CMD response")
        }
        XCTAssertEqual(f.tag, 7)
        XCTAssertEqual(f.status, .ok)
    }

    // MARK: - Type table

    func testFrameTypeValues() {
        XCTAssertEqual(LinkFrameType.cmdRequest.rawValue, 0x01)
        XCTAssertEqual(LinkFrameType.cmdResponse.rawValue, 0x81)
        XCTAssertEqual(LinkFrameType.notify.rawValue, 0x02)
        XCTAssertEqual(LinkFrameType.poll.rawValue, 0x03)
        XCTAssertEqual(LinkFrameType.fwData.rawValue, 0x04)
        XCTAssertEqual(LinkFrameType.fwDataAck.rawValue, 0x84)
        XCTAssertEqual(LinkFrameType.resync.rawValue, 0x05)
        XCTAssertEqual(LinkDirection.set.rawValue, 0)
        XCTAssertEqual(LinkDirection.get.rawValue, 1)
    }
}
