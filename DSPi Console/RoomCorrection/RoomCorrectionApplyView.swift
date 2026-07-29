import SwiftUI

/// Write the correction, then prove it took.
///
/// The screen states what changes before it changes anything. Spec section 5:
/// "A user should never reach the Apply screen unsure of what is about to
/// change." That matters most for the PEQ ownership warning, since the
/// correction replaces the whole ordinary bank of every destination channel.
struct RoomCorrectionApplyView: View {
    @ObservedObject var model: RoomCorrectionModel
    @ObservedObject private var design: CorrectionDesign

    @State private var selected: Set<Int> = []
    @State private var applier: CorrectionApplier?
    @State private var applyState: CorrectionApplier.State = .idle
    @State private var verifier: CorrectionVerifier?
    @State private var verifyState: CorrectionVerifier.State = .idle
    @State private var verifyResults: [VerificationResult] = []
    @State private var shownVerification: Int?

    init(model: RoomCorrectionModel) {
        self.model = model
        self.design = model.design
    }

    private var plans: [ChannelApplyPlan] {
        design.applyPlans(mode: model.mode,
                          eqChannel: model.vm.eqChannel(forOutput:),
                          currentOutputGainDb: { output in
                              model.vm.outputGainDB.indices.contains(output)
                                  ? model.vm.outputGainDB[output] : 0
                          },
                          currentPreampDb: { channel in
                              model.vm.preampDB.indices.contains(channel)
                                  ? model.vm.preampDB[channel] : 0
                          })
    }

