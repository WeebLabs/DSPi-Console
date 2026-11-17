import Foundation

// Which vendor protocol generation a connected board speaks, how the Console
// finds out, and which requests it may send before and after it knows.
//
// Firmware 1.1.7 addresses commands by page (wIndex high byte) and number.
// Firmware 1.1.6 and older ignore the page and run whatever old opcode has the
// same number, and some of those numbers are factory reset or a preset
// overwrite. So nothing paged may reach a board until the probe has shown it
// speaks the paged protocol (client update guide, section 2).

/// What the Console knows about a board's vendor protocol.
enum DeviceProtocolState: Equatable {
    /// Not probed yet on this connection, or a remote board whose hub does
    /// not say.
    case unknown
    /// Firmware 1.1.6 or older. Only the old GET_PLATFORM (0x7F) and
    /// ENTER_BOOTLOADER (0xF0) may be sent to it.
    case legacy(FirmwareVersion)
    /// Speaks the paged protocol at this version.
    case paged(major: UInt8, minor: UInt8)
    /// Speaks a paged protocol major this Console does not know. Nothing more
    /// is sent; the user needs a newer Console.
    case unsupported(major: UInt8)

    var isPaged: Bool { if case .paged = self { return true }; return false }
    var isLegacy: Bool { if case .legacy = self { return true }; return false }
}

extension VendorCommand {
    /// wIndex for a USB control transfer: the page in the high byte, the
    /// vendor interface (2) in the low byte.
    var usbIndex: UInt16 { (UInt16(page) << 8) | 2 }
}

/// The old 1.1.6 opcodes a legacy board may still receive.
enum LegacyOpcode {
    static let getPlatform: UInt8 = 0x7F
    static let enterBootloader: UInt8 = 0xF0
}

// MARK: - Probe

enum ProtocolProbe {
    enum Outcome: Equatable {
        case paged(major: UInt8, minor: UInt8)
        case unsupported(major: UInt8)
        /// The probe STALLed and the old GET_PLATFORM answered with this reply.
        case legacy(platformReply: Data)
        /// No verdict: a timeout, a dead link, or a STALL that GET_PLATFORM
        /// did not back up. A board still booting after a flash may STALL its
        /// first request, so the caller retries from the probe.
        case notReady
    }

    /// `SYS.PROTOCOL_INFO` reply magic, "DSPi".
    static let magic: [UInt8] = [0x44, 0x53, 0x50, 0x69]
    static let replyLength: UInt16 = 16

    /// Run the probe through `get(bRequest, wIndex, wLength)`. Sends the probe
    /// and, only after a STALL, the old GET_PLATFORM. Never caches anything.
    static func run(_ get: (UInt8, UInt16, UInt16) -> Result<Data, LinkStatus>) -> Outcome {
        let probe = VC.SYS.PROTOCOL_INFO
        switch get(probe.number, probe.usbIndex, replyLength) {
        case .success(let reply):
            let bytes = [UInt8](reply)
            guard bytes.count >= 6, Array(bytes[0..<4]) == magic else { return .notReady }
            let major = bytes[4], minor = bytes[5]
            return major == VendorProtocolVersion.major
                ? .paged(major: major, minor: minor)
                : .unsupported(major: major)
        case .failure(.error):
            // A STALL alone could be a board that is still booting. Only a
            // valid old platform reply makes it legacy.
            guard case .success(let reply) = get(LegacyOpcode.getPlatform, 2, 7),
                  FirmwareVersion.fromPlatformReply([UInt8](reply)) != nil else { return .notReady }
            return .legacy(platformReply: reply)
        case .failure:
            return .notReady
        }
    }
}

// MARK: - Gate

enum ProtocolGate {
    /// Phase 2 of the port leaves the old 8-bit call sites working on 1.1.6
    /// boards, so page-0 requests are not restricted yet. Phase 3 moves every
    /// call site to paged commands and removes this.
    static let allowsUnrestrictedPageZero = true

    /// Whether a request may go to a board in `state`. A refused request
    /// never reaches the bus.
    static func admits(request: UInt8, index: UInt16, isGet: Bool, state: DeviceProtocolState) -> Bool {
        let page = UInt8(index >> 8)
        let probe = VC.SYS.PROTOCOL_INFO
        if isGet, page == probe.page, request == probe.number { return true }   // the probe, in any state
        if page != 0 { return state.isPaged }
        if allowsUnrestrictedPageZero { return true }
        // Page 0 holds no paged commands; only the two old opcodes go there.
        switch state {
        case .unknown: return isGet && request == LegacyOpcode.getPlatform
        case .legacy: return isGet && (request == LegacyOpcode.getPlatform || request == LegacyOpcode.enterBootloader)
        case .paged, .unsupported: return false
        }
    }
}

// MARK: - Last result

/// `SYS.LAST_RESULT`, read straight after a STALL to learn why a request was
/// refused. The record is shared by every USB program on the device, so it is
/// trusted only when it names the request just sent.
enum VendorLastResult {
    static let length: UInt16 = 8

    /// The Link status for `reply`, or `.error` (refused, reason unknown) when
    /// the record is short or describes some other request.
    static func status(from reply: Data, request: UInt8, index: UInt16, value: UInt16, isGet: Bool) -> LinkStatus {
        let b = [UInt8](reply)
        guard b.count >= 6 else { return .error }
        let id = UInt16(b[0]) | (UInt16(b[1]) << 8)
        let recordedValue = UInt16(b[4]) | (UInt16(b[5]) << 8)
        let expectedID = (index & 0xFF00) | UInt16(request)
        guard id == expectedID, b[2] == (isGet ? 1 : 0), recordedValue == value,
              let status = LinkStatus(rawValue: b[3]), status.isVendorResult else { return .error }
        return status
    }
}
