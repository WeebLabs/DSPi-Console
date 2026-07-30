import AppKit
import SwiftUI

// MARK: - Window

/// Room Correction lives in its own window, like the other tools, but is
/// larger and resizable: the graph is the workspace here rather than an
/// illustration beside the controls, so a fixed narrow column would defeat it.
final class RoomCorrectionWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false

    @MainActor
    func show(vm: DSPViewModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            isVisible = true
            return
        }

        let model = RoomCorrectionModel(vm: vm)
        let view = RoomCorrectionView(model: model).environmentObject(vm)

        // Configured at creation rather than after the fact: the main window
        // is built this way too, and applying it later would show the default
        // chrome for a frame before it changed.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Room Correction"
        // Content runs the full height of the window so the sidebar's material
        // reaches the top, with the traffic lights floating over it. Matches
        // the main window, which uses SwiftUI's `.hiddenTitleBar` for the same
        // effect.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: view)
        window.contentMinSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }
}

extension RoomCorrectionWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}

// MARK: - Steps

enum RoomCorrectionStep: Int, CaseIterable, Identifiable {
    case setup
    case levelCheck
    case measurements
    case target
    case results
    case apply

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .setup: return "Setup"
        case .levelCheck: return "Level Check"
        case .measurements: return "Measurements"
        case .target: return "Target"
        case .results: return "Results"
        case .apply: return "Apply & Verify"
        }
    }

    var symbol: String {
        switch self {
        case .setup: return "slider.horizontal.3"
        case .levelCheck: return "waveform.badge.exclamationmark"
        case .measurements: return "dot.radiowaves.left.and.right"
        case .target: return "scribble.variable"
        case .results: return "chart.xyaxis.line"
        case .apply: return "checkmark.seal"
        }
    }

    var caption: String {
        switch self {
        case .setup: return "Microphone, channels, plan"
        case .levelCheck: return "Noise floor and level"
        case .measurements: return "Capture positions"
        case .target: return "Design the house curve"
        case .results: return "Review the correction"
        case .apply: return "Write and verify"
        }
    }
}

// MARK: - Model

/// State for one Room Correction session.
///
/// Deliberately separate from `DSPViewModel`: this owns only what the session
/// needs, so opening the window cannot disturb the rest of the app, and closing
/// it discards session state without touching device state.
@MainActor
final class RoomCorrectionModel: ObservableObject {

    @Published var step: RoomCorrectionStep = .setup

    // Devices
    @Published var deviceCatalog: AudioDeviceCatalog
    @Published var microphoneUID: String?
    @Published var microphoneChannel: Int = 0
    @Published var micPermission: MicrophoneAccess.State = MicrophoneAccess.state

    // Calibration
    @Published var calibration: RoomCorrectionCore.Calibration?
    @Published var calibrationName: String?
    @Published var calibrationError: String?

    // What to measure, and therefore what to correct.
    //
    // These are one choice, not two. Host playback can only drive inputs, so
    // measuring a program channel means measuring everything that reproduces
    // it - and the filters belong on that input. Measuring one driver means
    // finding a path that excites it alone, and the filters belong on that
    // output. Splitting them into independent pickers would let a user ask for
    // combinations that cannot exist.
    @Published var mode: MeasurementMode = .inputChannels
    @Published var selectedTargets: Set<Int> = []
    @Published var targetRoles: [Int: RoomCorrectionCore.SpeakerRole] = [:]

    // Plan
    @Published var plannedPositions: Int = 5
    @Published var sweepSeconds: Double = 8

    /// Destination gains as they were when the measurement was taken.
    ///
    /// The compensation is relative to the state the room was measured in, not
    /// to whatever the device holds now - which after one apply already
    /// includes a compensation. Reading the live value made every re-apply
    /// compound the last one.
    @Published private(set) var baselineOutputGainDb: [Float] = []
    @Published private(set) var baselineInputPreampDb: [Float] = []

