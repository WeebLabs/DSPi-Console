import Foundation

// Moving a `PresetDocument` between a file and a device: capture reads the view
// model, apply writes it back through the ordinary setters.
//
// Apply deliberately does not use a bulk write.  Every value goes through the
// same setter a user edit would, so it gets the same clamping, quantization,
// platform gating and dirty-tracking - and anything the firmware refuses comes
// back as a status code we can report instead of a silent no-op.

// MARK: - Capture

extension PresetDocument {

    /// Snapshot the current configuration.  Reads the view model, which is the
    /// live mirror of the device (kept current by the bulk fetch and the notify
    /// endpoint), so this does not need the bus to be idle.
    ///
    /// Call on the main thread: it reads `@Published` state.
    static func capture(from vm: DSPViewModel, name: String? = nil) -> PresetDocument {
        var doc = PresetDocument()
        let platform = vm.platformName

        doc.meta.name = name
        doc.meta.savedUtc = ISO8601DateFormatter().string(from: Date())
        doc.meta.appVersion = GeneralSettingsTab.appVersion
        doc.meta.platform = platform.isEmpty ? nil : platform
        doc.meta.firmwareVersion = vm.firmwareVersion.map { "\($0.major).\($0.minor).\($0.patch)" }
        doc.meta.wireFormatVersion = vm.firmwareWireFormatVersion
        doc.meta.inputChannelCount = vm.chOut1
        doc.meta.outputChannelCount = vm.numOutputChannels
        doc.meta.masterVolumeMode = vm.presetMasterVolumeMode
        doc.meta.outputConfigMode = vm.presetOutputConfigMode

        // Global
        doc.global.inputPreampsDb = vm.preampDB
        doc.global.bypass = vm.bypass
        doc.global.masterVolumeDb = vm.masterVolumeDB
        doc.global.userVolumeDb = vm.userVolumeDB
        doc.global.inputSource = vm.inputSource
        doc.global.lgSoundSyncEnabled = vm.lgSoundSyncEnabled
        doc.global.inputPairLinked = (0..<DSPViewModel.inputPairCount).map { vm.isInputPairLinked($0) }

        // Feature blocks
        doc.loudness.enabled = vm.loudnessEnabled
        doc.loudness.refSpl = vm.loudnessRefSPL
        doc.loudness.intensityPct = vm.loudnessIntensity
        doc.loudness.outputMask = Int(vm.loudnessOutputMask)

        doc.crossfeed.enabled = vm.crossfeedEnabled
        doc.crossfeed.preset = vm.crossfeedPreset
        doc.crossfeed.freqHz = vm.crossfeedFreq
        doc.crossfeed.feedDb = vm.crossfeedFeed
        doc.crossfeed.itd = vm.crossfeedITD
        doc.crossfeed.outputPairMask = Int(vm.crossfeedOutputMask)

        doc.leveller.enabled = vm.levellerEnabled
        doc.leveller.speed = vm.levellerSpeed
        doc.leveller.lookahead = vm.levellerLookahead
        doc.leveller.amountPct = vm.levellerAmount
        doc.leveller.maxGainDb = vm.levellerMaxGainDB
        doc.leveller.gateDb = vm.levellerGateDB
        doc.leveller.detectorMask = Int(vm.levellerDetectorMask)
        doc.leveller.applyMask = Int(vm.levellerApplyMask)

        // Optional blocks are written only when the source device had the
        // feature, so a document never claims something the device never had.
        if vm.firmwareSupportsPsybass {
            var block = PsybassBlock()
            block.enabled = vm.psybassEnabled
            block.cutoffHz = vm.psybassCutoffHz
            block.harmonicsDb = vm.psybassHarmonicsDB
            block.driveDb = vm.psybassDriveDB
            block.characterPct = vm.psybassCharacterPct
            block.originalDb = vm.psybassOriginalDB
            block.outputMask = Int(vm.psybassOutputMask)
            doc.psybass = block
        }

        if vm.firmwareSupportsUpmixer {
            var block = UpmixBlock()
            block.enabled = vm.upmixEnabled
            block.centerMode = vm.upmixCenterMode
            block.surroundMode = vm.upmixSurroundMode
            block.strengthPct = vm.upmixStrengthPct
            block.centerWidthPct = vm.upmixCenterWidthPct
            block.thresholdPct = vm.upmixThresholdPct
            block.attackMs = vm.upmixAttackMs
            block.releaseMs = vm.upmixReleaseMs
            block.detectorHpfHz = vm.upmixDetectorHpfHz
            block.surroundDelayMs = vm.upmixSurroundDelayMs
            block.surroundHpfHz = vm.upmixSurroundHpfHz
            block.surroundLpfHz = vm.upmixSurroundLpfHz
            block.decorrPct = vm.upmixDecorrPct
            block.presenceDb = vm.upmixPresenceDB
            doc.upmix = block
        }

        // Channels: every input the platform has (not just the ones currently
        // streaming - the dormant ones still hold EQ on the device), then every
        // output.
        for input in 0..<vm.chOut1 {
            doc.channels.append(channelBlock(vm: vm, ref: .input(input), platform: platform))
        }
        for output in 0..<vm.numOutputChannels {
            doc.channels.append(channelBlock(vm: vm, ref: .output(output), platform: platform))
        }

        // Matrix
        for input in 0..<MAX_MATRIX_INPUTS {
            for output in 0..<vm.numOutputChannels {
                var cp = CrosspointBlock()
                cp.input = input
                cp.output = output
                cp.enabled = vm.matrixRouting[input][output]
                cp.invert = vm.matrixInvert[input][output]
                cp.gainDb = vm.matrixGain[input][output]
                doc.matrix.append(cp)
            }
        }

        doc.io = ioBlock(vm: vm)
        return doc
    }

