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
    /// Attenuation the designed correction takes so its peak sits on the
    /// combined ceiling.
    ///
    /// The optimizer's error term is level-blind on purpose, so the raw
    /// cascade's absolute level is a free variable and routinely lands well
    /// above unity - up to +18 dB on the corpus. Every safety guarantee the fit
    /// makes is a property of the curve *after* this trim, so the bands alone
    /// do not carry the correction that was designed: this has to be written
    /// too, or the device runs that much hotter than anything the user was
    /// shown.
    let trimDb: Double
    /// Level the correction removes, weighted over the correction band.
    let levelChangeDb: Double
    /// Offset that brings this channel to the common datum, from the level
    /// pass. Zero when level matching was not run or not needed.
    let levelMatchDb: Double
    /// The level every corrected channel is brought to, shared by all of them.
    ///
    /// Set by `balanced(_:)` across the channels being applied, not by any one
    /// channel. See there for why it is the deepest channel's level change.
    let commonDatumDb: Double
    /// Peak of the designed correction, which the fit holds at the combined
    /// ceiling. Only used to work out how hot the filter block itself runs.
    let combinedPeakDb: Double
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

    /// What the destination's gain becomes.
    ///
    /// One value written once. Two separate writes could each be correct and
    /// still leave the device wrong if only one of them landed.
    ///
    /// Derived rather than stored so it cannot disagree with the terms it is
    /// made of - `balanced(_:)` changes the datum, and a stored gain would go
    /// stale the moment the user changed which channels to apply.
    var compensatedGainDb: Float {
        originalGainDb + Float(trimDb - levelChangeDb + commonDatumDb + levelMatchDb)
    }

    /// The gain that makes a flat bank sound as loud as the correction does.
    ///
    /// The corrected channel averages `commonDatumDb` above its baseline, so
    /// this is simply that - which is the whole point of choosing one datum for
    /// every channel. Bypassing at this gain gives a comparison of shape rather
    /// than of loudness.
    var bypassedGainDb: Float {
        originalGainDb + Float(commonDatumDb + levelMatchDb)
    }

    /// Everything the gain moves by, which is what actually gets written.
    var compensationDb: Float { compensatedGainDb - originalGainDb }

    /// The part of the move that belongs to the correction: the headroom it
    /// takes, less the level its cuts removed, brought to the shared datum.
    var correctionLevelDb: Float { Float(trimDb - levelChangeDb + commonDatumDb) }

    /// How far above its input the filter block itself peaks.
    ///
    /// The bands carry the untrimmed cascade, so this is what the EQ stage sees
    /// internally regardless of where the compensating gain lands. It only
    /// matters when that gain is downstream - see `runsHot`.
    var internalPeakDb: Double { combinedPeakDb - trimDb }

    /// Whether the filter block is asked to exceed unity before anything pulls
    /// it back.
    ///
    /// For an input destination the preamp is upstream of the bank, so the
    /// attenuation lands first and the block never sees more than the output
    /// does. For an output destination the per-output gain sits after the
    /// output EQ, so the block runs `internalPeakDb` hot on its own.
    var runsHot: Bool {
        if case .outputGain = destination { return internalPeakDb > 0 }
        return false
    }

    /// Where the internal peak stops being a note and becomes a warning.
    ///
    /// Almost every output-destination correction runs somewhat hot, so
    /// flagging any excursion would flag nearly all of them and mean nothing.
    /// The threshold is set against the tighter of the two platforms: RP2350
    /// works in float32, where internal headroom is not a practical concern,
    /// while RP2040 runs a fixed-point path with a bounded margin above unity.
    /// Spec 7.3 records that the firmware's saturation behaviour has not been
    /// measured, so this is a judgement pending that measurement rather than a
    /// figure derived from it.
    static let hotWarningDb = 12.0
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

@MainActor
extension CorrectionApplyTarget {
    func readGain(_ destination: ChannelApplyPlan.Destination) -> Float? {
        switch destination {
        case .outputGain(let output): return readOutputGain(output: output)
        case .inputPreamp(let channel): return readInputPreamp(channel: channel)
        }
    }

    func writeGain(_ destination: ChannelApplyPlan.Destination, db: Float) {
        switch destination {
        case .outputGain(let output): writeOutputGain(output: output, db: db)
        case .inputPreamp(let channel): writeInputPreamp(channel: channel, db: db)
        }
    }

    /// A whole bank plus its destination gain, in the order that never gets
    /// loud in between.
    ///
    /// Every band is written, including the unused ones cleared to Off, so no
    /// remnant of the user's previous bank survives underneath.
    ///
    /// The attenuating half goes first. The bands carry the untrimmed cascade
    /// and the gain carries the trim, so writing the bands first would put the
    /// whole of that boost on the output for as long as the gain write takes -
    /// on the corpus that is up to 18 dB.
    func writeBank(_ bands: [FilterParams],
                   to channel: Int,
                   destination: ChannelApplyPlan.Destination,
                   gainDb: Float,
                   from previousGainDb: Float) {
        let attenuating = gainDb < previousGainDb
        if attenuating { writeGain(destination, db: gainDb) }
        for (band, params) in bands.enumerated() {
            writeBand(channel: channel, band: band, params: params)
        }
        if !attenuating { writeGain(destination, db: gainDb) }
    }
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

