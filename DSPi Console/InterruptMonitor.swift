//
//  InterruptMonitor.swift
//  DSPi Console
//
//  Receives notification packets from the device's bulk IN endpoint
//  (EP 0x83 on the vendor interface) and presents them in a scrolling log
//  window opened via Tools → Interrupt Monitor.
//
//  Two wire-level protocol versions coexist:
//    v1 (8-byte MASTER_VOLUME packets, legacy)
//    v2 (generic PARAM_CHANGED + discrete events, byte 0 = version = 0x02)
//
//  Both are decoded and displayed here.  See
//  Documentation/Features/notification_protocol_v2_spec.md in the firmware
//  repo for the protocol specification.
//

import Foundation
import SwiftUI
import AppKit
import IOKit
import IOKit.usb

// MARK: - Wire-Level Constants (mirror firmware notify.h / usb_descriptors.h)

// EP 0x83 max packet size.  Bumped from 8 to 64 when the v2 protocol shipped.
// The monitor reads with a 64-byte buffer regardless of the actual packet
// size the device sends — IOKit reports the actual size.
private let NOTIFY_EP_MAX_PKT: UInt32 = 64
private let NOTIFY_EP_ADDRESS: UInt8 = 0x83

// Legacy v1 event (packet byte 0 == event_id when byte 0 < 0x02).
private let NOTIFY_EVT_IDLE: UInt8 = 0x00
private let NOTIFY_EVT_MASTER_VOLUME_V1: UInt8 = 0x01

// v2 protocol: byte 0 == 0x02 (version), byte 1 == event_id.
private let NOTIFY_V2_VERSION: UInt8 = 0x02
private let NOTIFY_EVT_PARAM_CHANGED: UInt8 = 0x02
private let NOTIFY_EVT_BULK_INVALIDATED: UInt8 = 0x03
private let NOTIFY_EVT_PRESET_LOADED: UInt8 = 0x04
private let NOTIFY_EVT_INPUT_FORMAT: UInt8 = 0x05
private let NOTIFY_EVT_SIGGEN_STATE: UInt8 = 0x07
private let NOTIFY_EVT_ADAT_STATE: UInt8 = 0x08
private let NOTIFY_EVT_I2S_SLAVE_STATE: UInt8 = 0x09
private let NOTIFY_EVT_ADAT_INPUT_STATE: UInt8 = 0x0B

// Source tags (from ParamSource enum in firmware notify.h)
private func sourceLabel(_ src: UInt8) -> String {
    switch src {
    case 0: return "?"
    case 1: return "HOST"
    case 2: return "BULK"
    case 3: return "PRESET"
    case 4: return "FACTORY"
    case 5: return "GPIO"
    case 6: return "INTERNAL"
    case 7: return "UAC1"
    default: return String(format: "src=0x%02X", src)
    }
}

// MARK: - Event Model

