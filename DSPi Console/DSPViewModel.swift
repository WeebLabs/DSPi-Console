import SwiftUI
import Combine

// MARK: - GPIO Pin Conflict Resolution
//
// Top-level enum + view-model method so any tab that needs to filter
// pin pickers shares one source of truth.  Without this, each tab that
// owns a pin assignment maintains its own conflict list and a pin set
// in one tab would silently appear "available" in another.
enum PinConsumer: Equatable {
    case output(Int)    // slot or PDM index — indexes vm.outputPins[]
    case i2sBck         // also covers LRCLK (BCK + 1)
    case mck
    case spdifRx
    case i2sRx(Int)     // I2S input data pin, per stereo pair (0..3)
    case dacMute
    case uartCtrl       // UART control interface (covers both TX and RX pins)
    case i2cCtrl        // I2C control interface (covers both SDA and SCL pins)
    case controlSurface(Int)  // one Control Surfaces binding slot (covers both its GPIOs)
    case adatOut        // ADAT bulk output data pin
}

// MARK: - DAC Hardware Mute Config
//
// 16-byte wire-format struct mirroring firmware `DacHwMuteConfig` in
// `dac_hardware_mute_spec.md` §4.1.  Stored in the firmware's directory
// sector (board-level config — not per preset).  A single shared GPIO
// drives the DAC's MUTE input; pipeline reset is global so there's no
// per-slot granularity (installations with multiple DACs wire their
// MUTE pins together to one RP2 GPIO).
//
// Byte layout:
//   0:    enabled
//   1:    active_low
//   2:    pin (0xFF = none)
//   3:    reserved0 (alignment for hold_ms)
//   4-5:  hold_ms  (little-endian)
//   6-7:  release_ms (little-endian)
//   8-15: reserved
struct DacHwMuteConfig: Equatable {
    var enabled: Bool = false
    var activeLow: Bool = true
    var pin: UInt8 = DAC_HW_MUTE_PIN_NONE
    var holdMs: UInt16 = 0
    var releaseMs: UInt16 = 0

    /// Serialize to the 16-byte wire layout.  Reserved bytes are zero-filled.
    func toData() -> Data {
        var d = Data(count: 16)
        d[0] = enabled ? 1 : 0
        d[1] = activeLow ? 1 : 0
        d[2] = pin
        d[3] = 0  // reserved0 alignment
        d[4] = UInt8(holdMs & 0xFF)
        d[5] = UInt8((holdMs >> 8) & 0xFF)
        d[6] = UInt8(releaseMs & 0xFF)
        d[7] = UInt8((releaseMs >> 8) & 0xFF)
        return d
    }

    /// Parse the 16-byte wire layout.  Returns nil if too short.
    static func fromData(_ data: Data) -> DacHwMuteConfig? {
        guard data.count >= 16 else { return nil }
        let base = data.startIndex
        return DacHwMuteConfig(
            enabled:   data[base + 0] != 0,
            activeLow: data[base + 1] != 0,
            pin:       data[base + 2],
            holdMs:    UInt16(data[base + 4]) | (UInt16(data[base + 5]) << 8),
            releaseMs: UInt16(data[base + 6]) | (UInt16(data[base + 7]) << 8)
        )
    }
}

// MARK: - ADAT Bulk Output Status
//
// 8-byte wire-format struct mirroring firmware `AdatStatus`
// (REQ_GET_ADAT_STATUS, adat_output_spec.md §"AdatStatus").  Packed,
// little-endian.  RP2040 returns all zeros.
//
// Byte layout:
//   0:   enabled  (configured/persisted intent)
//   1:   active   (stream currently running)
//   2:   pin      (configured data GPIO)
//   3:   rate_ok  (current sample rate is 44.1/48 kHz)
//   4-5: resync_count (u16, stream restarts since boot)
//   6-7: slip_count   (u16, emergency local resyncs; should stay 0)
struct AdatStatus: Equatable {
    var enabled: Bool = false
    var active: Bool = false
    var pin: UInt8 = 0
    var rateOk: Bool = false
    var resyncCount: UInt16 = 0
    var slipCount: UInt16 = 0

    /// Parse the 8-byte wire layout.  Returns nil if too short.
    static func fromData(_ data: Data) -> AdatStatus? {
        guard data.count >= 8 else { return nil }
        let base = data.startIndex
        return AdatStatus(
            enabled:     data[base + 0] != 0,
            active:      data[base + 1] != 0,
            pin:         data[base + 2],
            rateOk:      data[base + 3] != 0,
            resyncCount: UInt16(data[base + 4]) | (UInt16(data[base + 5]) << 8),
            slipCount:   UInt16(data[base + 6]) | (UInt16(data[base + 7]) << 8)
        )
    }

    /// User-facing one-line state description for the Settings status row.
    var stateString: String {
        if !enabled { return "Disabled" }
        if active { return "Streaming" }
        if !rateOk { return "Suspended (rate above 48 kHz)" }
        return "Enabled"
    }

    /// Colored-dot tint for the Stats window state row (mirrors SpdifRxStatus).
    var stateColor: Color {
        if !enabled { return .gray }
        if active { return .green }
        if !rateOk { return .orange }   // enabled but suspended above 48 kHz
        return .yellow                  // enabled, waiting to (re)start
    }
}

// MARK: - External Control Interface Configs
//
// 8-byte wire-format structs mirroring firmware `UartCtrlConfig` /
// `I2cCtrlConfig` / `CtrlIfaceStatus` in control_interfaces_spec.md §2.1.
// These configure the UART and I2C-target control transports that expose the
// full vendor-command surface to an external microcontroller.  They are
// device-level (stored in the preset directory, survive factory reset) and are
// configured over USB only - the very transport being reconfigured can never
// lock itself out.  All fields little-endian, packed, no padding.

/// UART control interface configuration (8 bytes).  Framing is fixed 8N1;
/// only the baud rate and the notify-enable flag are configurable.
struct UartCtrlConfig: Equatable {
    var enabled: Bool = false
    var txPin: UInt8 = UART_CTRL_TX_PIN_DEFAULT   // pin % 4 == 0 (UARTx TX mux)
    var rxPin: UInt8 = UART_CTRL_RX_PIN_DEFAULT   // pin % 4 == 1 (same instance RX)
    var notifyEnable: Bool = false                // push type-0x40 notification frames
    var baud: UInt32 = UART_CTRL_BAUD_DEFAULT     // 9600 .. 1000000

    /// Serialize to the 8-byte wire layout.
    func toData() -> Data {
        var d = Data(count: 8)
        d[0] = enabled ? 1 : 0
        d[1] = txPin
        d[2] = rxPin
        d[3] = notifyEnable ? 1 : 0
        d[4] = UInt8(baud & 0xFF)
        d[5] = UInt8((baud >> 8) & 0xFF)
        d[6] = UInt8((baud >> 16) & 0xFF)
        d[7] = UInt8((baud >> 24) & 0xFF)
        return d
    }

    /// Parse the 8-byte wire layout.  Returns nil if too short.
    static func fromData(_ data: Data) -> UartCtrlConfig? {
        guard data.count >= 8 else { return nil }
        let base = data.startIndex
        return UartCtrlConfig(
            enabled:      data[base + 0] != 0,
            txPin:        data[base + 1],
            rxPin:        data[base + 2],
            notifyEnable: data[base + 3] != 0,
            baud:         UInt32(data[base + 4])
                        | (UInt32(data[base + 5]) << 8)
                        | (UInt32(data[base + 6]) << 16)
                        | (UInt32(data[base + 7]) << 24)
        )
    }
}

/// I2C-target control interface configuration (8 bytes).  Bus speed and
/// clock-stretch behavior are controller-side properties and are not stored.
struct I2cCtrlConfig: Equatable {
    var enabled: Bool = false
    var sdaPin: UInt8 = I2C_CTRL_SDA_PIN_DEFAULT   // even (I2Cx SDA mux)
    var sclPin: UInt8 = I2C_CTRL_SCL_PIN_DEFAULT   // next odd GPIO (same instance SCL)
    var address: UInt8 = I2C_CTRL_ADDR_DEFAULT     // 7-bit, 0x08 .. 0x77

    /// Serialize to the 8-byte wire layout.  Reserved bytes are zero-filled.
    func toData() -> Data {
        var d = Data(count: 8)
        d[0] = enabled ? 1 : 0
        d[1] = sdaPin
        d[2] = sclPin
        d[3] = address
        return d  // bytes 4-7 reserved (0)
    }

    /// Parse the 8-byte wire layout.  Returns nil if too short.
    static func fromData(_ data: Data) -> I2cCtrlConfig? {
        guard data.count >= 8 else { return nil }
        let base = data.startIndex
        return I2cCtrlConfig(
            enabled: data[base + 0] != 0,
            sdaPin:  data[base + 1],
            sclPin:  data[base + 2],
            address: data[base + 3]
        )
    }
}

/// REQ_GET_CTRL_IFACE_STATUS response (8 bytes).  `*_lastStatus` is the
/// PIN_CONFIG_* outcome of the most recent SET; `*_live` is 1 when the
/// peripheral is actually up and listening (0 if a stored-but-enabled config's
/// pins collide with the current output wiring at boot).
struct CtrlIfaceStatus: Equatable {
    var uartLastStatus: UInt8 = 0
    var uartLive: Bool = false
    var i2cLastStatus: UInt8 = 0
    var i2cLive: Bool = false
    var protoVersion: UInt8 = 0

