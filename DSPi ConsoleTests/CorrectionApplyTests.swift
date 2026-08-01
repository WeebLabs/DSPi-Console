import XCTest
@testable import DSPi_Console

/// Covers the apply transaction.
///
/// Almost all of the value here is in paths a manual test with real hardware
/// never reaches: a band that reads back wrong, a device swapped between
/// calculation and apply, routing changed underneath. Spec section 5 steps 1-6,
/// and Milestone 4's exit criterion that fault injection proves rollback.
@MainActor
final class CorrectionApplyTests: XCTestCase {

    // MARK: - A device that can be made to misbehave

    private final class FakeDevice: CorrectionApplyTarget {
        var deviceSerial: String? = "DEVICE-A"
        var routingSnapshot: [[Bool]] = [[true, false], [false, true]]

        /// `bands[channel][band]`, and the gains, as the device holds them.
        var bands: [Int: [FilterParams]] = [:]
        var outputGain: [Int: Float] = [:]
        var inputPreamp: [Int: Float] = [:]

        /// Corrupts the next write to this channel and band, once.
        var corruptBand: (channel: Int, band: Int)?
        /// Refuses to read this channel back at all.
        var unreadableChannel: Int?
        /// Corrupts the gain write for this destination.
        var corruptGainFor: Int?

        private(set) var log: [String] = []

        func writeBand(channel: Int, band: Int, params: FilterParams) {
            log.append("write ch\(channel) band\(band)")
            var stored = params
            if let corrupt = corruptBand, corrupt.channel == channel, corrupt.band == band {
                stored.gain += 3          // a plausible wire corruption
                corruptBand = nil
            }
            if bands[channel] == nil {
                bands[channel] = Array(repeating: FilterParams(), count: 10)
            }
            bands[channel]?[band] = stored
        }

        func readBand(channel: Int, band: Int) -> FilterParams? {
            if channel == unreadableChannel { return nil }
            return bands[channel]?[band]
        }

        func writeOutputGain(output: Int, db: Float) {
            log.append("write gain out\(output)")
            outputGain[output] = (corruptGainFor == output) ? db + 1 : db
        }

        func readOutputGain(output: Int) -> Float? { outputGain[output] }

        func writeInputPreamp(channel: Int, db: Float) {
            log.append("write preamp ch\(channel)")
            inputPreamp[channel] = (corruptGainFor == channel) ? db + 1 : db
        }

        func readInputPreamp(channel: Int) -> Float? { inputPreamp[channel] }
    }

    private var device: FakeDevice!

    override func setUp() {
        super.setUp()
        device = FakeDevice()
        // Two output banks with the user's own EQ already in them, and a trim.
        for channel in [2, 3] {
            var bank = Array(repeating: FilterParams(), count: 10)
            var existing = FilterParams()
            existing.type = .peaking
            existing.freq = 4000
            existing.gain = 5
            bank[0] = existing
            device.bands[channel] = bank
        }
        device.outputGain = [0: -2, 1: -2]
        device.inputPreamp = [0: 0, 1: 0]
    }

    // MARK: - Plans

    private func peak(_ hz: Float, _ db: Float) -> FilterParams {
        var params = FilterParams()
        params.type = .peaking
        params.freq = hz
        params.q = 2
        params.gain = db
        return params
    }

    private func plan(speaker: Int, channel: Int,
                      trim: Double = 0,
                      levelChange: Double = -3,
                      levelMatch: Double = 0,
                      datum: Double? = nil,
                      combinedPeak: Double = -0.5,
                      preamp: Bool = false,
                      originalGain: Float = -2) -> ChannelApplyPlan {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = peak(63, -6)
        bands[1] = peak(180, -4)
        return ChannelApplyPlan(speakerIndex: speaker,
                                destinationChannel: channel,
                                destination: preamp
                                    ? .inputPreamp(channel: speaker)
                                    : .outputGain(output: speaker),
                                bands: bands,
                                trimDb: trim,
                                levelChangeDb: levelChange,
                                levelMatchDb: levelMatch,
                                // Alone unless told otherwise, so the datum is
                                // this channel's own level change.
                                commonDatumDb: datum ?? min(0, levelChange),
                                combinedPeakDb: combinedPeak,
                                originalGainDb: originalGain)
    }

    private func applier(serial: String? = "DEVICE-A",
                         routing: [[Bool]]? = nil) -> CorrectionApplier {
        CorrectionApplier(target: device,
                          expectedSerial: serial,
                          expectedRouting: routing ?? device.routingSnapshot)
    }