struct InterruptEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let rawBytes: Data

    /// One-line rendering of the event for the log view.
    var formattedLine: String {
        let ts = InterruptEvent.dateFormatter.string(from: timestamp)
        return "\(ts)  \(decode())"
    }

    /// Decode the raw bytes into a human-readable description.
    private func decode() -> String {
        guard let first = rawBytes.first else { return "(empty)" }

        // v1 single-byte idle keep-alive (should be filtered upstream but be
        // defensive).
        if first == NOTIFY_EVT_IDLE && rawBytes.count <= 1 {
            return "Idle"
        }

        // v2 detection: byte 0 == 0x02 and we have at least a 4-byte header.
        if first == NOTIFY_V2_VERSION && rawBytes.count >= 4 {
            return decodeV2()
        }

        // v1 legacy format: byte 0 is the event ID directly.
        return decodeV1()
    }

    // MARK: - v1 Decoder (legacy)

    private func decodeV1() -> String {
        guard let eventID = rawBytes.first else { return "(empty)" }

        switch eventID {
        case NOTIFY_EVT_MASTER_VOLUME_V1:
            // 8 bytes: [0x01, 0, 0, 0, float_db_LE]
            guard rawBytes.count >= 8 else {
                return column("v1.MasterVolume", "(short: \(rawBytes.count) bytes)")
            }
            let db: Float = rawBytes.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Float.self) }
            let value = db <= -128 ? "MUTE" : String(format: "%+7.2f dB", db)
            return column("v1.MasterVolume", value)

        default:
            let hex = rawBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            return column(String(format: "v1?evt=0x%02X", eventID), hex)
        }
    }

    // MARK: - v2 Decoder

    private func decodeV2() -> String {
        let bytes = rawBytes
        guard bytes.count >= 4 else { return "(short v2)" }
        let eventID = bytes[1]
        let seq = bytes[3]
        let seqStr = String(format: "[%3u]", seq)

        switch eventID {
        case NOTIFY_EVT_PARAM_CHANGED:
            // [ver=2, evt=0x02, flags, seq, off_LE, size_LE, src, 0, 0, 0, value...]
            guard bytes.count >= 12 else {
                return "\(seqStr) v2.ParamChanged (short: \(bytes.count) bytes)"
            }
            let offset = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
            let size   = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
            let source = bytes[8]
            let payloadEnd = min(bytes.count, 12 + Int(size))
            let payload = bytes.subdata(in: 12..<payloadEnd)

            let (name, value) = ParamOffsetDecoder.decode(offset: offset, size: size, payload: payload)
            let srcStr = sourceLabel(source)
            return "\(seqStr) [\(srcStr.padding(toLength: 8, withPad: " ", startingAt: 0))] \(name.padding(toLength: 32, withPad: " ", startingAt: 0))  \(value)"

        case NOTIFY_EVT_BULK_INVALIDATED:
            // 8 bytes: [ver, evt, flags, seq, src, 0, 0, 0]
            let source = bytes.count > 4 ? bytes[4] : 0
            return "\(seqStr) v2.BulkInvalidated            source=\(sourceLabel(source))"

        case NOTIFY_EVT_PRESET_LOADED:
            // 8 bytes: [ver, evt, flags, seq, slot, 0, 0, 0]
            let slot = bytes.count > 4 ? bytes[4] : 0
            return "\(seqStr) v2.PresetLoaded                slot=\(slot)"

        case NOTIFY_EVT_SIGGEN_STATE:
            // 8 bytes: [ver, evt, flags, seq, state, reason, signal_type, channel]
            guard bytes.count >= 8 else {
                return "\(seqStr) v2.SiggenState (short: \(bytes.count) bytes)"
            }
            let states = ["IDLE", "FADE_IN", "RUN", "GAP", "FADE_OUT"]
            let reasons = ["-", "HOST", "COMPLETED", "PRESET", "RECONFIG"]
            let state = Int(bytes[4]) < states.count ? states[Int(bytes[4])] : "state=\(bytes[4])"
            let reason = Int(bytes[5]) < reasons.count ? reasons[Int(bytes[5])] : "reason=\(bytes[5])"
            let channel = bytes[7] == 0xFF ? "-" : "\(bytes[7])"
            return "\(seqStr) v2.SiggenState                 \(state) reason=\(reason) type=\(bytes[6]) ch=\(channel)"

        case NOTIFY_EVT_ADAT_STATE:
            // 8 bytes: [ver, evt, flags, seq, enabled, active, pin, 0]
            guard bytes.count >= 8 else {
                return "\(seqStr) v2.AdatState (short: \(bytes.count) bytes)"
            }
            return "\(seqStr) v2.AdatState                   enabled=\(bytes[4]) active=\(bytes[5]) pin=\(bytes[6])"

        case NOTIFY_EVT_I2S_SLAVE_STATE:
            // 9 bytes: [ver, evt, flags, seq, state, rate_LE(4)].  Note this
            // event is 9 bytes where most v2 events are 8 (per-event length).
            guard bytes.count >= 9 else {
                return "\(seqStr) v2.I2sSlaveState (short: \(bytes.count) bytes)"
            }
            let states = ["INACTIVE", "ACQUIRING", "RELOCKING", "LOCKED"]
            let state = Int(bytes[4]) < states.count ? states[Int(bytes[4])] : "state=\(bytes[4])"
            let rate = UInt32(bytes[5]) | (UInt32(bytes[6]) << 8) | (UInt32(bytes[7]) << 16) | (UInt32(bytes[8]) << 24)
            return "\(seqStr) v2.I2sSlaveState              \(state) rate=\(rate)"

        case NOTIFY_EVT_ADAT_INPUT_STATE:
            // 10 bytes: [ver, evt, flags, seq, state, rate_LE(4), clock_mode].
            guard bytes.count >= 10 else {
                return "\(seqStr) v2.AdatInputState (short: \(bytes.count) bytes)"
            }
            let states = ["INACTIVE", "ACQUIRING", "SYNCING", "LOCKED", "RELOCKING"]
            let state = Int(bytes[4]) < states.count ? states[Int(bytes[4])] : "state=\(bytes[4])"
            let rate = UInt32(bytes[5]) | (UInt32(bytes[6]) << 8) | (UInt32(bytes[7]) << 16) | (UInt32(bytes[8]) << 24)
            let mode = bytes[9] == 1 ? "slave" : "master"
            return "\(seqStr) v2.AdatInputState             \(state) rate=\(rate) mode=\(mode)"

        default:
            let hex = bytes.dropFirst(4).map { String(format: "%02X", $0) }.joined(separator: " ")
            return "\(seqStr) v2?evt=\(String(format: "0x%02X", eventID))  \(hex)"
        }
    }

    private func column(_ name: String, _ value: String) -> String {
        "\(name.padding(toLength: 14, withPad: " ", startingAt: 0))  \(value)"
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        df.timeZone = .current
        return df
    }()
}

// MARK: - Offset → Field Name Decoder (v2 PARAM_CHANGED)

/// Resolves a `WireBulkParams` offset to a human-readable field name and
/// formats the payload according to the field's type.  Layout constants
/// mirror the firmware's `bulk_params.h`.
private enum ParamOffsetDecoder {