    private static func channelBlock(vm: DSPViewModel, ref: PresetChannelRef,
                                     platform: String) -> ChannelBlock {
        var block = ChannelBlock()
        let eqCh: Int

        switch ref {
        case .input(let input):
            eqCh = input
            block.channelId = PresetChannelID.id(forInput: input)
            block.inputIndex = input
            block.isOutput = false
        case .output(let output):
            eqCh = vm.eqChannel(forOutput: output)
            block.channelId = PresetChannelID.id(forOutput: output, platform: platform)
            block.outputIndex = output
            block.isOutput = true
            block.gainDb = vm.outputGainDB[output]
            block.muted = vm.outputMuted[output]
            block.enabled = vm.outputEnabled[output]
            block.outputDelayMs = vm.outputDelayMS[output]
            block.crossover = (vm.xoverData[eqCh] ?? []).map { BandBlock($0) }
        }

        block.eqChannel = eqCh
        block.name = eqCh < vm.channelNames.count ? vm.channelNames[eqCh] : ""
        block.delayMs = vm.channelDelays[eqCh] ?? 0
        block.eq = (vm.channelData[eqCh] ?? []).map { BandBlock($0) }
        return block
    }

    private static func ioBlock(vm: DSPViewModel) -> IoBlock {
        var io = IoBlock()
        io.outputPins = vm.outputPins
        io.outputSlotTypes = vm.outputSlotTypes
        io.i2sBckPin = vm.i2sBckPin
        io.mckEnabled = vm.mckEnabled
        io.mckPin = vm.mckPin
        io.mckMultiplier = vm.mckMultiplier
        io.i2sClockMode = vm.i2sClockMode
        io.i2sClockPinMode = vm.i2sClockPinMode
        io.i2sBckPinSlave = vm.i2sBckPinSlave

        // The shared schema's S/PDIF pin array is three long (input 1 plus two
        // optional).  The fourth input is newer than the schema, so its pin
        // travels in its own additive field.
        io.spdifRxPins = (0..<3).map { vm.spdifPin(index: $0) }
        if SPDIF_RX_NUM_INPUTS > 3 { io.spdifRxPin4 = vm.spdifPin(index: 3) }
        io.spdifEnabledExt = (1..<SPDIF_RX_NUM_INPUTS).reduce(into: UInt8(0)) { mask, index in
            if vm.spdifInputEnabled(index: index) { mask |= UInt8(1) << (index - 1) }
        }

        io.i2sRxPins = vm.i2sRxPins
        io.i2sInputChannels = vm.i2sInputChannels
        io.i2sInputRateHz = vm.i2sInputRateHz

        io.adatEnabled = vm.adatEnabled
        io.adatPin = vm.adatPin
        io.adatInputEnabled = vm.adatInputEnabled
        io.adatInputPin = vm.adatInputPin
        io.adatInputClockMode = vm.adatInputClockMode

        if vm.dacHwMuteSupported { io.dacHwMute = DacHwMuteBlock(vm.dacHwMuteConfig) }
        return io
    }
}