        for plan in plans {
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
        target.writeBank(plan.bands,
                         to: plan.destinationChannel,
                         destination: plan.destination,
                         gainDb: plan.compensatedGainDb,
                         from: plan.originalGainDb)
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
            target.writeBank(entry.bands,
                             to: entry.plan.destinationChannel,
                             destination: entry.plan.destination,
                             gainDb: entry.gainDb,
                             from: entry.plan.compensatedGainDb)
        }
    }

    private func readGain(_ destination: ChannelApplyPlan.Destination) -> Float? {
        target.readGain(destination)
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
    /// `baselineOutputGainDb` and `baselinePreampDb` must be the gains the
    /// measurement was taken with, not the device's current values. The
    /// compensation is an offset from that state, and after one apply the
    /// device already carries it - so feeding the live value back in makes
    /// every re-apply compound the last.
    func applyPlans(mode: MeasurementMode,
                    eqChannel: (Int) -> Int,
                    baselineOutputGainDb: (Int) -> Float,
                    baselinePreampDb: (Int) -> Float,
                    levelMatchDb: (Int) -> Double = { _ in 0 }) -> [ChannelApplyPlan] {
        let built: [ChannelApplyPlan] = fittedChannels.compactMap { speaker in
            guard let fit = fits[speaker] else { return nil }

            var bands = (try? fit.filters) ?? []
            guard bands.count <= Self.bandsPerBank else { return nil }
            while bands.count < Self.bandsPerBank { bands.append(FilterParams()) }

            let trim = (try? fit.trimDb) ?? 0
            let levelChange = (try? fit.levelChangeDb) ?? 0
            let peak = (try? fit.metrics.maxCombinedCorrectionDb) ?? 0
            let levelMatch = levelMatchDb(speaker)

            switch mode {
            case .outputChannels:
                let original = baselineOutputGainDb(speaker)
                return ChannelApplyPlan(
                    speakerIndex: speaker,
                    destinationChannel: eqChannel(speaker),
                    destination: .outputGain(output: speaker),
                    bands: bands,
                    trimDb: trim,
                    levelChangeDb: levelChange,
                    levelMatchDb: levelMatch,
                    commonDatumDb: 0,
                    combinedPeakDb: peak,
                    originalGainDb: original)
            case .inputChannels:
                let original = baselinePreampDb(speaker)
                return ChannelApplyPlan(
                    speakerIndex: speaker,
                    destinationChannel: speaker,
                    destination: .inputPreamp(channel: speaker),
                    bands: bands,
                    trimDb: trim,
                    levelChangeDb: levelChange,
                    levelMatchDb: levelMatch,
                    commonDatumDb: 0,
                    combinedPeakDb: peak,
                    originalGainDb: original)
            }
        }
        return ChannelApplyPlan.balanced(built)
    }
}

extension ChannelApplyPlan {
    /// The same plan with its level-match offset moved.
    ///
    /// Used by the residual pass after verification, where the filters are
    /// already right and only the measured level needs closing.
    func nudged(by offsetDb: Double) -> ChannelApplyPlan {
        ChannelApplyPlan(speakerIndex: speakerIndex,
                         destinationChannel: destinationChannel,
                         destination: destination,
                         bands: bands,
                         trimDb: trimDb,
                         levelChangeDb: levelChangeDb,
                         levelMatchDb: levelMatchDb + offsetDb,
                         commonDatumDb: commonDatumDb,
                         combinedPeakDb: combinedPeakDb,
                         originalGainDb: originalGainDb)
    }

    /// Settles the shared datum across the channels that are actually going to
    /// be written.
    ///
    /// Each channel's gain is `trim - levelChange + datum + levelMatch`. The
    /// three moving parts do different jobs:
    ///
    /// - `trim` puts the designed correction on the device rather than the
    ///   untrimmed cascade the bands describe;
    /// - `-levelChange` gives back the broadband level this channel's cuts
    ///   removed, so a channel that needed deep cuts does not emerge quieter
    ///   than one that needed gentle ones (spec section 7.5);
    /// - `datum` then lowers every channel by the same amount.
    ///
    /// Only the differences between channels carry the balance, so the datum is
    /// free, and choosing the deepest channel's level change spends that
    /// freedom on never asking a destination gain to go positive. The channel
    /// that needed the most gets exactly its own trim; every other channel gets
    /// less. That also keeps the applied peak at or under the combined ceiling
    /// on every channel, which giving the level back outright does not: a
    /// correction's peak is always above its average, and the difference was
    /// landing on the output as clipping.
    ///
    /// Recomputable: the gain is derived, so calling this again with a
    /// different subset simply settles a different datum.
    static func balanced(_ plans: [ChannelApplyPlan]) -> [ChannelApplyPlan] {
        guard let deepest = plans.map(\.levelChangeDb).min() else { return plans }
        // Clamped so a correction that nets out louder cannot raise the datum
        // above unity, which would put boost on a bypassed, flat bank.
        let datum = min(0, deepest)
        return plans.map { plan in
            ChannelApplyPlan(
                speakerIndex: plan.speakerIndex,
                destinationChannel: plan.destinationChannel,
                destination: plan.destination,
                bands: plan.bands,
                trimDb: plan.trimDb,
                levelChangeDb: plan.levelChangeDb,
                levelMatchDb: plan.levelMatchDb,
                commonDatumDb: datum,
                combinedPeakDb: plan.combinedPeakDb,
                originalGainDb: plan.originalGainDb)
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