    /// Returns (fieldName, formattedValue).  Unknown offsets fall through
    /// to a generic hex dump.
    static func decode(offset: UInt16, size: UInt16, payload: Data) -> (String, String) {
        let off = Int(offset)
        let sz  = Int(size)

        // Header (0..15) — the firmware never writes header fields, but
        // handle defensively so stray writes show up cleanly.
        if off < 16 {
            return ("header+0x\(String(format: "%02X", off))", fmtHex(payload))
        }

        // Global (16..31)
        switch off {
        case 16: return ("global.preamp_gain_db", fmtFloat(payload, suffix: " dB"))
        case 20: return ("global.bypass", fmtBool(payload))
        case 21: return ("global.loudness_enabled", fmtBool(payload))
        case 22: return ("global.loudness_output_mask", fmtHex(payload))
        case 24: return ("global.loudness_ref_spl", fmtFloat(payload, suffix: " dB SPL"))
        case 28: return ("global.loudness_intensity_pct", fmtFloat(payload, suffix: "%"))
        default: break
        }

        // Crossfeed (32..47)
        switch off {
        case 32: return ("crossfeed.enabled", fmtBool(payload))
        case 33: return ("crossfeed.preset", fmtUInt8(payload))
        case 34: return ("crossfeed.itd_enabled", fmtBool(payload))
        case 36: return ("crossfeed.custom_fc", fmtFloat(payload, suffix: " Hz"))
        case 40: return ("crossfeed.custom_feed_db", fmtFloat(payload, suffix: " dB"))
        default: break
        }

        // Legacy channels (48..63)
        if off >= 48 && off <= 59 && (off - 48) % 4 == 0 && sz == 4 {
            return ("legacy.gain_db[\((off - 48) / 4)]", fmtFloat(payload, suffix: " dB"))
        }
        if off >= 60 && off <= 62 && sz == 1 {
            return ("legacy.mute[\(off - 60)]", fmtBool(payload))
        }

        // --- V16 flat layout offsets (unified channel model) ---

        // Delays (64..) — 17 × 4 bytes
        if off >= BULK_DELAYS_OFFSET && off < BULK_DELAYS_OFFSET + 17 * 4 && (off - BULK_DELAYS_OFFSET) % 4 == 0 && sz == 4 {
            return ("delays.delay_ms[\((off - BULK_DELAYS_OFFSET) / 4)]", fmtFloat(payload, suffix: " ms"))
        }

        // Matrix crosspoints (132..) — 8 inputs × 9 outputs × 8 bytes
        if off >= BULK_CROSSPOINT_OFFSET && off < BULK_CROSSPOINT_OFFSET + 8 * 9 * 8 {
            let rel = off - BULK_CROSSPOINT_OFFSET
            let idx = rel / 8
            let sub = rel % 8
            let input = idx / 9
            let output = idx % 9
            if sub == 0 && sz == 8 && payload.count >= 8 {
                let enabled = payload[0] != 0
                let invert  = payload[1] != 0
                let gain: Float = payload.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Float.self) }
                return ("crosspoints[\(input)][\(output)]",
                        "en=\(enabled ? "1" : "0") inv=\(invert ? "1" : "0") \(String(format: "%+6.2f", gain)) dB")
            }
            return ("crosspoints[\(input)][\(output)]+0x\(String(format: "%X", sub))", fmtHex(payload))
        }

        // Matrix outputs (708..) — 9 outputs × 12 bytes
        if off >= BULK_OUTPUTS_OFFSET && off < BULK_OUTPUTS_OFFSET + 9 * 12 {
            let rel = off - BULK_OUTPUTS_OFFSET
            let idx = rel / 12
            let sub = rel % 12
            let name: String
            let value: String
            switch sub {
            case 0:
                name = "outputs[\(idx)].enabled"
                value = fmtBool(payload)
            case 1:
                name = "outputs[\(idx)].mute"
                value = fmtBool(payload)
            case 4:
                name = "outputs[\(idx)].gain_db"
                value = fmtFloat(payload, suffix: " dB")
            case 8:
                name = "outputs[\(idx)].delay_ms"
                value = fmtFloat(payload, suffix: " ms")
            default:
                name = "outputs[\(idx)]+0x\(String(format: "%X", sub))"
                value = fmtHex(payload)
            }
            return (name, value)
        }

        // Pin config (816..)
        if off == BULK_PINS_OFFSET && sz == 1 { return ("pins.num_pin_outputs", fmtUInt8(payload)) }
        if off >= BULK_PINS_OFFSET + 1 && off <= BULK_PINS_OFFSET + 5 && sz == 1 {
            return ("pins.pins[\(off - BULK_PINS_OFFSET - 1)]", fmtUInt8(payload))
        }

        // EQ bands (824..) — 17 × 12 × 16 bytes
        if off >= BULK_EQ_OFFSET && off < BULK_EQ_OFFSET + 17 * 12 * 16 {
            let rel = off - BULK_EQ_OFFSET
            let idx = rel / 16
            let sub = rel % 16
            let ch = idx / 12
            let band = idx % 12
            if sub == 0 && sz == 16 && payload.count >= 16 {
                let type = payload[0]
                let bypass = payload[1]
                let freq: Float = payload.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Float.self) }
                let q:    Float = payload.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Float.self) }
                let gain: Float = payload.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Float.self) }
                return ("eq[\(ch)][\(band)]",
                        String(format: "type=%u  byp=%u  f=%.1f Hz  Q=%.2f  g=%+.2f dB",
                               type, bypass, freq, q, gain))
            }
            return ("eq[\(ch)][\(band)]+0x\(String(format: "%X", sub))", fmtHex(payload))
        }

        // Channel names (4088..) — 17 × 32 bytes
        if off >= BULK_CHANNEL_NAMES_OFFSET && off < BULK_CHANNEL_NAMES_OFFSET + 17 * 32 && (off - BULK_CHANNEL_NAMES_OFFSET) % 32 == 0 && sz == 32 {
            let ch = (off - BULK_CHANNEL_NAMES_OFFSET) / 32
            return ("channel_names[\(ch)]", fmtString(payload))
        }

        // I2S config (4632..)
        if off >= BULK_I2S_OFFSET && off <= BULK_I2S_OFFSET + 3 && sz == 1 {
            let idx = off - BULK_I2S_OFFSET
            let label = payload.first == 1 ? "I2S" : "SPDIF"
            return ("i2s_config.output_types[\(idx)]", "\(payload.first ?? 0) (\(label))")
        }
        switch off {
        case BULK_I2S_OFFSET + 4: return ("i2s_config.bck_pin", fmtUInt8(payload))
        case BULK_I2S_OFFSET + 5: return ("i2s_config.mck_pin", fmtUInt8(payload))
        case BULK_I2S_OFFSET + 6: return ("i2s_config.mck_enabled", fmtBool(payload))
        case BULK_I2S_OFFSET + 7:
            let raw = payload.first ?? 0
            return ("i2s_config.mck_multiplier", "\(raw) (\(raw == 1 ? "256x" : "128x"))")
        default: break
        }

        // Volume leveller (4648..)
        switch off {
        case BULK_LEVELLER_OFFSET:     return ("leveller.enabled", fmtBool(payload))
        case BULK_LEVELLER_OFFSET + 1: return ("leveller.speed", fmtUInt8(payload))
        case BULK_LEVELLER_OFFSET + 2: return ("leveller.lookahead", fmtBool(payload))
        case BULK_LEVELLER_OFFSET + 4: return ("leveller.amount", fmtFloat(payload, suffix: "%"))
        case BULK_LEVELLER_OFFSET + 8: return ("leveller.max_gain_db", fmtFloat(payload, suffix: " dB"))
        case BULK_LEVELLER_OFFSET + 12: return ("leveller.gate_threshold_db", fmtFloat(payload, suffix: " dB"))
        case BULK_LEVELLER_OFFSET + 16: return ("leveller.detector_mask", fmtHex(payload))
        case BULK_LEVELLER_OFFSET + 17: return ("leveller.apply_mask", fmtHex(payload))
        default: break
        }

        // Per-input preamp (4664..) — preamp_db[8]
        if off >= BULK_PREAMP_OFFSET && off < BULK_PREAMP_OFFSET + 8 * 4 && (off - BULK_PREAMP_OFFSET) % 4 == 0 && sz == 4 {
            return ("preamp.preamp_db[\((off - BULK_PREAMP_OFFSET) / 4)]", fmtFloat(payload, suffix: " dB"))
        }

        // Master volume (4696..)
        if off == BULK_MASTER_VOLUME_OFFSET && sz == 4 {
            let db: Float = payload.withUnsafeBytes { $0.load(as: Float.self) }
            let v = db <= -128 ? "MUTE" : String(format: "%+7.2f dB", db)
            return ("master_volume.master_volume_db", v)
        }

        // Input config
        if off == BULK_INPUT_CONFIG_OFFSET && sz == 1 {
            let src = payload.first ?? 0
            let names: [UInt8: String] = [0: "USB", 1: "SPDIF", 2: "I2S", 3: "ADAT",
                                          4: "SPDIF2", 5: "SPDIF3", 6: "SPDIF4"]
            return ("input_config.input_source", "\(src) (\(names[src] ?? "?"))")
        }
        if off == BULK_INPUT_CONFIG_OFFSET + 1 && sz == 1 {
            return ("input_config.spdif_rx_pin", fmtUInt8(payload))
        }
        if off == BULK_INPUT_CONFIG_OFFSET + 2 && sz == 1 {
            return ("input_config.i2s_rx_pin", fmtUInt8(payload))
        }
        if off == BULK_INPUT_CONFIG_OFFSET + 3 && sz == 1 {
            let raw = payload.first ?? 0
            let hz = raw < 3 ? ["44100", "48000", "96000"][Int(raw)] : "?"
            return ("input_config.i2s_input_rate", "\(raw) (\(hz) Hz)")
        }
        if off == BULK_INPUT_ADAT_PIN_OFFSET && sz == 1 {
            let v = payload.first ?? 0
            return ("input_config.adat_input_pin", v == 0 ? "unset" : "GPIO \(v)")
        }
        if off == BULK_INPUT_ADAT_ENABLED_P1_OFFSET && sz == 1 {
            let v = payload.first ?? 0
            let label = v == 0 ? "absent" : (v == 2 ? "enabled" : "disabled")
            return ("input_config.adat_input_enabled_p1", "\(v) (\(label))")
        }
        if off == BULK_INPUT_ADAT_CLOCK_MODE_P1_OFFSET && sz == 1 {
            let v = payload.first ?? 0
            let label = v == 0 ? "absent" : (v == 2 ? "slave" : "master")
            return ("input_config.adat_clock_mode_p1", "\(v) (\(label))")
        }

        // LG Sound Sync (4728..) — first 4 bytes are meaningful; rest reserved.
        if off == BULK_LG_OFFSET && sz == 1 { return ("lg_sound_sync.enabled", fmtBool(payload)) }
        if off == BULK_LG_OFFSET + 1 && sz == 1 { return ("lg_sound_sync.present", fmtBool(payload)) }
        if off == BULK_LG_OFFSET + 2 && sz == 1 {
            let v = payload.first ?? 0xFF
            return ("lg_sound_sync.volume", v == 0xFF ? "—" : "\(v) / 100")
        }
        if off == BULK_LG_OFFSET + 3 && sz == 1 { return ("lg_sound_sync.muted", fmtBool(payload)) }

        // User volume (4744..) — float dB at +0, mute byte at +4.
        if off == BULK_USER_VOLUME_OFFSET && sz == 4 {
            let db: Float = payload.withUnsafeBytes { $0.load(as: Float.self) }
            let v = db <= -128 ? "MUTE" : String(format: "%+7.2f dB", db)
            return ("user_volume.user_volume_db", v)
        }
        if off == BULK_USER_VOLUME_OFFSET + 4 && sz == 1 {
            return ("user_volume.user_mute", fmtBool(payload))
        }

        // ADAT bulk output config (5864..) — enable at +0, data pin at +1.
        if off == BULK_ADAT_OFFSET && sz == 1 { return ("adat_config.enabled", fmtBool(payload)) }
        if off == BULK_ADAT_OFFSET + 1 && sz == 1 {
            let v = payload.first ?? 0
            return ("adat_config.pin", v == 0 ? "default" : "GPIO \(v)")
        }

        // Psychoacoustic Bass (5876..5899) — WirePsybassParams
        if off >= BULK_PSYBASS_OFFSET && off < BULK_PSYBASS_OFFSET + 24 {
            switch off - BULK_PSYBASS_OFFSET {
            case 0:  return ("psybass.enabled", fmtBool(payload))
            case 2:  return ("psybass.output_mask", fmtHex(payload))
            case 4:  return ("psybass.cutoff_hz", fmtFloat(payload, suffix: " Hz"))
            case 8:  return ("psybass.harmonics_db", fmtFloat(payload, suffix: " dB"))
            case 12: return ("psybass.drive_db", fmtFloat(payload, suffix: " dB"))
            case 16: return ("psybass.character_pct", fmtFloat(payload, suffix: "%"))
            case 20: return ("psybass.original_db", fmtFloat(payload, suffix: " dB"))
            default: break
            }
        }

        // Fallback — unknown offset
        return (String(format: "offset=0x%04X size=%d", off, sz), fmtHex(payload))
    }

    // MARK: - Small value formatters

    static func fmtFloat(_ data: Data, suffix: String = "") -> String {
        guard data.count >= 4 else { return "(short)" }
        let v: Float = data.withUnsafeBytes { $0.load(as: Float.self) }
        return String(format: "%+.3f", v) + suffix
    }

    static func fmtBool(_ data: Data) -> String {
        guard let b = data.first else { return "(empty)" }
        return b == 0 ? "0 (false)" : "1 (true)"
    }

    static func fmtUInt8(_ data: Data) -> String {
        guard let v = data.first else { return "(empty)" }
        return "\(v)"
    }

    static func fmtHex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func fmtString(_ data: Data) -> String {
        let nulIdx = data.firstIndex(of: 0) ?? data.endIndex
        let slice = data[data.startIndex..<nulIdx]
        let str = String(data: slice, encoding: .utf8)
            ?? String(data: slice, encoding: .ascii)
            ?? "(invalid)"
        return "\"\(str)\""
    }
}