    static func fromData(_ data: Data) -> CtrlIfaceStatus? {
        guard data.count >= 8 else { return nil }
        let base = data.startIndex
        return CtrlIfaceStatus(
            uartLastStatus: data[base + 0],
            uartLive:       data[base + 1] != 0,
            i2cLastStatus:  data[base + 2],
            i2cLive:        data[base + 3] != 0,
            protoVersion:   data[base + 4]
        )
    }
}

// MARK: - Control Surfaces
//
// Wire-format structs mirroring firmware `control_surfaces.h`
// (control_surfaces_spec.md §2).  All packed, little-endian, no padding.  A
// binding attaches one physical component (CsType) to one firmware parameter
// (CsNoun) through one operation (CsAction) on one or two GPIOs.  The config
// is device-global (stored in the preset directory; survives factory reset).

/// One user-wired control binding (24 bytes, capability format v2).  The same
/// bytes appear on the wire (REQ_SET/GET_CS_BINDING) and in flash.  Numeric
/// operands are unit-encoded per the noun's unit (spec §2.1): dB / Q / percent
/// as signed 8.8 fixed point, Hz as a plain integer, enum/bool as plain ints.
struct CsBinding: Equatable {
    var type: UInt8 = 0                 // Byte 0: CsType; 0 (CS_TYPE_NONE) = slot cleared
    var noun: UInt8 = 0                 // Byte 1: CsNoun
    var action: UInt8 = 0              // Byte 2: CsAction
    var flags: UInt8 = 0              // Byte 3: CS_FLAG_* bitfield
    var gpio0: UInt8 = 0             // Byte 4: primary GPIO
    // Byte 5: second GPIO (encoders); CS_GPIO_UNUSED (0xFF) for a configured
    // single-pin component.  The default is 0 so a default-constructed
    // CsBinding() is the all-zero "cleared slot" blob the device stores
    // (spec §8.3) - a configured single-pin binding sets this to 0xFF explicitly.
    var gpio1: UInt8 = 0
    var event: UInt8 = 0            // Byte 6: CsEvent (buttons: press/long/double); 0 for other types
    var target: UInt8 = 0          // Byte 7: channel address for targeted nouns; 0 otherwise
    var index: UInt8 = 0           // Byte 8: filter band for CS_TARGET_DSP_BAND nouns; 0 otherwise
    // Byte 9: reserved (0)
    var value: Int16 = 0           // Bytes 10-11: SET/MOMENTARY target, IND_EQUALS/IND_ABOVE comparand
    var step: Int16 = 0            // Bytes 12-13: STEP/INC/DEC size; 0 = the unit default
    var rangeMin: Int16 = 0       // Bytes 14-15: pot / IND_LEVEL span low; both 0 = the noun's full range
    var rangeMax: Int16 = 0       // Bytes 16-17: pot / IND_LEVEL span high
    // Bytes 18-23: reserved2[6] (0)

    /// True when the slot holds a component (not CS_TYPE_NONE).
    var isConfigured: Bool { type != UInt8(CS_TYPE_NONE) }

    /// Serialize to the 24-byte wire layout.  Bytes 9 and 18-23 are reserved (0).
    func toData() -> Data {
        var d = Data(count: 24)
        d[0] = type
        d[1] = noun
        d[2] = action
        d[3] = flags
        d[4] = gpio0
        d[5] = gpio1
        d[6] = event
        d[7] = target
        d[8] = index
        // 9 reserved (0)
        func put(_ v: Int16, _ off: Int) {
            let u = UInt16(bitPattern: v)
            d[off] = UInt8(u & 0xFF)
            d[off + 1] = UInt8((u >> 8) & 0xFF)
        }
        put(value, 10)
        put(step, 12)
        put(rangeMin, 14)
        put(rangeMax, 16)
        // 18-23 reserved2 (0)
        return d
    }

    /// Parse the 24-byte wire layout.  Returns nil if too short.
    static func fromData(_ data: Data) -> CsBinding? {
        guard data.count >= 24 else { return nil }
        let b = data.startIndex
        func i16(_ off: Int) -> Int16 {
            Int16(bitPattern: UInt16(data[b + off]) | (UInt16(data[b + off + 1]) << 8))
        }
        return CsBinding(
            type: data[b + 0], noun: data[b + 1], action: data[b + 2], flags: data[b + 3],
            gpio0: data[b + 4], gpio1: data[b + 5],
            event: data[b + 6], target: data[b + 7], index: data[b + 8],
            value: i16(10), step: i16(12), rangeMin: i16(14), rangeMax: i16(16))
    }
}

/// One entry of the capability type table (4 bytes; spec §2.4).  Says which
/// actions a component can drive, how many GPIOs it consumes, and its pin class.
struct CsTypeDesc: Equatable {
    var actions: UInt16 = 0   // CS_ACT_BIT mask this component can drive
    var pinCount: UInt8 = 0   // GPIOs consumed (1 or 2)
    var pinClass: UInt8 = 0   // CS_PINCLASS_ANY / _ADC
}

/// Capability header returned by REQ_GET_CS_CAPS, wValue = 0xFFFF (40 bytes in
/// v3: 4-byte header + 8 CsTypeDesc + a 4-byte tail; spec §2.4).  Hosts build
/// their picker UI from this, not from hardcoded tables, so a future firmware's
/// new types appear with no app change.  The parser reads `typeCount` entries
/// and locates the v3 tail at offset `4 + 4*typeCount`, so it adapts to any
/// type-table size and stays compatible with a shorter v2 header.
struct CsCapsHeader: Equatable {
    var capsVersion: UInt8 = 0
    var maxBindings: UInt8 = 0
    var typeCount: UInt8 = 0
    var nounCount: UInt8 = 0
    var types: [CsTypeDesc] = []
    var maxIrCommands: UInt8 = 0   // v3 tail: IR command sub-slots (0 if pre-v3)

    static func fromData(_ data: Data) -> CsCapsHeader? {
        guard data.count >= 4 else { return nil }
        let b = data.startIndex
        let typeCount = data[b + 2]
        guard data.count >= 4 + Int(typeCount) * 4 else { return nil }
        var types: [CsTypeDesc] = []
        for i in 0..<Int(typeCount) {
            let o = b + 4 + i * 4
            types.append(CsTypeDesc(
                actions: UInt16(data[o]) | (UInt16(data[o + 1]) << 8),
                pinCount: data[o + 2],
                pinClass: data[o + 3]))
        }
        // The v3 tail (max_ir_commands) sits after the variable-length type
        // table; absent on a v2 header, in which case IR is unavailable.
        let tail = b + 4 + Int(typeCount) * 4
        let maxIr: UInt8 = data.count > tail ? data[tail] : 0
        return CsCapsHeader(capsVersion: data[b + 0], maxBindings: data[b + 1],
                            typeCount: typeCount, nounCount: data[b + 3], types: types,
                            maxIrCommands: maxIr)
    }
}

/// Per-noun descriptor returned by REQ_GET_CS_CAPS, wValue = noun index
/// (12 bytes in v2; spec §2.5).  Says the noun's kind, enum size, unit-encoded
/// range, unit, target addressing, and the action mask it accepts.  An
/// `actions == 0` noun is unavailable on this platform (e.g. ADAT on RP2040).
struct CsNounDesc: Equatable {
    var kind: UInt8 = 0        // CS_KIND_*
    var enumCount: UInt8 = 0   // valid enum values 0..enumCount-1 (ENUM only)
    var actions: UInt16 = 0    // CS_ACT_BIT mask this noun accepts; 0 = unavailable here
    var minQ8: Int16 = 0       // continuous range low end, unit-encoded (2.1)
    var maxQ8: Int16 = 0       // continuous range high end, unit-encoded
    var unit: UInt8 = 0        // CS_UNIT_*
    var targetKind: UInt8 = 0  // CS_TARGET_*
    var targetCount: UInt8 = 0 // valid target values 0..targetCount-1; 0 when untargeted
    var dflags: UInt8 = 0      // CS_NDF_* (deferred apply)

    /// True when the noun addresses a channel (or channel + band).
    var isTargeted: Bool { targetKind != CS_TARGET_NONE && targetCount > 0 }
    /// True when the noun addresses a filter band (needs an `index` picker too).
    var hasBand: Bool { targetKind == CS_TARGET_DSP_BAND }

    static func fromData(_ data: Data) -> CsNounDesc? {
        guard data.count >= 12 else { return nil }
        let b = data.startIndex
        func i16(_ off: Int) -> Int16 {
            Int16(bitPattern: UInt16(data[b + off]) | (UInt16(data[b + off + 1]) << 8))
        }
        return CsNounDesc(
            kind: data[b + 0], enumCount: data[b + 1],
            actions: UInt16(data[b + 2]) | (UInt16(data[b + 3]) << 8),
            minQ8: i16(4), maxQ8: i16(6),
            unit: data[b + 8], targetKind: data[b + 9],
            targetCount: data[b + 10], dflags: data[b + 11])
    }
}

