import AppKit

// MARK: - Snapshot Types

/// Filter parameters stripped of UI-only fields (id, active) for comparison.
struct SnapshotFilterParams: Equatable {
    let type: FilterType
    let freq: Float
    let q: Float
    let gain: Float

    init(from fp: FilterParams) {
        self.type = fp.type
        self.freq = fp.freq
        self.q = fp.q
        self.gain = fp.gain
    }
}

/// Captures all preset-relevant DSP state at a point in time.
/// Uses compiler-synthesized Equatable — exact Float equality is safe because
/// values are quantized at the USB protocol level (single-precision, rounded to 0.1 dB).
struct PresetSnapshot: Equatable {
    let preampDB: [Float]
    let masterVolumeDB: Float?  // nil when presetMasterVolumeMode != MASTER_VOLUME_MODE_WITH_PRESET
    let bypass: Bool
    let loudnessEnabled: Bool
    let loudnessRefSPL: Float
    let loudnessIntensity: Float
    let crossfeedEnabled: Bool
    let crossfeedPreset: Int
    let crossfeedFreq: Float
    let crossfeedFeed: Float
    let crossfeedITD: Bool
    let levellerEnabled: Bool
    let levellerAmount: Float
    let levellerSpeed: Int
    let levellerMaxGainDB: Float
    let levellerLookahead: Bool
    let levellerGateDB: Float
    let channelDelays: [Int: Float]
    let matrixRouting: [[Bool]]
    let matrixGain: [[Float]]
    let matrixInvert: [[Bool]]
    let outputEnabled: [Bool]
    let outputMuted: [Bool]
    let outputGainDB: [Float]
    let outputDelayMS: [Float]
    let channelFilters: [Int: [SnapshotFilterParams]]
    let channelNames: [String]
    let outputPins: [UInt8]?  // nil when presetIncludePins is false
    let outputSlotTypes: [UInt8]?  // nil when presetIncludePins is false
    let i2sBckPin: UInt8?
    let mckEnabled: Bool?
    let mckPin: UInt8?
    let mckMultiplier: Int?
    let inputSource: Int?  // nil when firmware doesn't support input switching
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

        // Global — per-channel preamp
        let preampLabels = ["L", "R"]
        for ch in 0..<min(old.preampDB.count, new.preampDB.count) {
            if old.preampDB[ch] != new.preampDB[ch] {
                changes.append(.init(category: "Global", description: "Preamp \(preampLabels[ch]): \(formatDB(old.preampDB[ch])) → \(formatDB(new.preampDB[ch]))"))
            }
        }
        // Master volume (only when included in presets)
        if let oldVol = old.masterVolumeDB, let newVol = new.masterVolumeDB, oldVol != newVol {
            let oldStr = oldVol <= -128 ? "-∞ dB" : formatDB(oldVol)
            let newStr = newVol <= -128 ? "-∞ dB" : formatDB(newVol)
            changes.append(.init(category: "Global", description: "Master Volume: \(oldStr) → \(newStr)"))
        }
        if old.bypass != new.bypass {
            changes.append(.init(category: "Global", description: "Master EQ bypass: \(old.bypass ? "on" : "off") → \(new.bypass ? "on" : "off")"))
        }

        // Loudness
        if old.loudnessEnabled != new.loudnessEnabled {
            changes.append(.init(category: "Loudness", description: "Loudness: \(new.loudnessEnabled ? "enabled" : "disabled")"))
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

        // Per-output settings
        for i in 0..<min(old.outputEnabled.count, new.outputEnabled.count) {
            let name = (i + 2) < channelNames.count ? channelNames[i + 2] : "Output \(i)"
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

        // Channel names
        for i in 0..<min(old.channelNames.count, new.channelNames.count) {
            if old.channelNames[i] != new.channelNames[i] && !(old.channelNames[i].isEmpty && new.channelNames[i].isEmpty) {
                changes.append(.init(category: "Names", description: "'\(old.channelNames[i])' → '\(new.channelNames[i])'"))
            }
        }

        // Pin config (only if both snapshots track pins)
        if let oldPins = old.outputPins, let newPins = new.outputPins {
            var pinChanges = 0
            for i in 0..<min(oldPins.count, newPins.count) {
                if oldPins[i] != newPins[i] { pinChanges += 1 }
            }
            if pinChanges > 0 {
                changes.append(.init(category: "Pins", description: "\(pinChanges) pin assignment\(pinChanges == 1 ? "" : "s") changed"))
            }
        }

        // I2S config (only if both snapshots track it)
        if let oldTypes = old.outputSlotTypes, let newTypes = new.outputSlotTypes {
            var typeChanges = 0
            for i in 0..<min(oldTypes.count, newTypes.count) {
                if oldTypes[i] != newTypes[i] { typeChanges += 1 }
            }
            if typeChanges > 0 {
                changes.append(.init(category: "I2S", description: "\(typeChanges) output type\(typeChanges == 1 ? "" : "s") changed"))
            }
        }
        if let oldPin = old.i2sBckPin, let newPin = new.i2sBckPin, oldPin != newPin {
            changes.append(.init(category: "I2S", description: "BCK pin: GPIO \(oldPin) → GPIO \(newPin)"))
        }
        if let oldVal = old.mckEnabled, let newVal = new.mckEnabled, oldVal != newVal {
            changes.append(.init(category: "I2S", description: "MCK: \(newVal ? "enabled" : "disabled")"))
        }
        if let oldPin = old.mckPin, let newPin = new.mckPin, oldPin != newPin {
            changes.append(.init(category: "I2S", description: "MCK pin: GPIO \(oldPin) → GPIO \(newPin)"))
        }
        if let oldVal = old.mckMultiplier, let newVal = new.mckMultiplier, oldVal != newVal {
            changes.append(.init(category: "I2S", description: "MCK multiplier: \(oldVal)x → \(newVal)x"))
        }

        // Input source
        if let oldSrc = old.inputSource, let newSrc = new.inputSource, oldSrc != newSrc {
            let names = ["USB", "S/PDIF"]
            let oldName = oldSrc < names.count ? names[oldSrc] : "\(oldSrc)"
            let newName = newSrc < names.count ? names[newSrc] : "\(newSrc)"
            changes.append(.init(category: "Input", description: "Input source: \(oldName) → \(newName)"))
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