// MARK: - Apply options and report

/// Which parts of a document an import should apply.
struct PresetApplyOptions {
    /// EQ, crossover, delays, gains, matrix, the DSP feature blocks and channel
    /// names.  Always applied - it is what a configuration file is for.
    var audioProcessing = true

    /// Master and listening volume.  Off by default: a document from another
    /// system would otherwise change how loud the room gets on import.
    var volumeLevels = false

    /// GPIO pin assignments, clocking, ADAT and the S/PDIF & I2S input wiring.
    /// Off by default - these describe a board, not a listening setup.
    var hardwareIO = false
}

/// What an import actually did, so the user is told rather than left to infer
/// it from the UI.  A reference type because the apply steps run as closures.
final class PresetApplyReport {
    var channelsApplied = 0
    var bandsApplied = 0
    var crossoverBandsApplied = 0
    var crosspointsApplied = 0

    /// Channels in the document that this device does not have.
    var missingChannels: [String] = []

    /// Blocks skipped because this firmware or platform lacks the feature, or
    /// because the device refused the write.
    private(set) var skipped: [String] = []

    /// Records a reason once.  Per-band problems would otherwise repeat for
    /// every band in the file.
    func skip(_ reason: String) {
        guard !skipped.contains(reason) else { return }
        skipped.append(reason)
    }

    var isClean: Bool { missingChannels.isEmpty && skipped.isEmpty }
}

// MARK: - Apply

enum PresetDocumentApply {

    /// One unit of work.  `blocking` marks the steps that issue synchronous
    /// control transfers (every pin and clock setter does): those must run off
    /// the main thread, while the audio setters mutate `@Published` state and
    /// so must run on it.
    private struct Step {
        let blocking: Bool
        let work: () -> Void
    }

    /// Push a document to the device.  Call on the main thread.
    ///
    /// Steps are run one per run-loop turn so a progress sheet actually redraws;
    /// `completion` lands back on the main thread when everything has been sent.
    static func apply(_ doc: PresetDocument, to vm: DSPViewModel,
                      options: PresetApplyOptions,
                      progress: @escaping (Double) -> Void = { _ in },
                      completion: @escaping (PresetApplyReport) -> Void) {
        let report = PresetApplyReport()
        let platform = vm.platformName

        // Index the document by the channel it refers to on *this* device, and
        // name the blocks that don't land anywhere.
        var byRef: [PresetChannelRef: PresetDocument.ChannelBlock] = [:]
        for block in doc.channels {
            // A hand-edited file with a duplicated channel applies the last one
            // rather than failing.
            guard let ref = block.ref(platform: platform), exists(ref, on: vm) else {
                report.missingChannels.append(block.name.isEmpty ? "channel \(block.channelId)" : block.name)
                continue
            }
            byRef[ref] = block
        }

        var steps: [Step] = []

        if options.audioProcessing {
            steps += audioSteps(doc, vm: vm, byRef: byRef, report: report)
        }
        if options.volumeLevels {
            steps.append(Step(blocking: false) { applyVolumes(doc, vm: vm, report: report) })
        }
        if options.hardwareIO {
            steps.append(Step(blocking: true) { applyIO(doc, vm: vm, report: report) })
        }

        // The device ends up holding the document but nothing is written to
        // flash, so the preset stays marked dirty - which is what the result
        // dialog tells the user.
        run(steps, index: 0, progress: progress) { completion(report) }
    }