// MARK: - Monitor (ObservableObject)

class InterruptMonitor: ObservableObject {
    @Published private(set) var events: [InterruptEvent] = []
    @Published var isPaused: Bool = false
    @Published private(set) var isActive: Bool = false
    @Published var errorMessage: String?

    /// Maximum retained events in the rolling log.  Oldest entries are
    /// dropped FIFO when the cap is reached.
    static let maxEvents = 2000

    /// How often notifications are allowed to reach the UI.
    ///
    /// A bound control emits one PARAM_CHANGED per change it makes, and the
    /// firmware samples pots at 1 kHz, so an unwired ADC pin reading noise
    /// floods this endpoint continuously.  Each delivery sets a `@Published`
    /// property, which invalidates every view observing the view model - the
    /// whole Control Surfaces page included, whether or not it shows the
    /// parameter that moved.  At a thousand a second the main thread has
    /// nothing left for the user.
    ///
    /// 25 Hz is past what anyone can see, and only the newest value per
    /// offset is delivered, which is the one that describes the device now.
    /// A change arriving into a quiet monitor still goes straight out, so a
    /// single knob turn or preset load is as immediate as it ever was.
    private static let flushInterval: TimeInterval = 0.04

    /// Newest pending payload per parameter offset, and the order the offsets
    /// first arrived in, so a flush replays them in the order they happened.
    private struct PendingParam {
        var size: UInt16
        var source: UInt8
        var payload: Data
    }
    private var pendingParams: [UInt16: PendingParam] = [:]
    private var pendingOrder: [UInt16] = []
    private var pendingEvents: [InterruptEvent] = []
    private var flushScheduled = false
    private var lastFlush: TimeInterval = 0