    /// Outputs whose crossover the user has chosen to bypass while measuring.
    ///
    /// Empty by default and never populated automatically: bypassing is only
    /// ever the user's decision, because it is the one action here that can
    /// destroy a driver.  See room_correction_measurement_modes.md.
    @Published var bypassCrossoverOutputs: Set<Int> = []

    let vm: DSPViewModel

    /// Owns the level check, so its findings survive stepping away and back.
    let levelCheck: LevelCheckController

    /// Owns the capture run, for the same reason: stepping back to Setup to
    /// change something must not throw away the positions already measured.
    let run: MeasurementRun

    /// Owns the target and the fits derived from it.
    let design = CorrectionDesign()

    /// `catalog` and `levelCheck` are injectable so tests can pass ones that
    /// touch no hardware: every live catalog installs a CoreAudio listener, and
    /// a test that creates several leaves them running.
    init(vm: DSPViewModel,
         catalog: AudioDeviceCatalog = AudioDeviceCatalog(),
         levelCheck: LevelCheckController? = nil,
         run: MeasurementRun? = nil) {
        self.vm = vm
        self.deviceCatalog = catalog
        self.levelCheck = levelCheck ?? LevelCheckController(capture: HALCaptureBackend(),
                                                             playback: HALPlaybackBackend())
        self.run = run ?? MeasurementRun(session: MeasurementSession(
            capture: HALCaptureBackend(),
            playback: HALPlaybackBackend(),
            preparation: DSPiDevicePreparation(vm: vm, journal: MeasurementStateJournal())))
        mode = routing.suggestedMode()
        // Default to everything measurable: the common case is "correct what I
        // have", and unticking is easier than hunting for what is usable.
        selectedTargets = Set(routing.plan(for: mode).targets.map(\.index))
    }

    /// Re-pick targets when the mode changes: indices mean different things
    /// in each mode, so carrying a selection across would silently select
    /// the wrong channels.
    func modeChanged() {
        selectedTargets = Set(plan.targets.map(\.index))
        // A bypass choice is made against a specific speaker.  Carrying one
        // into a different mode, or onto a target that is no longer selected,
        // would silently bypass a crossover nobody agreed to bypass.
        bypassCrossoverOutputs = []
    }

    func targetsChanged() {
        bypassCrossoverOutputs.formIntersection(selectedTargets)
    }

    // MARK: Routing

    var routing: RoutingValidator { RoutingValidator(viewModel: vm) }

    var isDeviceConnected: Bool { vm.selectedDevice != nil }

    var plan: RoutingPlan { routing.plan(for: mode) }

    /// Name of a target in the current mode.
    var targetName: (Int) -> String {
        { [self] index in
            mode == .inputChannels ? inputName(index) : speakerName(index)
        }
    }

    var speakerName: (Int) -> String {
        { [vm] index in
            let channel = vm.eqChannel(forOutput: index)
            let name = vm.channelNames[channel] ?? ""
            return name.isEmpty ? "Output \(index + 1)" : name
        }
    }

    var inputName: (Int) -> String {
        { [vm] index in
            let name = vm.channelNames[index] ?? ""
            return name.isEmpty ? "Input \(index + 1)" : name
        }
    }

    /// Whether the correction should bring the channels to a common level.
    ///
    /// On by default, because that is what calibration means and what every
    /// comparable tool does. Off for someone who has already matched levels
    /// with an SPL meter and does not want their trims touched.
    @Published var matchChannelLevels = true

    /// What the level pass found, and what to do about it.
    ///
    /// Nil until the pass has run. Without it the correction still applies, it
    /// just leaves the existing balance alone.
    var levelMatch: ChannelLevelMatch? {
        let levels = levelCheck.channelLevels.filter { selectedTargets.contains($0.speakerIndex) }
        guard matchChannelLevels, !levels.isEmpty else { return nil }
        return ChannelLevelMatch(levels: levels, hasCalibration: calibration != nil)
    }

    /// The offset that brings one channel to the datum, or zero.
    func levelMatchOffset(_ speaker: Int) -> Double {
        levelMatch?.offset(for: speaker) ?? 0
    }

