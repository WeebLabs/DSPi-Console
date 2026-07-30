import Foundation

/// Everything that will be written to the device for one channel.
///
/// Built before anything is touched, so the Apply screen can show exactly what
/// is about to change and the transaction has a single description to work
/// from. Spec section 5: "A user should never reach the Apply screen unsure of
/// what is about to change."
struct ChannelApplyPlan: Identifiable, Equatable {
    /// Index in the measurement mode's numbering: an input, or an output.
    let speakerIndex: Int
    /// The PEQ bank that will be written, in the device's channel numbering.
    let destinationChannel: Int
    /// Where the compensation lands. Section 7.5 requires it at the same end
    /// as the filters, or a non-one-to-one routing carries them to different
    /// places.
    let destination: Destination
    /// Ten bands, unused ones already cleared to Off.
    let bands: [FilterParams]
    /// Level the correction removes, weighted over the correction band.
    let levelChangeDb: Double
    /// What the destination's gain becomes: its original value less the level
    /// the correction added, so the pre-correction balance survives.
    let compensatedGainDb: Float
    let originalGainDb: Float

    var id: Int { speakerIndex }

    enum Destination: Equatable {
        /// Output trim, for an output-destination correction.
        case outputGain(output: Int)
        /// Per-input preamp, for an input-destination correction.
        case inputPreamp(channel: Int)
    }

    /// Bands carrying an actual filter, for display.
    var activeBandCount: Int { bands.filter { $0.type != .flat }.count }

    var compensationDb: Float { compensatedGainDb - originalGainDb }
}

/// What Apply needs from the device.
///
/// A protocol for the same reason `MeasurementDeviceWriter` is one: the
/// transaction's value is entirely in its failure paths, and those are the
/// paths a manual test with real hardware never reaches.
@MainActor
protocol CorrectionApplyTarget: AnyObject {
    /// Identity, checked against what was recorded at calculation time.
    var deviceSerial: String? { get }
    /// `routing[input][output]`, checked for the same reason.
    var routingSnapshot: [[Bool]] { get }

    func writeBand(channel: Int, band: Int, params: FilterParams)
    /// Reads the band back from the device, not from a cache.
    func readBand(channel: Int, band: Int) -> FilterParams?

    func writeOutputGain(output: Int, db: Float)
    func readOutputGain(output: Int) -> Float?
    func writeInputPreamp(channel: Int, db: Float)
    func readInputPreamp(channel: Int) -> Float?
}

/// Applies a calculated correction as a best-effort transaction.
///
/// Spec section 5, steps 1-6: snapshot, confirm identity, write, read back,
/// roll back on any mismatch, and never touch flash.
@MainActor
final class CorrectionApplier: ObservableObject {

    enum State: Equatable {
        case idle
        case applying(channel: Int, of: Int)
        case applied
        case rolledBack(reason: String)
        case refused(reason: String)

        var isBusy: Bool { if case .applying = self { return true }; return false }
    }

    @Published private(set) var state: State = .idle
    /// What was written, once it verified. Empty until then.
    @Published private(set) var appliedPlans: [ChannelApplyPlan] = []

    private let target: CorrectionApplyTarget
    /// Identity and routing as they were when the correction was calculated.
    private let expectedSerial: String?
    private let expectedRouting: [[Bool]]

    init(target: CorrectionApplyTarget,
         expectedSerial: String?,
         expectedRouting: [[Bool]]) {
        self.target = target
        self.expectedSerial = expectedSerial
        self.expectedRouting = expectedRouting
    }

    /// Bands must match to this before a write counts as verified.
    ///
    /// The wire carries float32, so a value should survive exactly; the
    /// tolerance is for the frequency and Q quantization the firmware applies,
    /// not for slack in the comparison.
    private let tolerance: Float = 0.01

    // MARK: - Applying