/// REQ_GET_CS_STATUS response (32 bytes in v3; spec §2.6).  `lastStatus`/
/// `lastSlot` report the most recent deferred SET's outcome (`lastSlot` =
/// 0x80|n for an IR sub-slot, 0xFF for save/revert); `dirty` = the live config
/// differs from flash (unsaved preview); `activeMask` (uint16) bit N = binding N
/// is live; `slotStatus[N]` = that slot's per-apply health.  The v3 tail adds
/// the IR component's active mask, learn state, and per-command health.
struct CsStatusPacket: Equatable {
    var lastStatus: UInt8 = 0
    var lastSlot: UInt8 = 0
    var maxBindings: UInt8 = 0
    var dirty: Bool = false        // Byte 3: 1 = unsaved live changes (v3)
    var activeMask: UInt16 = 0     // Bytes 4-5 (LE): bit N = binding N is live
    var slotStatus: [UInt8] = Array(repeating: 0, count: CS_MAX_BINDINGS)   // Bytes 6-21
    var irActiveMask: UInt8 = 0    // Byte 22: bit N = IR command N is live (v3)
    var irLearnState: UInt8 = 0    // Byte 23: CS_IR_LEARN_STATE_* (v3)
    var irCmdStatus: [UInt8] = Array(repeating: 0, count: CS_MAX_IR_COMMANDS)   // Bytes 24-31

    /// True when binding `slot` is live (its `activeMask` bit is set).
    func isSlotActive(_ slot: Int) -> Bool {
        slot >= 0 && slot < CS_MAX_BINDINGS && (activeMask & (UInt16(1) << UInt16(slot))) != 0
    }

    /// This slot's per-apply health code (0 = ok / cleared).
    func slotHealth(_ slot: Int) -> UInt8 {
        slot >= 0 && slot < slotStatus.count ? slotStatus[slot] : 0
    }

    /// True when IR command sub-slot `n` is live (valid, learned, receiver up).
    func isIrCmdActive(_ sub: Int) -> Bool {
        sub >= 0 && sub < CS_MAX_IR_COMMANDS && (irActiveMask & (UInt8(1) << UInt8(sub))) != 0
    }

    /// This IR sub-slot's per-apply health code (0 = ok / cleared).
    func irCmdHealth(_ sub: Int) -> UInt8 {
        sub >= 0 && sub < irCmdStatus.count ? irCmdStatus[sub] : 0
    }

    static func fromData(_ data: Data) -> CsStatusPacket? {
        // Base (v2) layout is 22 bytes; the v3 tail (IR fields) runs to 32.
        guard data.count >= 22 else { return nil }
        let b = data.startIndex
        var slots: [UInt8] = []
        for i in 0..<CS_MAX_BINDINGS { slots.append(data[b + 6 + i]) }
        var irStatus = Array(repeating: UInt8(0), count: CS_MAX_IR_COMMANDS)
        var irActive: UInt8 = 0
        var learn: UInt8 = 0
        if data.count >= 32 {
            irActive = data[b + 22]
            learn = data[b + 23]
            for i in 0..<CS_MAX_IR_COMMANDS { irStatus[i] = data[b + 24 + i] }
        }
        return CsStatusPacket(
            lastStatus: data[b + 0], lastSlot: data[b + 1], maxBindings: data[b + 2],
            dirty: data[b + 3] != 0,
            activeMask: UInt16(data[b + 4]) | (UInt16(data[b + 5]) << 8), slotStatus: slots,
            irActiveMask: irActive, irLearnState: learn, irCmdStatus: irStatus)
    }
}

/// One learned IR remote-button command (16 bytes; spec §2.7).  Semantically a
/// button-shaped binding: the noun/action/target/value/step fields follow the
/// same CsBinding rules, fired by the learned `code` instead of a GPIO edge.
/// The same bytes appear on the wire (REQ_SET/GET_CS_IR_CMD) and in flash.
struct IrCommand: Equatable {
    var noun: UInt8 = 0            // Byte 0: CsNoun
    var action: UInt8 = 0         // Byte 1: CsAction (button subset)
    var flags: UInt8 = 0          // Byte 2: CS_FLAG_WRAP / CS_FLAG_REPEAT only
    var target: UInt8 = 0         // Byte 3: channel address for targeted nouns
    var index: UInt8 = 0          // Byte 4: filter band for CS_TARGET_DSP_BAND
    var proto: UInt8 = 0          // Byte 5: CS_IR_PROTO_*; 0 (NONE) = empty sub-slot
    var value: Int16 = 0          // Bytes 6-7: SET/MOMENTARY target, unit-encoded
    var step: Int16 = 0           // Bytes 8-9: INC/DEC size; 0 = the unit default
    // Bytes 10-11: reserved (0)
    var code: UInt32 = 0          // Bytes 12-15 (LE): the learned code; 0 = never learned

    /// True when the sub-slot holds a learned command (not CS_IR_PROTO_NONE).
    var isConfigured: Bool { proto != CS_IR_PROTO_NONE }

    /// Serialize to the 16-byte wire layout.  Bytes 10-11 are reserved (0).
    func toData() -> Data {
        var d = Data(count: 16)
        d[0] = noun
        d[1] = action
        d[2] = flags
        d[3] = target
        d[4] = index
        d[5] = proto
        func put16(_ v: Int16, _ off: Int) {
            let u = UInt16(bitPattern: v)
            d[off] = UInt8(u & 0xFF); d[off + 1] = UInt8((u >> 8) & 0xFF)
        }
        put16(value, 6)
        put16(step, 8)
        // 10-11 reserved (0)
        for i in 0..<4 { d[12 + i] = UInt8((code >> (8 * UInt32(i))) & 0xFF) }
        return d
    }

    /// Parse the 16-byte wire layout.  Returns nil if too short.
    static func fromData(_ data: Data) -> IrCommand? {
        guard data.count >= 16 else { return nil }
        let b = data.startIndex
        func i16(_ off: Int) -> Int16 {
            Int16(bitPattern: UInt16(data[b + off]) | (UInt16(data[b + off + 1]) << 8))
        }
        let code = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[b + 12 + $1]) << (8 * UInt32($1))) }
        return IrCommand(
            noun: data[b + 0], action: data[b + 1], flags: data[b + 2],
            target: data[b + 3], index: data[b + 4], proto: data[b + 5],
            value: i16(6), step: i16(8), code: code)
    }
}

/// Result of REQ_CS_IR_LEARN, wValue = 2 (8 bytes; spec §3.6.1):
/// {state, protocol, 0, 0, code_le32}.  `state` is CS_IR_LEARN_STATE_DONE (2)
/// with protocol/code valid, or _TIMEOUT (3) / _ARMED (1) / _IDLE (0).
struct CsIrLearnResult: Equatable {
    var state: UInt8 = 0
    var proto: UInt8 = 0
    var code: UInt32 = 0

    var isDone: Bool { state == CS_IR_LEARN_STATE_DONE }
    var isTimeout: Bool { state == CS_IR_LEARN_STATE_TIMEOUT }

    static func fromData(_ data: Data) -> CsIrLearnResult? {
        guard data.count >= 8 else { return nil }
        let b = data.startIndex
        let code = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[b + 4 + $1]) << (8 * UInt32($1))) }
        return CsIrLearnResult(state: data[b + 0], proto: data[b + 1], code: code)
    }
}

// MARK: - Test Signal Generator Wire Structs
//
// Wire-format structs mirroring firmware `siggen.h`
// (test_signals_spec.md §3).  All packed, little-endian; floats are IEEE-754
// single precision.  The generator is transient: never persisted to flash,
// stopped by preset load and factory reset.

/// The 36-byte generator configuration - payload of REQ_SIGGEN_SET_CONFIG and
/// response of REQ_SIGGEN_GET_CONFIG (spec §3.1).  p1..p4 are per-type
/// parameters (spec §2); duration/repeat/gap depend on the timing model
/// (spec §6).
struct SiggenConfig: Equatable {
    var version: UInt8 = SIGGEN_CFG_VERSION
    var signalType: UInt8 = 0          // SiggenType 0..14
    var channelMask: UInt16 = 0        // bit i = output i; clamped to valid outputs
    var invertMask: UInt16 = 0         // polarity-inverted subset of channelMask
    var flags: UInt8 = 0               // SIGGEN_FLAG_* bitmask
    var levelDB: Float = -20.0         // peak level dBFS, -120..0
    var durationMS: UInt32 = 0         // timing-model dependent
    var repeatCount: UInt16 = 0        // timing-model dependent (0 = infinite)
    var gapMS: UInt16 = 0              // inter-cycle silence
    var p1: Float = 0
    var p2: Float = 0
    var p3: Float = 0
    var p4: Float = 0