    private static func run(_ steps: [Step], index: Int,
                            progress: @escaping (Double) -> Void,
                            done: @escaping () -> Void) {
        guard index < steps.count else {
            progress(1.0)
            done()
            return
        }
        let step = steps[index]
        let queue = step.blocking ? DispatchQueue.global(qos: .userInitiated) : DispatchQueue.main
        queue.async {
            step.work()
            DispatchQueue.main.async {
                progress(Double(index + 1) / Double(steps.count))
                run(steps, index: index + 1, progress: progress, done: done)
            }
        }
    }

    private static func exists(_ ref: PresetChannelRef, on vm: DSPViewModel) -> Bool {
        switch ref {
        case .input(let input):   return input >= 0 && input < vm.chOut1
        case .output(let output): return output >= 0 && output < vm.numOutputChannels
        }
    }

    // MARK: Audio processing

    private static func audioSteps(_ doc: PresetDocument, vm: DSPViewModel,
                                   byRef: [PresetChannelRef: PresetDocument.ChannelBlock],
                                   report: PresetApplyReport) -> [Step] {
        var steps: [Step] = []

        // PEQ link state first: a linked input pair mirrors every filter and
        // preamp write to its partner, so applying it after the channels would
        // let the device's *current* link state rewrite what we just pushed.
        steps.append(Step(blocking: false) {
            for pair in 0..<DSPViewModel.inputPairCount {
                let linked = pair < doc.global.inputPairLinked.count ? doc.global.inputPairLinked[pair] : false
                if vm.isInputPairLinked(pair) != linked { vm.setInputPairLinked(pair, linked) }
            }
        })

        // Output enable: disable pass, then enable pass.  An enable can conflict
        // with an output the document is about to switch off (PDM against the
        // Core 1 EQ workers), so freeing first is what makes the pair land.
        steps.append(Step(blocking: false) {
            for enabling in [false, true] {
                for output in 0..<vm.numOutputChannels {
                    guard let block = byRef[.output(output)], block.enabled == enabling else { continue }
                    guard vm.outputEnabled[output] != block.enabled else { continue }
                    if block.enabled && vm.outputEnableWouldConflict(output) {
                        report.skip("\(block.name) could not be enabled (conflicts with another output)")
                        continue
                    }
                    vm.setOutputEnable(output: output, enabled: block.enabled)
                }
            }
        })

        // One step per channel, so the progress bar tracks something real.
        for input in 0..<vm.chOut1 {
            guard let block = byRef[.input(input)] else { continue }
            steps.append(Step(blocking: false) {
                applyChannel(block, ref: .input(input), vm: vm, report: report)

                // A linked pair's preamp write mirrors onto its partner, so
                // writing both halves would let the second one undo the first.
                // Write the lower half only; the mirror gives the pair the one
                // value a link means it has.
                let partner = vm.linkedPartner(of: input)
                if partner == nil || partner! > input {
                    vm.setPreampChannel(channel: input, db: preamp(doc, input: input))
                }
            })
        }
        for output in 0..<vm.numOutputChannels {
            guard let block = byRef[.output(output)] else { continue }
            steps.append(Step(blocking: false) {
                applyChannel(block, ref: .output(output), vm: vm, report: report)
            })
        }

        steps.append(Step(blocking: false) { applyMatrix(doc, vm: vm, report: report) })
        steps.append(Step(blocking: false) { applyFeatureBlocks(doc, vm: vm, report: report) })
        return steps
    }

    private static func preamp(_ doc: PresetDocument, input: Int) -> Float {
        input < doc.global.inputPreampsDb.count ? doc.global.inputPreampsDb[input] : 0
    }