    func apply(_ plans: [ChannelApplyPlan]) async {
        guard !state.isBusy else { return }
        guard !plans.isEmpty else {
            state = .refused(reason: "No channels were selected to apply.")
            return
        }

        // Step 2: identity and routing, before anything is written.
        if let expectedSerial, target.deviceSerial != expectedSerial {
            state = .refused(reason: "This is not the device the correction was "
                             + "calculated for. Reconnect the original device, or "
                             + "recalculate for this one.")
            return
        }
        if !routingMatches() {
            // Section 5: a routing change invalidates an input-destination
            // result even though every band would write successfully.
            state = .refused(reason: "The matrix routing has changed since the "
                             + "correction was calculated, so it no longer describes "
                             + "this signal path. Recalculate before applying.")
            return
        }

        // Step 1: snapshot every destination, read from the device rather than
        // from any cache, so a rollback restores what is really there.
        guard let snapshot = captureSnapshot(of: plans) else {
            state = .refused(reason: "The device did not return its current settings, "
                             + "so there would be no way back if the write failed.")
            return
        }

        for (index, plan) in plans.enumerated() {
            state = .applying(channel: plan.speakerIndex, of: plans.count)

            write(plan)
            if let failure = verify(plan) {
                // Step 5: restore every affected channel, not just this one.
                restore(snapshot)
                state = .rolledBack(reason: failure)
                appliedPlans = []
                return
            }
        }

        appliedPlans = plans
        // Step 6: the preset is now unsaved. Flash is never written here.
        state = .applied
    }

    // MARK: - Steps

    private func routingMatches() -> Bool {
        let live = target.routingSnapshot
        guard live.count == expectedRouting.count else { return false }
        for (row, expected) in zip(live, expectedRouting) where row != expected {
            return false
        }
        return true
    }

    /// One channel's device state, as it was before the write.
    private struct Snapshot {
        let plan: ChannelApplyPlan
        let bands: [FilterParams]
        let gainDb: Float
    }

    private func captureSnapshot(of plans: [ChannelApplyPlan]) -> [Snapshot]? {
        var captured: [Snapshot] = []
        for plan in plans {
            var bands: [FilterParams] = []
            for band in plan.bands.indices {
                guard let value = target.readBand(channel: plan.destinationChannel,
                                                  band: band) else { return nil }
                bands.append(value)
            }
            guard let gain = readGain(plan.destination) else { return nil }
            captured.append(Snapshot(plan: plan, bands: bands, gainDb: gain))
        }
        return captured
    }

    private func write(_ plan: ChannelApplyPlan) {
        // Step 3: every band, including the unused ones cleared to Off, so no
        // remnant of the user's previous bank survives underneath.
        for (band, params) in plan.bands.enumerated() {
            target.writeBand(channel: plan.destinationChannel, band: band, params: params)
        }
        writeGain(plan.destination, db: plan.compensatedGainDb)
    }

    /// Step 4. Returns nil when everything read back correctly.
    private func verify(_ plan: ChannelApplyPlan) -> String? {
        for (band, expected) in plan.bands.enumerated() {
            guard let actual = target.readBand(channel: plan.destinationChannel,
                                               band: band) else {
                return "Band \(band + 1) could not be read back from the device."
            }
            if !matches(actual, expected) {
                return "Band \(band + 1) read back as \(describe(actual)) after writing "
                     + "\(describe(expected))."
            }
        }
        guard let gain = readGain(plan.destination) else {
            return "The level compensation could not be read back from the device."
        }
        if abs(gain - plan.compensatedGainDb) > tolerance {
            return String(format: "The level compensation read back as %.2f dB after "
                          + "writing %.2f dB.", gain, plan.compensatedGainDb)
        }
        return nil
    }

    private func restore(_ snapshot: [Snapshot]) {
        for entry in snapshot {
            for (band, params) in entry.bands.enumerated() {
                target.writeBand(channel: entry.plan.destinationChannel,
                                 band: band, params: params)
            }
            writeGain(entry.plan.destination, db: entry.gainDb)
        }
    }

    // MARK: - Destination

    private func readGain(_ destination: ChannelApplyPlan.Destination) -> Float? {
        switch destination {
        case .outputGain(let output): return target.readOutputGain(output: output)
        case .inputPreamp(let channel): return target.readInputPreamp(channel: channel)
        }
    }