    /// Fires on the main thread for every v2 PARAM_CHANGED event regardless
    /// of pause state.  Consumers (e.g. DSPViewModel) use this to mirror
    /// non-host parameter changes back into the UI without waiting for the
    /// next bulk fetch.  Pause only affects the display log.
    var onParamChanged: ((_ offset: UInt16, _ size: UInt16, _ source: UInt8, _ payload: Data) -> Void)?

    /// Fires on the main thread when the host switches the USB input format
    /// (NOTIFY_EVT_INPUT_FORMAT).  Carries the new active input channel count
    /// (2/4/6/8) so the UI can relayout immediately.
    var onInputFormatChanged: ((_ channels: Int) -> Void)?

    /// Fires on the main thread for every siggen state push
    /// (NOTIFY_EVT_SIGGEN_STATE: start, stop, completion, reconfigure).
    /// Carries the SiggenState, SIGGEN_STOP_* reason, active/last signal
    /// type, and the walk channel (0xFF when not walking).
    var onSiggenState: ((_ state: UInt8, _ reason: UInt8, _ signalType: UInt8, _ channel: UInt8) -> Void)?

    /// Fires on the main thread for every ADAT stream state push
    /// (NOTIFY_EVT_ADAT_STATE: start / stop, including rate-policy
    /// auto-suspend/resume).  Carries the configured enable, live active flag,
    /// and configured data pin.
    var onAdatState: ((_ enabled: Bool, _ active: Bool, _ pin: UInt8) -> Void)?

    /// Fires on the main thread for every I2S clock-slave lock-state push
    /// (NOTIFY_EVT_I2S_SLAVE_STATE: ACQUIRING / RELOCKING / INACTIVE / LOCKED).
    /// Carries the I2sSlaveState and the detected rate in Hz (0 unless LOCKED).
    var onI2sSlaveState: ((_ state: UInt8, _ detectedRate: UInt32) -> Void)?

    /// Fires on the main thread for every ADAT input lock-state push
    /// (NOTIFY_EVT_ADAT_INPUT_STATE: INACTIVE / ACQUIRING / SYNCING / LOCKED /
    /// RELOCKING).  Carries the AdatInputState, the detected rate in Hz (0 unless
    /// LOCKED), and the live clock mode (0 master / 1 slave).
    var onAdatInputState: ((_ state: UInt8, _ detectedRate: UInt32, _ clockMode: UInt8) -> Void)?

    private let usb: USBDevice