    // MARK: - The happy path

    func testApplyWritesEveryBandAndTheCompensation() async {
        let applier = applier()
        await applier.apply([plan(speaker: 0, channel: 2)])

        XCTAssertEqual(applier.state, .applied)
        // All ten bands, not just the two carrying filters: the correction
        // owns the bank, and a leftover band would sit under it unannounced.
        for band in 0..<10 {
            XCTAssertEqual(device.log.filter { $0 == "write ch2 band\(band)" }.count, 1,
                           "band \(band) should have been written exactly once")
        }
        XCTAssertEqual(device.bands[2]?[0].freq, 63)
        // The user's old 4 kHz band is gone rather than surviving underneath.
        XCTAssertEqual(device.bands[2]?[2].type, .flat)
    }

    func testASingleChannelGetsExactlyItsTrim() async {
        // With one channel there is nothing to balance against, so the datum is
        // its own level change and the two cancel. What is left is the trim -
        // the headroom the designed correction takes - which is the whole of
        // what the device needs and is what REW would call the preamp.
        let applier = applier()
        await applier.apply([plan(speaker: 0, channel: 2,
                                  trim: -8, levelChange: -3, originalGain: -2)])

        XCTAssertEqual(applier.state, .applied)
        XCTAssertEqual(device.outputGain[0] ?? 999, -10, accuracy: 0.001)
    }

    func testTheTrimReachesTheDevice() async {
        // The bands carry the untrimmed cascade. Without the trim the device
        // runs that much hotter than anything the fit gated or the user saw.
        let applier = applier()
        await applier.apply([plan(speaker: 0, channel: 2,
                                  trim: -12, levelChange: -3, originalGain: 0)])

        XCTAssertEqual(applier.state, .applied)
        XCTAssertEqual(device.outputGain[0] ?? 999, -12, accuracy: 0.001)
    }

    func testTheDestinationGainIsNeverPositive() async {
        // The rule the whole scheme exists to keep. A correction that takes a
        // lot of level does not get it back by turning the input up.
        for levelChange in [-24.0, -12.0, -3.0, 0.0, 2.0] {
            for trim in [0.0, -6.0, -18.3] {
                let single = plan(speaker: 0, channel: 2,
                                  trim: trim, levelChange: levelChange,
                                  originalGain: 0)
                XCTAssertLessThanOrEqual(
                    single.compensatedGainDb, 0,
                    "level change \(levelChange), trim \(trim)")
            }
        }
    }

    func testBalancePreservedWithoutRaisingAnything() async {
        // Section 7.5 asks that applying a correction not silently rebalance
        // the system. Only the differences between channels carry that, so
        // both come down rather than the gentler one going up.
        let deep = plan(speaker: 0, channel: 2, trim: -4, levelChange: -10,
                        datum: -10, originalGain: 0)
        let gentle = plan(speaker: 1, channel: 3, trim: -4, levelChange: -2,
                          datum: -10, originalGain: 0)

        // Each channel ends up at the datum: its cuts take levelChange, the
        // gain gives back the difference.
        XCTAssertEqual(Double(deep.compensatedGainDb) + deep.levelChangeDb,
                       Double(gentle.compensatedGainDb) + gentle.levelChangeDb,
                       accuracy: 0.001)
        XCTAssertLessThanOrEqual(deep.compensatedGainDb, 0)
        XCTAssertLessThanOrEqual(gentle.compensatedGainDb, 0)
    }

    func testTheDatumIsTheDeepestChannel() {
        let settled = ChannelApplyPlan.balanced([
            plan(speaker: 0, channel: 2, levelChange: -2),
            plan(speaker: 1, channel: 3, levelChange: -11),
            plan(speaker: 2, channel: 4, levelChange: -5),
        ])
        XCTAssertEqual(settled.map(\.commonDatumDb), [-11, -11, -11])
        // The channel that needed the most gets exactly its trim; nothing is
        // asked to go above unity to keep up with it.
        XCTAssertEqual(settled[1].compensatedGainDb,
                       settled[1].originalGainDb + Float(settled[1].trimDb),
                       accuracy: 0.001)
    }