    /// Serialize to the 36-byte wire layout.  Byte 7 is reserved (0).
    func toData() -> Data {
        var d = Data(count: 36)
        d[0] = version
        d[1] = signalType
        func putU16(_ v: UInt16, _ off: Int) {
            d[off] = UInt8(v & 0xFF)
            d[off + 1] = UInt8((v >> 8) & 0xFF)
        }
        func putU32(_ v: UInt32, _ off: Int) {
            for i in 0..<4 { d[off + i] = UInt8((v >> (8 * i)) & 0xFF) }
        }
        func putF32(_ v: Float, _ off: Int) { putU32(v.bitPattern, off) }
        putU16(channelMask, 2)
        putU16(invertMask, 4)
        d[6] = flags
        // 7 reserved (0)
        putF32(levelDB, 8)
        putU32(durationMS, 12)
        putU16(repeatCount, 16)
        putU16(gapMS, 18)
        putF32(p1, 20)
        putF32(p2, 24)
        putF32(p3, 28)
        putF32(p4, 32)
        return d
    }

    /// Parse the 36-byte wire layout.  Returns nil if too short.
    static func fromData(_ data: Data) -> SiggenConfig? {
        guard data.count >= 36 else { return nil }
        let b = data.startIndex
        func u16(_ off: Int) -> UInt16 {
            UInt16(data[b + off]) | (UInt16(data[b + off + 1]) << 8)
        }
        func u32(_ off: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[b + off + $1]) << (8 * $1)) }
        }
        func f32(_ off: Int) -> Float { Float(bitPattern: u32(off)) }
        return SiggenConfig(
            version: data[b + 0], signalType: data[b + 1],
            channelMask: u16(2), invertMask: u16(4), flags: data[b + 6],
            levelDB: f32(8), durationMS: u32(12),
            repeatCount: u16(16), gapMS: u16(18),
            p1: f32(20), p2: f32(24), p3: f32(28), p4: f32(32))
    }
}

/// REQ_SIGGEN_GET_STATUS response (16 bytes; spec §3.2).  `state` already
/// folds in the fade overlay (FADE_IN / FADE_OUT).
struct SiggenStatus: Equatable {
    var version: UInt8 = SIGGEN_CFG_VERSION
    var state: UInt8 = SIGGEN_STATE_IDLE
    var signalType: UInt8 = 0          // active or last SiggenType
    var activeChannel: UInt8 = 0xFF    // walk channel; 0xFF when not walking
    var elapsedMS: UInt32 = 0
    var cyclesDone: UInt16 = 0
    var stopReason: UInt8 = SIGGEN_STOP_NONE
    var currentFreq: Float = 0         // instantaneous sweep Hz; 0 when not sweeping

    var isRunning: Bool { state != SIGGEN_STATE_IDLE }

    static func fromData(_ data: Data) -> SiggenStatus? {
        guard data.count >= 16 else { return nil }
        let b = data.startIndex
        func u32(_ off: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[b + off + $1]) << (8 * $1)) }
        }
        return SiggenStatus(
            version: data[b + 0], state: data[b + 1],
            signalType: data[b + 2], activeChannel: data[b + 3],
            elapsedMS: u32(4),
            cyclesDone: UInt16(data[b + 8]) | (UInt16(data[b + 9]) << 8),
            stopReason: data[b + 10],
            currentFreq: Float(bitPattern: u32(12)))
    }
}

/// Caps header returned by REQ_SIGGEN_GET_CAPS, wValue = 0xFFFF (8 bytes;
/// spec §3.3).  `multitoneMax` and `outputChannels` are the two
/// platform-dependent fields (RP2040: 5/8, RP2350: 9/16).
struct SiggenCapsHeader: Equatable {
    var version: UInt8 = 0
    var typeCount: UInt8 = 0
    var outputChannels: UInt8 = 0
    var multitoneMax: UInt8 = 0
    var validChannelMask: UInt16 = 0

    static func fromData(_ data: Data) -> SiggenCapsHeader? {
        guard data.count >= 8 else { return nil }
        let b = data.startIndex
        return SiggenCapsHeader(
            version: data[b + 0], typeCount: data[b + 1],
            outputChannels: data[b + 2], multitoneMax: data[b + 3],
            validChannelMask: UInt16(data[b + 4]) | (UInt16(data[b + 5]) << 8))
    }
}

/// One of the four per-parameter descriptors inside a SiggenTypeDesc
/// (13 bytes each; spec §3.4).  Floats are unaligned on the wire.
struct SiggenParamDesc: Equatable {
    var semantic: UInt8 = SIGGEN_PARAM_UNUSED
    var min: Float = 0
    var max: Float = 0
    var def: Float = 0

    var isUsed: Bool { semantic != SIGGEN_PARAM_UNUSED }
}

/// Per-type descriptor returned by REQ_SIGGEN_GET_CAPS with wValue = type
/// index (62 bytes; spec §3.4).  The authoritative source for parameter
/// ranges and defaults - already reflects the running platform's
/// multitone_max.
struct SiggenTypeDesc: Equatable {
    var id: UInt8 = 0
    var name: String = ""              // NUL-padded 8-char short name on the wire
    var timingModel: UInt8 = SIGGEN_TIMING_CONTINUOUS
    var params: [SiggenParamDesc] = Array(repeating: SiggenParamDesc(), count: 4)

    static func fromData(_ data: Data) -> SiggenTypeDesc? {
        guard data.count >= 62 else { return nil }
        let b = data.startIndex
        func f32(_ off: Int) -> Float {
            Float(bitPattern: (0..<4).reduce(UInt32(0)) {
                $0 | (UInt32(data[b + off + $1]) << (8 * $1))
            })
        }
        let nameBytes = data[(b + 1)..<(b + 9)].prefix { $0 != 0 }
        var params: [SiggenParamDesc] = []
        for i in 0..<4 {
            let o = 10 + i * 13
            params.append(SiggenParamDesc(
                semantic: data[b + o],
                min: f32(o + 1), max: f32(o + 5), def: f32(o + 9)))
        }
        return SiggenTypeDesc(
            id: data[b + 0],
            name: String(decoding: nameBytes, as: UTF8.self),
            timingModel: data[b + 9],
            params: params)
    }
}

// MARK: - View Model

class DSPViewModel: ObservableObject {
    /// Per-input preamp (dB).  Always `MAX_MATRIX_INPUTS` (8) wide: indices 0/1
    /// are the stereo USB L/R bus (also the master chain), 2-7 are the extra
    /// USB channels in RP2350 8-channel input mode.  Indices 2-7 stay 0 on
    /// stereo-only firmware.
    @Published var preampDB: [Float] = Array(repeating: 0.0, count: MAX_MATRIX_INPUTS)
    @Published var preampLinked: Bool = true
    @Published var masterVolumeDB: Float = 0.0
    /// Vendor-channel "user volume" — same field as the UAC1 host slider
    /// (`audio_state.volume`), driven via REQ_SET_USER_VOLUME (0xDA).
    /// Used as the sidebar volume control when input source is non-USB.
    /// Range: -60.0 ... 0.0 dB.
    @Published var userVolumeDB: Float = 0.0
    @Published var bypass: Bool = false
    @Published var channelData: [Int: [FilterParams]] = [:]
    /// Crossover bands per EQ channel.  Only output channels (eqCh >= chOut1) carry
    /// real entries; master channels are kept empty since crossover is
    /// rejected pre-matrix-mixer per spec §1.  Always 4 bands per channel
    /// (the 16-byte WireBandParams entries mapped to wire band indices 20..23).
    @Published var xoverData: [Int: [FilterParams]] = [:]
    @Published var channelVisibility: [Int: Bool] = [:]
    @Published var channelDelays: [Int: Float] = [:]
    @Published var loudnessEnabled: Bool = false
    @Published var loudnessRefSPL: Float = 83.0
    @Published var loudnessIntensity: Float = 100.0
    @Published var crossfeedEnabled: Bool = false
    @Published var crossfeedPreset: Int = 0
    @Published var crossfeedFreq: Float = 700.0
    @Published var crossfeedFeed: Float = 4.5
    @Published var crossfeedITD: Bool = true

    // Matrix mixer state (up to 8 inputs x 9 outputs).  Backing arrays are
    // always MAX_MATRIX_INPUTS rows so crosspoint bindings for inputs 2-7 are
    // always valid; the UI renders only `numMatrixInputs` of them.  Rows 2-7
    // stay all-false / 0 dB on stereo-only firmware.
    @Published var matrixRouting = Array(repeating: Array(repeating: false, count: 9), count: MAX_MATRIX_INPUTS)
    @Published var matrixGain = Array(repeating: Array(repeating: Float(0.0), count: 9), count: MAX_MATRIX_INPUTS)
    @Published var matrixInvert = Array(repeating: Array(repeating: false, count: 9), count: MAX_MATRIX_INPUTS)
    @Published var outputEnabled = Array(repeating: false, count: 9)
    @Published var outputGainDB = Array(repeating: Float(0.0), count: 9)
    @Published var outputMuted = Array(repeating: false, count: 9)
    @Published var outputDelayMS = Array(repeating: Float(0.0), count: 9)
    @Published var channelNames: [String] = DSPViewModel.defaultChannelNames(for: "")
    @Published var core1Mode: Int = 0  // 0=IDLE, 1=PDM, 2=EQ_WORKER
    @Published var outputPins: [UInt8] = [6, 7, 8, 9, 10]  // GPIO pins for SPDIF 1-4 + PDM

    // Volume Leveller state
    @Published var levellerEnabled: Bool = false
    @Published var levellerAmount: Float = 100.0
    @Published var levellerSpeed: Int = 0        // 0=Slow, 1=Medium, 2=Fast
    @Published var levellerMaxGainDB: Float = 24.0
    @Published var levellerLookahead: Bool = false
    @Published var levellerGateDB: Float = -70.0