    /// One reader session per start(). The session owns its vendor-interface
    /// handle and cancellation flag, so a superseded reader (device switch,
    /// stop/start cycle) winds down on its own without touching the current
    /// session's handle or the monitor's published state.
    private final class ReaderSession {
        let interface: USBDevice.InterfaceInterfacePtr
        let pipeRef: UInt8
        var thread: Thread?
        // Written on main, read on the reader thread. Swift Bool reads are
        // effectively atomic on the supported archs.
        var cancelled = false

        // Serializes interface teardown against stop()'s AbortPipe: on unplug
        // the reader can see a device-gone read error and Release the handle
        // on its own thread at the same moment the termination path calls
        // stop() on main. Abort and close must never overlap or run after
        // the Release.
        private let interfaceLock = NSLock()
        private var interfaceClosed = false

        init(interface: USBDevice.InterfaceInterfacePtr, pipeRef: UInt8) {
            self.interface = interface
            self.pipeRef = pipeRef
        }

        /// Wake a blocking ReadPipeTO. Safe to call at any point in the
        /// session's life; a no-op once the interface has been closed.
        func abortPipe() {
            interfaceLock.lock()
            defer { interfaceLock.unlock() }
            guard !interfaceClosed else { return }
            _ = interface.pointee!.pointee.AbortPipe(interface, pipeRef)
        }

        /// Close and release the interface handle exactly once (reader thread,
        /// on loop exit).
        func closeInterface() {
            interfaceLock.lock()
            defer { interfaceLock.unlock() }
            guard !interfaceClosed else { return }
            interfaceClosed = true
            _ = interface.pointee!.pointee.USBInterfaceClose(interface)
            _ = interface.pointee!.pointee.Release(interface)
        }
    }
    private var currentSession: ReaderSession?

    init(usb: USBDevice) {
        self.usb = usb
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Delays between attempts to claim the vendor interface.  Interfaces are
    /// published a little after the device itself, so a start() issued the
    /// instant we connect - especially on the re-enumeration after a firmware
    /// flash - can find nothing to open.  Without retries the monitor would
    /// stay silently dead until the next device switch.
    private static let interfaceRetryDelays: [TimeInterval] = [0.1, 0.2, 0.4, 0.8]

    func start() {
        start(attempt: 0)
    }

    private func start(attempt: Int) {
        // Always (re)attach to the currently open device: the connect path
        // calls start() on every successful device open, including a switch
        // to a different device, and the reader must follow it. A plain
        // guard-if-active here would leave the reader stuck on the previous
        // device (a switch never publishes isConnected == false).
        stop()
        errorMessage = nil

        let generation = usb.generation
        guard let interface = usb.openVendorInterface() else {
            if attempt < InterruptMonitor.interfaceRetryDelays.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + InterruptMonitor.interfaceRetryDelays[attempt]) { [weak self] in
                    // Bail if the device changed or a later start() already
                    // brought up a reader.
                    guard let self = self,
                          self.usb.generation == generation,
                          self.currentSession == nil else { return }
                    self.start(attempt: attempt + 1)
                }
                return
            }
            errorMessage = "Could not open vendor interface (is the device connected?)"
            return
        }

        // Resolve the pipe reference for EP 0x83.  Pipe 0 is the control EP,
        // real endpoints start at pipe 1.  Walk them until we find an
        // interrupt IN pipe with direction=IN and matching EP number.
        guard let pipeRef = findPipeRef(interface: interface, epAddress: NOTIFY_EP_ADDRESS) else {
            errorMessage = "Notification EP 0x83 not found on vendor interface"
            InterruptMonitor.closeInterface(interface)
            return
        }

        let session = ReaderSession(interface: interface, pipeRef: pipeRef)
        currentSession = session
        isActive = true

