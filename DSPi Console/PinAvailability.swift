import Foundation

// MARK: - Pin availability wire format
//
// Replies of the pin availability GETs, SYS.PIN_STATE and SYS.PIN_CLAIMS
// (firmware pin_availability_query_spec.md, section 8).  The device owns every
// pin rule; these types only decode what it reports.

/// Wire-stable pin function IDs (spec 4.1, firmware `vendor/vc_pins.h`).
enum PinFunction: UInt8, CaseIterable {
    case output   = 1    // index = output slot
    case pdm      = 2
    case i2sClock = 3    // index 0 master or unified pair, 1 slave pair; role 1 = LRCLK
    case mck      = 4
    case adatTx   = 5
    case adatRx   = 6
    case spdifRx  = 7    // index = S/PDIF input
    case i2sRx    = 8    // index = stereo pair
    case dacMute  = 9
    case uartCtrl = 10   // role 0 TX, 1 RX
    case i2cCtrl  = 11   // role 0 SDA, 1 SCL
    case controlSurface = 12  // index = binding slot

    /// The Overview groups claims by this.
    var role: PinRole {
        switch self {
        case .output, .pdm, .adatTx: return .output
        case .i2sClock, .mck: return .clock
        case .adatRx, .spdifRx, .i2sRx: return .input
        case .uartCtrl, .i2cCtrl, .controlSurface: return .control
        case .dacMute: return .utility
        }
    }
}

/// Flag bits of an availability reply header (spec 8.2).
struct PinAvailFlags: OptionSet, Equatable {
    let rawValue: UInt8
    /// The function is in use, live or pending.  For a CS reply: the slot's binding is active.
    static let inUse        = PinAvailFlags(rawValue: 0x01)
    /// Role 0 implies a second pin at +1 (the I2S clock pair: LRCLK = BCK + 1).
    static let pairPlusOne  = PinAvailFlags(rawValue: 0x02)
    /// No pin assigned.  For a CS reply: the slot's current type is not the type asked about.
    static let unassigned   = PinAvailFlags(rawValue: 0x04)
    /// The current pins are all free, so a start would not be refused on pins.
    static let startOK      = PinAvailFlags(rawValue: 0x08)
}

struct PinMaskPair: Equatable {
    /// GPIOs the function could ever use in this role.
    var valid: UInt64
    /// The subset of `valid` no other function claims now.
    var free: UInt64
}

/// One availability reply.  `status` is a `VC_ERR_*` code for every family
/// except Control Surfaces, whose replies carry a `CS_STATUS_*` code.
struct PinAvailability: Equatable {
    static let headerSize = 8
    /// `CS.BINDING_PIN_AVAIL` is always this long: four mask pairs laid out
    /// for G = 2, R = 2, then the button-shareable mask.
    static let csReplySize = 80
    /// Large enough for any reply (the XPORT ones are 72 bytes, or 40 on a
    /// platform build with one I2C/UART instance).
    static let maxReplySize: UInt16 = 80

    var status: UInt8
    var flags: PinAvailFlags
    var generation: UInt32
    /// `masks[group][role]`.
    var masks: [[PinMaskPair]]
    /// Pins held only by other button bindings (Control Surfaces only).
    var shareable: UInt64 = 0

    var groupCount: Int { masks.count }
    var roleCount: Int { masks.first?.count ?? 0 }

    /// Decode a non-CS reply.  The length is checked against the header's own
    /// group and role counts, not a fixed size.
    static func decode(_ data: Data) -> PinAvailability? {
        decode(data, csLayout: false)
    }

    /// Decode a `CS.BINDING_PIN_AVAIL` reply.
    static func decodeCS(_ data: Data) -> PinAvailability? {
        decode(data, csLayout: true)
    }

    private static func decode(_ data: Data, csLayout: Bool) -> PinAvailability? {
        let d = Data(data)  // rebase to 0
        guard d.count >= headerSize else { return nil }
        let groups = Int(d[2]), roles = Int(d[3])
        guard groups >= 1, groups <= 2, roles <= 2 else { return nil }
        if csLayout {
            guard d.count >= csReplySize else { return nil }
        } else {
            guard roles >= 1, d.count >= headerSize + 16 * groups * roles else { return nil }
        }
        // The CS layout always reserves two roles per group.
        let stride = csLayout ? 2 : roles
        var masks: [[PinMaskPair]] = []
        for g in 0..<groups {
            var row: [PinMaskPair] = []
            for r in 0..<roles {
                let o = headerSize + 16 * (g * stride + r)
                row.append(PinMaskPair(valid: d.u64(o), free: d.u64(o + 8)))
            }
            masks.append(row)
        }
        return PinAvailability(status: d[0], flags: PinAvailFlags(rawValue: d[1]),
                               generation: d.u32(4), masks: masks,
                               shareable: csLayout ? d.u64(72) : 0)
    }

    private func mask(_ group: Int, _ role: Int) -> PinMaskPair? {
        guard group >= 0, group < masks.count, role >= 0, role < masks[group].count else { return nil }
        return masks[group][role]
    }

