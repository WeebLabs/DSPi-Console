import Foundation

// MARK: - Selectable System Clock
//
// Mirrors the firmware's `sys_clock.c` (Documentation/Features/
// selectable_sys_clock.md).  The system clock is a device-global setting kept
// in the flash directory - never in a preset - and applied both at boot and
// live at runtime.  Modes 1 and 2 are overclocks bought purely for DSP
// headroom; the firmware treats "this chip cannot run the stored clock" as a
// first-class case (watchdog breadcrumb -> fallback boot at mode 0), so the app
// has to be able to show and undo a fallback.

/// One selectable clock mode, mirroring firmware `sys_clock_table`.
/// `defaultVreg` is the firmware's floor for the mode: a lower selection is
/// STALLed rather than clamped, so the app never offers one.
struct SysClockModeInfo: Identifiable, Equatable {
    let mode: UInt8
    let hz: UInt32
    let defaultVreg: UInt8

    var id: UInt8 { mode }

    /// "307.2 MHz" / "384 MHz" - trailing ".0" trimmed.
    var label: String {
        let mhz = Double(hz) / 1_000_000.0
        return mhz == mhz.rounded()
            ? String(format: "%.0f MHz", mhz)
            : String(format: "%.1f MHz", mhz)
    }

    static let all: [SysClockModeInfo] = [
        SysClockModeInfo(mode: SYS_CLOCK_MODE_307P2, hz: 307_200_000, defaultVreg: 12),  // 1.15 V
        SysClockModeInfo(mode: SYS_CLOCK_MODE_384,   hz: 384_000_000, defaultVreg: 13),  // 1.20 V
        SysClockModeInfo(mode: SYS_CLOCK_MODE_480,   hz: 480_000_000, defaultVreg: 15),  // 1.30 V
    ]

    static func info(for mode: UInt8) -> SysClockModeInfo {
        all.first { $0.mode == mode } ?? all[0]
    }

    /// Voltage selections the firmware accepts for this mode: the mode's own
    /// default and every step above it, up to the platform ceiling.  Anything
    /// lower is rejected outright (`sys_clock_vreg_valid`).
    func allowedVregs(ceiling: UInt8 = SYS_CLOCK_VREG_MAX) -> [UInt8] {
        guard defaultVreg <= ceiling else { return [] }
        return Array(defaultVreg...ceiling)
    }

    /// True when the raw selection (0xFF included) is one the firmware accepts
    /// for this mode.  Mirrors `sys_clock_vreg_valid` so the app never sends a
    /// request it knows will STALL.  The default ceiling is the permissive one
    /// (RP2350); callers that know the platform should pass its own.
    func accepts(vregSelection: UInt8, ceiling: UInt8 = SYS_CLOCK_VREG_MAX) -> Bool {
        vregSelection == SYS_CLOCK_VREG_DEFAULT || allowedVregs(ceiling: ceiling).contains(vregSelection)
    }

    /// Voltage ceiling for a platform, mirroring firmware `SYS_CLOCK_VREG_CEIL`.
    /// RP2350 disables the POWMAN voltage limit to reach 1.50 V; every other
    /// platform stops at the regulator's own 1.30 V maximum.
    static func vregCeiling(platform: String) -> UInt8 {
        platform == "RP2350" ? SYS_CLOCK_VREG_1_50 : SYS_CLOCK_VREG_1_30
    }
}

/// Decoded `REQ_GET_SYS_CLOCK` reply (8 bytes).
///
/// Byte layout:
///   0:   active mode (what the device is running right now)
///   1:   stored mode (what the directory holds)
///   2:   stored vreg_sel, raw - 0xFF preserved as "mode default"
///   3:   live vreg enum
///   4:   fallback-active flag
///   5-7: reserved (zero)
///
/// `activeMode` and `storedMode` differ exactly while a fallback boot is in
/// force - i.e. the stored clock did not survive this chip's confirm window.
struct SysClockState: Equatable {
    var activeMode: UInt8 = SYS_CLOCK_MODE_307P2
    var storedMode: UInt8 = SYS_CLOCK_MODE_307P2
    var storedVregSelection: UInt8 = SYS_CLOCK_VREG_DEFAULT
    var liveVreg: UInt8 = 0
    var fallbackActive: Bool = false

    /// Parse the 8-byte reply.  Returns nil on a short read or an
    /// out-of-range mode, so a stray/foreign answer can't be mistaken for
    /// firmware that supports the feature.
    static func fromData(_ data: Data) -> SysClockState? {
        guard data.count >= 8 else { return nil }
        let base = data.startIndex
        let active = data[base + 0]
        let stored = data[base + 1]
        guard active < UInt8(SYS_CLOCK_MODE_COUNT), stored < UInt8(SYS_CLOCK_MODE_COUNT) else { return nil }
        return SysClockState(
            activeMode: active,
            storedMode: stored,
            storedVregSelection: data[base + 2],
            liveVreg: data[base + 3],
            fallbackActive: data[base + 4] != 0
        )
    }

    var activeInfo: SysClockModeInfo { SysClockModeInfo.info(for: activeMode) }
    var storedInfo: SysClockModeInfo { SysClockModeInfo.info(for: storedMode) }

    /// The voltage the stored selection resolves to (mirrors
    /// `sys_clock_resolve_vreg`), for showing what a reboot would apply.
    var storedVreg: UInt8 {
        storedInfo.accepts(vregSelection: storedVregSelection) && storedVregSelection != SYS_CLOCK_VREG_DEFAULT
            ? storedVregSelection
            : storedInfo.defaultVreg
    }

    /// True while the device is running something other than what it stores -
    /// the stored clock crashed inside the firmware's 5 s confirm window and
    /// the fallback latch is holding mode 0 across warm reboots.
    var isFallenBack: Bool { fallbackActive || activeMode != storedMode }
}

/// Outcome of an attempted clock/voltage change, as observed by reading the
/// device back.  The switch itself is disruptive (mute, flash write, PLL
/// relock, full output restart) and a marginal chip may watchdog-reboot
/// instead of completing it, so the app confirms rather than assumes.
enum SysClockApplyResult: Equatable {
    /// The device stored the request and is running it.
    case applied
    /// The device rebooted onto the safe default; the request is still stored.
    case fellBack
    /// The device never came back with the requested state (still switching,
    /// re-enumerating, or gone).
    case unconfirmed
    /// Rejected locally: the firmware would STALL this combination.
    case invalid
}