    func testACorrectionThatNetsLouderStillCannotRaiseTheDatum() {
        // Clamped at unity, or a bypassed flat bank would carry boost.
        let settled = ChannelApplyPlan.balanced([
            plan(speaker: 0, channel: 2, levelChange: 3),
            plan(speaker: 1, channel: 3, levelChange: 5),
        ])
        XCTAssertEqual(settled.map(\.commonDatumDb), [0, 0])
        for one in settled { XCTAssertLessThanOrEqual(one.compensatedGainDb, 0) }
    }

    func testRebalancingIsRecomputable() {
        // The gain is derived, so settling a different subset settles a
        // different datum rather than compounding the last one.
        let all = ChannelApplyPlan.balanced([
            plan(speaker: 0, channel: 2, levelChange: -2),
            plan(speaker: 1, channel: 3, levelChange: -11),
        ])
        let withoutTheDeepOne = ChannelApplyPlan.balanced([all[0]])
        XCTAssertEqual(withoutTheDeepOne[0].commonDatumDb, -2)
        XCTAssertEqual(withoutTheDeepOne[0].compensatedGainDb,
                       withoutTheDeepOne[0].originalGainDb
                           + Float(withoutTheDeepOne[0].trimDb),
                       accuracy: 0.001)
    }

    func testTheAttenuatingStepIsWrittenFirst() async {
        // The bands carry the untrimmed cascade, so writing them before the
        // gain comes down puts the whole boost on the output in between.
        let applier = applier()
        await applier.apply([plan(speaker: 0, channel: 2,
                                  trim: -18, levelChange: -3, originalGain: 0)])

        XCTAssertEqual(applier.state, .applied)
        let gain = device.log.firstIndex(of: "write gain out0")
        let firstBand = device.log.firstIndex(of: "write ch2 band0")
        XCTAssertNotNil(gain)
        XCTAssertNotNil(firstBand)
        XCTAssertLessThan(gain ?? .max, firstBand ?? .min,
                          "gain must land before the bands: \(device.log)")
    }

    func testAnInputDestinationWritesThePreamp() async {
        // An input bank to snapshot; setUp only seeds the output banks.
        device.bands[0] = Array(repeating: FilterParams(), count: 10)
        let applier = applier()
        await applier.apply([plan(speaker: 0, channel: 0,
                                  trim: -6, levelChange: -3,
                                  preamp: true, originalGain: 0)])

        XCTAssertEqual(applier.state, .applied)
        XCTAssertEqual(device.inputPreamp[0] ?? 999, -6, accuracy: 0.001)
        XCTAssertFalse(device.log.contains { $0.hasPrefix("write gain") },
                       "no output gain should have been touched: \(device.log)")
    }

    func testTheFilterBlockRunsHotOnlyWhenTheGainIsDownstream() {
        // An output's gain sits after its EQ, so the block sees the untrimmed
        // cascade. An input's preamp is upstream, so it never does.
        let output = plan(speaker: 0, channel: 2, trim: -18, combinedPeak: -0.5)
        let input = plan(speaker: 0, channel: 0, trim: -18, combinedPeak: -0.5,
                         preamp: true)
        XCTAssertEqual(output.internalPeakDb, 17.5, accuracy: 0.001)
        XCTAssertTrue(output.runsHot)
        XCTAssertFalse(input.runsHot)
    }

    func testApplyingASubsetLeavesTheOthersAlone() async {
        let applier = applier()
        await applier.apply([plan(speaker: 0, channel: 2)])

        XCTAssertEqual(applier.state, .applied)
        XCTAssertFalse(device.log.contains { $0.contains("ch3") },
                       "an unselected channel must not be touched: \(device.log)")
        XCTAssertEqual(device.bands[3]?[0].freq, 4000, "its existing EQ is intact")
    }

    func testTheLevelMatchAndTheCompensationAreWrittenAsOneValue() async {
        // Two writes could each be right and still leave the device wrong if
        // only one landed, so they are summed into the gain that gets written.
        let applier = applier()
        await applier.apply([plan(speaker: 0, channel: 2,
                                  trim: -5, levelChange: -3, levelMatch: -1.5,
                                  originalGain: -2)])

        XCTAssertEqual(applier.state, .applied)
        // -2 baseline, -5 of trim, +3 given back, -3 to the datum, -1.5 match.
        XCTAssertEqual(device.outputGain[0] ?? 999, -8.5, accuracy: 0.001)
        XCTAssertEqual(device.log.filter { $0 == "write gain out0" }.count, 1,
                       "one write, not two: \(device.log)")
    }

