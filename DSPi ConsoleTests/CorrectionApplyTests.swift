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
                      levelChange: Double = -3,
                      levelMatch: Double = 0,
                      originalGain: Float = -2) -> ChannelApplyPlan {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = peak(63, -6)
        bands[1] = peak(180, -4)
        return ChannelApplyPlan(speakerIndex: speaker,
                                destinationChannel: channel,
                                destination: .outputGain(output: speaker),
                                bands: bands,
                                levelChangeDb: levelChange,
                                levelMatchDb: levelMatch,
                                compensatedGainDb: originalGain
                                    + Float(-levelChange + levelMatch),
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

    func testCompensationGivesBackWhatTheCorrectionTook() async {
        // Section 7.5: the correction lowered this channel by 3 dB, so the
        // destination gains 3 dB and the pre-correction balance survives.
        let applier = applier()
        await applier.apply([plan(speaker: 0, channel: 2,
                                  levelChange: -3, originalGain: -2)])

        XCTAssertEqual(applier.state, .applied)
        XCTAssertEqual(device.outputGain[0] ?? 999, 1, accuracy: 0.001)
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
                                  levelChange: -3, levelMatch: -1.5,
                                  originalGain: -2)])

        XCTAssertEqual(applier.state, .applied)
        // -2 baseline, +3 given back, -1.5 to reach the datum.
        XCTAssertEqual(device.outputGain[0] ?? 999, -0.5, accuracy: 0.001)
        XCTAssertEqual(device.log.filter { $0 == "write gain out0" }.count, 1,
                       "one write, not two: \(device.log)")
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