    // I2S configuration state
    @Published var outputSlotTypes: [UInt8] = [0, 0, 0, 0]  // Per-slot: 0=S/PDIF, 1=I2S
    @Published var i2sBckPin: UInt8 = 14      // BCK GPIO (LRCLK = BCK + 1)
    @Published var mckEnabled: Bool = false
    @Published var mckPin: UInt8 = 13
    @Published var mckMultiplier: Int = 128   // 128 or 256
    @Published var sampleRateHz: UInt32 = 0   // live device sample rate (REQ_GET_STATUS wValue=15)

    // Input source state
    @Published var inputSource: Int = 0               // 0=USB, 1=SPDIF, 2=I2S
    @Published var inputSourceSupported: Bool = false  // false if firmware STALLs 0xE1
    @Published var spdifRxPin: UInt8 = 11             // GPIO pin for SPDIF RX

    // I2S input state (firmware wire format V12+).  `i2sInputSupported` is
    // false on older firmware that STALLs REQ_GET_I2S_RX_PIN (0xF2) or returns
    // a pre-V12 bulk payload.  See i2s_multi_input.md.
    @Published var i2sInputSupported: Bool = false
    /// Active I2S input channel count: 2 / 4 / 6 / 8 (1..4 stereo pairs).
    /// Multichannel (>2) is RP2350-only; RP2040 is stereo (always 2).
    @Published var i2sInputChannels: Int = 2
    /// Per-stereo-pair I2S RX data GPIO (pair 0..3).  Pair p carries input
    /// channels 2p, 2p+1.  Pairs 1..3 are RP2350-only.
    @Published var i2sRxPins: [UInt8] = I2S_RX_PIN_DEFAULTS
    @Published var i2sInputRateHz: UInt32 = 48000               // selected I2S input rate

    /// Max I2S stereo pairs / channels for this platform (RP2350 = 4 pairs / 8 ch,
    /// RP2040 = 1 pair / 2 ch).  Used to gate the multichannel I2S UI.
    var i2sMaxPairs: Int { platformName == "RP2040" ? 1 : I2S_RX_MAX_PAIRS_RP2350 }
    var i2sMaxInputChannels: Int { i2sMaxPairs * 2 }
    /// True when the device can do multichannel (>2) I2S input.
    var supportsMultichannelI2S: Bool { i2sInputSupported && platformName == "RP2350" }
    /// Number of currently-active I2S stereo pairs (count / 2).
    var i2sActivePairs: Int { max(1, i2sInputChannels / 2) }

    // LG Sound Sync — per-preset enable for LG TV optical-out volume decode.
    // `lgSoundSyncSupported` is set when V8+ bulk data is parsed or when an
    // explicit fetch returns a value.  Live runtime status (present/volume/
    // muted) is observed by StatsViewModel rather than mirrored here.
    @Published var lgSoundSyncEnabled: Bool = false
    @Published var lgSoundSyncSupported: Bool = false

    // DAC hardware mute — board-level config that drives a GPIO pin into
    // the DAC's mute input before clock-stop on pipeline reset.  Per-board
    // attribute, persisted in the firmware's directory sector (not per
    // preset).  `dacHwMuteSupported` flips true when the firmware responds
    // to REQ_GET_DAC_HW_MUTE_CONFIG (V10+ wire format).
    @Published var dacHwMuteConfig: DacHwMuteConfig = DacHwMuteConfig()
    @Published var dacHwMuteSupported: Bool = false

    // ADAT bulk output — streams all 8 main output channels as one ADAT
    // lightpipe signal on a single GPIO (RP2350 only).  `adatSupported` flips
    // true when the firmware answers REQ_GET_ADAT_STATUS (0xCE); older firmware
    // and RP2040 STALL / return zeros and the Outputs page hides the section.
    // Config (enable + pin) is part of the IO block governed by
    // `presetOutputConfigMode`; `adatStatus` is the live engine state, refreshed
    // by polling and by the NOTIFY_EVT_ADAT_STATE push.  See adat_output_spec.md.
    @Published var adatSupported: Bool = false
    @Published var adatEnabled: Bool = false
    @Published var adatPin: UInt8 = ADAT_PIN_DEFAULT
    @Published var adatStatus: AdatStatus = AdatStatus()

    // External control interfaces (UART / I2C target) - device-level config
    // exposing the vendor-command surface to an external microcontroller.
    // `controlInterfacesSupported` flips true when the firmware answers
    // REQ_GET_CTRL_IFACE_STATUS (0xF9); older firmware STALLs and the Settings
    // page hides itself.  See control_interfaces_spec.md.
    @Published var uartCtrlConfig: UartCtrlConfig = UartCtrlConfig()
    @Published var i2cCtrlConfig: I2cCtrlConfig = I2cCtrlConfig()
    @Published var ctrlIfaceStatus: CtrlIfaceStatus = CtrlIfaceStatus()
    @Published var controlInterfacesSupported: Bool = false

    // Control Surfaces - user-wired physical controls (buttons, switches, pots,
    // encoders, indicator LEDs) bound to firmware parameters on spare GPIOs.
    // Device-global config (stored in the preset directory, survives factory
    // reset).  `controlSurfacesSupported` flips true when the firmware answers
    // REQ_GET_CS_CAPS (0x86); older firmware STALLs and the Settings page hides
    // itself.  The picker UI is built entirely from the device-served caps
    // (`csCaps` + `csNounDescs`), never from hardcoded tables (spec §4).  See
    // control_surfaces_spec.md.
    @Published var controlSurfacesSupported: Bool = false
    @Published var csCaps: CsCapsHeader = CsCapsHeader()
    @Published var csNounDescs: [CsNounDesc] = []
    @Published var csBindings: [CsBinding] = Array(repeating: CsBinding(), count: CS_MAX_BINDINGS)
    @Published var csStatus: CsStatusPacket = CsStatusPacket()
    /// Device-persistent per-slot names (spec §3.4), read at connect and written
    /// on rename.  Empty = unnamed.  These are directory metadata, outside the
    /// Apply/Save/Revert preview: a name SET persists immediately.
    @Published var csNames: [String] = Array(repeating: "", count: CS_MAX_BINDINGS)
    /// Learned IR remote-button commands (spec §2.7), one per sub-slot.  Only
    /// meaningful while a CS_TYPE_IR component (the receiver) is configured.
    @Published var csIrCommands: [IrCommand] = Array(repeating: IrCommand(), count: CS_MAX_IR_COMMANDS)
    /// True while a v3 firmware exposes the IR receiver component + command table
    /// (caps `max_ir_commands` > 0 and the type table carries CS_TYPE_IR).
    var csIrSupported: Bool {
        csCaps.maxIrCommands > 0 && csCaps.typeCount > UInt8(CS_TYPE_IR)
    }
    /// True when the live Control Surfaces config has unsaved preview changes.
    var csDirty: Bool { csStatus.dirty }

    // Test signal generator (siggen) - onboard measurement/diagnostic signals
    // injected into the output mix buffers.  Transient only: never persisted,
    // stopped by preset load / factory reset.  `siggenSupported` flips true
    // when the firmware answers REQ_SIGGEN_GET_CAPS (0xA8); older firmware
    // STALLs and the Tools window shows an unsupported notice.  `siggenDraft`
    // is the host-side editing config (what Start sends); `siggenStatus` is
    // the live engine state, refreshed by polling and by the
    // NOTIFY_EVT_SIGGEN_STATE push.  See test_signals_spec.md.
    @Published var siggenSupported: Bool = false
    @Published var siggenCaps: SiggenCapsHeader = SiggenCapsHeader()
    @Published var siggenTypeDescs: [SiggenTypeDesc] = []
    @Published var siggenDraft: SiggenConfig = SiggenConfig(
        signalType: SIGGEN_SINE, channelMask: 0x0003, p1: 1000)
    @Published var siggenStatus: SiggenStatus = SiggenStatus()

    /// Device-served parameter descriptor table for a type, or nil before the
    /// caps fetch (the UI falls back to the spec §2 defaults table).
    func siggenTypeDesc(for type: UInt8) -> SiggenTypeDesc? {
        siggenTypeDescs.first { $0.id == type }
    }

    // Preset state
    @Published var presetOccupied: UInt16 = 0
    @Published var presetNames: [String] = Array(repeating: "", count: 10)
    @Published var activePresetSlot: Int = 0      // 0-9, always valid
    @Published var presetStartupMode: Int = 0     // 0 = specified default, 1 = last active
    @Published var presetDefaultSlot: Int = 0
    @Published var presetOutputConfigMode: Int = OUTPUT_CONFIG_MODE_WITH_PRESET
    @Published var presetMasterVolumeMode: Int = MASTER_VOLUME_MODE_INDEPENDENT

    @Published var platformName: String = ""

    /// Device MAX input channels, read from the bulk header (byte 4): 2 for
    /// RP2040, 8 for RP2350.  This is the capability flag and also defines the
    /// channel-index base for outputs (CH_OUT_1 = num_input_channels).  Defaults
    /// to the stereo base until the first bulk fetch.
    @Published var numInputChannels: Int = BASE_MATRIX_INPUTS