    /// Whether `pin` is valid for `role` in any group.
    func isValid(_ pin: UInt8, role: Int = 0) -> Bool {
        pin < 64 && masks.contains { $0.indices.contains(role) && $0[role].valid & (1 << UInt64(pin)) != 0 }
    }

    /// Whether `pin` is free for `role` in any group.
    func isFree(_ pin: UInt8, role: Int = 0) -> Bool {
        pin < 64 && masks.contains { $0.indices.contains(role) && $0[role].free & (1 << UInt64(pin)) != 0 }
    }

    func isShareable(_ pin: UInt8) -> Bool {
        pin < 64 && shareable & (1 << UInt64(pin)) != 0
    }

    /// The group whose `role` mask holds `pin` as valid, if any.
    func group(of pin: UInt8, role: Int) -> Int? {
        guard pin < 64 else { return nil }
        return masks.indices.first { g in mask(g, role).map { $0.valid & (1 << UInt64(pin)) != 0 } ?? false }
    }

    /// Valid pins for `role`, in pin order, across groups.
    func validPins(role: Int = 0) -> [UInt8] {
        pins(in: masks.reduce(UInt64(0)) { $0 | ($1.indices.contains(role) ? $1[role].valid : 0) })
    }

    /// Free pins for `role`, in pin order, across groups.
    func freePins(role: Int = 0) -> [UInt8] {
        pins(in: masks.reduce(UInt64(0)) { $0 | ($1.indices.contains(role) ? $1[role].free : 0) })
    }

    /// Free pins for `role` within one group.
    func freePins(role: Int, group: Int) -> [UInt8] {
        pins(in: mask(group, role)?.free ?? 0)
    }

    /// Whether `a` (role 0) and `b` (role 1) are both valid in one group.
    func pairValid(_ a: UInt8, _ b: UInt8) -> Bool {
        guard a < 64, b < 64 else { return false }
        return masks.contains { row in
            row.count >= 2 && row[0].valid & (1 << UInt64(a)) != 0 && row[1].valid & (1 << UInt64(b)) != 0
        }
    }
}

func pins(in mask: UInt64) -> [UInt8] {
    (0..<64).compactMap { mask & (1 << UInt64($0)) != 0 ? UInt8($0) : nil }
}

/// `SYS.PIN_STATE` (24 bytes, spec 8.3).
struct PinStateReply: Equatable {
    static let size: UInt16 = 24
    var generation: UInt32
    var gpioCount: UInt8
    var claimCount: UInt8
    /// Bit n set: the last restore replaced function n's pins or switched it off.
    var substituted: UInt16
    /// GPIOs that exist and are assignable to at least one function.
    var gpioMask: UInt64

    static func decode(_ data: Data) -> PinStateReply? {
        let d = Data(data)
        guard d.count >= Int(size) else { return nil }
        return PinStateReply(generation: d.u32(0), gpioCount: d[4], claimCount: d[5],
                             substituted: d.u16(6), gpioMask: d.u64(8))
    }

    var substitutedFunctions: [PinFunction] {
        PinFunction.allCases.filter { substituted & (1 << UInt16($0.rawValue)) != 0 }
    }

    var gpios: [UInt8] { pins(in: gpioMask) }
}

/// One entry of `SYS.PIN_CLAIMS` (spec 8.4).
struct PinClaim: Equatable {
    var gpio: UInt8
    /// Raw function ID; an ID this Console does not know still lists.
    var functionID: UInt8
    var index: UInt8
    /// False for the stored pin of a function that is not in use (blocks nothing).
    var active: Bool
    var role: UInt8
    /// Binding type for a Control Surfaces claim, 0 otherwise.
    var csType: UInt8

    var function: PinFunction? { PinFunction(rawValue: functionID) }

    /// Whether this claim belongs to `function` at `index`.
    func isOwned(by function: PinFunction, index: Int) -> Bool {
        functionID == function.rawValue && Int(self.index) == index
    }
}

struct PinClaimsReply: Equatable {
    /// `VC_REPLY_MAX`; the reply is shorter whenever there are fewer claims.
    static let requestSize: UInt16 = 256
    var generation: UInt32
    var claims: [PinClaim]

    static func decode(_ data: Data) -> PinClaimsReply? {
        let d = Data(data)
        guard d.count >= 8 else { return nil }
        let n = Int(d[4])
        guard d.count >= 8 + 4 * n else { return nil }
        let claims = (0..<n).map { i -> PinClaim in
            let o = 8 + 4 * i
            let meta = d[o + 3]
            return PinClaim(gpio: d[o], functionID: d[o + 1], index: d[o + 2],
                            active: meta & 3 == 0, role: (meta >> 2) & 3, csType: meta >> 4)
        }
        return PinClaimsReply(generation: d.u32(0), claims: claims)
    }
}

private extension Data {
    // Callers rebase to index 0 first.
    func u16(_ o: Int) -> UInt16 { UInt16(self[o]) | UInt16(self[o + 1]) << 8 }
    func u32(_ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(self[o + $1]) << (8 * UInt32($1)) } }
    func u64(_ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(self[o + $1]) << (8 * UInt64($1)) } }
}
