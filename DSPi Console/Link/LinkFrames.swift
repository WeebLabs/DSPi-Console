//
//  LinkFrames.swift
//  DSPi Console
//
//  Binary data-plane frames of the DSPi Link protocol, section 8 of
//  Documentation/dspi_link_protocol_spec.md.  Every frame starts with a
//  4-byte header (type, flags, tag) and all multi-byte integers are
//  little-endian, matching the firmware.  Status bytes are LinkStatus from
//  DeviceTransport.swift; there is deliberately no second status enum.
//

import Foundation

/// Frame types.  0x06..0x7F and 0x85..0xFF are reserved for later minor
/// versions, so decoding one is a distinct error the caller can ignore
/// rather than a failure.
enum LinkFrameType: UInt8 {
    case cmdRequest  = 0x01
    case cmdResponse = 0x81
    case notify      = 0x02
    case poll        = 0x03
    case fwData      = 0x04
    case fwDataAck   = 0x84
    case resync      = 0x05
}

/// Direction of a tunnelled vendor command.  This is the client's statement
/// of the USB transfer type, so write-as-read commands travel as `.get`
/// exactly as they do over USB (spec 8.2).
enum LinkDirection: UInt8 {
    case set = 0   // host to device, bmRequestType 0x41
    case get = 1   // device to host, bmRequestType 0xC1
}

enum LinkFrameError: Error, Equatable {
    /// A frame type this build does not know.  Per spec 10.4 a receiver
    /// drops these, so it is separate from a genuine decode failure.
    case unknownType(UInt8)
    case truncated
    case unknownStatus(UInt8)
    case unknownDirection(UInt8)
}

// MARK: - Frame bodies

struct LinkCmdRequest: Equatable {
    var tag: UInt16
    var handle: UInt8
    var direction: LinkDirection
    var bRequest: UInt8
    var wValue: UInt16
    var wIndex: UInt16
    /// SET: the payload length.  GET: the number of bytes requested.
    var wLength: UInt16
    var payload: Data

    /// Normalises the two fields the spec ties together: a SET carries its
    /// payload and `wLength` counts it, a GET carries none.
    init(tag: UInt16, handle: UInt8, direction: LinkDirection, bRequest: UInt8,
         wValue: UInt16 = 0, wIndex: UInt16 = 0, wLength: UInt16 = 0, payload: Data = Data()) {
        self.tag = tag
        self.handle = handle
        self.direction = direction
        self.bRequest = bRequest
        self.wValue = wValue
        self.wIndex = wIndex
        switch direction {
        case .set:
            self.wLength = UInt16(truncatingIfNeeded: payload.count)
            self.payload = payload
        case .get:
            self.wLength = wLength
            self.payload = Data()
        }
    }
}

struct LinkCmdResponse: Equatable {
    var tag: UInt16
    var status: LinkStatus
    var payload: Data

    init(tag: UInt16, status: LinkStatus, payload: Data = Data()) {
        self.tag = tag
        self.status = status
        self.payload = payload
    }
}

struct LinkNotifyFrame: Equatable {
    /// Link sequence number, per session.  A gap means the session missed
    /// events and must re-read state; it is not the firmware's own `seq`.
    var tag: UInt16
    var handle: UInt8
    var origin: LinkSessionID
    /// Verbatim v2 notification packet, first byte 0x02.
    var packet: Data
}

struct LinkPollFrame: Equatable {
    var tag: UInt16
    var handle: UInt8
    var slot: UInt8
    /// Verbatim response of the subscribed GET.
    var payload: Data
}

struct LinkFwDataFrame: Equatable {
    /// The `xfer` id from the fw.install reply.
    var tag: UInt16
    var offset: UInt32
    var data: Data
}

struct LinkFwDataAck: Equatable {
    var tag: UInt16
    var offset: UInt32
    var status: LinkStatus
}

struct LinkResyncFrame: Equatable {
    var handle: UInt8
    /// 0 = hub dropped notifications, 1 = device reattached, 2 = cache
    /// rebuilt.  Kept as a raw byte so an unknown reason still decodes.
    var reason: UInt8

    enum Reason: UInt8 {
        case notificationsDropped = 0
        case deviceReattached     = 1
        case cacheRebuilt         = 2
    }

    var knownReason: Reason? { Reason(rawValue: reason) }
}

// MARK: - Frame

enum LinkFrame: Equatable {
    case cmdRequest(LinkCmdRequest)
    case cmdResponse(LinkCmdResponse)
    case notify(LinkNotifyFrame)
    case poll(LinkPollFrame)
    case fwData(LinkFwDataFrame)
    case fwDataAck(LinkFwDataAck)
    case resync(LinkResyncFrame)

    var type: LinkFrameType {
        switch self {
        case .cmdRequest:  return .cmdRequest
        case .cmdResponse: return .cmdResponse
        case .notify:      return .notify
        case .poll:        return .poll
        case .fwData:      return .fwData
        case .fwDataAck:   return .fwDataAck
        case .resync:      return .resync
        }
    }

