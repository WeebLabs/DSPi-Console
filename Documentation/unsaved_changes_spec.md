# Unsaved Preset Changes Detection & Prompting — Specification

## Overview
When users modify DSP parameters, changes are sent to the device in real-time but are NOT persisted to flash until explicitly saved via a preset save. This feature detects when the live device state has diverged from the last-saved preset state and prompts the user before destructive actions (preset switch, app quit).

## Trigger Points
1. **Preset switch** — User selects a different preset slot in the sidebar dropdown
2. **App quit** — User closes the app (Cmd+Q, menu, or red button)

NOT triggered by: delete/clear (has own confirmation), revert/factory reset (calls fetchAllParams which re-snapshots).

## Snapshot Model

### PresetSnapshot
Captures all preset-relevant state at a point in time. Uses compiler-synthesized `Equatable`.

```
PresetSnapshot
├── preampDB: Float
├── bypass: Bool
├── loudnessEnabled: Bool
├── loudnessRefSPL: Float
├── loudnessIntensity: Float
├── crossfeedEnabled: Bool
├── crossfeedPreset: Int
├── crossfeedFreq: Float
├── crossfeedFeed: Float
├── crossfeedITD: Bool
├── channelDelays: [Int: Float]
├── matrixRouting: [[Bool]]
├── matrixGain: [[Float]]
├── matrixInvert: [[Bool]]
├── outputEnabled: [Bool]
├── outputMuted: [Bool]
├── outputGainDB: [Float]
├── outputDelayMS: [Float]
├── channelFilters: [Int: [SnapshotFilterParams]]
├── channelNames: [String]
└── outputPins: [UInt8]?  (nil when presetIncludePins is false)
```

### SnapshotFilterParams
Strips `id` (UUID, always unique) and `active` (UI-only graph toggle) from FilterParams:
```
SnapshotFilterParams: Equatable
├── type: FilterType
├── freq: Float
├── q: Float
└── gain: Float
```

Float comparisons use exact equality — values are quantized at the USB protocol level (single-precision, rounded to 0.1 dB), so the round-trip through firmware is lossless.

## Snapshot Lifecycle

```
Device Connect
    └── fetchAll() → fetchAllParams() → updateSavedSnapshot()
                                          savedSnapshot = current state

User Edits (setFilter, setPreamp, etc.)
    └── @Published properties change
    └── captureSnapshot() != savedSnapshot → hasUnsavedChanges = true

Preset Load
    └── loadPreset() → fetchAllParams() → updateSavedSnapshot()
                                            savedSnapshot = loaded state

Preset Save
    └── savePreset() success → updateSavedSnapshot()
                                 savedSnapshot = current state (now == saved)

Device Disconnect
    └── isConnected sink → savedSnapshot = nil
                            hasUnsavedChanges returns false → no prompts
```

## Diff Algorithm

`PresetSnapshot.diff(from:to:channelNames:)` compares two snapshots field-by-field:

### Categories
| Category | Fields Compared | Example Output |
|----------|----------------|----------------|
| Global | preampDB, bypass | "Preamp: -3.0 dB → 0.0 dB" |
| Loudness | enabled, refSPL, intensity | "Loudness enabled" |
| Crossfeed | enabled, preset, freq, feed, ITD | "Crossfeed frequency: 700 → 650" |
| Channel Delays | per-channel delay values | "USB L delay: 0 ms → 5 ms" |
| Matrix | routing, gain, invert crosspoints | "3 crosspoints changed" |
| Output [name] | enabled, muted, gain, delay | "SPDIF 1 L gain: 0.0 dB → -6.0 dB" |
| [name] EQ | count changed bands | "3 bands changed on USB L" |
| Channel Names | renames | "'USB L' → 'Left'" |
| Pin Config | pin assignments | "2 pin assignments changed" |

Truncated to ~15 lines with "...and N more changes" suffix.

## Alert Dialog

```
┌─────────────────────────────────────────┐
│ ⚠ Unsaved Changes                      │
│                                         │
│ The current preset has unsaved changes: │
│                                         │
│ • Preamp: -3.0 dB → 0.0 dB            │
│ • 3 bands changed on USB L             │
│ • SPDIF 1 L gain: 0.0 dB → -6.0 dB   │
│                                         │
│ Save before continuing?                 │
│                                         │
│        [Save] [Discard] [Cancel]        │
└─────────────────────────────────────────┘
```

- **Save**: Save current preset, then proceed (switch/quit)
- **Discard**: Proceed without saving
- **Cancel**: Abort the action (stay on current preset / cancel quit)

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Initial connect | fetchAllParams() snapshots → changes tracked from device state |
| Empty preset slot | Same flow — snapshot taken after load regardless of slot occupancy |
| Save fails | Snapshot NOT updated; preset switch aborted; user sees error |
| Device disconnects during dialog | Save will fail → error alert → action aborted |
| Multiple rapid switches | NSAlert.runModal() blocks main thread — impossible to queue |
| Factory Reset / Revert | Both call fetchAll() → fetchAllParams() → re-snapshots → clean |
| Filter import / AutoEQ | Modifies params via setFilter()/setPreamp() → correctly dirty |
| clearAllMaster() | Uses setFilter() → correctly dirty |
| Pin config changes | Only tracked if presetIncludePins is true |
| Device not connected at quit | savedSnapshot cleared on disconnect → quit proceeds |
