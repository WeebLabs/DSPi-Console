import AppKit

// MARK: - Snapshot Types

/// Filter parameters stripped of UI-only fields (id, active) for comparison.
struct SnapshotFilterParams: Equatable {
    let type: FilterType
    let freq: Float
    let q: Float
    let gain: Float
    let bypass: Bool

    init(from fp: FilterParams) {
        self.type = fp.type
        self.freq = fp.freq
        self.q = fp.q
        self.gain = fp.gain
        self.bypass = fp.bypass
    }
}

/// Captures all preset-relevant DSP state at a point in time.
/// Uses compiler-synthesized Equatable — exact Float equality is safe because
/// values are quantized at the USB protocol level (single-precision, rounded to 0.1 dB).
struct PresetSnapshot: Equatable {
    let preampDB: [Float]
    // Always captured — the diff function gates the comparison on `masterVolumeMode`
    // so that flipping modes can correctly mark dirty when the live value diverges
    // from what's on flash, instead of the comparison being silently skipped.
    let masterVolumeDB: Float
    let masterVolumeMode: Int   // The mode at snapshot time (0 = INDEPENDENT, 1 = WITH_PRESET)
    // Like masterVolumeMode: the output-config mode at snapshot time.  The diff
    // gates the output-config comparison on this so the wiring only counts
    // toward preset dirtiness in WITH_PRESET mode (in INDEPENDENT mode it lives
    // in the device directory and is saved explicitly).
    let outputConfigMode: Int   // 0 = INDEPENDENT, 1 = WITH_PRESET
    // Captured so the Names diff can compute the per-config default channel
    // names (which depend on platform layout + slot types) and ignore a
    // type-driven default->default rename - see the Names section in diff().
    let platformName: String
    let bypass: Bool
    let loudnessEnabled: Bool
    let loudnessOutputMask: UInt16
    let loudnessRefSPL: Float
    let loudnessIntensity: Float
    let crossfeedEnabled: Bool
    let crossfeedPreset: Int
    let crossfeedFreq: Float
    let crossfeedFeed: Float
    let crossfeedITD: Bool
    let crossfeedOutputMask: UInt8
    let levellerEnabled: Bool
    let levellerAmount: Float
    let levellerSpeed: Int
    let levellerMaxGainDB: Float
    let levellerLookahead: Bool
    let levellerGateDB: Float
    let levellerDetectorMask: UInt8
    let levellerApplyMask: UInt8
    let channelDelays: [Int: Float]
    let matrixRouting: [[Bool]]
    let matrixGain: [[Float]]
    let matrixInvert: [[Bool]]
    let outputEnabled: [Bool]
    let outputMuted: [Bool]
    let outputGainDB: [Float]
    let outputDelayMS: [Float]
    let channelFilters: [Int: [SnapshotFilterParams]]
    let crossoverFilters: [Int: [SnapshotFilterParams]]
    let channelNames: [String]
    // Output configuration (the IO block governed by outputConfigMode).  Always
    // captured; the diff gates these on outputConfigMode == WITH_PRESET.
    let outputPins: [UInt8]
    let outputSlotTypes: [UInt8]
    let i2sBckPin: UInt8
    let mckEnabled: Bool
    let mckPin: UInt8
    let mckMultiplier: Int
    let spdifRxPin: UInt8
    var spdifRxPinsExt: [UInt8]? = nil   // optional S/PDIF 2/3 pins; nil when unsupported
    var spdifExtEnabled: [Bool]? = nil   // optional S/PDIF 2/3 enable state; nil when unsupported
    let inputSource: Int?  // nil when firmware doesn't support input switching
    let i2sRxPins: [UInt8]?    // per-pair I2S RX data pins; nil when unsupported (pre-V12)
    let i2sInputChannels: Int? // active I2S input channel count (2/4/6/8); nil when unsupported
    let i2sInputRate: UInt32?  // selected I2S rate in Hz; nil when unsupported
    let i2sClockMode: UInt8?   // I2S clock mode (0=master, 1=slave); nil when unsupported (pre-V18)
    let lgSoundSyncEnabled: Bool?  // nil when firmware doesn't support LG Sound Sync
    let adatEnabled: Bool?  // ADAT bulk output enable; nil when unsupported (RP2040 / old fw)
    let adatPin: UInt8?     // ADAT data GPIO; nil when unsupported
}