    /// The channels the level pass will step through, in order.
    func levelTargets() -> [(speaker: Int, playbackChannel: Int,
                             role: RoomCorrectionCore.SpeakerRole)] {
        (try? speakerPlans())?.map {
            ($0.speakerIndex, $0.playbackChannel, $0.role)
        } ?? []
    }

    /// Records the pre-measurement gains, once per run.
    ///
    /// Taken before the first sweep, which is the state the correction is
    /// calculated against. Re-taking it later would capture a device that has
    /// already been corrected.
    func captureGainBaselineIfNeeded() {
        guard baselineOutputGainDb.isEmpty, baselineInputPreampDb.isEmpty else { return }
        baselineOutputGainDb = vm.outputGainDB
        baselineInputPreampDb = vm.preampDB
    }

    /// Forgets the baseline, so a fresh measurement captures a fresh one.
    func clearGainBaseline() {
        baselineOutputGainDb = []
        baselineInputPreampDb = []
    }

    /// The gain a channel had before measuring, falling back to the live value
    /// for a project opened without a measurement of its own.
    func baselineOutputGain(_ output: Int) -> Float {
        baselineOutputGainDb.indices.contains(output)
            ? baselineOutputGainDb[output]
            : (vm.outputGainDB.indices.contains(output) ? vm.outputGainDB[output] : 0)
    }

    func baselineInputPreamp(_ channel: Int) -> Float {
        baselineInputPreampDb.indices.contains(channel)
            ? baselineInputPreampDb[channel]
            : (vm.preampDB.indices.contains(channel) ? vm.preampDB[channel] : 0)
    }

    // MARK: Crossovers

    /// Where the sweep starts, for the warning about unprotected drivers.
    ///
    /// Sub targets sweep lower than full-range ones, so the figure quoted is
    /// the lowest any selected target will actually reach.
    var sweepStartHz: Double {
        let roles = selectedTargets.map { targetRoles[$0] ?? .fullRange }
        return roles.contains(.subwoofer) ? 10 : 20
    }

    /// Crossovers standing between the sweep and the selected outputs.
    ///
    /// Output mode only.  Input mode measures the system as configured, so
    /// there the crossovers are part of what is being corrected rather than
    /// something in the way.
    var crossoverDisclosures: [CrossoverDisclosure] {
        guard mode == .outputChannels else { return [] }
        let banks = Dictionary(uniqueKeysWithValues: selectedTargets.map { output in
            (output, vm.xoverData[vm.eqChannel(forOutput: output)] ?? [])
        })
        return RoutingValidator.crossoverDisclosures(forOutputs: Array(selectedTargets),
                                                     crossoverBands: banks)
    }

    /// Outputs measured without their crossover, for the results screen to
    /// carry forward.  Only ever a subset of what was actually disclosed.
    var bypassedForMeasurement: [CrossoverDisclosure] {
        crossoverDisclosures.filter { bypassCrossoverOutputs.contains($0.outputIndex) }
    }

    // MARK: Plan

    /// Turns the setup choices into the sweeps the session will run.
    ///
    /// This is where the crossover decision stops being a UI state and becomes
    /// something the device is told to do, so a target the user did not opt in
    /// for cannot pick up a bypass.
    func speakerPlans() throws -> [MeasurementSession.SpeakerPlan] {
        let rate = vm.sampleRateHz > 0 ? Double(vm.sampleRateHz) : 48000
        let validator = routing

        return try selectedTargets.sorted().map { index in
            let role = targetRoles[index] ?? .fullRange
            var sweep = try RoomCorrectionCore.SweepSpec(sampleRateHz: rate, role: role)
            sweep.durationSeconds = sweepSeconds

            switch mode {
            case .inputChannels:
                // The channel is measured exactly as it plays, crossovers and
                // all, so there is nothing to force.
                return MeasurementSession.SpeakerPlan(speakerIndex: index,
                                                      playbackChannel: index,
                                                      sweep: sweep,
                                                      role: role)
            case .outputChannels:
                let path = validator.forcedPath(
                    forOutput: index,
                    bypassCrossovers: bypassCrossoverOutputs.contains(index))
                return MeasurementSession.SpeakerPlan(speakerIndex: index,
                                                      playbackChannel: path.driveInput,
                                                      sweep: sweep,
                                                      role: role,
                                                      forcedPath: path)
            }
        }
    }