    private var chosen: [ChannelApplyPlan] {
        plans.filter { selected.contains($0.speakerIndex) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if plans.isEmpty {
                        nothingToApply
                    } else {
                        ownershipWarning
                        Divider()
                        checklist
                        Divider()
                        outcome
                        if case .applied = applyState {
                            Divider()
                            verification
                        }
                    }
                }
                .padding(22)
            }
            Divider()
            footer
        }
        .onAppear {
            // Everything measured is selected by default; any subset may be
            // applied (spec section 5).
            if selected.isEmpty { selected = Set(plans.map(\.speakerIndex)) }
        }
    }

    private var nothingToApply: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No correction has been calculated yet.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text("Go back to Target and calculate one.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - What will change

    private var destinationWord: String {
        model.mode == .inputChannels ? "input" : "output"
    }

    private var ownershipWarning: some View {
        formSection("WHAT WILL CHANGE") {
            Label("Room correction replaces all ten PEQ bands on each "
                  + "\(destinationWord) it writes to.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            note("Any filters you already have on these banks are replaced, not "
                 + "merged. Crossovers are preserved. Nothing is written to flash, "
                 + "and the original banks are restored if the write does not read "
                 + "back correctly."
                 + (model.mode == .inputChannels
                    ? " Input banks are where tone controls and house EQ usually "
                      + "live, so check the list below before applying."
                    : ""))
        }
    }

    private var checklist: some View {
        formSection("CHANNELS") {
            HStack(spacing: 0) {
                Text("").frame(width: 26)
                Text("CHANNEL").frame(width: 130, alignment: .leading)
                Text("WRITES TO").frame(width: 120, alignment: .leading)
                Text("BANDS").frame(width: 70, alignment: .trailing)
                Text("LEVEL").frame(width: 90, alignment: .trailing)
                Spacer()
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.secondary)

            ForEach(plans) { plan in
                HStack(spacing: 0) {
                    Toggle("", isOn: Binding(
                        get: { selected.contains(plan.speakerIndex) },
                        set: { isOn in
                            if isOn { selected.insert(plan.speakerIndex) }
                            else { selected.remove(plan.speakerIndex) }
                        }))
                        .labelsHidden()
                        .frame(width: 26)
                        .disabled(applyState.isBusy)

                    Text(model.targetName(plan.speakerIndex))
                        .frame(width: 130, alignment: .leading)
                    Text(destinationLabel(plan))
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text("\(plan.activeBandCount) of \(CorrectionDesign.bandsPerBank)")
                        .frame(width: 70, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%+.1f dB", plan.compensationDb))
                        .frame(width: 90, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.system(size: 11))
            }

            note("The level column is the balance compensation: a cut-only "
                 + "correction lowers each channel by a different amount, so the "
                 + "\(destinationWord) gain gives that back and your existing "
                 + "balance between channels survives.")
        }
    }

    private func destinationLabel(_ plan: ChannelApplyPlan) -> String {
        switch plan.destination {
        case .outputGain(let output): return "Output \(output + 1) EQ"
        case .inputPreamp(let channel): return "Input \(channel + 1) EQ"
        }
    }

    // MARK: - Outcome

    @ViewBuilder
    private var outcome: some View {
        switch applyState {
        case .idle:
            EmptyView()
        case .applying(let channel, let total):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Writing \(model.targetName(channel)), \(total) channel"
                     + (total == 1 ? "" : "s") + " selected.")
                    .font(.system(size: 12))
                Spacer()
            }
        case .applied:
            formSection("APPLIED") {
                Label("Written and read back correctly.",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                note("Nothing has been saved to flash. Use Save to Current Preset in "
                     + "the main window to keep this across a power cycle, or reload "
                     + "the preset to discard it.")
            }
        case .rolledBack(let reason):
            formSection("ROLLED BACK") {
                Label(reason, systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                note("Every channel in this apply was restored to what it held "
                     + "before, including any that wrote successfully.")
            }
        case .refused(let reason):
            formSection("NOT APPLIED") {
                Label(reason, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                note("Nothing was written.")
            }
        }
    }

    // MARK: - Verification

    private var verification: some View {
        formSection("VERIFY") {
            note("Sweeps each applied channel once at the main listening position "
                 + "with the correction running, and compares what was measured "
                 + "against what was predicted. This is the strongest check for a "
                 + "routing mistake or a channel that is not the one you think.")

            HStack(spacing: 12) {
                Button("Verify Correction") { runVerification() }
                    .disabled(verifyState.isBusy || model.microphone == nil)
                if case .sweeping(let speaker, let done, let total) = verifyState {
                    ProgressView().controlSize(.small)
                    Text("Sweeping \(model.targetName(speaker)), \(done + 1) of \(total).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if model.microphone == nil {
                    Text("No microphone selected.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if case .failed(let reason) = verifyState {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !verifyResults.isEmpty {
                verificationResults
            }
        }
    }

    private var verificationResults: some View {
        let shown = verifyResults.first { $0.speakerIndex == shownVerification }
            ?? verifyResults.first

        return VStack(alignment: .leading, spacing: 10) {
            if verifyResults.count > 1 {
                Picker("", selection: Binding(
                    get: { shown?.speakerIndex ?? 0 },
                    set: { shownVerification = $0 })) {
                    ForEach(verifyResults) { result in
                        Text(model.targetName(result.speakerIndex)).tag(result.speakerIndex)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            if let shown {
                VerificationPlot(measured: shown.measuredDb,
                                 predicted: shown.predictedDb,
                                 target: shown.targetDb,
                                 frequencies: design.grid.frequencies)
                    .frame(height: 200)

                HStack(spacing: 18) {
                    legend("Measured after", .green)
                    legend("Predicted", .accentColor)
                    legend("Target", .secondary)
                    Spacer()
                }

                Label(shown.summary,
                      systemImage: shown.crossoverWasBypassed
                        ? "info.circle"
                        : (shown.agreesWithPrediction
                           ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                    .font(.system(size: 11))
                    .foregroundStyle(shown.crossoverWasBypassed ? Color.secondary
                                     : (shown.agreesWithPrediction ? Color.green
                                                                   : Color.orange))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func legend(_ label: String, _ colour: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1)
                .fill(colour)
                .frame(width: 14, height: 2)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func runVerification() {
        let verifier = CorrectionVerifier(session: model.run.session, design: design)
        self.verifier = verifier
        let bypassed = Set(model.bypassedForMeasurement.map(\.outputIndex))
        Task {
            await verifier.verify(plans: chosen, model: model,
                                  bypassedCrossovers: bypassed)
            verifyState = verifier.state
            verifyResults = verifier.results
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Back to Results") { model.step = .results }
                .disabled(applyState.isBusy)
            Spacer()

            if case .applied = applyState {
                Text("\(model.run.usablePositionCount) position"
                     + (model.run.usablePositionCount == 1 ? "" : "s") + " measured")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Button("Apply to DSPi") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || applyState.isBusy
                          || model.vm.selectedDevice == nil)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private func apply() {
        // Identity and routing are captured now, from the state the correction
        // was calculated against, and checked again inside the transaction.
        let applier = CorrectionApplier(target: model.vm,
                                        expectedSerial: model.vm.selectedDevice?.serial,
                                        expectedRouting: model.vm.matrixRouting)
        self.applier = applier
        Task {
            await applier.apply(chosen)
            applyState = applier.state
        }
    }

    // MARK: - Helpers

    private func formSection<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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


// MARK: - Plot

/// What was measured after applying, over what was predicted, over the target.
///
/// Measured and predicted are already referenced to a common mean by
/// `CorrectionVerifier`, since the comparison is about whether the shape came
/// out as modelled rather than about absolute level.
private struct VerificationPlot: View {
    let measured: [Double]
    let predicted: [Double]
    let target: [Double]
    let frequencies: [Double]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let axis = FrequencyAxis(frequencies: frequencies)
            let scale = FrequencyPlotScale(fitting: measured + predicted,
                                           minimumHalfRange: 8, padding: 1.1)
            ZStack {
                FrequencyPlotBackground(axis: axis, scale: scale)
                axis.path(target, scale: scale, in: size)
                    .stroke(Color.secondary.opacity(0.5),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                axis.path(predicted, scale: scale, in: size)
                    .stroke(Color.accentColor.opacity(0.9), lineWidth: 1.5)
                axis.path(measured, scale: scale, in: size)
                    .stroke(Color.green, lineWidth: 2)
            }
        }
    }
}