// MARK: - Diff

struct PresetDiff {
    struct Change {
        let category: String
        let description: String
    }

    let changes: [Change]
    var hasChanges: Bool { !changes.isEmpty }

    var summary: String {
        let maxLines = 15
        if changes.count <= maxLines {
            return changes.map { "• \($0.description)" }.joined(separator: "\n")
        }
        let shown = changes.prefix(maxLines)
        let remaining = changes.count - maxLines
        return shown.map { "• \($0.description)" }.joined(separator: "\n")
            + "\n...and \(remaining) more change\(remaining == 1 ? "" : "s")"
    }
}

extension PresetSnapshot {
    static func diff(from old: PresetSnapshot, to new: PresetSnapshot, channelNames: [String]) -> PresetDiff {
        var changes = [PresetDiff.Change]()

        // Global — per-channel preamp (inputs 0/1 are USB L/R; 2-7 are the 7.1
        // surround inputs in RP2350 8-channel mode).
        let preampLabels = ["L", "R", "FC", "LFE", "BL", "BR", "SL", "SR"]
        for ch in 0..<min(old.preampDB.count, new.preampDB.count) {
            if old.preampDB[ch] != new.preampDB[ch] {
                let label = ch < preampLabels.count ? preampLabels[ch] : "In \(ch + 1)"
                changes.append(.init(category: "Global", description: "Preamp \(label): \(formatDB(old.preampDB[ch])) → \(formatDB(new.preampDB[ch]))"))
            }
        }
        // Master volume — only relevant to preset persistence when the device is
        // currently in WITH_PRESET mode.  Comparing on `new.masterVolumeMode`
        // (the live mode) ensures that flipping INDEPENDENT → WITH_PRESET marks
        // dirty when the live value diverges from what was captured at preset
        // load time, prompting the user to save.  In INDEPENDENT mode this
        // comparison is skipped entirely — master volume isn't part of the
        // preset's persistent state in that mode.
        if new.masterVolumeMode == MASTER_VOLUME_MODE_WITH_PRESET
            && old.masterVolumeDB != new.masterVolumeDB {
            let oldStr = old.masterVolumeDB <= -128 ? "-∞ dB" : formatDB(old.masterVolumeDB)
            let newStr = new.masterVolumeDB <= -128 ? "-∞ dB" : formatDB(new.masterVolumeDB)
            changes.append(.init(category: "Global", description: "Master Volume: \(oldStr) → \(newStr)"))
        }
        if old.bypass != new.bypass {
            changes.append(.init(category: "Global", description: "Master EQ bypass: \(old.bypass ? "on" : "off") → \(new.bypass ? "on" : "off")"))
        }

        // Loudness
        if old.loudnessEnabled != new.loudnessEnabled {
            changes.append(.init(category: "Loudness", description: "Loudness: \(new.loudnessEnabled ? "enabled" : "disabled")"))
        }
        if old.loudnessOutputMask != new.loudnessOutputMask {
            changes.append(.init(category: "Loudness", description: "Loudness outputs: \(String(format: "0x%04X", old.loudnessOutputMask)) → \(String(format: "0x%04X", new.loudnessOutputMask))"))
        }
        if old.loudnessRefSPL != new.loudnessRefSPL {
            changes.append(.init(category: "Loudness", description: "Loudness ref SPL: \(formatVal(old.loudnessRefSPL)) → \(formatVal(new.loudnessRefSPL))"))
        }
        if old.loudnessIntensity != new.loudnessIntensity {
            changes.append(.init(category: "Loudness", description: "Loudness intensity: \(formatVal(old.loudnessIntensity))% → \(formatVal(new.loudnessIntensity))%"))
        }

        // Crossfeed
        if old.crossfeedEnabled != new.crossfeedEnabled {
            changes.append(.init(category: "Crossfeed", description: "Crossfeed: \(new.crossfeedEnabled ? "enabled" : "disabled")"))
        }
        if old.crossfeedPreset != new.crossfeedPreset {
            changes.append(.init(category: "Crossfeed", description: "Crossfeed preset: \(old.crossfeedPreset) → \(new.crossfeedPreset)"))
        }
        if old.crossfeedFreq != new.crossfeedFreq {
            changes.append(.init(category: "Crossfeed", description: "Crossfeed frequency: \(formatVal(old.crossfeedFreq)) → \(formatVal(new.crossfeedFreq)) Hz"))
        }
        if old.crossfeedFeed != new.crossfeedFeed {
            changes.append(.init(category: "Crossfeed", description: "Crossfeed feed: \(formatVal(old.crossfeedFeed)) → \(formatVal(new.crossfeedFeed))"))
        }
        if old.crossfeedITD != new.crossfeedITD {
            changes.append(.init(category: "Crossfeed", description: "Crossfeed ITD: \(new.crossfeedITD ? "enabled" : "disabled")"))
        }
        if old.crossfeedOutputMask != new.crossfeedOutputMask {
            changes.append(.init(category: "Crossfeed", description: "Crossfeed output pairs: \(String(format: "0x%02X", old.crossfeedOutputMask)) → \(String(format: "0x%02X", new.crossfeedOutputMask))"))
        }

        // Volume Leveller
        if old.levellerEnabled != new.levellerEnabled {
            changes.append(.init(category: "Leveller", description: "Volume Leveller: \(new.levellerEnabled ? "enabled" : "disabled")"))
        }
        if old.levellerAmount != new.levellerAmount {
            changes.append(.init(category: "Leveller", description: "Leveller amount: \(formatVal(old.levellerAmount))% → \(formatVal(new.levellerAmount))%"))
        }
        if old.levellerSpeed != new.levellerSpeed {
            let names = ["Slow", "Medium", "Fast"]
            let oldName = old.levellerSpeed < names.count ? names[old.levellerSpeed] : "\(old.levellerSpeed)"
            let newName = new.levellerSpeed < names.count ? names[new.levellerSpeed] : "\(new.levellerSpeed)"
            changes.append(.init(category: "Leveller", description: "Leveller speed: \(oldName) → \(newName)"))
        }
        if old.levellerMaxGainDB != new.levellerMaxGainDB {
            changes.append(.init(category: "Leveller", description: "Leveller max gain: \(formatVal(old.levellerMaxGainDB)) dB → \(formatVal(new.levellerMaxGainDB)) dB"))
        }
        if old.levellerLookahead != new.levellerLookahead {
            changes.append(.init(category: "Leveller", description: "Leveller lookahead: \(new.levellerLookahead ? "enabled" : "disabled")"))
        }
        if old.levellerGateDB != new.levellerGateDB {
            changes.append(.init(category: "Leveller", description: "Leveller gate: \(formatVal(old.levellerGateDB)) dB → \(formatVal(new.levellerGateDB)) dB"))
        }
        if old.levellerDetectorMask != new.levellerDetectorMask {
            changes.append(.init(category: "Leveller", description: "Leveller detector channels changed"))
        }
        if old.levellerApplyMask != new.levellerApplyMask {
            changes.append(.init(category: "Leveller", description: "Leveller apply channels changed"))
        }

        // Channel Delays
        let allDelayKeys = Set(old.channelDelays.keys).union(new.channelDelays.keys)
        for ch in allDelayKeys.sorted() {
            let oldVal = old.channelDelays[ch] ?? 0
            let newVal = new.channelDelays[ch] ?? 0
            if oldVal != newVal {
                let name = ch < channelNames.count ? channelNames[ch] : "Ch \(ch)"
                changes.append(.init(category: "Delays", description: "\(name) delay: \(formatVal(oldVal)) ms → \(formatVal(newVal)) ms"))
            }
        }

        // Matrix crosspoints
        var matrixCount = 0
        for input in 0..<min(old.matrixRouting.count, new.matrixRouting.count) {
            for output in 0..<min(old.matrixRouting[input].count, new.matrixRouting[input].count) {
                if old.matrixRouting[input][output] != new.matrixRouting[input][output]
                    || old.matrixGain[input][output] != new.matrixGain[input][output]
                    || old.matrixInvert[input][output] != new.matrixInvert[input][output] {
                    matrixCount += 1
                }
            }
        }
        if matrixCount > 0 {
            changes.append(.init(category: "Matrix", description: "\(matrixCount) crosspoint\(matrixCount == 1 ? "" : "s") changed"))
        }

        // Per-output settings.  Output i's unified EQ/channel index is i + chOut1
        // (chOut1 = device input count: 8 on RP2350, 2 on RP2040).
        let chOut1 = new.platformName == "RP2040" ? BASE_MATRIX_INPUTS : MAX_MATRIX_INPUTS
        for i in 0..<min(old.outputEnabled.count, new.outputEnabled.count) {
            let name = (i + chOut1) < channelNames.count ? channelNames[i + chOut1] : "Output \(i)"
            var outputChanges = [String]()
            if old.outputEnabled[i] != new.outputEnabled[i] { outputChanges.append(new.outputEnabled[i] ? "enabled" : "disabled") }
            if old.outputMuted[i] != new.outputMuted[i] { outputChanges.append(new.outputMuted[i] ? "muted" : "unmuted") }
            if old.outputGainDB[i] != new.outputGainDB[i] { outputChanges.append("gain: \(formatDB(old.outputGainDB[i])) → \(formatDB(new.outputGainDB[i]))") }
            if old.outputDelayMS[i] != new.outputDelayMS[i] { outputChanges.append("delay: \(formatVal(old.outputDelayMS[i])) ms → \(formatVal(new.outputDelayMS[i])) ms") }
            for change in outputChanges {
                changes.append(.init(category: name, description: "\(name) \(change)"))
            }
        }

        // EQ bands
        let allEQKeys = Set(old.channelFilters.keys).union(new.channelFilters.keys)
        for ch in allEQKeys.sorted() {
            let oldBands = old.channelFilters[ch] ?? []
            let newBands = new.channelFilters[ch] ?? []
            let maxBands = max(oldBands.count, newBands.count)
            var changedCount = 0
            for b in 0..<maxBands {
                let oldB = b < oldBands.count ? oldBands[b] : nil
                let newB = b < newBands.count ? newBands[b] : nil
                if oldB != newB { changedCount += 1 }
            }
            if changedCount > 0 {
                let name = ch < channelNames.count ? channelNames[ch] : "Ch \(ch)"
                changes.append(.init(category: "\(name) EQ", description: "\(changedCount) band\(changedCount == 1 ? "" : "s") changed on \(name)"))
            }
        }

        // Crossover bands (per output channel; outputs are ch >= chOut1)
        let allXoverKeys = Set(old.crossoverFilters.keys).union(new.crossoverFilters.keys)
        for ch in allXoverKeys.sorted() where ch >= chOut1 {
            let oldBands = old.crossoverFilters[ch] ?? []
            let newBands = new.crossoverFilters[ch] ?? []
            let maxBands = max(oldBands.count, newBands.count)
            var changedCount = 0
            for b in 0..<maxBands {
                let oldB = b < oldBands.count ? oldBands[b] : nil
                let newB = b < newBands.count ? newBands[b] : nil
                if oldB != newB { changedCount += 1 }
            }
            if changedCount > 0 {
                let name = ch < channelNames.count ? channelNames[ch] : "Ch \(ch)"
                changes.append(.init(category: "\(name) Crossover",
                                     description: "\(changedCount) crossover band\(changedCount == 1 ? "" : "s") changed on \(name)"))
            }
        }

        // Channel names.  Output-channel default names are derived from the slot
        // type (e.g. "SPDIF 1 L" vs "I2S 1 L"), so flipping an output type makes
        // the firmware auto-rename any channel still at its default and notify us.
        // That default->default rename is a consequence of the output-config
        // change, not a user edit, so it must not dirty the preset (especially in
        // INDEPENDENT mode, where the type change itself is intentionally ignored).
        // The firmware only auto-renames channels that are at their default, so
        // skipping default->default transitions never suppresses a real rename.
        let oldDefaultNames = DSPViewModel.defaultChannelNames(for: old.platformName, slotTypes: old.outputSlotTypes)
        let newDefaultNames = DSPViewModel.defaultChannelNames(for: new.platformName, slotTypes: new.outputSlotTypes)
        for i in 0..<min(old.channelNames.count, new.channelNames.count) {
            guard old.channelNames[i] != new.channelNames[i],
                  !(old.channelNames[i].isEmpty && new.channelNames[i].isEmpty) else { continue }
            let wasDefault = i < oldDefaultNames.count && old.channelNames[i] == oldDefaultNames[i]
            let isDefault = i < newDefaultNames.count && new.channelNames[i] == newDefaultNames[i]
            if wasDefault && isDefault { continue }
            changes.append(.init(category: "Names", description: "'\(old.channelNames[i])' → '\(new.channelNames[i])'"))
        }

        // Output configuration — pins, output types, I2S clocks, and the
        // S/PDIF RX pin.  Like master volume, these are captured
        // unconditionally; the comparison is gated on the live mode so it only
        // contributes to preset dirtiness in WITH_PRESET mode.  In INDEPENDENT
        // mode the wiring lives in the device directory (saved explicitly via
        // Save Output Configuration), so preset diffs ignore it.
        if new.outputConfigMode == OUTPUT_CONFIG_MODE_WITH_PRESET {
            var pinChanges = 0
            for i in 0..<min(old.outputPins.count, new.outputPins.count) {
                if old.outputPins[i] != new.outputPins[i] { pinChanges += 1 }
            }
            if pinChanges > 0 {
                changes.append(.init(category: "Pins", description: "\(pinChanges) pin assignment\(pinChanges == 1 ? "" : "s") changed"))
            }

            var typeChanges = 0
            for i in 0..<min(old.outputSlotTypes.count, new.outputSlotTypes.count) {
                if old.outputSlotTypes[i] != new.outputSlotTypes[i] { typeChanges += 1 }
            }
            if typeChanges > 0 {
                changes.append(.init(category: "I2S", description: "\(typeChanges) output type\(typeChanges == 1 ? "" : "s") changed"))
            }
            if old.i2sBckPin != new.i2sBckPin {
                changes.append(.init(category: "I2S", description: "BCK pin: GPIO \(old.i2sBckPin) → GPIO \(new.i2sBckPin)"))
            }
            if old.mckEnabled != new.mckEnabled {
                changes.append(.init(category: "I2S", description: "MCK: \(new.mckEnabled ? "enabled" : "disabled")"))
            }
            if old.mckPin != new.mckPin {
                changes.append(.init(category: "I2S", description: "MCK pin: GPIO \(old.mckPin) → GPIO \(new.mckPin)"))
            }
            if old.mckMultiplier != new.mckMultiplier {
                changes.append(.init(category: "I2S", description: "MCK multiplier: \(old.mckMultiplier)x → \(new.mckMultiplier)x"))
            }
            if old.spdifRxPin != new.spdifRxPin {
                changes.append(.init(category: "S/PDIF", description: "S/PDIF RX pin: GPIO \(old.spdifRxPin) → GPIO \(new.spdifRxPin)"))
            }
            if let oldEn = old.spdifExtEnabled, let newEn = new.spdifExtEnabled {
                for i in 0..<min(oldEn.count, newEn.count) where oldEn[i] != newEn[i] {
                    changes.append(.init(category: "S/PDIF", description: "S/PDIF \(i + 2) input: \(newEn[i] ? "enabled" : "disabled")"))
                }
            }
            if let oldPins = old.spdifRxPinsExt, let newPins = new.spdifRxPinsExt {
                for i in 0..<min(oldPins.count, newPins.count) where oldPins[i] != newPins[i] {
                    changes.append(.init(category: "S/PDIF", description: "S/PDIF \(i + 2) RX pin: GPIO \(oldPins[i]) → GPIO \(newPins[i])"))
                }
            }
            if let oldCount = old.i2sInputChannels, let newCount = new.i2sInputChannels, oldCount != newCount {
                changes.append(.init(category: "I2S Input", description: "I2S input channels: \(oldCount) → \(newCount)"))
            }
            if let oldPins = old.i2sRxPins, let newPins = new.i2sRxPins {
                for pair in 0..<min(oldPins.count, newPins.count) where oldPins[pair] != newPins[pair] {
                    changes.append(.init(category: "I2S Input", description: "I2S RX pin (pair \(pair + 1)): GPIO \(oldPins[pair]) → GPIO \(newPins[pair])"))
                }
            }
            if let oldRate = old.i2sInputRate, let newRate = new.i2sInputRate, oldRate != newRate {
                changes.append(.init(category: "I2S Input", description: "I2S rate: \(oldRate) Hz → \(newRate) Hz"))
            }
            if let oldMode = old.i2sClockMode, let newMode = new.i2sClockMode, oldMode != newMode {
                let name: (UInt8) -> String = { $0 == I2S_CLOCK_MODE_SLAVE ? "Slave" : "Master" }
                changes.append(.init(category: "I2S Input", description: "I2S clock mode: \(name(oldMode)) → \(name(newMode))"))
            }
            if let oldEn = old.adatEnabled, let newEn = new.adatEnabled, oldEn != newEn {
                changes.append(.init(category: "ADAT", description: "ADAT output: \(newEn ? "enabled" : "disabled")"))
            }
            if let oldPin = old.adatPin, let newPin = new.adatPin, oldPin != newPin {
                changes.append(.init(category: "ADAT", description: "ADAT pin: GPIO \(oldPin) → GPIO \(newPin)"))
            }
        }

        // Input source
        if let oldSrc = old.inputSource, let newSrc = new.inputSource, oldSrc != newSrc {
            func sourceName(_ s: Int) -> String {
                switch s {
                case 0: return "USB"
                case 1: return "S/PDIF 1"
                case 2: return "I2S"
                case 4: return "S/PDIF 2"
                case 5: return "S/PDIF 3"
                default: return "\(s)"
                }
            }
            changes.append(.init(category: "Input", description: "Input source: \(sourceName(oldSrc)) → \(sourceName(newSrc))"))
        }

        // LG Sound Sync — per-preset enable (only when firmware supports it)
        if let oldVal = old.lgSoundSyncEnabled, let newVal = new.lgSoundSyncEnabled, oldVal != newVal {
            changes.append(.init(category: "LG Sound Sync", description: "LG Sound Sync: \(newVal ? "enabled" : "disabled")"))
        }

        return PresetDiff(changes: changes)
    }

    private static func formatDB(_ val: Float) -> String {
        String(format: "%.1f dB", val)
    }

    private static func formatVal(_ val: Float) -> String {
        if val == val.rounded() && abs(val) < 100000 {
            return String(format: "%.0f", val)
        }
        return String(format: "%.1f", val)
    }
}

// MARK: - Alert Helper

enum UnsavedChangesAction {
    case save, discard, cancel
}

enum PresetAlerts {
    static func showUnsavedChangesAlert(diff: PresetDiff) -> UnsavedChangesAction {
        let alert = NSAlert()
        alert.messageText = "Unsaved Changes"
        alert.informativeText = "The current preset has unsaved changes:\n\n\(diff.summary)\n\nSave before continuing?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }
}