    // MARK: Microphone

    var microphone: AudioDeviceInfo? {
        guard let microphoneUID else { return nil }
        return deviceCatalog.device(uid: microphoneUID)
    }

    /// The DSPi as CoreAudio sees it.
    ///
    /// Matched by name rather than assumed: the session plays through whatever
    /// output device actually is the DSPi, and picking the wrong one would
    /// measure someone's built-in speakers.
    var playbackDevice: AudioDeviceInfo? {
        deviceCatalog.outputDevices.first { $0.name.localizedCaseInsensitiveContains("dspi") }
    }

    func requestMicrophoneAccess() {
        Task { micPermission = await MicrophoneAccess.request() }
    }

    func loadCalibration(from url: URL) {
        do {
            calibration = try RoomCorrectionCore.Calibration(contentsOf: url)
            calibrationName = url.lastPathComponent
            calibrationError = nil
        } catch {
            calibration = nil
            calibrationName = nil
            calibrationError = error.localizedDescription
        }
    }

    func clearCalibration() {
        calibration = nil
        calibrationName = nil
        calibrationError = nil
    }

    // MARK: Readiness

    /// Why the session cannot start yet, in the order worth fixing.
    var blockers: [String] {
        var reasons: [String] = []
        if vm.selectedDevice == nil {
            reasons.append("No DSPi is connected.")
        }
        if !micPermission.canRecord, let explanation = micPermission.explanation {
            reasons.append(explanation)
        }
        if microphone == nil {
            reasons.append("Choose a microphone.")
        }
        if playbackDevice == nil {
            reasons.append("The DSPi is not available as an audio output device.")
        }
        if selectedTargets.isEmpty {
            reasons.append(mode == .inputChannels
                           ? "Select at least one input channel to measure."
                           : "Select at least one speaker to measure.")
        }
        return reasons
    }

    var canContinue: Bool { blockers.isEmpty }

    /// Time the plan will take, so nobody discovers it partway through.
    ///
    /// Nine outputs at twenty-one positions is 189 sweeps: a very different
    /// proposition from a five-position stereo session, and the user should be
    /// told which one they have chosen.
    var estimatedMinutes: Double {
        let sweeps = Double(selectedTargets.count * plannedPositions)
        let perSweep = sweepSeconds + 2.5          // gap, analysis, settling
        let perPositionMove = 25.0
        let seconds = sweeps * perSweep + Double(plannedPositions) * perPositionMove
        return seconds / 60.0
    }
}

// MARK: - Root view

struct RoomCorrectionView: View {
    @ObservedObject var model: RoomCorrectionModel

    var body: some View {
        HStack(spacing: 0) {
            stepList
            Divider()
                .ignoresSafeArea()
            content
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    // The step list is persistent rather than a wizard's hidden breadcrumb, so
    // the user can always see where they are and go back without losing work.
    //
    // A stack over a sidebar-material backing rather than a sidebar-styled
    // List. The main window uses a List because it has a long, changing set of
    // channels; six fixed steps gain nothing from one, and a List renders
    // nothing at all in an offscreen NSHostingView, which would cost the whole
    // sidebar its render-test coverage.
    private var stepList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ROOM CORRECTION")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                // Matches the row content's leading edge below, so the header
                // and the step icons line up on one margin.
                .padding(.horizontal, 14)
                // Small: the safe area already holds the content clear of the
                // title bar, so anything more here reads as a blank gap.
                .padding(.top, 10)
                .padding(.bottom, 10)

            ForEach(RoomCorrectionStep.allCases) { step in
                stepRow(step)
            }

            Spacer()
            estimatedTime
        }
        .frame(width: 230)
        // The material ignores the safe area while the content above respects
        // it, so the translucency runs the full height of the window with the
        // traffic lights floating over it, rather than stopping at the title
        // bar and leaving a solid band across the top.
        .background(SidebarMaterial().ignoresSafeArea())
    }