    /// Live ACTIVE input count (2/4/6/8), driven by the host's USB audio format.
    /// Read from the status packet and the NOTIFY_EVT_INPUT_FORMAT push; used to
    /// lay out exactly that many input strips (sidebar + matrix).  Always >= 2.
    @Published var activeInputChannels: Int = BASE_MATRIX_INPUTS

    /// True when the device supports multichannel (>2) USB input: an RP2350 on
    /// V16 firmware reporting 8 inputs.  Gates all multichannel UI (spec §4).
    var supports8chInput: Bool {
        platformName == "RP2350"
            && firmwareWireFormatVersion == WIRE_FORMAT_VERSION
            && numInputChannels == MAX_MATRIX_INPUTS
    }

    /// First output's unified channel index (CH_OUT_1 = device max inputs).
    /// 8 on RP2350, 2 on RP2040.  Output EQ channel = output index + chOut1.
    var chOut1: Int { platformName == "RP2040" ? BASE_MATRIX_INPUTS : MAX_MATRIX_INPUTS }

    /// Unified EQ/channel index for a matrix output index (0-8).
    func eqChannel(forOutput output: Int) -> Int { output + chOut1 }

    /// Number of input strips to render: the live active count (>= 2).
    var numMatrixInputs: Int { max(BASE_MATRIX_INPUTS, min(activeInputChannels, chOut1)) }

    // Firmware version tuple parsed from REQ_GET_PLATFORM (data[1] = major,
    // data[2] high nibble = minor, data[2] low nibble = patch).  nil before
    // the first successful fetchPlatform().
    @Published var firmwareVersion: (major: Int, minor: Int, patch: Int)? = nil

    /// Bulk wire-format version (WIRE_FORMAT_VERSION), captured from byte 0 of
    /// the last REQ_GET_BULK_PARAMS reply.  This - not the firmware release
    /// version, which lagged behind - is the reliable signal for filter-type
    /// capabilities: the crossover-type renumber and first-order all-pass
    /// shipped in V13, the first-order shelves in V14.  0 before the first
    /// successful bulk fetch.
    @Published var firmwareWireFormatVersion: Int = 0

    /// First-order all-pass (FilterType.allPass1) shipped in wire format V13,
    /// which also renumbered the crossover types to 32..63.  Hidden from the
    /// PEQ picker until we've confirmed a V13+ firmware so we never send the
    /// new type byte (or the renumbered crossover values) to firmware that
    /// would misinterpret it.
    var firmwareSupportsFirstOrderAllPass: Bool { firmwareWireFormatVersion >= 13 }

    /// First-order low/high shelves (FilterType.lowShelf1 / .highShelf1)
    /// shipped in wire format V14.  Hidden from the PEQ picker until confirmed.
    var firmwareSupportsFirstOrderShelves: Bool { firmwareWireFormatVersion >= 14 }

    /// Notch filter type was added in firmware 1.1.4.  Older firmware won't
    /// recognize the type byte and would reject or misbehave on REQ_SET_EQ_PARAM.
    /// Defaults to `false` when the version is unknown (pre-connection) so the
    /// UI is conservative — the option becomes available the moment we confirm
    /// a supporting firmware.
    var firmwareSupportsNotch: Bool {
        guard let v = firmwareVersion else { return false }
        return (v.major, v.minor, v.patch) >= (1, 1, 4)
    }

    /// AllPass filter shipped in firmware 1.1.4.  Older firmware won't
    /// recognize the type byte and would reject or misbehave on REQ_SET_EQ_PARAM.
    /// Defaults to `false` when the version is unknown (pre-connection) so the
    /// UI is conservative — the option becomes available the moment we confirm
    /// a supporting firmware.
    var firmwareSupportsAllPass: Bool {
        guard let v = firmwareVersion else { return false }
        return (v.major, v.minor, v.patch) >= (1, 1, 4)
    }

    /// Per-band bypass shipped in firmware 1.1.4.  Older firmware STALLs the
    /// new opcodes; the bypass byte at offset 3 of EqParamPacket is also the
    /// legacy `reserved` byte, so sending bypass=1 is safe but ignored.
    var firmwareSupportsBandBypass: Bool {
        guard let v = firmwareVersion else { return false }
        return (v.major, v.minor, v.patch) >= (1, 1, 4)
    }

    /// Crossover stage (V11 wire format) shipped alongside crossover_filters_spec.
    /// Tracked via the bulk-transfer format version: firmware that returns a
    /// V11 payload accepts crossover writes at band indices 20..23.  Defaults
    /// to false until we've parsed a bulk reply, so the UI tab can hide itself
    /// on pre-V11 firmware.
    @Published var firmwareSupportsCrossover: Bool = false

    /// Wire band index for the i-th crossover band (0..3 → 20..23).  Single
    /// source of truth so view-model and view code agree about addressing.
    /// Crossover moved to base 20 (XOVER_BAND_BASE) to open a reserved gap at
    /// bands 10..19 for future PEQ-count growth - see firmware config.h.
    static func crossoverWireBand(_ localBand: Int) -> Int { 20 + localBand }
    static let crossoverBandsPerChannel = 4
    static let firstCrossoverWireBand = 20
    @Published var isDeviceConnected: Bool = false
    @Published var availableDevices: [DSPiDevice] = []
    @Published var selectedDevice: DSPiDevice? = nil

    /// Snapshot of state at last save/load point for unsaved changes detection
    var savedSnapshot: PresetSnapshot?

    // Platform-aware layout (platformName is set once at connection, safe to read from poll queue).
    // V16 unified channel model: inputs 0..chOut1-1, outputs chOut1..numChannels-1.
    var numChannels: Int { chOut1 + numOutputChannels }   // 7 (RP2040) / 17 (RP2350)
    var numOutputChannels: Int { platformName == "RP2040" ? 5 : 9 }
    var pdmOutputIndex: Int { numOutputChannels - 1 }     // matrix output index (4 / 8)
    // EQ-worker outputs that share Core 1 with the PDM sub (matrix output indices).
    var eqWorkerRange: ClosedRange<Int> { platformName == "RP2040" ? 2...3 : 2...7 }
    var numOutputSlots: Int { platformName == "RP2040" ? 2 : 4 }
    var anySlotIsI2S: Bool { outputSlotTypes.prefix(numOutputSlots).contains(1) }
    private(set) var isOverviewMode: Bool = true
    @Published var activeEqChannel: Int? = nil

    // Live Data
    let meters = DSPMeterModel()

    /// Returns true if the matrix output is disabled or muted.
    func isOutputInactive(_ outputIndex: Int) -> Bool {
        !outputEnabled[outputIndex] || outputMuted[outputIndex]
    }

    func isPresetOccupied(_ slot: Int) -> Bool { presetOccupied & (1 << slot) != 0 }

    /// Returns the name of the feature currently claiming `pin`, or nil
    /// if free.  `excluding` lets the caller skip its own claim — e.g.
    /// the DAC-mute picker passes `.dacMute` so its own pin isn't
    /// reported as a conflict against itself.
    ///
    /// Single source of truth: HardwareSettingsTab AND GlobalSettingsTab
    /// both call this so a pin assigned in one tab can't quietly appear
    /// as "available" in the other.
    func pinInUseBy(_ pin: UInt8, excluding consumer: PinConsumer? = nil) -> String? {
        // SPDIF / I2S output slot pins.
        for slot in 0..<numOutputSlots {
            if consumer != .output(slot) && outputPins[slot] == pin {
                return "Output \(slot + 1)"
            }
        }
        // PDM (Subwoofer) — its outputPins index is numOutputSlots.
        let pdmIdx = numOutputSlots
        if pdmIdx < outputPins.count,
           consumer != .output(pdmIdx),
           outputPins[pdmIdx] == pin {
            return "Subwoofer"
        }
        if consumer != .i2sBck {
            if pin == i2sBckPin { return "I2S BCK" }
            if pin == i2sBckPin &+ 1 { return "I2S LRCLK" }
        }
        if consumer != .mck && pin == mckPin { return "I2S MCK" }
        if consumer != .spdifRx && inputSourceSupported && pin == spdifRxPin { return "S/PDIF RX" }
        // I2S RX data pins.  Mirrors the firmware's two-tier rule:
        //   - Assigning an I2S RX pin itself keeps ALL configured pair pins
        //     mutually distinct (firmware i2s_rx_pair_pin_taken), so a pair can't
        //     land on another pair's pin even if that pair is currently inactive.
        //   - Every OTHER consumer (outputs, MCK, BCK, S/PDIF RX, DAC mute) only
        //     sees the *active* pairs as reserved (firmware is_pin_in_use), so
        //     inactive placeholder pins never lock GPIOs out of other functions
        //     while in a lower channel mode.
        if i2sInputSupported {
            let assigningI2SRx: Bool
            if case .some(.i2sRx) = consumer { assigningI2SRx = true } else { assigningI2SRx = false }
            let pairsReserved = assigningI2SRx ? i2sMaxPairs : i2sActivePairs
            for pair in 0..<min(pairsReserved, i2sRxPins.count) where consumer != .i2sRx(pair) && i2sRxPins[pair] == pin {
                return i2sMaxPairs > 1 ? "I2S RX \(pair + 1)" : "I2S RX"
            }
        }
        if consumer != .dacMute,
           dacHwMuteConfig.enabled,
           dacHwMuteConfig.pin != DAC_HW_MUTE_PIN_NONE,
           pin == dacHwMuteConfig.pin {
            return "DAC Mute"
        }
        // ADAT owns its GPIO only while enabled (mirrors the firmware: a
        // disabled ADAT stream holds no pin, so its GPIO is free for other uses).
        if consumer != .adatOut, adatSupported, adatEnabled, pin == adatPin {
            return "ADAT Output"
        }
        // External control interfaces reserve their pins only while LIVE (a
        // disabled interface, or one kept down by a boot pin-collision, holds
        // no GPIOs) - mirrors the firmware's is_pin_in_use rule (spec §5.3).
        if consumer != .uartCtrl, ctrlIfaceStatus.uartLive,
           pin == uartCtrlConfig.txPin || pin == uartCtrlConfig.rxPin {
            return "UART Control"
        }
        if consumer != .i2cCtrl, ctrlIfaceStatus.i2cLive,
           pin == i2cCtrlConfig.sdaPin || pin == i2cCtrlConfig.sclPin {
            return "I2C Control"
        }
        // Control Surfaces reserve their GPIO(s) only while the binding is LIVE
        // (its active_mask bit is set) - a cleared binding, or one kept down by
        // a boot pin-collision, holds no GPIOs.  Mirrors the firmware's
        // control_surfaces_owns_pin rule (spec §10).
        for slot in 0..<min(csBindings.count, CS_MAX_BINDINGS)
        where consumer != .controlSurface(slot) && csStatus.isSlotActive(slot) {
            let bind = csBindings[slot]
            if bind.gpio0 == pin || (bind.gpio1 != CS_GPIO_UNUSED && bind.gpio1 == pin) {
                return "Control Surface \(slot + 1)"
            }
        }
        return nil
    }