    private static func applyChannel(_ block: PresetDocument.ChannelBlock, ref: PresetChannelRef,
                                     vm: DSPViewModel, report: PresetApplyReport) {
        let eqCh: Int
        switch ref {
        case .input(let input):   eqCh = input
        case .output(let output): eqCh = vm.eqChannel(forOutput: output)
        }

        if !block.name.isEmpty, eqCh < vm.channelNames.count, block.name != vm.channelNames[eqCh] {
            vm.setChannelName(channel: eqCh, name: block.name)
        }
        vm.setDelay(ch: eqCh, ms: block.delayMs)

        if case .output(let output) = ref {
            vm.setOutputGain(output: output, db: block.gainDb)
            if vm.outputMuted[output] != block.muted {
                vm.setOutputMute(output: output, muted: block.muted)
            }
            // Additive field: a document written by a build (or a platform) that
            // doesn't carry the post-matrix delay leaves it alone.
            if let delay = block.outputDelayMs { vm.setOutputDelay(output: output, ms: delay) }
        }

        // A document that carries no bands for this channel leaves its EQ alone
        // (the same rule a filter file with no PEQ section follows); one that
        // carries some flattens the rest, so an imported channel is never a
        // blend of two configurations.  Bands past this channel's bank are
        // dropped - a wider source read by a narrower build.
        if !block.eq.isEmpty {
            let bandCount = vm.channelData[eqCh]?.count ?? 10
            for band in 0..<bandCount {
                let params = band < block.eq.count
                    ? sanitize(block.eq[band].filterParams, vm: vm, report: report)
                    : FilterParams(type: .flat)
                vm.setFilter(ch: eqCh, band: band, p: params)
                report.bandsApplied += 1
            }
        }

        if case .output = ref, !block.crossover.isEmpty {
            if vm.isDeviceConnected && !vm.firmwareSupportsCrossover {
                report.skip("Crossover bands (not supported by this firmware)")
            } else {
                for band in 0..<DSPViewModel.crossoverBandsPerChannel {
                    let params = band < block.crossover.count
                        ? block.crossover[band].filterParams
                        : FilterParams(type: .flat)
                    vm.setCrossoverBand(ch: eqCh, localBand: band, p: params)
                    report.crossoverBandsApplied += 1
                }
            }
        }

        report.channelsApplied += 1
    }

    /// Neutralise a band the connected firmware can't represent.  Writing one
    /// blind would leave the device audibly different from what the app shows:
    /// an unknown type is rejected outright, and a bypass flag on firmware
    /// without per-band bypass would leave the band audible while the app
    /// believed it muted.
    private static func sanitize(_ params: FilterParams, vm: DSPViewModel,
                                 report: PresetApplyReport) -> FilterParams {
        var params = params
        if !vm.firmwareSupports(filterType: params.type) {
            report.skip("\(params.type.name) bands (not supported by this firmware) were set to Off")
            return FilterParams(type: .flat)
        }
        if params.bypass && vm.isDeviceConnected && !vm.firmwareSupportsBandBypass {
            report.skip("Per-band bypass (not supported by this firmware) was cleared")
            params.bypass = false
        }
        return params
    }

    private static func applyMatrix(_ doc: PresetDocument, vm: DSPViewModel,
                                    report: PresetApplyReport) {
        for cp in doc.matrix {
            guard cp.input >= 0, cp.input < MAX_MATRIX_INPUTS,
                  cp.output >= 0, cp.output < vm.numOutputChannels else { continue }
            vm.setMatrixRoute(input: cp.input, output: cp.output,
                              enabled: cp.enabled, gain: cp.gainDb, invert: cp.invert)
            report.crosspointsApplied += 1
        }
    }

