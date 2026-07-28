import Foundation

/// Puts a real DSPi into a measurable state and puts it back.
///
/// This is the only place that writes device state on behalf of a measurement.
/// Everything it changes is captured in the recovery journal first, so an
/// interrupted session can still be undone, and every change has a reason
/// recorded next to it: the cost of getting this wrong is a correction built on
/// a measurement of something other than what the user listens to.
///
/// See `Documentation/room_correction_measurement_modes.md`.
@MainActor
final class DSPiDevicePreparation: DevicePreparing {

    private let vm: DSPViewModel
    private let journal: MeasurementStateJournal

    /// The state to put back. Held as well as journalled, so a normal restore
    /// does not depend on reading a file.
    private var snapshot: MeasurementStateSnapshot?

    /// The path currently forced, if any.
    private var activePath: ForcedPath?

    /// How long to let a burst of USB writes settle before measuring.
    ///
    /// The writes are fire-and-forget on a serial queue, so returning
    /// immediately would let a sweep start against a half-applied
    /// configuration. Small, but not zero.
    var settleSeconds: Double = 0.12

    init(vm: DSPViewModel, journal: MeasurementStateJournal = MeasurementStateJournal()) {
        self.vm = vm
        self.journal = journal
    }

    enum PreparationError: LocalizedError {
        case noDevice
        case journalFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDevice:
                return "No DSPi is connected."
            case .journalFailed(let reason):
                // Refusing here is deliberate: without a journal an interrupted
                // session cannot be undone, and the user would be left with a
                // flattened EQ and no way back.
                return "Could not save the current settings, so measurement was not "
                     + "started: \(reason)"
            }
        }
    }

    // MARK: - Session wide

    func prepare(mode: MeasurementMode, correctedChannels: [Int]) async throws {
        guard vm.selectedDevice != nil else { throw PreparationError.noDevice }

        let captured = MeasurementStateSnapshot(capturing: vm)
        do {
            try journal.write(captured)
        } catch {
            throw PreparationError.journalFailed(error.localizedDescription)
        }
        snapshot = captured

        // Anything nonlinear, dynamic or channel-deriving makes a measurement
        // describe something other than the room. These hold for the whole
        // session in both modes.
        if vm.loudnessEnabled { vm.setLoudness(false) }
        if vm.levellerEnabled { vm.setLeveller(false) }
        if vm.psybassEnabled { vm.setPsybass(false) }
        if vm.crossfeedEnabled { vm.setCrossfeed(false) }
        if vm.upmixEnabled { vm.setUpmixEnabled(false) }
        // Master EQ bypass is a global mute of the input banks; leaving it on
        // would flatten channels we are deliberately leaving alone.
        if vm.bypass { vm.setBypass(false) }

        // Input mode flattens only the input banks being corrected, and leaves
        // everything downstream exactly as the user has it. Output mode does
        // its flattening per sweep, since which banks are involved changes
        // with the target.
        if mode == .inputChannels {
            for channel in correctedChannels {
                setBankBypassed(true, channel: channel)
            }
        }

        try await settle()
    }

    func restore() async {
        // Whatever else happens, the path comes down first: everything below
        // is meaningless while the matrix is still rewired.
        await releasePath()

        guard let snapshot else { return }

        restoreMatrix(snapshot)
        restorePeqBanks(snapshot)

        if vm.loudnessEnabled != snapshot.loudnessEnabled {
            vm.setLoudness(snapshot.loudnessEnabled)
        }
        if vm.levellerEnabled != snapshot.levellerEnabled {
            vm.setLeveller(snapshot.levellerEnabled)
        }
        if vm.psybassEnabled != snapshot.psybassEnabled {
            vm.setPsybass(snapshot.psybassEnabled)
        }
        if vm.crossfeedEnabled != snapshot.crossfeedEnabled {
            vm.setCrossfeed(snapshot.crossfeedEnabled)
        }
        if vm.upmixEnabled != snapshot.upmixEnabled {
            vm.setUpmixEnabled(snapshot.upmixEnabled)
        }
        if vm.bypass != snapshot.bypassMasterEQ {
            vm.setBypass(snapshot.bypassMasterEQ)
        }

        try? await settle()

        // Only now is the journal safe to discard: it exists to survive a
        // failure to get back here.
        journal.clear()
        self.snapshot = nil
    }

    // MARK: - Per sweep

    func configure(path: ForcedPath) async throws {
        guard let snapshot else { throw PreparationError.noDevice }

        // Take down any previous path before building this one, so two targets
        // are never live at once.
        await releasePath()

        // Disconnect every route the driven input has, then connect only the
        // one we want. Working from the snapshot rather than live state means a
        // half-applied previous path cannot leave a stray route behind.
        let outputCount = vm.numOutputChannels
        for output in 0..<outputCount where output < snapshot.matrixRouting[safe: path.driveInput]?.count ?? 0 {
            if snapshot.matrixRouting[path.driveInput][output] {
                vm.setMatrixRoute(input: path.driveInput, output: output,
                                  enabled: false, gain: 0, invert: false)
            }
        }

        // Also silence anything else feeding the target, or the measurement
        // picks up whatever else is routed there.
        for input in 0..<vm.numMatrixInputs where input != path.driveInput {
            guard input < snapshot.matrixRouting.count,
                  path.targetOutput < snapshot.matrixRouting[input].count else { continue }
            if snapshot.matrixRouting[input][path.targetOutput] {
                vm.setMatrixRoute(input: input, output: path.targetOutput,
                                  enabled: false, gain: 0, invert: false)
            }
        }

        // Unity, non-inverted: a user's matrix trim would otherwise skew the
        // measurement, and an invert would not change magnitude but would make
        // the impulse polarity misleading in the diagnostics.
        vm.setMatrixRoute(input: path.driveInput, output: path.targetOutput,
                          enabled: true, gain: 0, invert: false)

        // The driven input is synthetic, so whatever the user has on it is
        // irrelevant. The target output's bank is bypassed because the
        // correction replaces it outright.
        setBankBypassed(true, channel: path.bypassInputBank)
        setBankBypassed(true, channel: vm.eqChannel(forOutput: path.bypassOutputBank))

        // Only ever non-empty when the user explicitly opted in, having been
        // told what it means.
        for output in path.bypassCrossoversOn {
            setCrossoverBypassed(true, output: output)
        }

        activePath = path
        try await settle()
    }

    func releasePath() async {
        guard let path = activePath, let snapshot else { return }
        activePath = nil

        // Routing first, for the same reason as in restore().
        restoreMatrix(snapshot, forInput: path.driveInput, andOutput: path.targetOutput)

        restoreBank(snapshot, channel: path.bypassInputBank)
        restoreBank(snapshot, channel: vm.eqChannel(forOutput: path.bypassOutputBank))

        for output in path.bypassCrossoversOn {
            restoreCrossover(snapshot, output: output)
        }

        try? await settle()
    }

    // MARK: - Helpers

    /// Bypass or restore every band of one PEQ bank.
    ///
    /// Uses the per-band bypass rather than writing flat filters, so the user's
    /// parameters survive untouched and restoring is a matter of clearing a
    /// flag rather than replaying values that may have been quantized.
    private func setBankBypassed(_ bypassed: Bool, channel: Int) {
        guard let bands = vm.channelData[channel] else { return }
        for band in bands.indices where bands[band].type != .flat {
            vm.setBandBypass(ch: channel, band: band, bypass: bypassed)
        }
    }

    private func restoreBank(_ snapshot: MeasurementStateSnapshot, channel: Int) {
        guard let saved = snapshot.peqBanks[channel] else { return }
        for (band, state) in saved.enumerated() where state.type != FilterType.flat.rawValue {
            vm.setBandBypass(ch: channel, band: band, bypass: state.bypass)
        }
    }

    private func setCrossoverBypassed(_ bypassed: Bool, output: Int) {
        let channel = vm.eqChannel(forOutput: output)
        guard let bands = vm.xoverData[channel] else { return }
        for band in bands.indices where bands[band].type != .flat {
            vm.setCrossoverBandBypass(ch: channel, localBand: band, bypass: bypassed)
        }
    }

    private func restoreCrossover(_ snapshot: MeasurementStateSnapshot, output: Int) {
        let channel = vm.eqChannel(forOutput: output)
        guard let saved = snapshot.crossoverBanks[channel] else { return }
        for (band, state) in saved.enumerated() where state.type != FilterType.flat.rawValue {
            vm.setCrossoverBandBypass(ch: channel, localBand: band, bypass: state.bypass)
        }
    }

    /// Restore every matrix cell that a forced path could have touched.
    private func restoreMatrix(_ snapshot: MeasurementStateSnapshot,
                               forInput input: Int, andOutput output: Int) {
        for target in 0..<vm.numOutputChannels {
            restoreCell(snapshot, input: input, output: target)
        }
        for source in 0..<vm.numMatrixInputs where source != input {
            restoreCell(snapshot, input: source, output: output)
        }
    }

    /// Restore the whole matrix, for the end of a session.
    private func restoreMatrix(_ snapshot: MeasurementStateSnapshot) {
        for input in 0..<min(vm.numMatrixInputs, snapshot.matrixRouting.count) {
            for output in 0..<min(vm.numOutputChannels, snapshot.matrixRouting[input].count) {
                restoreCell(snapshot, input: input, output: output)
            }
        }
    }

    private func restoreCell(_ snapshot: MeasurementStateSnapshot, input: Int, output: Int) {
        guard input < snapshot.matrixRouting.count,
              output < snapshot.matrixRouting[input].count else { return }

        let enabled = snapshot.matrixRouting[input][output]
        let gain = snapshot.matrixGain[safe: input]?[safe: output] ?? 0
        let invert = snapshot.matrixInvert[safe: input]?[safe: output] ?? false

        // Only write cells that actually differ: a full 8x9 rewrite on every
        // sweep would be 72 control transfers for no reason.
        if vm.matrixRouting[input][output] != enabled
            || vm.matrixGain[input][output] != gain
            || vm.matrixInvert[input][output] != invert {
            vm.setMatrixRoute(input: input, output: output,
                              enabled: enabled, gain: gain, invert: invert)
        }
    }

    private func restorePeqBanks(_ snapshot: MeasurementStateSnapshot) {
        for channel in snapshot.peqBanks.keys {
            restoreBank(snapshot, channel: channel)
        }
        for output in 0..<vm.numOutputChannels {
            restoreCrossover(snapshot, output: output)
        }
    }

    private func settle() async throws {
        guard settleSeconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
    }
}

// MARK: - Recovery

extension DSPiDevicePreparation {
    /// A session that was interrupted before it could put the device back.
    ///
    /// Offered on the next connection to the same hardware. A journal from a
    /// different device is not offered, because accepting it would be worse
    /// than leaving things alone.
    static func pendingRecovery(for vm: DSPViewModel,
                                journal: MeasurementStateJournal = MeasurementStateJournal())
        -> MeasurementStateSnapshot? {
        journal.pendingRecovery(for: vm)
    }

    /// Adopt a snapshot as the state to put back, without restoring yet.
    ///
    /// Separate from `restore(from:)` because adopting and restoring are two
    /// things: recovery adopts an interrupted session's journal so that a later
    /// restore has something to work from, and a session in progress needs its
    /// snapshot installed before any path can be forced.
    func adopt(_ snapshot: MeasurementStateSnapshot) {
        self.snapshot = snapshot
        self.activePath = nil
    }

    /// Put back a snapshot from an interrupted session.
    func restore(from snapshot: MeasurementStateSnapshot) async {
        adopt(snapshot)
        await restore()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
