//
//  LinkSnapshotCacheTests.swift
//  DSPi ConsoleTests
//

import XCTest
@testable import DSPi_Console

final class LinkSnapshotCacheTests: XCTestCase {

    private func blob(version: UInt8 = 30, count: Int = 5980) -> Data {
        var d = Data(count: count)
        d[0] = version
        return d
    }

    /// A packet in the v2 PARAM_CHANGED shape writing `value` at `offset`.
    private func paramPacket(offset: Int, value: [UInt8]) -> Data {
        var p = Data(count: 12 + value.count)
        p[0] = 0x02; p[1] = 0x02             // version, PARAM_CHANGED
        p[4] = UInt8(offset & 0xFF); p[5] = UInt8((offset >> 8) & 0xFF)
        p[6] = UInt8(value.count & 0xFF); p[7] = UInt8((value.count >> 8) & 0xFF)
        for (i, byte) in value.enumerated() { p[12 + i] = byte }
        return p
    }

    func testSnapshotMissesUntilBulkSet() {
        let c = SnapshotCache()
        XCTAssertNil(c.snapshot())
        c.setBulk(blob())
        XCTAssertNotNil(c.snapshot())
        XCTAssertEqual(c.snapshot()?.wireVersion, 30)
    }

    func testParamChangePatchesInPlace() {
        let c = SnapshotCache()
        c.setBulk(blob())
        XCTAssertTrue(c.applyParamChange(packet: paramPacket(offset: 16, value: [0xAA, 0xBB, 0xCC, 0xDD])))
        let snap = c.snapshot()!
        XCTAssertEqual([UInt8](snap.bulk[16..<20]), [0xAA, 0xBB, 0xCC, 0xDD])
    }

    func testParamChangeIgnoredWhenBlobAbsent() {
        let c = SnapshotCache()
        XCTAssertFalse(c.applyParamChange(packet: paramPacket(offset: 16, value: [1,2,3,4])))
    }

    func testOutOfRangePatchIgnored() {
        let c = SnapshotCache()
        c.setBulk(blob(count: 100))
        XCTAssertFalse(c.applyParamChange(packet: paramPacket(offset: 98, value: [1,2,3,4])),
                       "a patch running past the end must not corrupt the blob")
        XCTAssertNotNil(c.snapshot())
    }

    func testNonParamPacketIgnored() {
        let c = SnapshotCache()
        c.setBulk(blob())
        var idle = Data([0x02, 0x00, 0, 0])   // not PARAM_CHANGED
        idle.append(contentsOf: [0,0,0,0])
        XCTAssertFalse(c.applyParamChange(packet: idle))
    }

    func testInvalidateClearsBlob() {
        let c = SnapshotCache()
        c.setBulk(blob())
        c.invalidate()
        XCTAssertNil(c.snapshot())
        XCTAssertFalse(c.hasBulk)
    }

    func testStatusCarriedInSnapshot() {
        let c = SnapshotCache()
        c.setBulk(blob())
        c.setStatus(Data([1,2,3,4,5]))
        XCTAssertEqual(c.snapshot()?.status, Data([1,2,3,4,5]))
    }

    func testUpdatedAtAdvancesOnPatch() {
        let c = SnapshotCache()
        let t0 = Date(timeIntervalSince1970: 1000)
        c.setBulk(blob(), now: t0)
        XCTAssertEqual(c.snapshot()?.updatedAt, t0)
        let t1 = Date(timeIntervalSince1970: 2000)
        c.applyParamChange(packet: paramPacket(offset: 16, value: [9,9,9,9]), now: t1)
        XCTAssertEqual(c.snapshot()?.updatedAt, t1)
    }
}