    private static func applyFeatureBlocks(_ doc: PresetDocument, vm: DSPViewModel,
                                           report: PresetApplyReport) {
        // Master EQ bypass and input source.  (The per-input preamps are applied
        // with their channels, and the PEQ links earlier still - see audioSteps.)
        vm.setBypass(doc.global.bypass)

        if vm.inputSourceSupported {
            if vm.inputSource != doc.global.inputSource {
                vm.setInputSource(doc.global.inputSource)
            }
        } else if doc.global.inputSource != INPUT_SOURCE_USB {
            report.skip("Input source (not supported by this firmware)")
        }

        if vm.lgSoundSyncSupported {
            vm.setLgSoundSyncEnabled(doc.global.lgSoundSyncEnabled)
        } else if doc.global.lgSoundSyncEnabled {
            report.skip("LG Sound Sync (not supported by this firmware)")
        }

        // Each feature sets its parameters before its enable flag, so the device
        // never spends a moment running the feature with the old settings.
        vm.setLoudnessRef(doc.loudness.refSpl)
        vm.setLoudnessIntensity(doc.loudness.intensityPct)
        if vm.firmwareSupportsLoudnessMask {
            vm.setLoudnessMask(UInt16(truncatingIfNeeded: doc.loudness.outputMask))
        }
        vm.setLoudness(doc.loudness.enabled)

        vm.setCrossfeedPreset(doc.crossfeed.preset)
        vm.setCrossfeedFreq(doc.crossfeed.freqHz)
        vm.setCrossfeedFeed(doc.crossfeed.feedDb)
        vm.setCrossfeedITD(doc.crossfeed.itd)
        if vm.firmwareSupportsCrossfeedMask {
            vm.setCrossfeedMask(UInt8(truncatingIfNeeded: doc.crossfeed.outputPairMask))
        }
        vm.setCrossfeed(doc.crossfeed.enabled)

        vm.setLevellerSpeed(doc.leveller.speed)
        vm.setLevellerLookahead(doc.leveller.lookahead)
        vm.setLevellerAmount(doc.leveller.amountPct)
        vm.setLevellerMaxGain(doc.leveller.maxGainDb)
        vm.setLevellerGate(doc.leveller.gateDb)
        if vm.firmwareSupportsLevellerMasks {
            vm.setLevellerMasks(detector: UInt8(truncatingIfNeeded: doc.leveller.detectorMask),
                                apply: UInt8(truncatingIfNeeded: doc.leveller.applyMask))
        }
        vm.setLeveller(doc.leveller.enabled)

        if let psybass = doc.psybass {
            if vm.firmwareSupportsPsybass {
                vm.setPsybassCutoff(psybass.cutoffHz)
                vm.setPsybassHarmonics(psybass.harmonicsDb)
                vm.setPsybassDrive(psybass.driveDb)
                vm.setPsybassCharacter(psybass.characterPct)
                vm.setPsybassOriginal(psybass.originalDb)
                vm.setPsybassMask(UInt16(truncatingIfNeeded: psybass.outputMask))
                vm.setPsybass(psybass.enabled)
            } else {
                report.skip("Psychoacoustic bass (not supported by this firmware)")
            }
        }

        if let upmix = doc.upmix {
            if vm.firmwareSupportsUpmixer {
                vm.setUpmixCenterMode(upmix.centerMode)
                vm.setUpmixSurroundMode(upmix.surroundMode)
                vm.setUpmixStrength(upmix.strengthPct)
                vm.setUpmixCenterWidth(upmix.centerWidthPct)
                vm.setUpmixThreshold(upmix.thresholdPct)
                vm.setUpmixAttack(upmix.attackMs)
                vm.setUpmixRelease(upmix.releaseMs)
                vm.setUpmixDetectorHpf(upmix.detectorHpfHz)
                vm.setUpmixSurroundDelay(upmix.surroundDelayMs)
                vm.setUpmixSurroundHpf(upmix.surroundHpfHz)
                vm.setUpmixSurroundLpf(upmix.surroundLpfHz)
                vm.setUpmixDecorr(upmix.decorrPct)
                vm.setUpmixPresence(upmix.presenceDb)
                vm.setUpmixEnabled(upmix.enabled)
            } else {
                report.skip("Stereo upmixer (not supported by this device)")
            }
        }
    }

    private static func applyVolumes(_ doc: PresetDocument, vm: DSPViewModel,
                                     report: PresetApplyReport) {
        // Master volume is only per-preset when the device says so; in
        // independent mode it is device-global and saved separately, so
        // overwriting it from a file would fight the user's own setting.
        if vm.presetMasterVolumeMode == MASTER_VOLUME_MODE_WITH_PRESET {
            vm.setMasterVolume(doc.global.masterVolumeDb)
        } else {
            report.skip("Master volume (device is in independent master-volume mode)")
        }
        vm.setUserVolume(doc.global.userVolumeDb)
    }

    // MARK: Physical IO