    static func decode(_ data: Data) throws -> LinkFrame {
        var r = LinkByteReader(data)
        let rawType = try r.u8()
        guard let type = LinkFrameType(rawValue: rawType) else {
            throw LinkFrameError.unknownType(rawType)
        }
        _ = try r.u8()                  // flags, reserved
        let tag = try r.u16()

        switch type {
        case .cmdRequest:
            let handle = try r.u8()
            let rawDir = try r.u8()
            guard let dir = LinkDirection(rawValue: rawDir) else {
                throw LinkFrameError.unknownDirection(rawDir)
            }
            let bRequest = try r.u8()
            _ = try r.u8()              // reserved
            let wValue = try r.u16()
            let wIndex = try r.u16()
            let wLength = try r.u16()
            let payload = dir == .set ? try r.bytes(Int(wLength)) : Data()
            return .cmdRequest(LinkCmdRequest(tag: tag, handle: handle, direction: dir,
                                              bRequest: bRequest, wValue: wValue, wIndex: wIndex,
                                              wLength: wLength, payload: payload))

        case .cmdResponse:
            let rawStatus = try r.u8()
            guard let status = LinkStatus(rawValue: rawStatus) else {
                throw LinkFrameError.unknownStatus(rawStatus)
            }
            _ = try r.u8()              // reserved
            let length = try r.u16()
            return .cmdResponse(LinkCmdResponse(tag: tag, status: status,
                                                payload: try r.bytes(Int(length))))

        case .notify:
            let handle = try r.u8()
            _ = try r.u8()              // reserved
            let origin = try r.u16()
            return .notify(LinkNotifyFrame(tag: tag, handle: handle, origin: origin,
                                           packet: r.rest()))

        case .poll:
            let handle = try r.u8()
            let slot = try r.u8()
            let length = try r.u16()
            return .poll(LinkPollFrame(tag: tag, handle: handle, slot: slot,
                                       payload: try r.bytes(Int(length))))

        case .fwData:
            let offset = try r.u32()
            return .fwData(LinkFwDataFrame(tag: tag, offset: offset, data: r.rest()))

        case .fwDataAck:
            let offset = try r.u32()
            let rawStatus = try r.u8()
            guard let status = LinkStatus(rawValue: rawStatus) else {
                throw LinkFrameError.unknownStatus(rawStatus)
            }
            return .fwDataAck(LinkFwDataAck(tag: tag, offset: offset, status: status))

        case .resync:
            let handle = try r.u8()
            let reason = try r.u8()
            return .resync(LinkResyncFrame(handle: handle, reason: reason))
        }
    }

    func encode() -> Data {
        var out = Data()
        out.append(type.rawValue)
        out.append(0)                   // flags

        switch self {
        case .cmdRequest(let f):
            out.appendLE(f.tag)
            out.append(f.handle)
            out.append(f.direction.rawValue)
            out.append(f.bRequest)
            out.append(0)               // reserved
            out.appendLE(f.wValue)
            out.appendLE(f.wIndex)
            // The initialiser keeps these consistent; recompute so a field
            // assignment after the fact cannot ship a lying wLength.
            let length = f.direction == .set ? UInt16(truncatingIfNeeded: f.payload.count) : f.wLength
            out.appendLE(length)
            if f.direction == .set { out.append(f.payload) }

        case .cmdResponse(let f):
            out.appendLE(f.tag)
            out.append(f.status.rawValue)
            out.append(0)               // reserved
            out.appendLE(UInt16(truncatingIfNeeded: f.payload.count))
            out.append(f.payload)

        case .notify(let f):
            out.appendLE(f.tag)
            out.append(f.handle)
            out.append(0)               // reserved
            out.appendLE(f.origin)
            out.append(f.packet)

        case .poll(let f):
            out.appendLE(f.tag)
            out.append(f.handle)
            out.append(f.slot)
            out.appendLE(UInt16(truncatingIfNeeded: f.payload.count))
            out.append(f.payload)

        case .fwData(let f):
            out.appendLE(f.tag)
            out.appendLE(f.offset)
            out.append(f.data)

        case .fwDataAck(let f):
            out.appendLE(f.tag)
            out.appendLE(f.offset)
            out.append(f.status.rawValue)

        case .resync(let f):
            out.appendLE(UInt16(0))     // tag unused
            out.append(f.handle)
            out.append(f.reason)
        }
        return out
    }
}

// MARK: - Byte plumbing

/// Little-endian reader that indexes relative to `startIndex`, so it works on
/// a slice of a larger buffer (WebSocket reads hand out slices).
struct LinkByteReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - offset }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw LinkFrameError.truncated }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func u16() throws -> UInt16 {
        let lo = try u8(), hi = try u8()
        return UInt16(lo) | (UInt16(hi) << 8)
    }

    mutating func u32() throws -> UInt32 {
        let a = try u16(), b = try u16()
        return UInt32(a) | (UInt32(b) << 16)
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw LinkFrameError.truncated }
        let start = data.startIndex + offset
        defer { offset += count }
        return Data(data[start ..< start + count])
    }

    mutating func rest() -> Data {
        let start = data.startIndex + offset
        defer { offset = data.count }
        return Data(data[start ..< data.endIndex])
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
