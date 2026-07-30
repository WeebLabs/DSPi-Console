import Foundation

/// One channel's measured level, as the level pass found it.
struct ChannelLevel: Identifiable, Equatable {
    let speakerIndex: Int
    /// In-band spectral level, power per bin in dB. Band-independent, so a
    /// subwoofer and a midband channel are directly comparable.
    let levelDb: Double
    let role: RoomCorrectionCore.SpeakerRole
    /// The band it was measured over, for reporting.
    let bandHz: ClosedRange<Double>

    var id: Int { speakerIndex }
    var isSubwoofer: Bool { role == .subwoofer }
}

/// What to do about the levels found.
///
/// Pure over the measured set, so every rule here - which channel is the datum,
/// which are too far out to absorb digitally, what a subwoofer does instead -
/// is testable without a device, a microphone or a room.
///
/// See `Documentation/room_correction_level_calibration.md`.
struct ChannelLevelMatch: Equatable {

    /// One channel's outcome.
    struct Offset: Identifiable, Equatable {
        let speakerIndex: Int
        /// What to add to the destination gain. Never positive for a
        /// full-range channel, since matching is downward.
        let offsetDb: Double
        /// How far this channel sat from the datum before matching.
        let deviationDb: Double
        let needsPhysicalGainChange: Bool
        let isSubwoofer: Bool

        var id: Int { speakerIndex }
    }

    /// The level every full-range channel is brought to.
    let datumDb: Double
    let offsets: [Offset]
    /// Total output given up by matching downward.
    let outputLostDb: Double
    /// Channels too far from the datum to absorb with a digital trim.
    let outOfRange: [Offset]
    /// True when no calibration file was loaded and a subwoofer was measured,
    /// so the cross-band comparison carries the microphone's own uncalibrated
    /// low-frequency response.
    let subwooferAccuracyReduced: Bool

    /// How far a channel may sit from the datum before a physical gain change
    /// is asked for.
    ///
    /// Beyond this the digital trim is being used to paper over a gain
    /// structure problem, and the cost is paid by every other channel.
    static let workableWindowDb = 3.0

    /// Bands the comparison uses. Full-range sits above the modal region and
    /// below where directivity takes over; a subwoofer is measured over its own
    /// passband, which is why the figures are band-independent.
    static let fullRangeBand: ClosedRange<Double> = 200...4000

    // MARK: - Deciding

    /// `hasCalibration` only affects whether a subwoofer result is flagged: a
    /// same-band comparison needs no calibration file, a cross-band one does.
    init(levels: [ChannelLevel], hasCalibration: Bool) {
        let fullRange = levels.filter { !$0.isSubwoofer }
        let subwoofers = levels.filter(\.isSubwoofer)

        // The datum is the median of the full-range channels rather than their
        // mean, so one badly set channel does not drag the reference it is
        // being judged against.
        let sorted = fullRange.map(\.levelDb).sorted()
        let median = sorted.isEmpty
            ? 0
            : (sorted.count % 2 == 1
                ? sorted[sorted.count / 2]
                : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2)

        // Matched downward, to the quietest full-range channel: every channel
        // has already spent headroom on its correction, and asking for gain on
        // top of that risks exceeding what is available. Attenuation always
        // succeeds.
        //
        // A channel outside the window is excluded from the search, or one
        // badly quiet channel would set the target for everything else - the
        // very outcome the user is being asked to fix.
        let inWindow = fullRange.filter { abs($0.levelDb - median) <= Self.workableWindowDb }
        let target = (inWindow.isEmpty ? fullRange : inWindow).map(\.levelDb).min() ?? median

        var built: [Offset] = []
        for channel in fullRange {
            let deviation = channel.levelDb - median
            let outside = abs(deviation) > Self.workableWindowDb
            built.append(Offset(speakerIndex: channel.speakerIndex,
                                // Never positive: a channel below the target is
                                // left alone rather than boosted into it.
                                offsetDb: outside ? 0 : min(0, target - channel.levelDb),
                                deviationDb: deviation,
                                needsPhysicalGainChange: outside,
                                isSubwoofer: false))
        }

        // A subwoofer sits on its own datum and never joins the downward
        // search. A weak one must not attenuate every other channel to meet it.
        for sub in subwoofers {
            let deviation = sub.levelDb - median
            built.append(Offset(speakerIndex: sub.speakerIndex,
                                offsetDb: 0,
                                deviationDb: deviation,
                                needsPhysicalGainChange:
                                    abs(deviation) > Self.workableWindowDb,
                                isSubwoofer: true))
        }

        self.datumDb = target
        self.offsets = built.sorted { $0.speakerIndex < $1.speakerIndex }
        self.outOfRange = self.offsets.filter(\.needsPhysicalGainChange)
        self.outputLostDb = median - target
        self.subwooferAccuracyReduced = !subwoofers.isEmpty && !hasCalibration
    }

    func offset(for speaker: Int) -> Double {
        offsets.first { $0.speakerIndex == speaker }?.offsetDb ?? 0
    }

    /// True when nothing needs a physical change and matching can proceed.
    var isReady: Bool { outOfRange.isEmpty }
}

// MARK: - What the user is told

extension ChannelLevelMatch.Offset {
    /// An instruction rather than a warning, with the cost of ignoring it.
    ///
    /// The second sentence is the important half. For a full-range channel that
    /// cost is paid by every other channel; a subwoofer never drags the others
    /// down, so it is offered a different choice.
    func guidance(name: String) -> String? {
        guard needsPhysicalGainChange else { return nil }
        let magnitude = abs(deviationDb)
        let direction = deviationDb < 0 ? "below" : "above"

        if isSubwoofer {
            return String(format: "%@ is %.1f dB %@ its reference level. Adjust its gain "
                          + "control and measure again, or continue with the subwoofer "
                          + "left uncalibrated.", name, magnitude, direction)
        }
        if deviationDb < 0 {
            return String(format: "%@ is %.1f dB below the other channels. Raise its gain "
                          + "control and measure again - otherwise every other channel "
                          + "has to be attenuated by %.1f dB to match it.",
                          name, magnitude, magnitude)
        }
        return String(format: "%@ is %.1f dB above the other channels. Lower its gain "
                      + "control and measure again, or the whole system loses %.1f dB "
                      + "of output to bring it down.", name, magnitude, magnitude)
    }
}