    func testBypassingIsLevelMatchedToTheCorrection() {
        // The corrected channel averages the datum above its baseline, so a
        // flat bank at that same gain sounds as loud. Anything else turns the
        // comparison into a loudness test.
        let one = plan(speaker: 0, channel: 2, trim: -5, levelChange: -3,
                       levelMatch: -1.5, originalGain: -2)
        XCTAssertEqual(one.bypassedGainDb,
                       one.originalGainDb + Float(one.commonDatumDb + one.levelMatchDb),
                       accuracy: 0.001)
        // Corrected mean = gain + levelChange. Bypassed mean = bypassed gain.
        XCTAssertEqual(Double(one.compensatedGainDb) + one.levelChangeDb - one.trimDb,
                       Double(one.bypassedGainDb), accuracy: 0.001)
    }

    // MARK: - Comparison

    private func comparison(_ plans: [ChannelApplyPlan],
                            serial: String? = "DEVICE-A") -> CorrectionComparison {
        CorrectionComparison(target: device, expectedSerial: serial, plans: plans)
    }

    func testBypassingClearsTheBandsAndDropsTheLevel() async {
        let one = plan(speaker: 0, channel: 2, trim: -5, levelChange: -3,
                       originalGain: -2)
        let applier = applier()
        await applier.apply([one])
        XCTAssertEqual(applier.state, .applied)

        let comparing = comparison([one])
        comparing.setBypassed(true)

        XCTAssertTrue(comparing.isBypassed)
        XCTAssertNil(comparing.failure)
        for band in 0..<10 {
            XCTAssertEqual(device.bands[2]?[band].type, .flat,
                           "band \(band) should be off while bypassed")
        }
        XCTAssertEqual(device.outputGain[0] ?? 999, one.bypassedGainDb, accuracy: 0.001)
    }

    func testEngagingPutsTheCorrectionBack() async {
        let one = plan(speaker: 0, channel: 2, trim: -5, levelChange: -3,
                       originalGain: -2)
        let applier = applier()
        await applier.apply([one])

        let comparing = comparison([one])
        comparing.setBypassed(true)
        comparing.setBypassed(false)

        XCTAssertFalse(comparing.isBypassed)
        XCTAssertEqual(device.bands[2]?[0].freq, 63)
        XCTAssertEqual(device.bands[2]?[1].freq, 180)
        XCTAssertEqual(device.outputGain[0] ?? 999, one.compensatedGainDb,
                       accuracy: 0.001)
    }

    func testTheTwoSidesOfTheComparisonAreTheSameLoudness() {
        // Corrected sits at its gain plus the level its own filters average to,
        // which is the level change less the trim the gain already carries.
        // Bypassed is flat at its gain. They must land in the same place, or
        // the louder side wins for the wrong reason.
        for levelChange in [-14.0, -6.0, -1.0] {
            for trim in [0.0, -9.0] {
                let one = plan(speaker: 0, channel: 2, trim: trim,
                               levelChange: levelChange, levelMatch: -2,
                               originalGain: -3)
                let corrected = Double(one.compensatedGainDb)
                    + (one.levelChangeDb - one.trimDb)
                XCTAssertEqual(corrected, Double(one.bypassedGainDb), accuracy: 1e-6,
                               "level change \(levelChange), trim \(trim)")
            }
        }
    }

    func testComparingRefusesADifferentDevice() async {
        let one = plan(speaker: 0, channel: 2)
        let applier = applier()
        await applier.apply([one])

        device.deviceSerial = "DEVICE-B"
        let comparing = comparison([one], serial: "DEVICE-A")
        comparing.setBypassed(true)

        XCTAssertFalse(comparing.isBypassed)
        XCTAssertNotNil(comparing.failure)
        XCTAssertEqual(device.bands[2]?[0].freq, 63, "nothing should have moved")
    }

    func testAGainThatDoesNotReadBackIsReported() async {
        let one = plan(speaker: 0, channel: 2)
        let applier = applier()
        await applier.apply([one])

        device.corruptGainFor = 0
        let comparing = comparison([one])
        comparing.setBypassed(true)

        // Reported rather than silently accepted: an unmatched comparison is
        // worse than none, because it reads as a verdict on the correction.
        XCTAssertNotNil(comparing.failure)
    }

    // MARK: - Refusals, before anything is written

