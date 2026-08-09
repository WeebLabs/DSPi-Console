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
    case i2sBckSlave    // slave-mode BCK pair (LRCLK = BCK + 1); reserved only in SPLIT clock-pin mode
    case mck
    case spdifRx(Int)   // S/PDIF RX data pin, per input index (0..3)
    case i2sRx(Int)     // I2S input data pin, per stereo pair (0..3)
    case dacMute
    case uartCtrl       // UART control interface (covers both TX and RX pins)
    case i2cCtrl        // I2C control interface (covers both SDA and SCL pins)
    case controlSurface(Int)  // one Control Surfaces binding slot (covers both its GPIOs)
    case adatOut        // ADAT bulk output data pin
    case adatIn         // ADAT input RX data pin
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

// MARK: - I2S Clock-Slave Status Data Model
//
// 16-byte I2sSlaveStatusPacket from REQ_GET_I2S_SLAVE_STATUS (0x8A), little-
// endian.  Mirrors the SPDIF RX lock state machine but for the I2S clock-slave
// role (external master drives BCK/LRCLK; the rate is auto-detected).  See
// Documentation/Features/i2s_slave_input_spec.md §4.  Layout:
//   0:    state       (I2sSlaveState 0-3)
//   1:    clock_mode  (live mode 0=master / 1=slave)
//   2:    lock_count  (locks since boot, saturates 255)
//   3:    loss_count  (losses since boot, saturates 255)
//   4-7:  detected_rate (snapped Hz 44100/48000/96000; 0 unless LOCKED)
//   8-11: measured_hz (raw measured external rate; 0 when no clocks)
//   12-15: reserved
struct I2sSlaveStatus: Equatable {
    var state: UInt8 = 0          // 0=INACTIVE, 1=ACQUIRING, 2=RELOCKING, 3=LOCKED
    var clockMode: UInt8 = 0      // 0=master, 1=slave (live)
    var lockCount: UInt8 = 0
    var lossCount: UInt8 = 0
    var detectedRate: UInt32 = 0
    var measuredHz: UInt32 = 0

    /// Parse the 16-byte wire layout.  Returns nil if too short.
    static func fromData(_ data: Data) -> I2sSlaveStatus? {
        guard data.count >= 16 else { return nil }
        let base = data.startIndex
        func u32(_ off: Int) -> UInt32 {
            UInt32(data[base + off]) | (UInt32(data[base + off + 1]) << 8)
                | (UInt32(data[base + off + 2]) << 16) | (UInt32(data[base + off + 3]) << 24)
        }
        return I2sSlaveStatus(
            state:        data[base + 0],
            clockMode:    data[base + 1],
            lockCount:    data[base + 2],
            lossCount:    data[base + 3],
            detectedRate: u32(4),
            measuredHz:   u32(8)
        )
    }

    var isSlave: Bool { clockMode == I2S_CLOCK_MODE_SLAVE }
    var isLocked: Bool { state == 3 }

    /// User-facing one-line state description.  ACQUIRING / RELOCKING /
    /// INACTIVE all collapse to "waiting for external clock" per spec §7.
    var stateString: String {
        switch state {
        case 0: return "Inactive"
        case 1: return "Acquiring"
        case 2: return "Relocking"
        case 3: return "Locked"
        default: return "Unknown (\(state))"
        }
    }

    /// Colored-dot tint mirroring SpdifRxStatus (gray / yellow / orange / green).
    var stateColor: Color {
        switch state {
        case 0: return .gray
        case 1: return .yellow
        case 2: return .orange
        case 3: return .green
        default: return .gray
        }
    }

    /// Snapped locked rate for display; "-" until LOCKED.
    var detectedRateString: String {
        guard isLocked, detectedRate > 0 else { return "-" }
        return String(format: "%.1f kHz", Double(detectedRate) / 1000.0)
    }

    /// Raw measured external rate for diagnostics; "-" when no clocks at all.
    var measuredHzString: String {
        guard measuredHz > 0 else { return "-" }
        return String(format: "%.1f kHz", Double(measuredHz) / 1000.0)
    }
}

// MARK: - ADAT Input Status Data Model
//
// 20-byte AdatInputStatusPacket from REQ_GET_ADAT_INPUT_STATUS (0x6E), little-
// endian.  The lock FSM mirrors the SPDIF/I2S input receivers but for the
// 8-channel ADAT lightpipe.  RP2040 returns all zeros.  See
// Documentation/Features/adat_input_spec.md.  Layout:
//   0:     state       (AdatInputState 0-4)
//   1:     clock_mode  (live mode 0=master / 1=slave)
//   2:     enabled     (configured enable)
//   3:     pin         (configured RX GPIO; 0xFF = unset)
//   4:     rate_ok     (0 while parked because the device rate is above 48 kHz)
//   5:     lock_count  (locks since input start, saturates 255)
//   6:     loss_count  (lock losses since input start, saturates 255)
//   7:     slip_count  (losses caused by header-verification failure)
//   8-9:   header_err  (u16, cumulative header mismatches; wraps)
//   10-11: reserved
//   12-15: detected_rate (Hz; slave: snapped wire rate, master: device rate; 0 unknown)
//   16-19: measured_hz   (slave: raw measured wire rate; 0 in master mode)
struct AdatInputStatus: Equatable {
    var state: UInt8 = 0          // 0=INACTIVE,1=ACQUIRING,2=SYNCING,3=LOCKED,4=RELOCKING
    var clockMode: UInt8 = 0      // 0=master, 1=slave (live)
    var enabled: Bool = false
    var pin: UInt8 = ADAT_INPUT_PIN_UNSET
    var rateOk: Bool = false
    var lockCount: UInt8 = 0
    var lossCount: UInt8 = 0
    var slipCount: UInt8 = 0
    var headerErr: UInt16 = 0
    var detectedRate: UInt32 = 0
    var measuredHz: UInt32 = 0

    /// Parse the 20-byte wire layout.  Returns nil if too short.
    static func fromData(_ data: Data) -> AdatInputStatus? {
        guard data.count >= 20 else { return nil }
        let base = data.startIndex
        func u16(_ off: Int) -> UInt16 {
            UInt16(data[base + off]) | (UInt16(data[base + off + 1]) << 8)
        }
        func u32(_ off: Int) -> UInt32 {
            UInt32(data[base + off]) | (UInt32(data[base + off + 1]) << 8)
                | (UInt32(data[base + off + 2]) << 16) | (UInt32(data[base + off + 3]) << 24)
        }
        return AdatInputStatus(
            state:        data[base + 0],
            clockMode:    data[base + 1],
            enabled:      data[base + 2] != 0,
            pin:          data[base + 3],
            rateOk:       data[base + 4] != 0,
            lockCount:    data[base + 5],
            lossCount:    data[base + 6],
            slipCount:    data[base + 7],
            headerErr:    u16(8),
            detectedRate: u32(12),
            measuredHz:   u32(16)
        )
    }

    var isSlave: Bool { clockMode == ADAT_INPUT_CLOCK_MODE_SLAVE }
    var isLocked: Bool { state == 3 }   // LOCKED

    /// User-facing one-line state description.
    var stateString: String {
        switch state {
        case 0: return "Inactive"
        case 1: return "Acquiring"
        case 2: return "Syncing"
        case 3: return "Locked"
        case 4: return "Relocking"
        default: return "Unknown (\(state))"
        }
    }

    /// Colored-dot tint mirroring the SPDIF / I2S input indicators.
    var stateColor: Color {
        switch state {
        case 0: return .gray
        case 1, 2: return .yellow
        case 3: return .green
        case 4: return .orange
        default: return .gray
        }
    }