        let thread = Thread { [weak self] in
            self?.runReadLoop(session: session)
        }
        thread.name = "DSPi Interrupt Monitor"
        thread.qualityOfService = .userInitiated
        session.thread = thread
        thread.start()
    }

    func stop() {
        discardPending()
        guard let session = currentSession else { return }
        currentSession = nil
        isActive = false
        session.cancelled = true
        // Wake the reader out of its (up to 500 ms) blocking read so its
        // interface handle closes promptly, then give it a brief moment to
        // finish - an immediate follow-up start() on the same device would
        // otherwise race the old handle's close and fail with exclusive
        // access. The session's interface is closed by its read loop on exit.
        session.abortPipe()
        if let thread = session.thread {
            let deadline = Date().addingTimeInterval(0.1)
            while !thread.isFinished && Date() < deadline {
                usleep(2000)
            }
        }
    }

    func clear() {
        pendingEvents.removeAll()
        events.removeAll()
    }

    func togglePause() {
        isPaused.toggle()
    }

    // MARK: - Read Loop (background thread)

    private func runReadLoop(session: ReaderSession) {
        let interface = session.interface
        let pipeRef = session.pipeRef
        var buffer = [UInt8](repeating: 0, count: Int(NOTIFY_EP_MAX_PKT))

        while !session.cancelled {
            var size: UInt32 = NOTIFY_EP_MAX_PKT
            // Note: ReadPipeTO timeouts are in MILLISECONDS.
            let result = buffer.withUnsafeMutableBufferPointer { bufPtr -> IOReturn in
                interface.pointee!.pointee.ReadPipeTO(
                    interface,
                    pipeRef,
                    bufPtr.baseAddress,
                    &size,
                    /* noDataTimeout */ 500,
                    /* completionTimeout */ 500
                )
            }

            if session.cancelled { break }

            switch result {
            case kIOReturnSuccess:
                if size == 0 { continue }
                let bytes = Array(buffer.prefix(Int(size)))
                enqueueEvent(bytes: bytes, session: session)
            case kIOReturnTimeout:
                // No data during the window — normal; loop and try again.
                continue
            case kIOReturnAborted, kIOReturnNotResponding, kIOReturnNoDevice:
                // Device went away.
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.currentSession === session else { return }
                    self.errorMessage = "Device disconnected"
                    self.isActive = false
                    self.currentSession = nil
                }
                session.cancelled = true
            default:
                // Recoverable stall — clear and continue.
                _ = interface.pointee!.pointee.ClearPipeStall(interface, pipeRef)
            }
        }

        session.closeInterface()
        DispatchQueue.main.async { [weak self] in
            // Only the current session may report itself stopped; a superseded
            // reader must not clobber its replacement's state.
            guard let self = self, self.currentSession === session else { return }
            self.isActive = false
            self.currentSession = nil
        }
    }

    /// Build an InterruptEvent from the raw bytes and post to the main
    /// thread for display.  Swallowed silently when paused.  Idle keep-alive
    /// packets (single-byte 0x00) are dropped — they exist only so the
    /// device can keep EP 0x83 armed and avoid a DCD crash; they're not
    /// user events.
    private func enqueueEvent(bytes: [UInt8], session: ReaderSession) {
        // Idle: single-byte 0x00 packet (kept version-neutral in firmware).
        if bytes.count == 1 && bytes[0] == NOTIFY_EVT_IDLE { return }

        // Hop to main and drop the event unless this reader is still the
        // current session - a notification read from the previous device just
        // before a switch must not update state that now describes the new one.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentSession === session else { return }
            self.processEvent(bytes: bytes)
        }
    }

    /// Parse a notification packet and fan it out to the registered handlers.
    /// Runs on the main thread, only for the current reader session.
    private func processEvent(bytes: [UInt8]) {

        // Dispatch v2 PARAM_CHANGED to non-display consumers regardless of
        // pause state (pause is only meant to freeze the visible log).
        if onParamChanged != nil,
           bytes.count >= 12,
           bytes[0] == NOTIFY_V2_VERSION,
           bytes[1] == NOTIFY_EVT_PARAM_CHANGED {
            let offset = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
            let size   = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
            let source = bytes[8]
            let payloadEnd = min(bytes.count, 12 + Int(size))
            let payload = Data(bytes[12..<payloadEnd])
            dispatchParam(offset: offset, size: size, source: source, payload: payload)
        }

        // Dispatch the input-format event (host switched USB alt → new active
        // channel count) so the UI relayouts without waiting for the 60ms poll.
        if let handler = onInputFormatChanged,
           bytes.count >= 8,
           bytes[0] == NOTIFY_V2_VERSION,
           bytes[1] == NOTIFY_EVT_INPUT_FORMAT {
            let channels = Int(bytes[4])
            DispatchQueue.main.async {
                handler(channels)
            }
        }

        // Dispatch siggen state pushes so the Test Signals window reacts
        // (completion, preset-load stop, walk advance) without polling lag.
        if let handler = onSiggenState,
           bytes.count >= 8,
           bytes[0] == NOTIFY_V2_VERSION,
           bytes[1] == NOTIFY_EVT_SIGGEN_STATE {
            let state = bytes[4]
            let reason = bytes[5]
            let signalType = bytes[6]
            let channel = bytes[7]
            DispatchQueue.main.async {
                handler(state, reason, signalType, channel)
            }
        }

        // Dispatch ADAT state pushes so the Outputs page status row reacts to
        // stream start/stop and rate-policy auto-suspend/resume without polling.
        if let handler = onAdatState,
           bytes.count >= 8,
           bytes[0] == NOTIFY_V2_VERSION,
           bytes[1] == NOTIFY_EVT_ADAT_STATE {
            let enabled = bytes[4] != 0
            let active = bytes[5] != 0
            let pin = bytes[6]
            DispatchQueue.main.async {
                handler(enabled, active, pin)
            }
        }

        // Dispatch I2S clock-slave lock-state pushes so the I2S settings-page
        // indicator reacts to lock/loss/rate-change without polling lag.  This
        // event is 9 bytes: [ver, evt, flags, seq, state, rate_LE(4)].
        if let handler = onI2sSlaveState,
           bytes.count >= 9,
           bytes[0] == NOTIFY_V2_VERSION,
           bytes[1] == NOTIFY_EVT_I2S_SLAVE_STATE {
            let state = bytes[4]
            let rate = UInt32(bytes[5]) | (UInt32(bytes[6]) << 8) | (UInt32(bytes[7]) << 16) | (UInt32(bytes[8]) << 24)
            DispatchQueue.main.async {
                handler(state, rate)
            }
        }

        // Dispatch ADAT input lock-state pushes so the ADAT settings-page
        // indicator reacts to lock/loss/rate-change without polling lag.  This
        // event is 10 bytes: [ver, evt, flags, seq, state, rate_LE(4), clock_mode].
        if let handler = onAdatInputState,
           bytes.count >= 10,
           bytes[0] == NOTIFY_V2_VERSION,
           bytes[1] == NOTIFY_EVT_ADAT_INPUT_STATE {
            let state = bytes[4]
            let rate = UInt32(bytes[5]) | (UInt32(bytes[6]) << 8) | (UInt32(bytes[7]) << 16) | (UInt32(bytes[8]) << 24)
            let mode = bytes[9]
            DispatchQueue.main.async {
                handler(state, rate, mode)
            }
        }

        // Snapshot pause state on this thread — worst case we lose or add a
        // single event right at a pause/resume edge, which is harmless.
        if isPaused { return }

        // Batched, not dropped: the log is a diagnostic trace and keeps every
        // event, but publishing it per event republishes the whole array to
        // the log view at the notification rate.
        pendingEvents.append(InterruptEvent(timestamp: Date(), rawBytes: Data(bytes)))
        scheduleFlush()
    }

    // MARK: - Coalescing

    /// Queue one parameter change for delivery, or deliver it now when the
    /// monitor has been quiet for a full interval.  Main thread only.
    private func dispatchParam(offset: UInt16, size: UInt16, source: UInt8, payload: Data) {
        let now = ProcessInfo.processInfo.systemUptime
        if !flushScheduled && now - lastFlush >= Self.flushInterval {
            lastFlush = now
            onParamChanged?(offset, size, source, payload)
            return
        }
        // Newest wins: an older value for the same offset no longer describes
        // the device, and replaying it would only make the UI flicker backwards.
        if pendingParams.updateValue(PendingParam(size: size, source: source, payload: payload),
                                     forKey: offset) == nil {
            pendingOrder.append(offset)
        }
        scheduleFlush()
    }

    /// Arm the next flush, at most one at a time.  Main thread only.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        let due = max(0, Self.flushInterval - (ProcessInfo.processInfo.systemUptime - lastFlush))
        DispatchQueue.main.asyncAfter(deadline: .now() + due) { [weak self] in
            self?.flush()
        }
    }

    /// Deliver everything queued since the last flush.  Main thread only.
    private func flush() {
        flushScheduled = false
        lastFlush = ProcessInfo.processInfo.systemUptime

        if !pendingEvents.isEmpty {
            events.append(contentsOf: pendingEvents)
            pendingEvents.removeAll(keepingCapacity: true)
            if events.count > Self.maxEvents {
                events.removeFirst(events.count - Self.maxEvents)
            }
        }

        if !pendingOrder.isEmpty {
            let order = pendingOrder
            let params = pendingParams
            pendingOrder.removeAll(keepingCapacity: true)
            pendingParams.removeAll(keepingCapacity: true)
            for offset in order {
                guard let p = params[offset] else { continue }
                onParamChanged?(offset, p.size, p.source, p.payload)
            }
        }

        // A handler can queue more work as it runs, and events keep arriving
        // during the flush; both leave the timer armed rather than waiting for
        // the next notification to restart it.
        if !pendingOrder.isEmpty || !pendingEvents.isEmpty { scheduleFlush() }
    }

    /// Drop anything queued but not yet delivered.  A pending change describes
    /// the device the reader was attached to, which after a switch is not the
    /// one the UI is now showing.
    private func discardPending() {
        pendingParams.removeAll()
        pendingOrder.removeAll()
        pendingEvents.removeAll()
        lastFlush = 0
    }

    // MARK: - Interface Helpers

    private func findPipeRef(interface: USBDevice.InterfaceInterfacePtr, epAddress: UInt8) -> UInt8? {
        var numEndpoints: UInt8 = 0
        let res = interface.pointee!.pointee.GetNumEndpoints(interface, &numEndpoints)
        guard res == kIOReturnSuccess else { return nil }
        guard numEndpoints > 0 else { return nil }  // 1...0 is a fatal range in Swift

        // Pipe 0 is control; real pipes are 1..numEndpoints.
        for pipeRef in 1...numEndpoints {
            var direction: UInt8 = 0
            var number: UInt8 = 0
            var transferType: UInt8 = 0
            var maxPacketSize: UInt16 = 0
            var interval: UInt8 = 0

            let r = interface.pointee!.pointee.GetPipeProperties(
                interface,
                pipeRef,
                &direction,
                &number,
                &transferType,
                &maxPacketSize,
                &interval
            )
            if r != kIOReturnSuccess { continue }

            // direction: 0 = OUT, 1 = IN, 2 = Control.  We want IN.
            // number: endpoint number (7 bits of the address).
            // transferType: 2 = bulk, 3 = interrupt.  Device moved from
            // interrupt to bulk after a DCD crash on RP2040/2350 — accept
            // either to keep the monitor forward-compatible.
            let wantedEpNum = epAddress & 0x7F
            if direction == 1 && number == wantedEpNum && (transferType == 2 || transferType == 3) {
                return pipeRef
            }
        }
        return nil
    }

    private static func closeInterface(_ interface: USBDevice.InterfaceInterfacePtr) {
        _ = interface.pointee!.pointee.USBInterfaceClose(interface)
        _ = interface.pointee!.pointee.Release(interface)
    }
}