    /// The GPIO, clocking and input-wiring writes.  Synchronous and blocking -
    /// runs on a background queue.  Refusals are collected rather than thrown:
    /// the setters answer with a PIN_CONFIG_* status, and a GPIO that is already
    /// in use is otherwise refused silently, which surfaces later as no audio.
    private static func applyIO(_ doc: PresetDocument, vm: DSPViewModel,
                                report: PresetApplyReport) {
        let io = doc.io
        let generation = vm.usb.generation
        func stillCurrent() -> Bool { vm.usb.generation == generation }

        func attempt(_ what: String, _ set: () -> UInt8) {
            let status = set()
            guard status != PIN_CONFIG_SUCCESS else { return }
            report.skip("\(what) rejected by the device (\(describe(status)))")
        }

        // Slot types before pins: a slot switching to I2S changes what its pin
        // assignment means, and the app regenerates auto channel names from it.
        for slot in 0..<min(vm.numOutputSlots, io.outputSlotTypes.count)
        where vm.outputSlotTypes[slot] != io.outputSlotTypes[slot] {
            attempt("Output \(slot + 1) type") { vm.setOutputSlotType(slot: slot, type: io.outputSlotTypes[slot]) }
        }
        guard stillCurrent() else { return }

        // Only the pin outputs this board has: the slots plus PDM, which sits at
        // a different index per platform (2 on RP2040, 4 on RP2350).
        var pinIndices = Array(0..<vm.numOutputSlots)
        pinIndices.append(vm.platformName == "RP2040" ? 2 : 4)
        for index in pinIndices where index < min(vm.outputPins.count, io.outputPins.count) {
            let want = io.outputPins[index]
            guard vm.outputPins[index] != want else { continue }
            var status = vm.setOutputPin(output: index, pin: want)

            // The firmware refuses to move the PDM pin while PDM is enabled.
            // Cycle it the way the Hardware settings page does, then put the
            // enable state back to whatever the output is supposed to be in.
            if status == PIN_CONFIG_OUTPUT_ACTIVE && index == pinIndices.last {
                let pdm = vm.pdmOutputIndex
                let wasEnabled = vm.outputEnabled[pdm]
                DispatchQueue.main.sync { vm.setOutputEnable(output: pdm, enabled: false) }
                status = vm.setOutputPin(output: index, pin: want)
                DispatchQueue.main.sync { vm.setOutputEnable(output: pdm, enabled: wasEnabled) }
            }

            if status != PIN_CONFIG_SUCCESS {
                report.skip("Output \(index + 1) GPIO rejected by the device (\(describe(status)))")
            }
        }
        guard stillCurrent() else { return }

        if vm.i2sBckPin != io.i2sBckPin { attempt("I2S BCK pin") { vm.setI2SBckPin(io.i2sBckPin) } }
        if vm.mckEnabled != io.mckEnabled { attempt("MCK enable") { vm.setMckEnable(io.mckEnabled) } }
        if vm.mckPin != io.mckPin { attempt("MCK pin") { vm.setMckPin(io.mckPin) } }
        if vm.mckMultiplier != io.mckMultiplier {
            attempt("MCK multiplier") { vm.setMckMultiplier(io.mckMultiplier) }
        }
        guard stillCurrent() else { return }

        // S/PDIF inputs.  Drop an enable before repinning so a move can't clash
        // with the pin it is leaving, and apply each pin before switching its
        // input on so the enable validates against the pin it will use.
        if vm.spdifRxPin != io.spdifRxPins.first ?? vm.spdifRxPin {
            attempt("S/PDIF RX pin") { vm.setSpdifRxPin(index: 0, io.spdifRxPins[0]) }
        }
        if vm.multiSpdifSupported {
            for index in 1..<vm.spdifInputCount {
                let want = documentSpdifPin(io, index: index)
                let wantEnabled = io.spdifEnabledExt & (UInt8(1) << (index - 1)) != 0
                let isEnabled = vm.spdifInputEnabled(index: index)

                if isEnabled && !wantEnabled {
                    attempt("S/PDIF input \(index + 1)") { vm.setSpdifInputEnable(index: index, false) }
                }
                if let want, vm.spdifPin(index: index) != want {
                    attempt("S/PDIF \(index + 1) RX pin") { vm.setSpdifRxPin(index: index, want) }
                }
                if !isEnabled && wantEnabled {
                    attempt("S/PDIF input \(index + 1)") { vm.setSpdifInputEnable(index: index, true) }
                }
            }
        } else if io.spdifEnabledExt != 0 {
            report.skip("Additional S/PDIF inputs (not supported by this firmware)")
        }
        guard stillCurrent() else { return }

        // I2S input: the channel count first (lowering it frees pairs and never
        // fails), then each pair's data pin, then the rate.
        if vm.i2sInputSupported {
            let channels = min(io.i2sInputChannels, vm.i2sMaxInputChannels)
            if [2, 4, 6, 8].contains(channels) && vm.i2sInputChannels != channels {
                attempt("I2S input channels") { vm.setI2SInputChannels(channels) }
            }
            for pair in 0..<min(vm.i2sMaxPairs, io.i2sRxPins.count)
            where vm.i2sRxPins[pair] != io.i2sRxPins[pair] {
                attempt("I2S serial data \(pair + 1) pin") { vm.setI2SRxPin(pair: pair, io.i2sRxPins[pair]) }
            }
            if vm.i2sInputRateHz != io.i2sInputRateHz { vm.setInputRate(io.i2sInputRateHz) }
        }
        if vm.i2sClockModeSupported {
            if vm.i2sClockMode != io.i2sClockMode { vm.setI2SClockMode(io.i2sClockMode) }
        } else if io.i2sClockMode != 0 {
            report.skip("I2S clock-slave mode (not supported by this firmware)")
        }
        // Clock-pin mode: store the slave pair first (a dormant store, accepted
        // any time) so entering SPLIT finds it already valid.
        if vm.i2sClockPinModeSupported {
            if vm.i2sBckPinSlave != io.i2sBckPinSlave {
                attempt("I2S slave BCK pin") { vm.setI2SBckPin(io.i2sBckPinSlave, role: I2S_BCK_ROLE_SLAVE) }
            }
            if vm.i2sClockPinMode != io.i2sClockPinMode {
                attempt("I2S clock pin mode") { vm.setI2SClockPinMode(io.i2sClockPinMode) }
            }
        }
        guard stillCurrent() else { return }

        // ADAT output: the data pin first (it re-routes under a muted restart
        // when enabled), then the enable state.
        if vm.adatSupported {
            if vm.adatPin != io.adatPin { attempt("ADAT output pin") { vm.setAdatPin(io.adatPin) } }
            if vm.adatEnabled != io.adatEnabled {
                attempt("ADAT output enable") { vm.setAdatEnable(io.adatEnabled) }
            }
        } else if io.adatEnabled {
            report.skip("ADAT output (not supported by this device)")
        }

        if vm.adatInputSupported {
            if io.adatInputPin != ADAT_INPUT_PIN_UNSET && vm.adatInputPin != io.adatInputPin {
                attempt("ADAT input pin") { vm.setAdatInputPin(io.adatInputPin) }
            }
            if vm.adatInputClockMode != io.adatInputClockMode {
                attempt("ADAT input clock mode") { vm.setAdatInputClockMode(io.adatInputClockMode) }
            }
            if vm.adatInputEnabled != io.adatInputEnabled {
                attempt("ADAT input enable") { vm.setAdatInputEnable(io.adatInputEnabled) }
            }
        } else if io.adatInputEnabled {
            report.skip("ADAT input (not supported by this device)")
        }
        guard stillCurrent() else { return }

        if let mute = io.dacHwMute {
            if vm.dacHwMuteSupported {
                vm.setDacHwMuteConfig(mute.config)
            } else {
                report.skip("External DAC hardware mute (not supported by this firmware)")
            }
        }
    }

    /// The S/PDIF pin a document holds for an input index, or nil when the
    /// document predates that input.  Index 3 lives in the additive field.
    private static func documentSpdifPin(_ io: PresetDocument.IoBlock, index: Int) -> UInt8? {
        if index == 3 { return io.spdifRxPin4 }
        return index < io.spdifRxPins.count ? io.spdifRxPins[index] : nil
    }

    private static func describe(_ status: UInt8) -> String {
        switch status {
        case PIN_CONFIG_INVALID_PIN:    return "invalid pin"
        case PIN_CONFIG_PIN_IN_USE:     return "pin already in use"
        case PIN_CONFIG_INVALID_OUTPUT: return "invalid output"
        case PIN_CONFIG_OUTPUT_ACTIVE:  return "output is active"
        default:                        return String(format: "status 0x%02X", status)
        }
    }
}
