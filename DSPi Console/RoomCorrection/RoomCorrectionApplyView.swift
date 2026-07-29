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
