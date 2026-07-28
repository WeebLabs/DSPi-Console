import SwiftUI

/// The capture step: walk the microphone around the room, one position at a
/// time, until there is enough to work with.
///
/// The plan is a suggestion rather than a contract. Stopping after any
/// completed position is a first-class action, not a way out - a user who has
/// captured five good positions should not be made to feel they abandoned
/// something at nine.
struct RoomCorrectionMeasurementsView: View {
    @ObservedObject var model: RoomCorrectionModel
    @ObservedObject private var run: MeasurementRun

    init(model: RoomCorrectionModel) {
        self.model = model
        self.run = model.run
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    progressSection
                    Divider()
                    activeSection
                    if !run.positions.isEmpty {
                        Divider()
                        capturedSection
                    }
                    if let message = run.errorMessage {
                        Divider()
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(22)
            }
            Divider()
            footer
        }
        .onDisappear {
            // Leaving the step must not leave the device rewired. Restoring is
            // idempotent, so doing it here costs nothing when the run already
            // ended cleanly.
            Task { await run.finish() }
        }
    }

    // MARK: - Progress

    private var progressSection: some View {
        formSection("PROGRESS") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(run.usablePositionCount)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text(run.usablePositionCount == 1 ? "position" : "positions")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("of \(model.plannedPositions) planned")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            PositionTrack(captured: run.usablePositionCount,
                          planned: model.plannedPositions)

            Text(run.readiness.summary)
                .font(.system(size: 11))
                .foregroundStyle(run.readiness.isEnough ? .secondary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The position being captured

    /// Always shown, not only while a capture runs: this is where the next
    /// position is named and weighted, so hiding it between captures would
    /// leave the user renaming positions afterwards from memory.
    private var activeSection: some View {
        formSection(run.isRunning ? "CURRENT POSITION" : "NEXT POSITION") {
            HStack {
                Text("Name")
                    .frame(width: 130, alignment: .leading)
                TextField("Position \(run.positions.count + 1)",
                          text: $run.nextPositionName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .disabled(run.isRunning)
                Spacer()
            }
            .font(.system(size: 12))

            HStack {
                Text("Weight")
                    .frame(width: 130, alignment: .leading)
                Picker("", selection: $run.nextPositionWeight) {
                    Text("Main listening seat").tag(3.0)
                    Text("Nearby seat").tag(2.0)
                    Text("Elsewhere in the room").tag(1.0)
                }
                .labelsHidden()
                .frame(width: 220)
                .disabled(run.isRunning)
                Spacer()
            }
            .font(.system(size: 12))

            if run.isRunning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(run.activityDescription(targetName: model.targetName))
                        .font(.system(size: 12))
                    Spacer()
                }
                ProgressView(value: run.positionProgress)
                    .frame(maxWidth: 380)
            } else {
                Text("Move the microphone, then capture. Positions spread around the "
                     + "listening area describe the room better than a tight cluster "
                     + "at one seat.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - What has been captured

    private var capturedSection: some View {
        formSection("CAPTURED") {
            ForEach(Array(run.positions.enumerated()), id: \.element.id) { index, position in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { position.enabled },
                            set: { run.setPosition(index, enabled: $0) })) {
                            Text(position.name)
                                .frame(width: 150, alignment: .leading)
                        }
                        .disabled(run.isRunning)

                        Text(String(format: "weight %.0f", position.weight))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)

                        if position.isComplete {
                            Label("\(position.measurements.count) measured",
                                  systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                                .frame(width: 150, alignment: .leading)
                        } else {
                            Label("\(position.failures.count) failed",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .frame(width: 150, alignment: .leading)
                        }

                        Button("Remove") { run.removePosition(at: index) }
                            .disabled(run.isRunning)
                        Spacer()
                    }

                    // Name what failed and why: "3 failed" on its own tells the
                    // user there is a problem without telling them anything
                    // they can act on.
                    ForEach(position.failures) { failure in
                        HStack(spacing: 6) {
                            Text(model.targetName(failure.speakerIndex))
                                .font(.system(size: 10, weight: .medium))
                                .frame(width: 110, alignment: .leading)
                            Text(failure.verdict.messages.first ?? "Unusable capture.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Button("Retry") { run.retry(failure, in: index, model: model) }
                                .controlSize(.small)
                                .disabled(run.isRunning)
                            Spacer()
                        }
                        .padding(.leading, 24)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Back") { model.step = .levelCheck }
                .disabled(run.isRunning)

            if run.isRunning {
                Button("Stop") { run.cancel() }
            } else {
                Button(run.positions.isEmpty ? "Capture First Position"
                                             : "Capture Next Position") {
                    run.capture(model: model)
                }
                .keyboardShortcut(run.readiness.isEnough ? nil : .defaultAction)
                .disabled(!run.canCapture(model: model))
            }
            Spacer()

            Button("Continue to Target") {
                Task {
                    await run.finish()
                    model.step = .target
                }
            }
            .keyboardShortcut(run.readiness.isEnough ? .defaultAction : nil)
            .disabled(run.isRunning || run.usablePositionCount == 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

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
}

/// Captured positions against the plan.
///
/// Shows the plan as something being filled rather than a bar to reach: the
/// captured pips stay solid past the planned count rather than the track
/// resetting or clamping, because measuring more than planned is a perfectly
/// reasonable thing to do.
private struct PositionTrack: View {
    let captured: Int
    let planned: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<max(captured, planned), id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < captured ? Color.accentColor
                                           : Color.primary.opacity(0.12))
                    .frame(width: 22, height: 6)
            }
        }
    }
}