    /// Locked / detected rate for display; "-" when unknown or parked.
    var detectedRateString: String {
        guard detectedRate > 0 else { return "-" }
        return String(format: "%.1f kHz", Double(detectedRate) / 1000.0)
    }

    /// Raw measured wire rate (slave diagnostics); "-" when unmeasured.
    var measuredHzString: String {
        guard measuredHz > 0 else { return "-" }
        return String(format: "%.1f kHz", Double(measuredHz) / 1000.0)
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
    // Indicator condition timing (caps v8, spec §6.5), carved from the former
    // reserved2 tail: the raw IND_EQUALS/IND_ABOVE condition must hold this
    // long before the LED follows it, like a PLC TON/TOF timer.  0.1 s units,
    // 0 = immediate.  Legal only on the LED types with those two actions;
    // anything else must write 0 or the device rejects the binding.
    var onDelay: UInt16 = 0       // Bytes 18-19
    var offDelay: UInt16 = 0      // Bytes 20-21
    // Bytes 22-23: reserved2[2] (0)

    /// True when the slot holds a component (not CS_TYPE_NONE).
    var isConfigured: Bool { type != UInt8(CS_TYPE_NONE) }

    /// Serialize to the 24-byte wire layout.  Bytes 9 and 22-23 are reserved (0).
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
        func putU16(_ v: UInt16, _ off: Int) {
            d[off] = UInt8(v & 0xFF)
            d[off + 1] = UInt8((v >> 8) & 0xFF)
        }
        putU16(onDelay, 18)
        putU16(offDelay, 20)
        // 22-23 reserved2 (0)
        return d
    }

