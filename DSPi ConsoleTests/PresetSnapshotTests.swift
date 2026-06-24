import XCTest
@testable import DSPi_Console

/// Pure-logic tests for unsaved-change detection (`PresetSnapshot.diff`). Builds
/// two snapshots that differ in exactly one dimension and asserts the diff
/// reports it (and reports nothing when they are identical). No hardware.
final class PresetSnapshotTests: XCTestCase {

    private let names = ["USB L", "USB R", "Out L", "Out R", "Sub"]

    /// Builds a neutral snapshot; pass only the field(s) under test. Every
    /// `PresetSnapshot` field is `let` with no default, so this factory carries
    /// the defaults once for all tests.
    private func makeSnapshot(
        preampDB: [Float] = [0, 0],
        masterVolumeDB: Float = 0,
        masterVolumeMode: Int = 0,
        outputConfigMode: Int = 0,
        platformName: String = "RP2350",
        bypass: Bool = false,
        channelFilters: [Int: [SnapshotFilterParams]] = [:],
        crossoverFilters: [Int: [SnapshotFilterParams]] = [:],
        channelNames: [String] = ["USB L", "USB R", "Out L", "Out R", "Sub"],
        outputPins: [UInt8] = [6, 7, 8, 9, 10],
        outputSlotTypes: [UInt8] = [0, 0, 0, 0],
        spdifRxPin: UInt8 = 11
    ) -> PresetSnapshot {
        PresetSnapshot(
            preampDB: preampDB,
            masterVolumeDB: masterVolumeDB,
            masterVolumeMode: masterVolumeMode,
            outputConfigMode: outputConfigMode,
            platformName: platformName,
            bypass: bypass,
            loudnessEnabled: false,
            loudnessRefSPL: 80,
            loudnessIntensity: 0,
            crossfeedEnabled: false,
            crossfeedPreset: 0,
            crossfeedFreq: 700,
            crossfeedFeed: 0,
            crossfeedITD: false,
            levellerEnabled: false,
            levellerAmount: 0,
            levellerSpeed: 0,
            levellerMaxGainDB: 0,
            levellerLookahead: false,
            levellerGateDB: -96,
            channelDelays: [:],
            matrixRouting: [],
            matrixGain: [],
            matrixInvert: [],
            outputEnabled: [true, true, true, true, true],
            outputMuted: [false, false, false, false, false],
            outputGainDB: [0, 0, 0, 0, 0],
            outputDelayMS: [0, 0, 0, 0, 0],
            channelFilters: channelFilters,
            crossoverFilters: crossoverFilters,
            channelNames: channelNames,
            outputPins: outputPins,
            outputSlotTypes: outputSlotTypes,
            i2sBckPin: 6,
            mckEnabled: false,
            mckPin: 21,
            mckMultiplier: 128,
            spdifRxPin: spdifRxPin,
            inputSource: nil,
            i2sRxPin: nil,
            i2sInputRate: nil,
            lgSoundSyncEnabled: nil
        )
    }

    private func band(_ type: FilterType, _ freq: Float, _ q: Float = 0.707, _ gain: Float = 0) -> SnapshotFilterParams {
        SnapshotFilterParams(from: FilterParams(type: type, freq: freq, q: q, gain: gain))
    }

    func testIdenticalSnapshotsAreClean() {
        let s = makeSnapshot(channelFilters: [0: [band(.peaking, 1000, 1, 3)]])
        let diff = PresetSnapshot.diff(from: s, to: s, channelNames: names)
        XCTAssertFalse(diff.hasChanges, "identical snapshots must produce no changes")
    }

    func testEQBandChangeIsDetected() {
        let old = makeSnapshot(channelFilters: [0: [band(.peaking, 1000, 1, 0)]])
        let new = makeSnapshot(channelFilters: [0: [band(.peaking, 1000, 1, 6)]])
        let diff = PresetSnapshot.diff(from: old, to: new, channelNames: names)
        XCTAssertTrue(diff.hasChanges, "a changed EQ gain must be detected")
        XCTAssertTrue(diff.changes.contains { $0.category.contains("EQ") },
                      "the change should be categorized under EQ: \(diff.changes.map(\.category))")
    }

    func testCrossoverBandChangeIsDetected() {
        let old = makeSnapshot(crossoverFilters: [2: [band(.lr4_lp, 1000)]])
        let new = makeSnapshot(crossoverFilters: [2: [band(.lr4_lp, 1200)]])
        let diff = PresetSnapshot.diff(from: old, to: new, channelNames: names)
        XCTAssertTrue(diff.hasChanges, "a changed crossover frequency must be detected")
        XCTAssertTrue(diff.changes.contains { $0.category.contains("Crossover") },
                      "the change should be categorized under Crossover: \(diff.changes.map(\.category))")
    }

    func testUserRenameIsDetected() {
        let old = makeSnapshot(channelNames: ["USB L", "USB R", "Out L", "Out R", "Sub"])
        let new = makeSnapshot(channelNames: ["USB L", "USB R", "Living Room Mains", "Out R", "Sub"])
        let diff = PresetSnapshot.diff(from: old, to: new, channelNames: names)
        XCTAssertTrue(diff.hasChanges, "renaming a channel to a custom value must be detected")
    }

    func testMasterVolumeChangeGatedByMode() {
        // In WITH_PRESET mode a master-volume change counts toward dirtiness.
        let old = makeSnapshot(masterVolumeDB: 0, masterVolumeMode: MASTER_VOLUME_MODE_WITH_PRESET)
        let new = makeSnapshot(masterVolumeDB: -10, masterVolumeMode: MASTER_VOLUME_MODE_WITH_PRESET)
        XCTAssertTrue(PresetSnapshot.diff(from: old, to: new, channelNames: names).hasChanges,
                      "master volume change should be dirty in WITH_PRESET mode")

        // In INDEPENDENT mode the same change must NOT dirty the preset.
        let oldI = makeSnapshot(masterVolumeDB: 0, masterVolumeMode: MASTER_VOLUME_MODE_INDEPENDENT)
        let newI = makeSnapshot(masterVolumeDB: -10, masterVolumeMode: MASTER_VOLUME_MODE_INDEPENDENT)
        XCTAssertFalse(PresetSnapshot.diff(from: oldI, to: newI, channelNames: names).hasChanges,
                       "master volume change should be ignored in INDEPENDENT mode")
    }
}
