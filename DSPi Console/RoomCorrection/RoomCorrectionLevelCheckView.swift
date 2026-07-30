import SwiftUI

/// The step that finds out whether a useful measurement is possible at all.
///
/// Deliberately sequential rather than a panel of independent controls: the
/// noise floor has to exist before a tone reading means anything, and a user
/// presented with both at once will reach for the loud one first.
struct RoomCorrectionLevelCheckView: View {
    @ObservedObject var model: RoomCorrectionModel
    @ObservedObject private var check: LevelCheckController

    init(model: RoomCorrectionModel) {
        self.model = model
        self.check = model.levelCheck
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    meterSection
                    Divider()
                    noiseFloorSection
                    Divider()
                    levelSection
                    if check.result != nil || check.errorMessage != nil {
                        Divider()
                        resultSection
                    }
                    if check.result != nil {
                        Divider()
                        channelLevelSection
                    }
                }
                .padding(22)
            }
            Divider()
            footer
        }
    }

    // MARK: - Live meter

    private var meterSection: some View {
        formSection("MICROPHONE") {
            HStack(spacing: 12) {
                Text(model.microphone?.name ?? "No microphone selected")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 200, alignment: .leading)
                LevelMeter(dbfs: check.inputPeakDbfs, isLive: check.stage.isBusy)
                Text(check.inputPeakDbfs <= -119
                     ? "  -  "
                     : String(format: "%.0f dB", check.inputPeakDbfs))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 56, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
            note("Put the microphone where you normally sit, pointing at the ceiling "
                 + "if it is an omnidirectional measurement microphone such as a UMIK-1.")
        }
    }

    // MARK: - Noise floor

    private var noiseFloorSection: some View {
        formSection("1. ROOM NOISE") {
            HStack(spacing: 12) {
                Button(check.noiseFloorDbfs == nil ? "Listen to the Room"
                                                   : "Listen Again") {
                    guard let microphone = model.microphone else { return }
                    Task {
                        await check.measureNoiseFloor(microphone: microphone,
                                                      channel: model.microphoneChannel)
                    }
                }
                .disabled(model.microphone == nil || check.stage.isBusy)

                if check.stage == .measuringNoiseFloor {
                    ProgressView().controlSize(.small)
                    Text("Listening. Please keep still and quiet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let verdict = check.noiseFloorVerdict {
                HStack(spacing: 8) {
                    Image(systemName: verdict.symbol)
                        .foregroundStyle(verdict.tint)
                    Text(String(format: "%.0f dBFS", verdict.dbfs))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .frame(width: 90, alignment: .leading)
                    Text(verdict.summary)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            } else {
                note("Measured with nothing playing. This sets the floor everything "
                     + "else is judged against.")
            }
        }
    }

    // MARK: - Level

    private var levelSection: some View {
        formSection("2. PLAYBACK LEVEL") {
            HStack {
                Text("Sweep level")
                    .frame(width: 130, alignment: .leading)
                // No step: a stepped slider draws a tick per decibel, which is
                // 57 of them across this range and reads as damage.
                Slider(value: $check.playbackLevelDbfs, in: -60...(-3))
                    .frame(width: 240)
                    .disabled(check.stage.isBusy)
                Text(String(format: "%.0f dBFS", check.playbackLevelDbfs))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 70, alignment: .leading)
                Spacer()
            }
            .font(.system(size: 12))

            HStack(spacing: 12) {
                Button("Play Test Signal") { playTone() }
                    .disabled(!canPlayTone)
                if check.stage == .playingTone {
                    ProgressView().controlSize(.small)
                    Text("Playing.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if check.stage.isBusy {
                    Button("Stop") { check.cancel() }
                }
                Spacer()
            }

            note("A short burst of band-limited noise, not a sweep. It is played "
                 + "through " + firstTargetName + ", which is loud enough to judge the "
                 + "level by but short enough not to be a nuisance.")

            if check.noiseFloorDbfs == nil {
                note("Measure the room noise first.")
            }
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultSection: some View {
        formSection("RESULT") {
            if let message = check.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let result = check.result {
                HStack(alignment: .top, spacing: 26) {
                    reading("Signal to noise",
                            String(format: "%.0f dB", result.estimatedSnrDb),
                            emphasis: check.isLevelAcceptable ? .good : .bad)
                    reading("Peak", String(format: "%.1f dBFS", result.peakDbfs),
                            emphasis: result.clipped ? .bad : .neutral)
                    // Headroom is -peak, so a peak of exactly 0 dBFS gives a
                    // negative zero and renders as "-0.0 dB", which reads as a
                    // bug rather than as no headroom.
                    reading("Headroom",
                            String(format: "%.1f dB", result.headroomDb == 0 ? 0
                                                                             : result.headroomDb),
                            emphasis: result.headroomDb < 3 ? .bad : .neutral)
                    Spacer()
                }

                ForEach(check.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let change = check.suggestedLevelChangeDb {
                    HStack(spacing: 10) {
                        Text(String(format: "Suggested: %@%.0f dB",
                                    change > 0 ? "+" : "", change))
                            .font(.system(size: 12, weight: .medium))
                        Button("Apply and Retest") {
                            check.applySuggestedLevel()
                            playTone()
                        }
                        .disabled(!canPlayTone)
                        Spacer()
                    }
                } else if check.isLevelAcceptable {
                    Label("This level will measure well.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private enum Emphasis { case good, bad, neutral }

    private func reading(_ label: String, _ value: String,
                         emphasis: Emphasis) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(emphasis == .good ? Color.green
                                 : emphasis == .bad ? Color.orange : Color.primary)
        }
        .frame(width: 130, alignment: .leading)
    }

    // MARK: - Channel levels

    private var channelLevelSection: some View {
        formSection("3. CHANNEL LEVELS") {
            Toggle("Bring the channels to a common level", isOn: $model.matchChannelLevels)
                .font(.system(size: 12))

            note("Measures each channel in turn at this position and works out the "
                 + "trim that matches them. Runs before the sweeps because fixing a "
                 + "badly matched channel means turning a gain control, and that "
                 + "invalidates any measurement already taken."
                 + (model.matchChannelLevels ? "" : " Turned off, your existing "
                    + "balance between channels is left exactly as it is."))

            HStack(spacing: 12) {
                Button(check.channelLevels.isEmpty ? "Measure Channel Levels"
                                                   : "Measure Again") { measureLevels() }
                    .disabled(!canPlayTone || !model.matchChannelLevels)
                if check.stage == .measuringChannels {
                    ProgressView().controlSize(.small)
                    Text("Measuring each channel. Please keep still and quiet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let match = model.levelMatch {
                levelTable(match)
            }
        }
    }

    private func levelTable(_ match: ChannelLevelMatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("CHANNEL").frame(width: 130, alignment: .leading)
                Text("LEVEL").frame(width: 90, alignment: .trailing)
                Text("VS OTHERS").frame(width: 90, alignment: .trailing)
                Text("TRIM").frame(width: 80, alignment: .trailing)
                Spacer()
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)

            ForEach(match.offsets) { offset in
                let level = check.channelLevels.first { $0.speakerIndex == offset.speakerIndex }
                HStack(spacing: 0) {
                    Text(model.targetName(offset.speakerIndex))
                        .frame(width: 130, alignment: .leading)
                    Text(level.map { String(format: "%.1f dB", $0.levelDb) } ?? "-")
                        .frame(width: 90, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%+.1f dB", offset.deviationDb))
                        .frame(width: 90, alignment: .trailing)
                        .foregroundStyle(offset.needsPhysicalGainChange ? .orange : .secondary)
                    Text(offset.isSubwoofer
                         ? "-"
                         : String(format: "%+.1f dB", offset.offsetDb))
                        .frame(width: 80, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.system(size: 11, design: .monospaced))
            }

            ForEach(match.outOfRange) { offset in
                if let text = offset.guidance(name: model.targetName(offset.speakerIndex)) {
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if match.outputLostDb > 0.05 {
                note(String(format: "Matching costs %.1f dB of output overall, because "
                            + "every channel comes down to the quietest one.",
                            match.outputLostDb))
            }
            if match.subwooferAccuracyReduced {
                Label("No microphone calibration is loaded, so the subwoofer's level "
                      + "relative to the other channels carries the microphone's own "
                      + "uncalibrated low-frequency response.",
                      systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if match.isReady {
                Label("Channels are close enough to match with a digital trim.",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }
        }
    }

    private func measureLevels() {
        guard let microphone = model.microphone,
              let playbackDevice = model.playbackDevice else { return }
        Task {
            _ = await check.measureChannelLevels(model.levelTargets(),
                                                 microphone: microphone,
                                                 micChannel: model.microphoneChannel,
                                                 playbackDevice: playbackDevice,
                                                 sampleRate: playbackDevice.nominalSampleRate)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Back") { model.step = .setup }

            if check.result != nil && !check.isLevelAcceptable {
                // Not a block. The user may know something the meter does not,
                // and a tool that refuses to proceed on a warning is a tool
                // people work around rather than one they trust.
                Text("You can continue anyway, but expect a less certain correction.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Continue to Measurements") { model.step = .measurements }
                .keyboardShortcut(.defaultAction)
                .disabled(check.result == nil)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private var canPlayTone: Bool {
        model.microphone != nil
            && model.playbackDevice != nil
            && check.noiseFloorDbfs != nil
            && !check.stage.isBusy
    }

    /// The level is checked through one speaker, not all of them.
    ///
    /// Checking every one would take as long as a measurement position, and the
    /// level that works for one full-range speaker works for its neighbours.
    private var firstTargetName: String {
        guard let first = model.selectedTargets.min() else { return "the first channel" }
        return model.targetName(first)
    }

    private func playTone() {
        guard let microphone = model.microphone,
              let playbackDevice = model.playbackDevice,
              let plan = try? model.speakerPlans().first else { return }
        Task {
            await check.measureTone(microphone: microphone,
                                    micChannel: model.microphoneChannel,
                                    playbackDevice: playbackDevice,
                                    playbackChannel: plan.playbackChannel,
                                    sampleRate: playbackDevice.nominalSampleRate)
        }
    }

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

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Meter

/// A peak meter reading in dBFS.
///
/// Scaled from -60 rather than linearly: a linear bar spends most of its length
/// on levels nobody cares about and squeezes the whole useful range into the
/// last few pixels.
private struct LevelMeter: View {
    let dbfs: Double
    let isLive: Bool

    var body: some View {
        GeometryReader { geometry in
            let fraction = max(0, min(1, (dbfs + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .orange],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * fraction)
                    .opacity(isLive ? 1 : 0.35)
            }
        }
        .frame(height: 8)
        .frame(maxWidth: 260)
    }
}

private extension NoiseFloorVerdict {
    var symbol: String {
        switch rating {
        case .quiet: return "checkmark.circle.fill"
        case .acceptable: return "checkmark.circle"
        case .noisy: return "exclamationmark.triangle.fill"
        case .tooNoisy: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch rating {
        case .quiet, .acceptable: return .green
        case .noisy: return .orange
        case .tooNoisy: return .red
        }
    }
}