    private func writeGain(_ destination: ChannelApplyPlan.Destination, db: Float) {
        switch destination {
        case .outputGain(let output): target.writeOutputGain(output: output, db: db)
        case .inputPreamp(let channel): target.writeInputPreamp(channel: channel, db: db)
        }
    }

    // MARK: - Comparison

    private func matches(_ actual: FilterParams, _ expected: FilterParams) -> Bool {
        guard actual.type == expected.type, actual.bypass == expected.bypass else {
            return false
        }
        // A cleared band only has to be off; its leftover frequency and Q are
        // not meaningful and the firmware may not preserve them.
        if expected.type == .flat { return true }
        return abs(actual.freq - expected.freq) <= max(tolerance, expected.freq * 0.001)
            && abs(actual.q - expected.q) <= tolerance
            && abs(actual.gain - expected.gain) <= tolerance
    }

    private func describe(_ params: FilterParams) -> String {
        params.type == .flat
            ? "off"
            : String(format: "%@ %.1f Hz %+.2f dB Q %.3f",
                     params.type.name, params.freq, params.gain, params.q)
    }
}

// MARK: - Building the plan

extension CorrectionDesign {
    /// Ten bands per bank, because room correction owns the whole ordinary PEQ
    /// bank of each destination channel (spec section 15, decision 1).
    static let bandsPerBank = 10

    /// What Apply would write, for every fitted channel.
    ///
    /// Built before anything is touched so the screen can state exactly what
    /// changes. Unused bands are cleared to Off rather than left alone: the
    /// correction replaces the bank, and a surviving band from the user's
    /// previous EQ would sit underneath it unannounced.
    func applyPlans(mode: MeasurementMode,
                    eqChannel: (Int) -> Int,
                    currentOutputGainDb: (Int) -> Float,
                    currentPreampDb: (Int) -> Float) -> [ChannelApplyPlan] {
        fittedChannels.compactMap { speaker in
            guard let fit = fits[speaker] else { return nil }

            var bands = (try? fit.filters) ?? []
            guard bands.count <= Self.bandsPerBank else { return nil }
            while bands.count < Self.bandsPerBank { bands.append(FilterParams()) }

            let levelChange = (try? fit.levelChangeDb) ?? 0

            switch mode {
            case .outputChannels:
                let original = currentOutputGainDb(speaker)
                return ChannelApplyPlan(
                    speakerIndex: speaker,
                    destinationChannel: eqChannel(speaker),
                    destination: .outputGain(output: speaker),
                    bands: bands,
                    levelChangeDb: levelChange,
                    compensatedGainDb: original - Float(levelChange),
                    originalGainDb: original)
            case .inputChannels:
                let original = currentPreampDb(speaker)
                return ChannelApplyPlan(
                    speakerIndex: speaker,
                    destinationChannel: speaker,
                    destination: .inputPreamp(channel: speaker),
                    bands: bands,
                    levelChangeDb: levelChange,
                    compensatedGainDb: original - Float(levelChange),
                    originalGainDb: original)
            }
        }
    }
}

// MARK: - The live device

@MainActor
extension DSPViewModel: CorrectionApplyTarget {
    var deviceSerial: String? { selectedDevice?.serial }
    var routingSnapshot: [[Bool]] { matrixRouting }

    func writeBand(channel: Int, band: Int, params: FilterParams) {
        setFilter(ch: channel, band: band, p: params)
    }

    func readBand(channel: Int, band: Int) -> FilterParams? {
        // Straight from the device, synchronously. The cache-populating
        // `fetchFilter` publishes from a main-queue hop, so reading the cache
        // here would return the value from before the fetch - which is to say,
        // whatever this app had just written into it.
        deviceFilter(ch: channel, band: band)
    }

    func writeOutputGain(output: Int, db: Float) {
        setOutputGain(output: output, db: db)
    }

    func readOutputGain(output: Int) -> Float? {
        deviceOutputGainDB(output: output)
    }

    func writeInputPreamp(channel: Int, db: Float) {
        setPreampChannel(channel: channel, db: db)
    }

    func readInputPreamp(channel: Int) -> Float? {
        devicePreampDB(channel: channel)
    }
}