    @ViewBuilder
    private var estimatedTime: some View {
        if model.estimatedMinutes > 0 {
            VStack(alignment: .leading, spacing: 2) {
                Text("ESTIMATED TIME")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(durationText)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var durationText: String {
        let minutes = model.estimatedMinutes
        if minutes < 1 { return "under a minute" }
        if minutes < 90 { return "about \(Int(minutes.rounded())) min" }
        return String(format: "about %.1f hours", minutes / 60)
    }

    private func stepRow(_ step: RoomCorrectionStep) -> some View {
        let isCurrent = model.step == step
        return Button {
            model.step = step
        } label: {
            HStack(spacing: 10) {
                Image(systemName: step.symbol)
                    .frame(width: 18)
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    Text(step.caption)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent ? Color.accentColor.opacity(0.13) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .setup:
            RoomCorrectionSetupView(model: model)
        case .levelCheck:
            RoomCorrectionLevelCheckView(model: model)
        case .measurements:
            RoomCorrectionMeasurementsView(model: model)
        case .target:
            RoomCorrectionTargetView(model: model)
        case .results:
            RoomCorrectionResultsView(model: model)
        case .apply:
            RoomCorrectionApplyView(model: model)
        }
    }

    }

// MARK: - Setup

struct RoomCorrectionSetupView: View {
    @ObservedObject var model: RoomCorrectionModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    deviceSection
                    Divider()
                    microphoneSection
                    Divider()
                    calibrationSection
                    Divider()
                    targetSection
                    if !model.crossoverDisclosures.isEmpty {
                        Divider()
                        crossoverSection
                    }
                    Divider()
                    planSection
                }
                .padding(22)
            }
            Divider()
            footer
        }
    }

    // MARK: Sections

    private var deviceSection: some View {
        formSection("DEVICE") {
            if let device = model.vm.selectedDevice {
                labelled("Connected", "\(device.serial.isEmpty ? "DSPi" : device.serial)")
                labelled("Platform", model.vm.platformName)
                labelled("Sample rate",
                         model.vm.sampleRateHz > 0
                            ? "\(model.vm.sampleRateHz) Hz"
                            : "unknown")
            } else {
                warning("No DSPi is connected.")
            }

            if let playback = model.playbackDevice {
                // Stated as fact, not as something to change here: the
                // configured CoreAudio mode is the user's deliberate choice.
                labelled("Audio output", "\(playback.name) - \(playback.outputChannels) ch "
                                         + "at \(Int(playback.nominalSampleRate)) Hz")
            } else {
                warning("The DSPi is not available as an audio output device. "
                        + "Room correction plays its sweeps through it.")
            }
        }
    }