// MARK: - SwiftUI View

struct InterruptMonitorView: View {
    @ObservedObject var monitor: InterruptMonitor

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar row
            HStack(spacing: 12) {
                Button(action: { monitor.togglePause() }) {
                    Label(monitor.isPaused ? "Resume" : "Pause",
                          systemImage: monitor.isPaused ? "play.fill" : "pause.fill")
                }
                .keyboardShortcut("p", modifiers: [.command])

                Button(action: { monitor.clear() }) {
                    Label("Clear", systemImage: "trash")
                }
                .keyboardShortcut("k", modifiers: [.command])

                Spacer()

                if !monitor.isActive {
                    Text("Inactive")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if monitor.isPaused {
                    Text("Paused")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else {
                    Text("Listening")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                Text("\(monitor.events.count) event\(monitor.events.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(10)

            Divider()

            // Event list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(monitor.events) { event in
                            Text(event.formattedLine)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(event.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: monitor.events.count) { _ in
                    guard !monitor.isPaused, let last = monitor.events.last else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if let err = monitor.errorMessage {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                    Spacer()
                }
                .padding(8)
            }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 320, idealHeight: 480)
    }
}

// MARK: - Window Controller

class InterruptMonitorWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if window == nil {
            let view = InterruptMonitorView(monitor: AppState.shared.interruptMonitor)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 480),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Interrupt Monitor"
            window?.contentView = NSHostingView(rootView: view)
            window?.isReleasedWhenClosed = false
            window?.minSize = NSSize(width: 720, height: 320)
            window?.delegate = self
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }
}

extension InterruptMonitorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}