    /// Parse the 24-byte wire layout.  Returns nil if too short.
    static func fromData(_ data: Data) -> CsBinding? {
        guard data.count >= 24 else { return nil }
        let b = data.startIndex
        func i16(_ off: Int) -> Int16 {
            Int16(bitPattern: UInt16(data[b + off]) | (UInt16(data[b + off + 1]) << 8))
        }
        func u16(_ off: Int) -> UInt16 {
            UInt16(data[b + off]) | (UInt16(data[b + off + 1]) << 8)
        }
        return CsBinding(
            type: data[b + 0], noun: data[b + 1], action: data[b + 2], flags: data[b + 3],
            gpio0: data[b + 4], gpio1: data[b + 5],
            event: data[b + 6], target: data[b + 7], index: data[b + 8],
            value: i16(10), step: i16(12), rangeMin: i16(14), rangeMax: i16(16),
            onDelay: u16(18), offDelay: u16(20))
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

/// REQ_GET_CS_STATUS response (41 bytes in v6; spec §2.6).  `lastStatus`/
/// `lastSlot` report the most recent deferred SET's outcome (`lastSlot` =
/// 0x80|n for an IR sub-slot, 0xFF for save/revert); `dirty` = the live config
/// differs from flash (unsaved preview); `activeMask` (uint16) bit N = binding N
/// is live; `slotStatus[N]` = that slot's per-apply health.  The v3 tail adds
/// the IR component's active mask, learn state, and per-command health; v6
/// widens that tail to 16 sub-slots (spec §11.2).
struct CsStatusPacket: Equatable {
    var lastStatus: UInt8 = 0
    var lastSlot: UInt8 = 0
    var maxBindings: UInt8 = 0
    var dirty: Bool = false        // Byte 3: 1 = unsaved live changes (v3)
    var activeMask: UInt16 = 0     // Bytes 4-5 (LE): bit N = binding N is live
    var slotStatus: [UInt8] = Array(repeating: 0, count: CS_MAX_BINDINGS)   // Bytes 6-21
    var irActiveMask: UInt16 = 0   // Bytes 22-23 (LE): bit N = IR command N is live (v6; uint8 @22 in v3-v5)
    var irLearnState: UInt8 = 0    // Byte 24: CS_IR_LEARN_STATE_* (v6; byte 23 in v3-v5)
    var irCmdStatus: [UInt8] = Array(repeating: 0, count: CS_MAX_IR_COMMANDS)   // Bytes 25-40 (v6; 24-31 in v3-v5)

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
        sub >= 0 && sub < CS_MAX_IR_COMMANDS && (irActiveMask & (UInt16(1) << UInt16(sub))) != 0
    }

    /// This IR sub-slot's per-apply health code (0 = ok / cleared).
    func irCmdHealth(_ sub: Int) -> UInt8 {
        sub >= 0 && sub < irCmdStatus.count ? irCmdStatus[sub] : 0
    }

    static func fromData(_ data: Data) -> CsStatusPacket? {
        // Three layouts share a prefix: v2 is 22 bytes, v3-v5 add an 8-command
        // IR tail (32 bytes), v6 widens the active mask to uint16 and the
        // command table to 16, pushing learn state to 24 and the statuses to
        // 25 (41 bytes).  Reading a v6 packet at the v3 offsets would take the
        // mask's high byte as the learn state, so the size gate matters.
        guard data.count >= 22 else { return nil }
        let b = data.startIndex
        var slots: [UInt8] = []
        for i in 0..<CS_MAX_BINDINGS { slots.append(data[b + 6 + i]) }
        var irStatus = Array(repeating: UInt8(0), count: CS_MAX_IR_COMMANDS)
        var irActive: UInt16 = 0
        var learn: UInt8 = 0
        if data.count >= 41 {
            irActive = UInt16(data[b + 22]) | (UInt16(data[b + 23]) << 8)
            learn = data[b + 24]
            for i in 0..<CS_MAX_IR_COMMANDS { irStatus[i] = data[b + 25 + i] }
        } else if data.count >= 32 {
            irActive = UInt16(data[b + 22])
            learn = data[b + 23]
            for i in 0..<8 { irStatus[i] = data[b + 24 + i] }
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

// MARK: - Platform Info

/// Lightweight observable holding just the connected device's platform name.
/// `DSPViewModel` republishes ~16x/second (peak/CPU meters via fetchStatus), so
/// any SwiftUI Scene that observed it merely to read `platformName` rebuilt its
/// entire `.commands` menu tree on every tick - which tore down and reopened any
/// open submenu (the "Favorite Profiles" open/close flicker). `platformName`
/// changes only on connect, so the menu bar observes this mirror instead.
final class PlatformInfo: ObservableObject {
    static let shared = PlatformInfo()
    @Published var name: String = ""
    private init() {}
}

// MARK: - View Model

class DSPViewModel: ObservableObject {
    /// Per-input preamp (dB).  Always `MAX_MATRIX_INPUTS` (8) wide: indices 0/1
    /// are the stereo USB L/R bus (also the master chain), 2-7 are the extra
    /// USB channels in RP2350 8-channel input mode.  Indices 2-7 stay 0 on
    /// stereo-only firmware.
    @Published var preampDB: [Float] = Array(repeating: 0.0, count: MAX_MATRIX_INPUTS)

    /// Stereo input pair links, one bit per adjacent pair: bit p couples input
    /// channels 2p and 2p+1.  A linked pair mirrors preamp and PEQ edits across
    /// both halves and draws both curves together - what Link L/R has always
    /// done for inputs 1/2 (pair 0, the only one on by default), now available
    /// on 3/4, 5/6 and 7/8 too.  Persisted per device serial.
    @Published var linkedInputPairs: UInt8 = DSPViewModel.defaultLinkedInputPairs {
        didSet {
            guard linkedInputPairs != oldValue, !isRestoringInputPairLinks else { return }
            Self.storeLinkedInputPairs(linkedInputPairs, serial: selectedDevice?.serial)
        }
    }
    /// Set while a stored mask is being applied so the restore doesn't write
    /// straight back out under the newly selected device's key.
    private var isRestoringInputPairLinks = false
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
    /// Per-output loudness mask (V19+): bit k enables compensation on output
    /// channel k.  Default 0xFFFF = every output compensated.
    @Published var loudnessOutputMask: UInt16 = LOUDNESS_DEFAULT_OUTPUT_MASK
    @Published var crossfeedEnabled: Bool = false
    @Published var crossfeedPreset: Int = 0
    @Published var crossfeedFreq: Float = 700.0
    @Published var crossfeedFeed: Float = 4.5
    @Published var crossfeedITD: Bool = true
    /// Crossfeed output-pair mask (V20+): bit p runs crossfeed on output pair p
    /// (outputs 2p / 2p+1).  Default 0x01 = pair 1 only (outputs 0/1).  Filter
    /// settings stay global; the mask only selects which pairs are crossfed.
    @Published var crossfeedOutputMask: UInt8 = CROSSFEED_DEFAULT_OUTPUT_MASK

    // Psychoacoustic Bass (V23): one global parameter set applied per output
    // channel selected by `psybassOutputMask`, exactly like loudness.  The
    // firmware clamps each value to the range shown; the app enforces the same
    // ranges so its state stays identical without a read-back.
    @Published var psybassEnabled: Bool = false
    @Published var psybassCutoffHz: Float = 80.0      // 30..300 Hz
    @Published var psybassHarmonicsDB: Float = 0.0    // -24..+12 dB
    @Published var psybassDriveDB: Float = 6.0        // 0..18 dB
    @Published var psybassCharacterPct: Float = 50.0  // 0..100 % (warm..aggressive)
    @Published var psybassOriginalDB: Float = 0.0     // -60..0 dB (speaker protection)
    /// Per-output psybass mask: bit k processes output channel k (PDM sub = bit 8
    /// on RP2350 / bit 4 on RP2040).  Default 0xFFFF = every output.
    @Published var psybassOutputMask: UInt16 = PSYBASS_DEFAULT_OUTPUT_MASK

    // Stereo Upmixer (V25): derives Centre + Ls/Rs matrix source rows from a
    // stereo input.  These mirror UpmixConfigPacket (spec §6.1); defaults match
    // the firmware factory defaults so a fresh device and the app agree before
    // the first fetch.  The firmware clamps every float to its documented range;
    // the app enforces the same ranges on commit so state stays identical.
    @Published var upmixEnabled: Bool = false
    @Published var upmixCenterMode: Int = UPMIX_CENTER_MODE_ADAPTIVE       // 0/1/2
    @Published var upmixSurroundMode: Int = UPMIX_SURROUND_MODE_ADAPTIVE   // 0/1/2
    @Published var upmixStrengthPct: Float = 100.0        // 0..100 %
    @Published var upmixCenterWidthPct: Float = 25.0      // 0..100 %
    @Published var upmixThresholdPct: Float = 30.0        // 0..95 %
    @Published var upmixAttackMs: Float = 10.0            // 1..500 ms
    @Published var upmixReleaseMs: Float = 100.0          // 5..2000 ms
    @Published var upmixDetectorHpfHz: Float = 200.0      // 20..1000 Hz
    @Published var upmixSurroundDelayMs: Float = 12.0     // 0..20 ms
    @Published var upmixSurroundHpfHz: Float = 300.0      // 20..2000 Hz
    @Published var upmixSurroundLpfHz: Float = 7000.0     // 1000..20000 Hz
    @Published var upmixDecorrPct: Float = 90.0           // 0..100 %
    /// Centre presence bell gain at 3 kHz / Q 0.6 (V26+).  Stored on the device in
    /// 0.5 dB steps (config byte presence_q1 = dB x 2); the app keeps the dB value.
    @Published var upmixPresenceDB: Float = 0.0           // -12..+12 dB

    // Upmix live telemetry (REQ_UPMIX_GET_STATUS, spec §6.3).  Polled only while
    // the upmixer window is open (`upmixStatusPolling`).
    @Published var upmixActive: Bool = false
    @Published var upmixParkedReason: UInt8 = UPMIX_PARKED_DISABLED
    @Published var upmixCorr: Float = 0.0          // smoothed L/R correlation, -1..+1
    @Published var upmixBalance: Float = 0.0       // level balance, 0 (centred)..1
    @Published var upmixCenterGain: Float = 0.0    // live centre extraction gain, 0..1
    @Published var upmixLsGain: Float = 0.0        // live Ls steering gain, 0..1
    @Published var upmixRsGain: Float = 0.0        // live Rs steering gain, 0..1
    /// Set by the upmixer window while visible so the shared poll timer fetches
    /// UpmixStatus (~16 Hz); left false everywhere else to avoid the extra I/O.
    @Published var upmixStatusPolling: Bool = false

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

    // Volume Leveller state (firmware factory defaults, overwritten on connect)
    @Published var levellerEnabled: Bool = false
    @Published var levellerAmount: Float = 50.0
    @Published var levellerSpeed: Int = 0        // 0=Slow, 1=Medium, 2=Fast
    @Published var levellerMaxGainDB: Float = 15.0
    @Published var levellerLookahead: Bool = true
    @Published var levellerGateDB: Float = -96.0
    // V18 channel masks: bit k = input channel k. Default all-on = classic stereo link.
    @Published var levellerDetectorMask: UInt8 = 0xFF
    @Published var levellerApplyMask: UInt8 = 0xFF

    // I2S configuration state
    @Published var outputSlotTypes: [UInt8] = [0, 0, 0, 0]  // Per-slot: 0=S/PDIF, 1=I2S
    @Published var i2sBckPin: UInt8 = 14      // BCK GPIO (LRCLK = BCK + 1)
    @Published var mckEnabled: Bool = false
    @Published var mckPin: UInt8 = 13
    @Published var mckMultiplier: Int = 128   // 128 or 256
    @Published var sampleRateHz: UInt32 = 0   // live device sample rate (REQ_GET_STATUS wValue=15)

    // Input source state
    @Published var inputSource: Int = 0               // 0=USB, 1=SPDIF, 2=I2S, 4/5/6=SPDIF2/3/4
    @Published var inputSourceSupported: Bool = false  // false if firmware STALLs 0xE1
    @Published var spdifRxPin: UInt8 = 11             // GPIO pin for S/PDIF input 1

    // Multiple S/PDIF inputs (firmware v1.1.5+, probed via REQ_GET_SPDIF_INPUT_CONFIG).
    // `multiSpdifSupported` is false on older firmware that STALLs 0xEF, in which
    // case only input 1 (`spdifRxPin`) exists.  Inputs 2/3/4 are optional and
    // disabled by default; a disabled input's pin is a stored preference only.
    // `spdifInputCount` is the device's own inventory size, so firmware that
    // predates the fourth input simply reports 3 and the extra row never appears.
    @Published var multiSpdifSupported: Bool = false
    @Published var spdifInputCount: Int = 1
    /// GPIO pins for the optional S/PDIF inputs 2/3/4 (indices 1..3).  Always
    /// SPDIF_RX_NUM_INPUTS-1 long; entries past the device's count are unused.
    @Published var spdifRxPinsExt: [UInt8] = Array(SPDIF_RX_PIN_DEFAULTS.dropFirst())
    /// Enable state for the optional S/PDIF inputs 2/3/4 (indices 1..3).
    @Published var spdifExtEnabled: [Bool] = Array(repeating: false, count: SPDIF_RX_NUM_INPUTS - 1)

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

    // I2S clock-slave input mode (firmware wire format V18+).  In SLAVE mode an
    // external master drives BCK/LRCLK and the rate is auto-detected; MASTER
    // (default) keeps DSPi as the clock authority.  `i2sClockModeSupported` is
    // false on firmware that STALLs REQ_GET_I2S_CLOCK_MODE (0x89).  Live lock
    // state arrives via REQ_GET_I2S_SLAVE_STATUS (0x8A) and NOTIFY event 0x09.
    // See i2s_slave_input_spec.md.
    @Published var i2sClockModeSupported: Bool = false
    @Published var i2sClockMode: UInt8 = 0                      // 0=master, 1=slave (live)
    @Published var i2sSlaveStatus: I2sSlaveStatus = I2sSlaveStatus()

    // I2S clock-pin mode (firmware clock_pins_spec.md).  UNIFIED (default) shares
    // one BCK/LRCLK pair for both clock roles; SPLIT gives slave clocking its own
    // pair (`i2sBckPinSlave`, LRCLK = +1), reserved only while SPLIT is active.
    // `i2sClockPinModeSupported` is false on firmware that STALLs 0xFF / reports
    // clock_pin_mode_p1 == 0 in bulk.  Default slave pair 26/27 (RP2350) or 12/13
    // (RP2040); the live value is read back from the device (0xC3 role 1).
    @Published var i2sClockPinModeSupported: Bool = false
    @Published var i2sClockPinMode: UInt8 = 0                   // 0=unified, 1=split
    @Published var i2sBckPinSlave: UInt8 = 26                   // slave-mode BCK; LRCLK = +1

    // ADAT input (firmware wire format V24+, RP2350 only).  A selectable
    // 8-channel input source: one TOSLINK receiver feeds input channels 0..7.
    // `adatInputSupported` is false on firmware that predates the feature (0x6E
    // STALLs) or on RP2040 (the engine is compiled out; 0x6E returns zeros).
    // There is no free default GPIO, so the pin ships unset (0xFF) and must be
    // assigned before the input can be enabled.  Clock mode mirrors I2S: MASTER
    // (default) makes DSPi the rate authority; SLAVE auto-detects the wire rate.
    // Live lock state arrives via REQ_GET_ADAT_INPUT_STATUS (0x6E) and NOTIFY
    // event 0x0B.  See adat_input_spec.md.
    @Published var adatInputSupported: Bool = false
    @Published var adatInputEnabled: Bool = false
    @Published var adatInputPin: UInt8 = ADAT_INPUT_PIN_UNSET
    @Published var adatInputClockMode: UInt8 = 0               // 0=master, 1=slave (live)
    @Published var adatInputStatus: AdatInputStatus = AdatInputStatus()

    /// True when the device is actively running the ADAT input in the clock-slave
    /// role (mode is slave AND ADAT is the selected input source).  Gates the
    /// slave-only lock diagnostics in the ADAT input settings UI.
    var adatInputSlaveActive: Bool {
        adatInputClockMode == ADAT_INPUT_CLOCK_MODE_SLAVE && inputSource == INPUT_SOURCE_ADAT
    }

    /// True when ADAT is the selected input source (drives the 8-channel matrix
    /// layout and the live lock indicator).
    var adatInputActive: Bool { inputSource == INPUT_SOURCE_ADAT }

    /// True when the device is actively running in the I2S clock-slave role
    /// (mode is slave AND I2S is the selected input source).  Gates the
    /// rate/MCK relabelling in the I2S settings UI.
    var i2sSlaveActive: Bool { i2sClockMode == I2S_CLOCK_MODE_SLAVE && inputSource == INPUT_SOURCE_I2S }

    /// Max I2S stereo pairs / channels for this platform (RP2350 = 4 pairs / 8 ch,
    /// RP2040 = 1 pair / 2 ch).  Used to gate the multichannel I2S UI.
    var i2sMaxPairs: Int { platformName == "RP2040" ? 1 : I2S_RX_MAX_PAIRS_RP2350 }
    var i2sMaxInputChannels: Int { i2sMaxPairs * 2 }
    /// True when the device can do multichannel (>2) I2S input.
    var supportsMultichannelI2S: Bool { i2sInputSupported && platformName == "RP2350" }
    /// Number of currently-active I2S stereo pairs (count / 2).
    var i2sActivePairs: Int { max(1, i2sInputChannels / 2) }

    // MARK: - S/PDIF input helpers

    /// GPIO pin configured for a S/PDIF input index (0 = input 1, 1..3 = optional).
    func spdifPin(index: Int) -> UInt8 {
        if index == 0 { return spdifRxPin }
        let i = index - 1
        if spdifRxPinsExt.indices.contains(i) { return spdifRxPinsExt[i] }
        return SPDIF_RX_PIN_DEFAULTS[min(index, SPDIF_RX_PIN_DEFAULTS.count - 1)]
    }

    /// Whether a S/PDIF input index is enabled.  Input 1 is always enabled.
    func spdifInputEnabled(index: Int) -> Bool {
        if index == 0 { return true }
        let i = index - 1
        return spdifExtEnabled.indices.contains(i) ? spdifExtEnabled[i] : false
    }

    /// Map a S/PDIF input index (0..3) to its InputSource enum value (1/4/5/6).
    /// The optional sources are contiguous from INPUT_SOURCE_SPDIF2, matching the
    /// firmware's arithmetic helpers.
    func spdifSource(forIndex index: Int) -> Int {
        index == 0 ? INPUT_SOURCE_SPDIF : INPUT_SOURCE_SPDIF2 + (index - 1)
    }

    /// Map an InputSource enum value (1/4/5/6) back to a S/PDIF input index
    /// (0..3), or nil if it isn't a S/PDIF source.
    func spdifIndex(forSource source: Int) -> Int? {
        if source == INPUT_SOURCE_SPDIF { return 0 }
        let i = source - INPUT_SOURCE_SPDIF2 + 1
        return (1..<SPDIF_RX_NUM_INPUTS).contains(i) ? i : nil
    }

    /// True when any optional S/PDIF input (2, 3 or 4) is enabled — used to
    /// decide whether input 1 should be labelled "S/PDIF 1" vs the bare "S/PDIF".
    var anyOptionalSpdifEnabled: Bool { spdifExtEnabled.contains(true) }

    /// Number of S/PDIF inputs treated as active for the count-selector UI:
    /// the highest enabled input index + 1 (input 1 is always counted).  A
    /// non-consecutive enable state (e.g. only input 3 on) still reports 3 so
    /// every row up to the highest is shown; re-selecting a count normalises it.
    var spdifEnabledCount: Int {
        for idx in stride(from: spdifInputCount - 1, through: 1, by: -1)
        where spdifInputEnabled(index: idx) {
            return idx + 1
        }
        return 1
    }

    /// The list of selectable input-source values for the current device config,
    /// in menu order: USB, S/PDIF 1, any enabled optional S/PDIF inputs, then I2S.
    var inputSourceOptions: [Int] {
        var opts: [Int] = [INPUT_SOURCE_USB, INPUT_SOURCE_SPDIF]
        if multiSpdifSupported {
            for idx in 1..<spdifInputCount where spdifInputEnabled(index: idx) {
                opts.append(spdifSource(forIndex: idx))
            }
        }
        if i2sInputSupported { opts.append(INPUT_SOURCE_I2S) }
        // ADAT is selectable only once it has been enabled with a valid pin
        // (a disabled or pin-less ADAT source is consumed as a no-op by the
        // firmware switch handler, so never offer it).
        if adatInputSupported && adatInputEnabled && adatInputPin != ADAT_INPUT_PIN_UNSET {
            opts.append(INPUT_SOURCE_ADAT)
        }
        return opts
    }

    /// User-facing title for an input-source value.
    func inputSourceTitle(_ source: Int) -> String {
        switch source {
        case INPUT_SOURCE_USB:    return "USB"
        case INPUT_SOURCE_SPDIF:  return anyOptionalSpdifEnabled ? "S/PDIF 1" : "S/PDIF"
        case INPUT_SOURCE_SPDIF2: return "S/PDIF 2"
        case INPUT_SOURCE_SPDIF3: return "S/PDIF 3"
        case INPUT_SOURCE_SPDIF4: return "S/PDIF 4"
        case INPUT_SOURCE_I2S:    return "I2S"
        case INPUT_SOURCE_ADAT:   return "ADAT"
        default: return "Source \(source)"
        }
    }

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
    /// True when the firmware honours the binding's on/off indicator delays
    /// (caps v8).  Nothing in the structure changes, so this is the only signal:
    /// a v7 device rejects a binding carrying a non-zero delay outright (its
    /// reserved2 all-zero check), which is why the fields stay hidden below v8.
    var csIndicatorDelaysSupported: Bool { csCaps.capsVersion >= 8 }
    /// The live Control Surfaces config as of the last moment the device
    /// reported it clean (matching flash): the connect load, a Save, or a
    /// Revert.  Compared against the current live config so a false "unsaved
    /// changes" banner is suppressed when live edits net back to the saved
    /// state (e.g. add a control then delete it).  The firmware's dirty flag is
    /// sticky - it's set on every live SET and only cleared by Save/Revert, so
    /// it cannot represent net-zero churn on its own.  nil until we first
    /// observe a clean device, in which case we trust the firmware flag.
    private var csCleanBindings: [CsBinding]? = nil
    private var csCleanIrCommands: [IrCommand]? = nil
    private var csCleanNames: [String]? = nil

    /// True when the live Control Surfaces config has unsaved preview changes.
    /// Requires the firmware's sticky dirty flag AND a real difference from the
    /// last-saved baseline, so add-then-remove (which leaves live == flash but
    /// keeps the firmware flag set) no longer strands the banner.  Names are
    /// part of the preview (spec 3.4/3.5), so a rename counts here too.
    var csDirty: Bool {
        guard csStatus.dirty else { return false }
        guard let cleanBindings = csCleanBindings, let cleanIr = csCleanIrCommands,
              let cleanNames = csCleanNames else {
            return true   // no known-clean baseline: defer to the firmware flag
        }
        return csBindings != cleanBindings || csIrCommands != cleanIr || csNames != cleanNames
    }

    /// Record the current live config as the clean (== flash) baseline.  Call
    /// on the main thread once the device reports it matches flash: after the
    /// connect load, a successful Save, or a Revert.
    func captureCsCleanSnapshot() {
        csCleanBindings = csBindings
        csCleanIrCommands = csIrCommands
        csCleanNames = csNames
    }

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

    // Mirror into the lightweight PlatformInfo.shared so the menu bar can
    // observe the platform without observing this high-frequency object. Both
    // call sites set this on the main thread, so the mirror update is safe.
    @Published var platformName: String = "" {
        didSet {
            if PlatformInfo.shared.name != platformName {
                PlatformInfo.shared.name = platformName
            }
        }
    }

    /// Device MAX input channels, read from the bulk header (byte 4): 2 for
    /// RP2040, 8 for RP2350.  This is the capability flag and also defines the
    /// channel-index base for outputs (CH_OUT_1 = num_input_channels).  Defaults
    /// to the stereo base until the first bulk fetch.
    @Published var numInputChannels: Int = BASE_MATRIX_INPUTS

    /// Live ACTIVE input count (2/4/6/8), driven by the host's USB audio format.
    /// Read from the status packet and the NOTIFY_EVT_INPUT_FORMAT push.  This is
    /// the device's view: it collapses to a stereo fallback whenever the host
    /// drops the USB streaming interface to alt 0 (idle), so it is NOT used for
    /// layout directly - see `effectiveInputChannels`.  Always >= 2.
    @Published var activeInputChannels: Int = BASE_MATRIX_INPUTS

    /// Host-selected USB output channel count (2/4/6/8) read from CoreAudio, or
    /// nil when the DSPi's CoreAudio device can't be resolved.  Unlike the device
    /// report this survives the host idling to USB alt 0, so it is the
    /// authoritative source for how many input strips to lay out.  Driven by
    /// HostAudioFormatMonitor.
    @Published var hostConfiguredInputChannels: Int? = nil

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

    /// Effective input channel count for layout (>= 2, <= chOut1).  The count is
    /// governed by whichever source is active:
    ///   - USB: the host-selected USB format from CoreAudio (which stays correct
    ///     while the device idles to alt 0), falling back to the live
    ///     device-reported active count only when CoreAudio can't be resolved.
    ///   - S/PDIF (1/4/5/6): always stereo.
    ///   - I2S: the configured I2S input channel count (2/4/6/8).
    /// CoreAudio only reflects the USB stream's format, so it must not drive the
    /// layout when a non-USB source is selected.
    var effectiveInputChannels: Int {
        let base: Int
        switch inputSource {
        case INPUT_SOURCE_SPDIF, INPUT_SOURCE_SPDIF2, INPUT_SOURCE_SPDIF3, INPUT_SOURCE_SPDIF4:
            base = BASE_MATRIX_INPUTS
        case INPUT_SOURCE_I2S:
            base = i2sInputChannels
        case INPUT_SOURCE_ADAT:
            base = 8   // ADAT is always 8 channels (input channels 0..7)
        default:   // USB (or firmware without input switching, which reports USB)
            base = hostConfiguredInputChannels ?? activeInputChannels
        }
        return max(BASE_MATRIX_INPUTS, min(base, chOut1))
    }

    /// Number of input strips to render (sidebar + matrix).
    var numMatrixInputs: Int { effectiveInputChannels }

    // MARK: - Input Pair Links

    /// Number of linkable adjacent input pairs (1/2, 3/4, 5/6, 7/8).
    static let inputPairCount = MAX_MATRIX_INPUTS / 2
    /// Pair 0 (inputs 1/2) linked, matching the long-standing Link L/R default.
    static let defaultLinkedInputPairs: UInt8 = 0b0000_0001

    /// Pair index for an input channel, or nil for anything that isn't an input.
    func inputPair(for channel: Int) -> Int? {
        guard channel >= 0, channel < chOut1 else { return nil }
        return channel / 2
    }

    func isInputPairLinked(_ pair: Int) -> Bool {
        guard pair >= 0, pair < Self.inputPairCount else { return false }
        return linkedInputPairs & (UInt8(1) << pair) != 0
    }

    func setInputPairLinked(_ pair: Int, _ linked: Bool) {
        guard pair >= 0, pair < Self.inputPairCount else { return }
        if linked {
            linkedInputPairs |= UInt8(1) << pair
        } else {
            linkedInputPairs &= ~(UInt8(1) << pair)
        }
    }

    /// The channel an edit on `channel` must be mirrored onto, or nil when the
    /// channel isn't half of a linked pair.  Both halves have to be live, so
    /// dropping to fewer active inputs suspends the higher pairs' links without
    /// forgetting them - they come back when those channels do.
    func linkedPartner(of channel: Int) -> Int? {
        guard let pair = inputPair(for: channel), isInputPairLinked(pair) else { return nil }
        let partner = channel ^ 1
        guard channel < numMatrixInputs, partner < numMatrixInputs else { return nil }
        return partner
    }

    /// Settings that differ between the two halves of a pair.  Linking only
    /// mirrors *future* edits, so anything already divergent stays that way
    /// unless it's reconciled at the moment the link is made.
    ///
    /// Band data that hasn't been fetched yet (an empty side) reports no
    /// mismatch rather than a false one - there's nothing to copy either way.
    func inputPairMismatch(_ a: Int, _ b: Int) -> (bands: Bool, preamp: Bool) {
        let bandsA = channelData[a] ?? []
        let bandsB = channelData[b] ?? []
        let bands = bandsA.isEmpty || bandsB.isEmpty ? false : bandsA != bandsB
        // Trims are stored rounded to 0.1 dB, so anything finer is noise.
        let preamp = abs(preampValue(a) - preampValue(b)) > 0.05
        return (bands, preamp)
    }

    /// Input trim for a channel, 0 for an index outside the preamp array.
    func preampValue(_ channel: Int) -> Float {
        preampDB.indices.contains(channel) ? preampDB[channel] : 0
    }

    /// Reapply the link mask stored for a device.  Called when the selected
    /// device changes; an absent serial (no device) leaves the current mask
    /// alone rather than resetting it on every disconnect.
    func restoreInputPairLinks(forSerial serial: String?) {
        guard let serial, !serial.isEmpty else { return }
        let restored = Self.loadLinkedInputPairs(serial: serial)
        guard restored != linkedInputPairs else { return }
        isRestoringInputPairLinks = true
        linkedInputPairs = restored
        isRestoringInputPairLinks = false
        refreshLinkedVisibility()
    }

    private static func linkedInputPairsKey(_ serial: String) -> String {
        "linkedInputPairs.\(serial)"
    }

    static func storeLinkedInputPairs(_ mask: UInt8, serial: String?) {
        guard let serial, !serial.isEmpty else { return }
        UserDefaults.standard.set(Int(mask), forKey: linkedInputPairsKey(serial))
    }

    static func loadLinkedInputPairs(serial: String?) -> UInt8 {
        guard let serial, !serial.isEmpty,
              let stored = UserDefaults.standard.object(forKey: linkedInputPairsKey(serial)) as? Int
        else { return defaultLinkedInputPairs }
        return UInt8(truncatingIfNeeded: stored)
    }

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

    /// First-order low/high pass (FilterType.lowPass1 / .highPass1) arrived as
    /// an enum-only addition that never bumped the wire format, so there is no
    /// version that marks them exactly.  V27 is ambiguous - it was bumped on
    /// main while the filter branch was still in flight, so early V27 builds
    /// lack the types and post-merge V27 builds have them - which leaves V28 as
    /// the first version that unambiguously carries them.  A post-merge V27
    /// build loses nothing but the 6 dB/oct menu entries.
    var firmwareSupportsFirstOrderPass: Bool { firmwareWireFormatVersion >= 28 }

    /// Volume-leveller detector/apply channel masks (cmds 0xDE/0xDF) shipped in
    /// wire format V18.  Older firmware levels on a fixed channel set, so the
    /// mask grid is hidden and the app leaves both masks alone.
    var firmwareSupportsLevellerMasks: Bool { firmwareWireFormatVersion >= 18 }

    /// True when the connected firmware can represent a filter type.  Every
    /// path that writes bands the user didn't pick one at a time (file import,
    /// configuration import) checks this first: an unrecognised type byte is
    /// rejected or misread by the firmware rather than ignored.
    ///
    /// Only meaningful while connected - every capability flag reads false
    /// before we've confirmed a version, and an offline edit is re-validated
    /// when a device next connects.
    func firmwareSupports(filterType type: FilterType) -> Bool {
        guard isDeviceConnected else { return true }
        switch type {
        case .notch:                  return firmwareSupportsNotch
        case .allPass:                return firmwareSupportsAllPass
        case .allPass1:               return firmwareSupportsFirstOrderAllPass
        case .lowShelf1, .highShelf1: return firmwareSupportsFirstOrderShelves
        case .lowPass1, .highPass1:   return firmwareSupportsFirstOrderPass
        case .linkwitzTransform:      return firmwareSupportsLinkwitzTransform
        default:                      return !type.isCrossover || firmwareSupportsCrossover
        }
    }

    /// True when enabling this output would collide with something already on.
    /// PDM and the Core 1 EQ workers share the same core, so only one side can
    /// run at a time; the firmware refuses the second one rather than choosing.
    func outputEnableWouldConflict(_ output: Int) -> Bool {
        let eqRange = eqWorkerRange
        if output == pdmOutputIndex {
            return eqRange.contains(where: { outputEnabled[$0] })
        }
        if eqRange.contains(output) {
            return outputEnabled[pdmOutputIndex]
        }
        return false
    }

    /// Per-output loudness mask (cmds 0xFA/0xFB) shipped in wire format V19.
    /// Gate the mask UI on this so older firmware (which applies loudness to
    /// everything) never shows the selector.
    var firmwareSupportsLoudnessMask: Bool { firmwareWireFormatVersion >= 19 }

    /// True when the firmware ships the crossfeed output-pair mask (wire V20+).
    /// Older firmware crossfeeds a fixed set of outputs, so the pair selector is
    /// hidden and the app leaves the mask alone.
    var firmwareSupportsCrossfeedMask: Bool { firmwareWireFormatVersion >= 20 }

    /// Linkwitz Transform PEQ type (FilterType.linkwitzTransform) shipped in
    /// wire format V22, which repurposes each WireBandParams' reserved bytes as
    /// the `qp` sidecar.  Hidden from the PEQ picker until confirmed so we never
    /// send type 11 (or an 18-byte payload) to firmware that can't parse it.
    var firmwareSupportsLinkwitzTransform: Bool { firmwareWireFormatVersion >= 22 }

    /// Psychoacoustic Bass (cmds 0x30-0x3D) shipped in wire format V23, which
    /// appends WirePsybassParams to the bulk layout.  The whole feature (window
    /// contents + output mask) is gated on this so older firmware never sees it.
    var firmwareSupportsPsybass: Bool { firmwareWireFormatVersion >= 23 }

    /// Stereo Upmixer (cmds 0x4A-0x4E) shipped in wire format V25 and gained the
    /// presence control in V26; the app is a V26 client (strict version match on
    /// the bulk image), so the whole feature is gated on V26.  RP2350 only: on
    /// RP2040 the SETs STALL
    /// and the GETs return zeros, so the window is hidden there.  Gating on both
    /// the wire version and the platform keeps the feature out of sight on any
    /// device that cannot run it.
    var firmwareSupportsUpmixer: Bool {
        firmwareWireFormatVersion >= 26 && platformName == "RP2350"
    }

    /// True when the upmixer is deriving matrix source rows: it is enabled and
    /// the active input is a plain stereo pair.  Drives the contextual row labels
    /// in the matrix mixer (rows 2-4 become Upmix C / Ls / Rs, spec §3).  Based on
    /// config (not the live parked state) so routing can be set up while parked.
    var upmixDerivesRows: Bool {
        firmwareSupportsUpmixer && upmixEnabled && effectiveInputChannels == BASE_MATRIX_INPUTS
    }

    /// Number of matrix source rows to display.  In stereo + upmix mode this
    /// exceeds the plain input count to expose the derived rows: 3 (L/R + C) when
    /// the surround engine is OFF, 5 (L/R + C + Ls + Rs) otherwise.
    var matrixSourceRowCount: Int {
        guard upmixDerivesRows else { return numMatrixInputs }
        return upmixSurroundMode == UPMIX_SURROUND_MODE_OFF ? 3 : 5
    }

    /// Short label for matrix source `row`, contextual on the upmixer state.
    func matrixRowShortName(_ row: Int) -> String {
        if upmixDerivesRows {
            switch row {
            case 2: return "C"
            case 3: return "Ls"
            case 4: return "Rs"
            default: break
            }
        }
        return MatrixInput.shortName(for: row, count: numMatrixInputs)
    }

    /// Full/tooltip label for matrix source `row`, contextual on the upmixer state.
    func matrixRowFullName(_ row: Int) -> String {
        if upmixDerivesRows {
            switch row {
            case 2: return "Upmix Centre"
            case 3: return "Upmix Left Surround"
            case 4: return "Upmix Right Surround"
            default: break
            }
        }
        return MatrixInput.fullName(for: row, count: numMatrixInputs)
    }

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
    /// Last USB connection error, mirrored from USBDevice so the status dot can
    /// explain a red state instead of leaving the user to guess.
    @Published var connectionError: String? = nil

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
        // Slave-mode clock pair: reserved only in SPLIT clock-pin mode.  In
        // UNIFIED the pair is dormant and constrains nothing (mirrors the
        // firmware i2s_clock_pin_claimed helper - clock_pins_spec.md §1).
        if consumer != .i2sBckSlave && i2sClockPinMode == I2S_CLOCK_PIN_MODE_SPLIT {
            if pin == i2sBckPinSlave { return "I2S Slave BCK" }
            if pin == i2sBckPinSlave &+ 1 { return "I2S Slave LRCLK" }
        }
        if consumer != .mck && pin == mckPin { return "I2S MCK" }
        // S/PDIF RX pins.  Input 1 is always reserved; the optional inputs 2/3/4
        // are reserved only while enabled (a disabled input's pin is invisible
        // to conflict checks, mirroring the firmware's per-input reservation).
        if inputSourceSupported {
            if consumer != .spdifRx(0) && pin == spdifRxPin {
                return multiSpdifSupported && anyOptionalSpdifEnabled ? "S/PDIF 1 RX" : "S/PDIF RX"
            }
            if multiSpdifSupported {
                for idx in 1..<spdifInputCount where spdifInputEnabled(index: idx) {
                    if consumer != .spdifRx(idx) && pin == spdifPin(index: idx) {
                        return "S/PDIF \(idx + 1) RX"
                    }
                }
            }
        }
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
        // The ADAT input may deliberately share the ADAT output pin (zero-hardware
        // loopback self-test), so an ADAT-input assignment never sees the output
        // pin as taken - the sharing exception is one-directional (input onto
        // output), so every other consumer still does.
        if consumer != .adatOut, consumer != .adatIn, adatSupported, adatEnabled, pin == adatPin {
            return "ADAT Output"
        }
        // ADAT input owns its GPIO only while enabled (same rule as the output).
        // Reserved against every other consumer, including the ADAT output - the
        // loopback exception is one-directional, so an output assignment still
        // sees the input pin as taken.
        if consumer != .adatIn, adatInputSupported, adatInputEnabled,
           adatInputPin != ADAT_INPUT_PIN_UNSET, pin == adatInputPin {
            return "ADAT Input"
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

    /// Reports the host-selected USB output channel count from CoreAudio, which
    /// survives the device idling to USB alt 0.  Drives `hostConfiguredInputChannels`.
    private let hostAudioFormatMonitor = HostAudioFormatMonitor()

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
                // The channel set changed, so re-derive which curves are shown -
                // otherwise inputs that just became active would stay hidden.
                self.resetDefaultVisibility()
            }
        }

        // Authoritative input-channel count from the host's selected USB audio
        // format (CoreAudio).  Unlike the device report above, this stays correct
        // while the host idles the streaming interface to alt 0, so it drives the
        // strip layout via effectiveInputChannels.  nil = DSPi not resolvable in
        // CoreAudio; layout then falls back to activeInputChannels.
        hostAudioFormatMonitor.onChannelCountChanged = { [weak self] channels in
            guard let self = self else { return }
            if self.hostConfiguredInputChannels != channels {
                self.hostConfiguredInputChannels = channels
                self.resetDefaultVisibility()
            }
        }
        hostAudioFormatMonitor.start()

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

        // I2S clock-slave lock-state pushes (ACQUIRING / RELOCKING / INACTIVE /
        // LOCKED).  The 9-byte event carries state + detected rate; mirror those
        // immediately for a snappy I2S settings-page indicator, then refresh the
        // full 16-byte status (lock/loss counts, measured Hz) off the main thread.
        AppState.shared.interruptMonitor.onI2sSlaveState = { [weak self] state, detectedRate in
            guard let self = self else { return }
            self.i2sClockModeSupported = true
            self.i2sSlaveStatus.state = state
            self.i2sSlaveStatus.detectedRate = detectedRate
            self.pollQueue.async { self.fetchI2SSlaveStatus() }
        }

        // ADAT input lock-state pushes (INACTIVE / ACQUIRING / SYNCING / LOCKED /
        // RELOCKING).  The 10-byte event carries state + detected rate + live
        // clock mode; mirror those immediately for a snappy ADAT settings-page
        // indicator, then refresh the full 20-byte status off the main thread.
        AppState.shared.interruptMonitor.onAdatInputState = { [weak self] state, detectedRate, clockMode in
            guard let self = self else { return }
            self.adatInputStatus.state = state
            self.adatInputStatus.detectedRate = detectedRate
            self.adatInputStatus.clockMode = clockMode
            self.adatInputClockMode = clockMode
            self.pollQueue.async { self.fetchAdatInputStatus() }
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
                        self?.fetchAll(afterConnect: true)
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

        usb.$errorMessage
            .receive(on: RunLoop.main)
            .assign(to: &$connectionError)

        // Keep the CoreAudio format monitor pinned to the selected unit so a
        // multi-device setup doesn't report another DSPi's host format.
        usb.$selectedDevice
            .receive(on: RunLoop.main)
            .sink { [weak self] device in
                self?.hostAudioFormatMonitor.setPreferredSerial(device?.serial)
                // Input pair links are an app-side preference, so they follow
                // the unit by serial rather than living in the preset.
                self?.restoreInputPairLinks(forSerial: device?.serial)
            }
            .store(in: &cancellables)

        // 2. Start Polling Timer (Every 60ms) on background queue
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: 0.06)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isDeviceConnected else { return }
            self.fetchStatus()
            // Upmix telemetry only while its window is open (~16 Hz, within the
            // spec's 5-20 Hz guidance); skipped everywhere else to avoid the I/O.
            if self.upmixStatusPolling && self.firmwareSupportsUpmixer {
                self.fetchUpmixStatus()
            }
        }
        timer.resume()
        pollTimer = timer

        // Initial Connect attempt
        usb.reconnect()
    }

    /// Pill states as they were on the dashboard, stashed when a channel page
    /// takes the graph over to its single curve and handed back when the user
    /// returns.  nil means "no snapshot to restore" - fall back to the defaults.
    var savedOverviewVisibility: [Int: Bool]?

    /// Select an input channel for editing (unified EQ channel index 0..chOut1-1),
    /// or pass nil for the overview.  Opening a channel page solos its curve;
    /// leaving one restores whatever the user had shown or hidden on the
    /// dashboard, rather than re-deriving the defaults.
    func updateSelection(to inputChannel: Int?) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if let ch = inputChannel {
                // Only snapshot on the way in from the dashboard: hopping
                // between channel pages must not capture a soloed state.
                if isOverviewMode { savedOverviewVisibility = channelVisibility }
                isOverviewMode = false
                activeEqChannel = ch
                // Selecting half of a linked input pair shows both curves
                // together (and the right pane stays on the clicked channel).
                let partner = linkedPartner(of: ch)
                for eqCh in 0..<numChannels {
                    channelVisibility[eqCh] = (eqCh == ch || eqCh == partner)
                }
            } else {
                isOverviewMode = true
                activeEqChannel = nil
                restoreOverviewVisibility()
            }
        }
    }

    /// Re-runs the current selection's graph-visibility logic.  Called after a
    /// pair's link changes so the graph reflects whether both of its curves
    /// should be drawn together.  No-op outside an input selection.
    func refreshLinkedVisibility() {
        guard let ch = activeEqChannel, ch < chOut1 else { return }
        updateSelection(to: ch)
    }

    func updateSelectionToOutput(_ outputIdx: Int) {
        let eqCh = eqChannel(forOutput: outputIdx)
        if isOverviewMode { savedOverviewVisibility = channelVisibility }
        isOverviewMode = false
        activeEqChannel = eqCh
        withAnimation(.easeInOut(duration: 0.2)) {
            for c in 0..<numChannels {
                channelVisibility[c] = (c == eqCh)
            }
        }
    }

    /// Hand the dashboard back its pills, or derive the defaults if the channel
    /// set has changed since the snapshot was taken.
    private func restoreOverviewVisibility() {
        if let saved = savedOverviewVisibility {
            channelVisibility = saved
            savedOverviewVisibility = nil
        } else {
            applyDefaultVisibility()
        }
    }

    /// Curve-visibility defaults: every active input plus every enabled output.
    /// Called when the channel set itself changes (host format switch, device
    /// data arriving); any dashboard snapshot is stale at that point, and a
    /// channel page keeps its soloed curve until the user leaves it.
    func resetDefaultVisibility() {
        savedOverviewVisibility = nil
        guard isOverviewMode else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            applyDefaultVisibility()
        }
    }

    private func applyDefaultVisibility() {
        for eqCh in 0..<numChannels { channelVisibility[eqCh] = false }
        for i in 0..<effectiveInputChannels { channelVisibility[i] = true }
        for outputIdx in 0..<numOutputChannels {
            channelVisibility[eqChannel(forOutput: outputIdx)] = outputEnabled[outputIdx]
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
            loudnessOutputMask: loudnessOutputMask,
            loudnessRefSPL: loudnessRefSPL,
            loudnessIntensity: loudnessIntensity,
            crossfeedEnabled: crossfeedEnabled,
            crossfeedPreset: crossfeedPreset,
            crossfeedFreq: crossfeedFreq,
            crossfeedFeed: crossfeedFeed,
            crossfeedITD: crossfeedITD,
            crossfeedOutputMask: crossfeedOutputMask,
            psybassEnabled: psybassEnabled,
            psybassOutputMask: psybassOutputMask,
            psybassCutoffHz: psybassCutoffHz,
            psybassHarmonicsDB: psybassHarmonicsDB,
            psybassDriveDB: psybassDriveDB,
            psybassCharacterPct: psybassCharacterPct,
            psybassOriginalDB: psybassOriginalDB,
            upmixEnabled: upmixEnabled,
            upmixCenterMode: upmixCenterMode,
            upmixSurroundMode: upmixSurroundMode,
            upmixStrengthPct: upmixStrengthPct,
            upmixCenterWidthPct: upmixCenterWidthPct,
            upmixThresholdPct: upmixThresholdPct,
            upmixAttackMs: upmixAttackMs,
            upmixReleaseMs: upmixReleaseMs,
            upmixDetectorHpfHz: upmixDetectorHpfHz,
            upmixSurroundDelayMs: upmixSurroundDelayMs,
            upmixSurroundHpfHz: upmixSurroundHpfHz,
            upmixSurroundLpfHz: upmixSurroundLpfHz,
            upmixDecorrPct: upmixDecorrPct,
            upmixPresenceDB: upmixPresenceDB,
            levellerEnabled: levellerEnabled,
            levellerAmount: levellerAmount,
            levellerSpeed: levellerSpeed,
            levellerMaxGainDB: levellerMaxGainDB,
            levellerLookahead: levellerLookahead,
            levellerGateDB: levellerGateDB,
            levellerDetectorMask: levellerDetectorMask,
            levellerApplyMask: levellerApplyMask,
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
            spdifRxPinsExt: multiSpdifSupported ? spdifRxPinsExt : nil,
            spdifExtEnabled: multiSpdifSupported ? spdifExtEnabled : nil,
            inputSource: inputSourceSupported ? inputSource : nil,
            i2sRxPins: i2sInputSupported ? Array(i2sRxPins.prefix(i2sMaxPairs)) : nil,
            i2sInputChannels: i2sInputSupported ? i2sInputChannels : nil,
            i2sInputRate: i2sInputSupported ? i2sInputRateHz : nil,
            i2sClockMode: i2sClockModeSupported ? i2sClockMode : nil,
            lgSoundSyncEnabled: lgSoundSyncSupported ? lgSoundSyncEnabled : nil,
            adatEnabled: adatSupported ? adatEnabled : nil,
            adatPin: adatSupported ? adatPin : nil,
            adatInputEnabled: adatInputSupported ? adatInputEnabled : nil,
            adatInputPin: adatInputSupported ? adatInputPin : nil,
            adatInputClockMode: adatInputSupported ? adatInputClockMode : nil
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

        // Pending Settings changes (staged global parameters, unflashed output
        // config) belong to the current device and are discarded on switch -
        // SettingsSaveCoordinator resets when the selected serial changes.
        // Warn so the user can cancel and save first.
        if isDeviceConnected && SettingsSaveCoordinator.shared.hasPendingChanges {
            let alert = NSAlert()
            alert.messageText = "Unsaved Settings Changes"
            alert.informativeText = "Settings has pending changes for the current device that have not been saved. Switching devices will discard them."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Discard and Switch")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

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
        /// Crossover bank, nil when the source was an input (inputs have none).
        let crossover: [FilterParams]?
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
                crossover: xoverData[eqChannel] ?? [],
                outputGainDB: outputGainDB[outIdx],
                outputDelayMS: outputDelayMS[outIdx],
                outputMuted: outputMuted[outIdx],
                sourceName: name
            )
        } else {
            channelClipboard = ChannelClipboard(
                filters: filters, crossover: nil,
                outputGainDB: nil, outputDelayMS: nil, outputMuted: nil,
                sourceName: name
            )
        }
    }

    func pasteChannelParams(eqChannel: Int) {
        guard let cb = channelClipboard else { return }
        // A linked pair mirrors every other filter edit (the FilterListView
        // callbacks do it per band), so a paste has to mirror too or the two
        // channels drift apart.
        let mirror = linkedPartner(of: eqChannel)
        for (i, filter) in cb.filters.prefix(10).enumerated() {
            setFilter(ch: eqChannel, band: i, p: filter)
            if let m = mirror { setFilter(ch: m, band: i, p: filter) }
        }
        for i in cb.filters.count..<10 {
            setFilter(ch: eqChannel, band: i, p: FilterParams())
            if let m = mirror { setFilter(ch: m, band: i, p: FilterParams()) }
        }
        if eqChannel >= chOut1 {
            let outIdx = eqChannel - chOut1
            // Crossover is output-only, so it travels only between outputs.
            // A clipboard taken from an input carries none, and the
            // destination's bank is left alone rather than cleared.
            if let xover = cb.crossover {
                for (i, band) in xover.prefix(DSPViewModel.crossoverBandsPerChannel).enumerated() {
                    setCrossoverBand(ch: eqChannel, localBand: i, p: band)
                }
            }
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
