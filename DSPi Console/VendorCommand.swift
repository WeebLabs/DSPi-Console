import Foundation

// Types for the paged vendor protocol of firmware 1.1.7. The command
// constants and the registry table themselves are generated into
// VendorCommands.swift from Protocol/dspi_commands.json.

/// One paged vendor command, addressed by its 16-bit ID `(page << 8) | command`.
/// On USB the page travels in the high byte of wIndex and the command number in
/// bRequest. Keep commands in this type end to end: an 8-bit opcode variable
/// silently drops the page and lands the request on page 0, which has no
/// commands.
struct VendorCommand: Hashable, Sendable, CustomStringConvertible {
    let id: UInt16

    init(_ id: UInt16) { self.id = id }

    var page: UInt8 { UInt8(id >> 8) }
    var number: UInt8 { UInt8(truncatingIfNeeded: id) }

    /// `PAGE.NAME` when the registry knows the command, else the hex ID.
    var description: String {
        VendorCommandRegistry.info(for: self)?.qualifiedName
            ?? String(format: "0x%04X", id)
    }
}

/// What `wValue` addresses for a command. `none` commands require wValue 0.
enum VendorAddressKind: String, Sendable, CaseIterable {
    case none = "NONE"
    case channel = "CHANNEL"
    case input = "INPUT"
    case output = "OUTPUT"
    case outputAll = "OUTPUT_ALL"
    case slot = "SLOT"
    case pinOutput = "PIN_OUTPUT"
    case preset = "PRESET"
    case channelBand = "CH_BAND"
    case inputOutput = "IN_OUT"
    case source = "SOURCE"
    case spdifRx = "SPDIF_RX"
    case i2sPair = "I2S_PAIR"
    case role = "ROLE"
    case csSlot = "CS_SLOT"
    case csSub = "CS_SUB"
    case csGroup = "CS_GROUP"
    case csMacro = "CS_MACRO"
    case csMacroStep = "CS_MACRO_STEP"
    case csPage = "CS_PAGE"
    case csNoun = "CS_NOUN"
    case page = "PAGE"
    case pageCommand = "PAGE_CMD"
    case offset = "OFFSET"
    case index = "INDEX"
}

/// Registry flags. `deferred` means an ACK only says "queued": the main loop
/// applies the write a moment later, so confirm by reading it back.
struct VendorCommandFlags: OptionSet, Hashable, Sendable {
    let rawValue: UInt8
    static let usbOnly    = VendorCommandFlags(rawValue: 1 << 0)
    static let setUsbOnly = VendorCommandFlags(rawValue: 1 << 1)
    static let bulk       = VendorCommandFlags(rawValue: 1 << 2)
    static let deferred   = VendorCommandFlags(rawValue: 1 << 3)
    static let flash      = VendorCommandFlags(rawValue: 1 << 4)
    static let restart    = VendorCommandFlags(rawValue: 1 << 5)
    static let keepalive  = VendorCommandFlags(rawValue: 1 << 6)

    /// Registry spelling, in the registry's canonical order.
    static let registryNames: [(String, VendorCommandFlags)] = [
        ("USB_ONLY", .usbOnly), ("SET_USB_ONLY", .setUsbOnly), ("BULK", .bulk),
        ("DEFERRED", .deferred), ("FLASH", .flash), ("RESTART", .restart),
        ("KEEPALIVE", .keepalive),
    ]
}

/// Length of a command's GET reply.
enum VendorReplyLength: Hashable, Sendable {
    /// The command has no GET.
    case none
    /// The reply is always exactly this many bytes.
    case fixed(Int)
    /// The length depends on the platform or the request; see the command's spec.
    case variable
}

/// Everything the registry says about one command.
struct VendorCommandInfo: Sendable {
    let command: VendorCommand
    let pageName: String
    let name: String
    let hasGet: Bool
    let hasSet: Bool
    let address: VendorAddressKind
    let getLength: VendorReplyLength
    /// Accepted SET payload length range, in bytes. Both 0 for a SET that
    /// takes no payload, and for a command with no SET.
    let setMin: Int
    let setMax: Int
    let flags: VendorCommandFlags
    /// Firmware build condition (`PICO_RP2350`, `DSPI_LOOPBACK`, ...), or nil
    /// when every build has the command. Absent commands are refused with
    /// VC_ERR_UNKNOWN; discover them with SYS.PAGE_COMMANDS, not by version.
    let build: String?

    var qualifiedName: String { "\(pageName).\(name)" }
}

/// One page of the registry.
struct VendorPageInfo: Sendable {
    let number: UInt8
    let name: String
    let revision: Int
}

enum VendorCommandRegistry {
    private static let byID: [UInt16: VendorCommandInfo] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.command.id, $0) })

    static func info(for command: VendorCommand) -> VendorCommandInfo? {
        byID[command.id]
    }
}