    let usb: USBDevice
    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "com.foxdac.poll", qos: .userInteractive)

    init(usb: USBDevice = AppState.shared.usb) {
        self.usb = usb

        // Initialize Default Data (V16 unified model: inputs 0..chOut1-1 are
        // first-class EQ channels; outputs chOut1..numChannels-1 add crossover).
        // platformName is empty at init, so chOut1 defaults to the RP2350 base
        // (8); fetchAllParams repopulates once the device platform is known.
        for ch in 0..<chOut1 {
            channelData[ch] = Array(repeating: FilterParams(), count: 10)
            channelVisibility[ch] = true
        }
        for outputIdx in 0..<9 {
            let eqCh = eqChannel(forOutput: outputIdx)
            channelData[eqCh] = Array(repeating: FilterParams(), count: 10)
            // Crossover bands default to FLAT (= bypassed) per spec §7.
            xoverData[eqCh] = Array(repeating:
                FilterParams(type: .flat, freq: 1000, q: 0.707, gain: 0), count: 4)
            channelVisibility[eqCh] = outputEnabled[outputIdx]
        }

        // Clean up legacy UserDefaults key
        UserDefaults.standard.removeObject(forKey: "outputNames")

        recomputeAllMagnitudes()

        // Mirror non-host change notifications back into UI.  Host-
        // originated edits (PARAM_SRC_HOST_SET == 1, our own EP0
        // REQ_SET_* writes) already update local state synchronously at
        // the setter call site (e.g. setChannelName, setUserVolume), so
        // we ignore source==HOST to avoid clobbering an in-flight edit
        // with its own stale notification echo.  Every other source is
        // the real payload we care about — in particular
        // PARAM_SRC_UAC1 (7), the OS volume slider writing user_volume
        // over UAC1, plus BULK / PRESET / FACTORY / GPIO / INTERNAL.
        AppState.shared.interruptMonitor.onParamChanged = { [weak self] offset, size, source, payload in
            guard source != 1 /* PARAM_SRC_HOST_SET */ else { return }
            self?.applyNotifiedParamChange(offset: offset, size: size, payload: payload)
        }

        // The host switched USB input format — update the live active input
        // count so the sidebar / matrix relayout to the new channel count.
        AppState.shared.interruptMonitor.onInputFormatChanged = { [weak self] channels in
            guard let self = self else { return }
            let clamped = max(BASE_MATRIX_INPUTS, min(channels, self.chOut1))
            if self.activeInputChannels != clamped {
                self.activeInputChannels = clamped
                if self.isOverviewMode { self.updateSelection(to: nil) }
            }
        }

        // Siggen state pushes (start / stop / completion / reconfigure).
        // The 8-byte event carries state+reason+type+channel; mirror those
        // immediately for a snappy transport UI, then refresh the full
        // status (elapsed / cycles / freq) off the main thread.
        AppState.shared.interruptMonitor.onSiggenState = { [weak self] state, reason, signalType, channel in
            guard let self = self else { return }
            self.siggenStatus.state = state
            self.siggenStatus.stopReason = reason
            self.siggenStatus.signalType = signalType
            self.siggenStatus.activeChannel = channel
            self.pollQueue.async { self.fetchSiggenStatus() }
        }

        // ADAT stream state pushes (start / stop / rate-policy auto-suspend or
        // resume).  The 8-byte event carries enabled+active+pin; mirror those
        // immediately for a snappy Outputs-page status row, then refresh the
        // full AdatStatus (resync / slip counts) off the main thread.
        AppState.shared.interruptMonitor.onAdatState = { [weak self] enabled, active, pin in
            guard let self = self else { return }
            self.adatEnabled = enabled
            self.adatStatus.enabled = enabled
            self.adatStatus.active = active
            if pin != 0 {
                self.adatPin = pin
                self.adatStatus.pin = pin
            }
            self.pollQueue.async { self.fetchAdatStatus() }
        }

        // 1. Subscribe to USB connection changes AND Trigger Fetch
        usb.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                self?.isDeviceConnected = connected
                if !connected {
                    self?.savedSnapshot = nil
                    self?.siggenStatus = SiggenStatus()
                    self?.presetOccupied = 0
                    self?.presetNames = Array(repeating: "", count: 10)
                    self?.activePresetSlot = 0
                    AppState.shared.interruptMonitor.stop()
                }
                if connected {
                    AppState.shared.interruptMonitor.start()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self?.updateSelection(to: nil)
                    }
                    self?.pollQueue.asyncAfter(deadline: .now() + 0.1) {
                        self?.fetchAll()
                    }
                }
            }
            .store(in: &cancellables)

        // Forward device list and selection from USBDevice
        usb.$availableDevices
            .receive(on: RunLoop.main)
            .assign(to: &$availableDevices)

        usb.$selectedDevice
            .receive(on: RunLoop.main)
            .assign(to: &$selectedDevice)

        // 2. Start Polling Timer (Every 60ms) on background queue
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: 0.06)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isDeviceConnected else { return }
            self.fetchStatus()
        }
        timer.resume()
        pollTimer = timer

        // Initial Connect attempt
        usb.reconnect()
    }

    /// Select an input channel for editing (unified EQ channel index 0..chOut1-1),
    /// or pass nil for the overview.  Drives graph curve visibility.
    func updateSelection(to inputChannel: Int?) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if let ch = inputChannel {
                isOverviewMode = false
                activeEqChannel = ch
                // Link L/R: selecting a stereo input (0/1) with link on shows
                // both curves together (and the right pane stays on the click).
                let showBothMasters = ch < BASE_MATRIX_INPUTS && preampLinked
                for eqCh in 0..<numChannels {
                    if showBothMasters && eqCh < BASE_MATRIX_INPUTS {
                        channelVisibility[eqCh] = true
                    } else {
                        channelVisibility[eqCh] = (eqCh == ch)
                    }
                }
            } else {
                isOverviewMode = true
                activeEqChannel = nil
                // Overview: show active input channels + all enabled outputs.
                for eqCh in 0..<numChannels { channelVisibility[eqCh] = false }
                for i in 0..<min(activeInputChannels, chOut1) { channelVisibility[i] = true }
                for outputIdx in 0..<numOutputChannels {
                    channelVisibility[eqChannel(forOutput: outputIdx)] = outputEnabled[outputIdx]
                }
            }
        }
    }

    /// Re-runs the current selection's graph-visibility logic.  Called after
    /// `preampLinked` changes so the graph reflects whether both stereo input
    /// curves should be drawn together.  No-op outside a stereo-input selection.
    func refreshLinkedVisibility() {
        guard let ch = activeEqChannel, ch < BASE_MATRIX_INPUTS else { return }
        updateSelection(to: ch)
    }

    func updateSelectionToOutput(_ outputIdx: Int) {
        isOverviewMode = false
        let eqCh = eqChannel(forOutput: outputIdx)
        activeEqChannel = eqCh
        withAnimation(.easeInOut(duration: 0.2)) {
            for c in 0..<numChannels {
                channelVisibility[c] = (c == eqCh)
            }
        }
    }

    // MARK: - Magnitude / Phase Cache
    @Published var cachedMagnitudes: [Int: [Double]] = [:]
    @Published var cachedPhases: [Int: [Double]] = [:]
    @Published var cachedPhasesUnwrapped: [Int: [Double]] = [:]

    func recomputeMagnitudes(for eqChannel: Int) {
        let peqFilters = channelData[eqChannel] ?? []
        // Crossover is an output-only feature (channels >= chOut1).
        let xoverFilters = (eqChannel >= chOut1) ? (xoverData[eqChannel] ?? []) : []
        let allFilters = peqFilters + xoverFilters
        let isBypassed = bypass && (eqChannel < BASE_MATRIX_INPUTS)
        var results = [Double]()
        var phases = [Double]()
        results.reserveCapacity(201)
        phases.reserveCapacity(201)
        let logMin = log10(Float(10.0)), logMax = log10(Float(20000.0))
        for i in 0...200 {
            let freq = pow(10, logMin + Float(i) / 200.0 * (logMax - logMin))
            results.append(Double(isBypassed ? 0 : DSPMath.responseAt(freq: freq, filters: allFilters)))
            phases.append(Double(isBypassed ? 0 : DSPMath.phaseAt(freq: freq, filters: allFilters)))
        }
        cachedMagnitudes[eqChannel] = results
        cachedPhases[eqChannel] = phases
        cachedPhasesUnwrapped[eqChannel] = DSPMath.unwrapPhase(phases)
    }

    func recomputeAllMagnitudes() {
        for eqCh in 0..<numChannels { recomputeMagnitudes(for: eqCh) }
    }

    // MARK: - Unsaved Changes Detection

    func captureSnapshot() -> PresetSnapshot {
        PresetSnapshot(
            preampDB: preampDB,
            masterVolumeDB: masterVolumeDB,
            masterVolumeMode: presetMasterVolumeMode,
            outputConfigMode: presetOutputConfigMode,
            platformName: platformName,
            bypass: bypass,
            loudnessEnabled: loudnessEnabled,
            loudnessRefSPL: loudnessRefSPL,
            loudnessIntensity: loudnessIntensity,
            crossfeedEnabled: crossfeedEnabled,
            crossfeedPreset: crossfeedPreset,
            crossfeedFreq: crossfeedFreq,
            crossfeedFeed: crossfeedFeed,
            crossfeedITD: crossfeedITD,
            levellerEnabled: levellerEnabled,
            levellerAmount: levellerAmount,
            levellerSpeed: levellerSpeed,
            levellerMaxGainDB: levellerMaxGainDB,
            levellerLookahead: levellerLookahead,
            levellerGateDB: levellerGateDB,
            channelDelays: channelDelays,
            matrixRouting: matrixRouting,
            matrixGain: matrixGain,
            matrixInvert: matrixInvert,
            outputEnabled: outputEnabled,
            outputMuted: outputMuted,
            outputGainDB: outputGainDB,
            outputDelayMS: outputDelayMS,
            channelFilters: channelData.mapValues { $0.map { SnapshotFilterParams(from: $0) } },
            crossoverFilters: xoverData.mapValues { $0.map { SnapshotFilterParams(from: $0) } },
            channelNames: channelNames,
            // Output configuration is captured unconditionally; PresetSnapshot.diff
            // gates the comparison on outputConfigMode so it only contributes to
            // preset dirtiness in WITH_PRESET mode (the master-volume pattern).
            outputPins: outputPins,
            outputSlotTypes: outputSlotTypes,
            i2sBckPin: i2sBckPin,
            mckEnabled: mckEnabled,
            mckPin: mckPin,
            mckMultiplier: mckMultiplier,
            spdifRxPin: spdifRxPin,
            inputSource: inputSourceSupported ? inputSource : nil,
            i2sRxPins: i2sInputSupported ? Array(i2sRxPins.prefix(i2sMaxPairs)) : nil,
            i2sInputChannels: i2sInputSupported ? i2sInputChannels : nil,
            i2sInputRate: i2sInputSupported ? i2sInputRateHz : nil,
            lgSoundSyncEnabled: lgSoundSyncSupported ? lgSoundSyncEnabled : nil,
            adatEnabled: adatSupported ? adatEnabled : nil,
            adatPin: adatSupported ? adatPin : nil
        )
    }

    func updateSavedSnapshot() {
        savedSnapshot = captureSnapshot()
    }

    var hasUnsavedChanges: Bool {
        // Route through computeDiff so the gating matches the alert text exactly:
        // master volume only counts when both snapshots have it (i.e. when the
        // current/baseline modes were WITH_PRESET).  Plain Equatable on
        // PresetSnapshot would say nil != Float and falsely report dirty after
        // a master-volume-mode flip even though no preset-persistent state
        // actually changed.
        guard savedSnapshot != nil else { return false }
        return !computeDiff().changes.isEmpty
    }

    func computeDiff() -> PresetDiff {
        guard let saved = savedSnapshot else { return PresetDiff(changes: []) }
        return PresetSnapshot.diff(from: saved, to: captureSnapshot(), channelNames: channelNames)
    }

    func switchToDevice(_ device: DSPiDevice) {
        guard device != selectedDevice else { return }

        if isDeviceConnected && hasUnsavedChanges {
            let diff = computeDiff()
            let action = PresetAlerts.showUnsavedChangesAlert(diff: diff)
            switch action {
            case .save:
                DispatchQueue.global(qos: .userInitiated).async {
                    if self.presetNames[self.activePresetSlot].isEmpty {
                        self.setPresetName(slot: self.activePresetSlot, name: "Preset \(self.activePresetSlot + 1)")
                    }
                    let saveStatus = self.savePreset(slot: self.activePresetSlot)
                    guard saveStatus == PRESET_OK else {
                        DispatchQueue.main.async {
                            let alert = NSAlert()
                            alert.messageText = "Save Failed"
                            alert.informativeText = "Failed to save preset (error \(saveStatus)). Device switch aborted."
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                        return
                    }
                    self.savedSnapshot = nil
                    self.usb.selectDevice(device)
                }
            case .discard:
                savedSnapshot = nil
                usb.selectDevice(device)
            case .cancel:
                return
            }
        } else {
            savedSnapshot = nil
            usb.selectDevice(device)
        }
    }

    // MARK: - Channel Clipboard

    struct ChannelClipboard {
        let filters: [FilterParams]
        let outputGainDB: Float?
        let outputDelayMS: Float?
        let outputMuted: Bool?
        let sourceName: String
    }

    var channelClipboard: ChannelClipboard? = nil

    func copyChannelParams(eqChannel: Int, name: String) {
        let filters = channelData[eqChannel] ?? []
        if eqChannel >= chOut1 {
            let outIdx = eqChannel - chOut1
            channelClipboard = ChannelClipboard(
                filters: filters,
                outputGainDB: outputGainDB[outIdx],
                outputDelayMS: outputDelayMS[outIdx],
                outputMuted: outputMuted[outIdx],
                sourceName: name
            )
        } else {
            channelClipboard = ChannelClipboard(
                filters: filters,
                outputGainDB: nil, outputDelayMS: nil, outputMuted: nil,
                sourceName: name
            )
        }
    }

    func pasteChannelParams(eqChannel: Int) {
        guard let cb = channelClipboard else { return }
        for (i, filter) in cb.filters.prefix(10).enumerated() {
            setFilter(ch: eqChannel, band: i, p: filter)
        }
        for i in cb.filters.count..<10 {
            setFilter(ch: eqChannel, band: i, p: FilterParams())
        }
        if eqChannel >= chOut1 {
            let outIdx = eqChannel - chOut1
            if let gain = cb.outputGainDB { setOutputGain(output: outIdx, db: gain) }
            if let delay = cb.outputDelayMS { setOutputDelay(output: outIdx, ms: delay) }
            if let muted = cb.outputMuted { setOutputMute(output: outIdx, muted: muted) }
        }
    }

    static func defaultChannelNames(for platform: String) -> [String] {
        return defaultChannelNames(for: platform, slotTypes: [0, 0, 0, 0])
    }

    /// Default channel names for the V16 unified model: inputs first, then
    /// outputs.  Matches firmware get_default_channel_name(): inputs are
    /// "USB L"/"USB R" then "USB 3".."USB 8"; outputs are "<type> N L/R" with
    /// the PDM sub last.  Returns one entry per channel for the platform.
    static func defaultChannelNames(for platform: String, slotTypes: [UInt8]) -> [String] {
        func slotName(_ slot: Int) -> String {
            slot < slotTypes.count && slotTypes[slot] == 1 ? "I2S" : "SPDIF"
        }
        let inputCount = platform == "RP2040" ? BASE_MATRIX_INPUTS : MAX_MATRIX_INPUTS
        let outputCount = platform == "RP2040" ? 5 : 9
        var names: [String] = []
        // Inputs 0..inputCount-1
        for ch in 0..<inputCount {
            switch ch {
            case 0:  names.append("USB L")
            case 1:  names.append("USB R")
            default: names.append("USB \(ch + 1)")
            }
        }
        // Outputs: stereo S/PDIF (or I2S) pairs, PDM sub last.
        for out in 0..<outputCount {
            if out == outputCount - 1 {
                names.append("PDM")
            } else {
                let slot = out / 2
                let side = out % 2 == 0 ? "L" : "R"
                names.append("\(slotName(slot)) \(slot + 1) \(side)")
            }
        }
        return names
    }
}
