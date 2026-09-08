//
//  SnapshotCache.swift
//  DSPi Console
//
//  Keeps one coherent copy of a device's bulk-parameter blob (and its last
//  status frame) so a client's first screen costs one JSON reply instead of a
//  bulk read plus dozens of GETs.  The hub refreshes the blob on a
//  BULK_INVALIDATED and patches it in place from every PARAM_CHANGED it
//  relays, using the notification's own (offset, size) addressing, which is
//  exactly offsetof into the same struct the blob is.  See spec 7.5 and
//  notification_protocol_v2_spec.md 3.6.
//

import Foundation

/// A cached device snapshot as `device.snapshot` returns it.
struct DeviceSnapshot {
    var wireVersion: Int
    var bulk: Data
    var status: Data?
    /// When the blob was last fully read or last patched.
    var updatedAt: Date
}

final class SnapshotCache {
    private var bulk: Data?
    private var status: Data?
    private var updatedAt = Date.distantPast
    private let lock = NSLock()

    /// v2 PARAM_CHANGED header: version, event, flags, seq, offset(2), size(2),
    /// source, reserved(3), then the value bytes.
    private static let paramHeaderLen = 12
    private static let eventParamChanged: UInt8 = 0x02

    /// Replace the whole blob after a fresh REQ_GET_ALL_PARAMS.  The wire
    /// version is byte 0 of the header.
    func setBulk(_ data: Data, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        bulk = data
        updatedAt = now
    }

    /// Record the latest status frame (REQ_GET_STATUS wValue 9), which the
    /// snapshot reply carries alongside the blob.
    func setStatus(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        status = data
    }

    /// Invalidate the blob so the next `snapshot` read misses until the hub
    /// re-reads it.  Called on BULK_INVALIDATED, since the per-field events
    /// are suppressed inside that bracket.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        bulk = nil
        updatedAt = .distantPast
    }

    /// Apply one PARAM_CHANGED packet to the cached blob.  A packet whose
    /// (offset, size) does not fit the blob, or that arrives while the blob is
    /// absent, is ignored: the client will re-read on the miss.  Returns true
    /// if the blob was patched.  `packet` is the verbatim v2 packet.
    @discardableResult
    func applyParamChange(packet: Data, now: Date = Date()) -> Bool {
        guard packet.count >= Self.paramHeaderLen else { return false }
        let b = packet.startIndex
        guard packet[b] == 0x02, packet[b + 1] == Self.eventParamChanged else { return false }
        let offset = Int(packet[b + 4]) | (Int(packet[b + 5]) << 8)
        let size = Int(packet[b + 6]) | (Int(packet[b + 7]) << 8)
        guard size > 0, packet.count >= Self.paramHeaderLen + size else { return false }
        let value = packet.subdata(in: (b + Self.paramHeaderLen)..<(b + Self.paramHeaderLen + size))

        lock.lock(); defer { lock.unlock() }
        guard var blob = bulk, offset >= 0, offset + size <= blob.count else { return false }
        blob.replaceSubrange((blob.startIndex + offset)..<(blob.startIndex + offset + size), with: value)
        bulk = blob
        updatedAt = now
        return true
    }

    /// The current snapshot, or nil if the blob is absent (invalidated or
    /// never read).  A caller that gets nil should read the device directly.
    func snapshot() -> DeviceSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let blob = bulk, let first = blob.first else { return nil }
        return DeviceSnapshot(wireVersion: Int(first), bulk: blob, status: status, updatedAt: updatedAt)
    }

    var hasBulk: Bool {
        lock.lock(); defer { lock.unlock() }
        return bulk != nil
    }
}