    func testADifferentDeviceIsRefused() async {
        device.deviceSerial = "DEVICE-B"
        let applier = applier(serial: "DEVICE-A")

        await applier.apply([plan(speaker: 0, channel: 2)])

        guard case .refused(let reason) = applier.state else {
            return XCTFail("expected a refusal, got \(applier.state)")
        }
        XCTAssertTrue(reason.contains("not the device"), reason)
        XCTAssertTrue(device.log.isEmpty, "nothing may be written: \(device.log)")
    }

    func testChangedRoutingIsRefused() async {
        // A routing change invalidates an input-destination result even though
        // every band would write successfully.
        let applier = applier(routing: [[true, false], [false, true]])
        device.routingSnapshot = [[true, true], [false, true]]

        await applier.apply([plan(speaker: 0, channel: 2)])

        guard case .refused(let reason) = applier.state else {
            return XCTFail("expected a refusal, got \(applier.state)")
        }
        XCTAssertTrue(reason.contains("routing"), reason)
        XCTAssertTrue(device.log.isEmpty, "nothing may be written: \(device.log)")
    }

    func testADeviceThatCannotBeReadIsRefusedRatherThanRisked() async {
        // Without a snapshot there is no way back, so the write must not start.
        device.unreadableChannel = 2
        let applier = applier()

        await applier.apply([plan(speaker: 0, channel: 2)])

        guard case .refused(let reason) = applier.state else {
            return XCTFail("expected a refusal, got \(applier.state)")
        }
        XCTAssertTrue(reason.contains("no way back"), reason)
        XCTAssertTrue(device.log.isEmpty, "nothing may be written: \(device.log)")
    }

    func testAnEmptySelectionIsRefused() async {
        let applier = applier()
        await applier.apply([])
        guard case .refused = applier.state else {
            return XCTFail("expected a refusal, got \(applier.state)")
        }
    }

    // MARK: - Rollback

    func testABandThatReadsBackWrongRollsEverythingBack() async {
        device.corruptBand = (channel: 2, band: 1)
        let applier = applier()

        await applier.apply([plan(speaker: 0, channel: 2)])

        guard case .rolledBack(let reason) = applier.state else {
            return XCTFail("expected a rollback, got \(applier.state)")
        }
        XCTAssertTrue(reason.contains("Band 2"), reason)
        // The user's original bank is back, including the band that wrote fine.
        XCTAssertEqual(device.bands[2]?[0].freq, 4000)
        XCTAssertEqual(device.bands[2]?[0].gain, 5)
        XCTAssertEqual(device.outputGain[0] ?? 999, -2, accuracy: 0.001)
        XCTAssertTrue(applier.appliedPlans.isEmpty)
    }

    func testAFailureOnTheSecondChannelRestoresTheFirstToo() async {
        // Step 5 says restore all affected banks, not only the one that failed.
        device.corruptBand = (channel: 3, band: 0)
        let applier = applier()

        await applier.apply([plan(speaker: 0, channel: 2),
                             plan(speaker: 1, channel: 3)])

        guard case .rolledBack = applier.state else {
            return XCTFail("expected a rollback, got \(applier.state)")
        }
        XCTAssertEqual(device.bands[2]?[0].freq, 4000,
                       "the channel that succeeded must be rolled back as well")
        XCTAssertEqual(device.outputGain[0] ?? 999, -2, accuracy: 0.001)
        XCTAssertEqual(device.outputGain[1] ?? 999, -2, accuracy: 0.001)
    }

    func testACompensationThatReadsBackWrongAlsoRollsBack() async {
        // The compensation is part of the correction, not a decoration on it.
        device.corruptGainFor = 0
        let applier = applier()

        await applier.apply([plan(speaker: 0, channel: 2)])

        guard case .rolledBack(let reason) = applier.state else {
            return XCTFail("expected a rollback, got \(applier.state)")
        }
        XCTAssertTrue(reason.lowercased().contains("compensation"), reason)
        XCTAssertEqual(device.bands[2]?[0].freq, 4000)
    }

    // MARK: - Comparison rules

    func testAClearedBandOnlyHasToBeOff() async {
        // The firmware need not preserve a disabled band's leftover frequency
        // and Q, and demanding it would fail every apply for no reason.
        var stale = FilterParams()
        stale.type = .flat
        stale.freq = 12345
        stale.q = 9
        device.bands[2]?[5] = stale

        let applier = applier()
        await applier.apply([plan(speaker: 0, channel: 2)])

        XCTAssertEqual(applier.state, .applied)
    }
}
