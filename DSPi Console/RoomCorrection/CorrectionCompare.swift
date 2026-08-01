import Foundation

/// Switches an applied correction in and out at a matched level.
///
/// The point of the exercise is to hear the correction's shape. An ordinary
/// bypass cannot do that: the destination gain lives outside the PEQ bank, so
/// turning the bands off leaves the level where the correction put it and the
/// comparison becomes a loudness test, which the louder side always wins.
///
/// So both halves are written together. Bypassed means a flat bank at
/// `bypassedGainDb`, which is the level the corrected channel averages to;
/// corrected means the plan's bands at `compensatedGainDb`. The two states have
/// the same broadband level by construction, and differ only in shape.
///
/// Nothing here touches flash, and nothing here is the rollback path - it
/// restores the correction, not the user's original EQ. `CorrectionApplier`
/// owns that.
@MainActor
final class CorrectionComparison: ObservableObject {

    /// What the device is currently carrying.
    @Published private(set) var isBypassed = false
    /// Set when a write did not read back. The device is left wherever the
    /// failed write put it, and the caller is expected to say so.
    @Published private(set) var failure: String?

    private let target: CorrectionApplyTarget
    /// Identity as it was when the correction was applied.
    private let expectedSerial: String?
    private let plans: [ChannelApplyPlan]

    init(target: CorrectionApplyTarget,
         expectedSerial: String?,
         plans: [ChannelApplyPlan]) {
        self.target = target
        self.expectedSerial = expectedSerial
        self.plans = plans
    }

    var canCompare: Bool { !plans.isEmpty }

    func setBypassed(_ bypassed: Bool) {
        guard bypassed != isBypassed, canCompare else { return }
        if let expectedSerial, target.deviceSerial != expectedSerial {
            failure = "This is not the device the correction was applied to."
            return
        }
        failure = nil

        for plan in plans {
            let bands = bypassed
                ? Array(repeating: FilterParams(), count: plan.bands.count)
                : plan.bands
            let gain = bypassed ? plan.bypassedGainDb : plan.compensatedGainDb
            let previous = bypassed ? plan.compensatedGainDb : plan.bypassedGainDb

            target.writeBank(bands,
                             to: plan.destinationChannel,
                             destination: plan.destination,
                             gainDb: gain,
                             from: previous)

            guard let readBack = target.readGain(plan.destination) else {
                failure = "The device did not confirm the level change, so the two "
                        + "sides may not be level matched."
                isBypassed = bypassed
                return
            }
            if abs(readBack - gain) > 0.01 {
                failure = String(format: "The level read back as %.2f dB after writing "
                                 + "%.2f dB, so the two sides are not level matched.",
                                 readBack, gain)
                isBypassed = bypassed
                return
            }
        }

        isBypassed = bypassed
    }
}