    private var microphoneSection: some View {
        formSection("MICROPHONE") {
            if !model.micPermission.canRecord {
                VStack(alignment: .leading, spacing: 8) {
                    if let explanation = model.micPermission.explanation {
                        warning(explanation)
                    }
                    HStack(spacing: 8) {
                        if model.micPermission == .notDetermined {
                            Button("Allow Microphone Access") { model.requestMicrophoneAccess() }
                        }
                        if model.micPermission.offersSystemSettings,
                           let url = MicrophoneAccess.systemSettingsURL {
                            Button("Open System Settings") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }

            HStack {
                Text("Input device")
                    .frame(width: 130, alignment: .leading)
                Picker("", selection: Binding(
                    get: { model.microphoneUID ?? "" },
                    set: { model.microphoneUID = $0.isEmpty ? nil : $0 })) {
                    Text("Choose...").tag("")
                    ForEach(model.deviceCatalog.inputDevices) { device in
                        Text("\(device.name) (\(device.inputChannels) ch)").tag(device.uid)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 340)
                Button {
                    model.deviceCatalog.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan audio devices")
                Spacer()
            }

            if let microphone = model.microphone, microphone.inputChannels > 1 {
                HStack {
                    Text("Channel")
                        .frame(width: 130, alignment: .leading)
                    Picker("", selection: $model.microphoneChannel) {
                        ForEach(0..<microphone.inputChannels, id: \.self) { index in
                            Text("Channel \(index + 1)").tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                    Spacer()
                }
            }
        }
    }

    private var calibrationSection: some View {
        formSection("MICROPHONE CALIBRATION") {
            HStack {
                Text("Calibration file")
                    .frame(width: 130, alignment: .leading)
                Button("Choose...") { chooseCalibration() }
                if model.calibration != nil {
                    Button("Clear") { model.clearCalibration() }
                }
                Text(model.calibrationName ?? "None loaded")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let error = model.calibrationError {
                warning(error)
            }

            if let calibration = model.calibration {
                let range = String(format: "%.0f Hz to %.0f Hz",
                                   calibration.minHz, calibration.maxHz)
                labelled("Coverage", "\(calibration.pointCount) points, \(range)")
                if !calibration.covers(minHz: 20, maxHz: 20000) {
                    note("Outside this range the last known value is held rather than "
                         + "extrapolated, so the correction is less certain at the extremes.")
                }
                ForEach(calibration.warnings, id: \.self) { warningText in
                    note(warningText)
                }
            } else {
                note("Without a calibration file the measured tonal balance is only as "
                     + "accurate as the microphone. Relative low-frequency correction is "
                     + "still useful.")
            }
        }
    }

    private var targetSection: some View {
        let plan = model.plan
        return formSection(model.mode == .inputChannels ? "INPUT CHANNELS TO MEASURE"
                                                   : "SPEAKERS TO MEASURE") {
            Picker("", selection: $model.mode) {
                ForEach(MeasurementMode.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .onChange(of: model.mode) { _, _ in model.modeChanged() }

            Text(model.mode.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.isDeviceConnected {
                note("Connect a DSPi to choose what to measure.")
            }

            let count = model.mode == .inputChannels
                ? model.vm.numMatrixInputs
                : model.vm.numOutputChannels

            ForEach(0..<count, id: \.self) { index in
                let target = plan.target(at: index)
                let obstacle = plan.obstacle(at: index)
                let disabled = target == nil || !model.isDeviceConnected

                HStack(spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { model.selectedTargets.contains(index) },
                        set: { isOn in
                            if isOn { model.selectedTargets.insert(index) }
                            else { model.selectedTargets.remove(index) }
                            model.targetsChanged()
                        })) {
                        Text(model.targetName(index))
                            .frame(width: 130, alignment: .leading)
                    }
                    .disabled(disabled)

                    Picker("", selection: Binding(
                        get: { model.targetRoles[index] ?? .fullRange },
                        set: { model.targetRoles[index] = $0 })) {
                        Text("Full range").tag(RoomCorrectionCore.SpeakerRole.fullRange)
                        Text("Bass limited").tag(RoomCorrectionCore.SpeakerRole.bassLimited)
                        Text("Subwoofer").tag(RoomCorrectionCore.SpeakerRole.subwoofer)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    .disabled(disabled)

                    // Mapping a correction to the wrong channel is a silent
                    // failure, and this is the cheap defence against it.
                    if model.mode == .outputChannels {
                        Button("Identify") { model.vm.identifyOutput(index) }
                            .disabled(disabled)
                    }

                    if let target, model.mode == .inputChannels, target.excitedOutputs.count > 1 {
                        // Naming the drivers makes bass management visible
                        // rather than something the user has to infer.
                        Text("plays through "
                             + target.excitedOutputs.map(model.speakerName).joined(separator: ", "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else if let obstacle, model.isDeviceConnected {
                        Text(obstacle.describe(outputName: model.speakerName,
                                               inputName: model.inputName))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }

            ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warningItem in
                note(warningItem.describe(outputName: model.speakerName,
                                          inputName: model.inputName))
            }

            note("Room correction replaces all ten PEQ bands on each "
                 + (model.mode == .inputChannels ? "input" : "output")
                 + " it writes to. The original bands are restored unless you apply "
                 + "the result."
                 + (model.mode == .inputChannels
                    ? " Crossovers are never touched."
                    : " Crossovers stay on unless you turn one off below."))
        }
    }

    /// Asks about crossovers rather than deciding.
    ///
    /// Bypassing one is the only action in this window that can destroy
    /// hardware, and leaving one on is the only one that can produce a
    /// correction demanding output in a band the crossover removes.  Neither is
    /// safe to assume, so both are put to the user with their consequences.
    @ViewBuilder
    private var crossoverSection: some View {
        let disclosures = model.crossoverDisclosures
        if !disclosures.isEmpty {
            formSection("CROSSOVERS ON THE SPEAKERS YOU SELECTED") {
                note("Measuring an output drives it directly, so whatever crossover is "
                     + "on it shapes the sweep. Leave it on to measure the speaker as "
                     + "it plays, or turn it off to measure the driver alone.")

                ForEach(disclosures) { disclosure in
                    let bypassing = model.bypassCrossoverOutputs.contains(disclosure.outputIndex)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 10) {
                            Text(model.speakerName(disclosure.outputIndex))
                                .frame(width: 130, alignment: .leading)
                            Text(disclosure.description)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 210, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { bypassing },
                                set: { shouldBypass in
                                    if shouldBypass {
                                        model.bypassCrossoverOutputs.insert(disclosure.outputIndex)
                                    } else {
                                        model.bypassCrossoverOutputs.remove(disclosure.outputIndex)
                                    }
                                })) {
                                Text("Keep it on").tag(false)
                                Text("Turn it off").tag(true)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 190)
                            Spacer()
                        }
                        .font(.system(size: 12))

                        if bypassing {
                            ForEach(disclosure.bypassConsequences(
                                sweepStartHz: model.sweepStartHz), id: \.self) { consequence in
                                if disclosure.isHighPass {
                                    warning(consequence)
                                } else {
                                    note(consequence)
                                }
                            }
                            .padding(.leading, 140)
                        }
                    }
                }

                if model.bypassCrossoverOutputs.isEmpty {
                    note("Keeping a crossover on is the safe default. The correction then "
                         + "describes the speaker as you actually listen to it.")
                }
            }
        }
    }

    private var planSection: some View {
        formSection("MEASUREMENT PLAN") {
            HStack {
                Text("Positions")
                    .frame(width: 130, alignment: .leading)
                Picker("", selection: $model.plannedPositions) {
                    Text("Quick (3)").tag(3)
                    Text("Recommended (5)").tag(5)
                    Text("Wide (9)").tag(9)
                    Text("Thorough (13)").tag(13)
                    Text("Maximum (21)").tag(21)
                }
                .labelsHidden()
                .frame(width: 200)
                Spacer()
            }
            HStack {
                Text("Sweep length")
                    .frame(width: 130, alignment: .leading)
                Slider(value: $model.sweepSeconds, in: 3...16, step: 1)
                    .frame(width: 200)
                Text("\(Int(model.sweepSeconds)) s")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 40, alignment: .leading)
                Spacer()
            }
            note("You can stop after any completed position. A longer sweep improves "
                 + "low-frequency signal to noise; a shorter one makes a large plan "
                 + "practical.")
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(model.blockers, id: \.self) { blocker in
                    Label(blocker, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Continue to Level Check") { model.step = .levelCheck }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canContinue)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    // MARK: Helpers

    private func formSection<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fixed label column so stacked rows line up regardless of content length.
    private func labelled(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: 12))
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseCalibration() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.allowedFileTypes = ["txt", "cal", "csv"]
        panel.message = "Choose a microphone calibration file"
        if panel.runModal() == .OK, let url = panel.url {
            model.loadCalibration(from: url)
        }
    }
}

/// The system sidebar material, blended with what is behind the window.
///
/// SwiftUI's `.regularMaterial` blends with the window's own content, so it
/// reads as a flat grey panel. Real sidebar translucency - the desktop showing
/// faintly through - needs `NSVisualEffectView` with behind-window blending,
/// which is what the system's own sidebars use.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        // Dims with the window, as every other sidebar on the system does.
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
