import SwiftUI

/// Review the correction before writing anything.
///
/// Shows what the room did, what it will do, and what the filters cost. This is
/// the last honest place to decide against applying, so the cautions are on the
/// page rather than behind a disclosure.
struct RoomCorrectionResultsView: View {
    @ObservedObject var model: RoomCorrectionModel
    @ObservedObject private var design: CorrectionDesign

    @State private var selectedChannel: Int?
    @State private var showFilters = false

    init(model: RoomCorrectionModel) {
        self.model = model
        self.design = model.design
    }

    private var channel: Int { selectedChannel ?? design.fittedChannels.first ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if design.fittedChannels.isEmpty {
                        nothingToShow
                    } else {
                        channelPicker
                        Divider()
                        responseSection
                        Divider()
                        verdictSection
                        if !crossoverNotes.isEmpty {
                            Divider()
                            crossoverSection
                        }
                        Divider()
                        filtersSection
                    }
                }
                .padding(22)
            }
            Divider()
            footer
        }
    }

    private var nothingToShow: some View {
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

    // MARK: - Channel

    private var channelPicker: some View {
        HStack(spacing: 10) {
            Text("Channel")
                .font(.system(size: 12))
                .frame(width: 70, alignment: .leading)
            Picker("", selection: Binding(
                get: { channel },
                set: { selectedChannel = $0 })) {
                ForEach(design.fittedChannels, id: \.self) { index in
                    Text(model.targetName(index)).tag(index)
                }
            }
            .labelsHidden()
            .frame(width: 220)
            Spacer()
        }
    }

    // MARK: - Response

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREDICTED RESPONSE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            ResponseComparisonPlot(
                measured: design.curve(.powerAverage, channel: channel),
                target: design.curve(.target, channel: channel),
                correction: design.curve(.correction, channel: channel),
                frequencies: design.grid.frequencies)
                .frame(height: 220)

            HStack(spacing: 18) {
                legend("Measured", .secondary)
                legend("Target", .accentColor)
                legend("Corrected", .green)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Verdict

    @ViewBuilder
    private var verdictSection: some View {
        if let summary = design.summaries().first(where: { $0.channel == channel }) {
            formSection("RESULT") {
                HStack(alignment: .top, spacing: 26) {
                    reading("Improvement",
                            summary.outcome == .noBenefit
                                ? "none"
                                : String(format: "%.1f dB", summary.improvementDb),
                            caption: summary.outcome == .noBenefit
                                ? "already on target"
                                : String(format: "%.0f%% closer to target",
                                         summary.improvementPercent),
                            emphasis: summary.outcome == .improved ? .good : .neutral)
                    reading("Filters used", "\(summary.filterCount)",
                            caption: summary.shelfCount > 0
                                ? "\(summary.shelfCount) shelving" : "all peaking",
                            emphasis: .neutral)
                    reading("Level taken",
                            String(format: "%.1f dB", summary.trimDb == 0 ? 0
                                                                          : summary.trimDb),
                            caption: "to make headroom", emphasis: .neutral)
                    Spacer()
                }

                Text(summary.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(summary.cautions, id: \.self) { caution in
                    Label(caution, systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if summary.transitionEstimated {
                    Text(String(format: "Modal behaviour gives way to statistical around "
                                + "%.0f Hz in this room. Below that the correction is "
                                + "position-specific; above it, broad.", summary.transitionHz))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Crossovers

    /// What was measured without a crossover, and what that means for the result.
    ///
    /// The user agreed to this in Setup, but by now they have run a whole
    /// measurement and are looking at a curve. Not repeating it here would let
    /// them judge the result against a configuration they are not going to
    /// listen to.
    private var crossoverNotes: [CrossoverDisclosure] { model.bypassedForMeasurement }

    private var crossoverSection: some View {
        formSection("MEASURED WITHOUT A CROSSOVER") {
            ForEach(crossoverNotes) { note in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(model.speakerName(note.outputIndex))
                            .font(.system(size: 12, weight: .medium))
                        Text(note.description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text("You chose to switch this crossover off for the measurement, so "
                         + "the correction above describes the driver without it. Once "
                         + "the crossover is switched back on, the response you actually "
                         + "hear will differ from what is shown here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 24)
                }
            }
        }
    }

    // MARK: - Filters

    private var filtersSection: some View {
        DisclosureGroup(isExpanded: $showFilters) {
            let filters = design.filters(channel: channel)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 0) {
                    Text("TYPE").frame(width: 90, alignment: .leading)
                    Text("FREQUENCY").frame(width: 100, alignment: .trailing)
                    Text("GAIN").frame(width: 80, alignment: .trailing)
                    Text("Q").frame(width: 70, alignment: .trailing)
                    Spacer()
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

                ForEach(Array(filters.enumerated()), id: \.offset) { _, filter in
                    HStack(spacing: 0) {
                        Text(filter.type.name)
                            .frame(width: 90, alignment: .leading)
                        Text(filter.freq >= 1000
                             ? String(format: "%.2f kHz", filter.freq / 1000)
                             : String(format: "%.1f Hz", filter.freq))
                            .frame(width: 100, alignment: .trailing)
                        Text(String(format: "%+.2f dB", filter.gain))
                            .frame(width: 80, alignment: .trailing)
                            .foregroundStyle(filter.gain > 0 ? .orange : .primary)
                        Text(String(format: "%.3f", filter.q))
                            .frame(width: 70, alignment: .trailing)
                        Spacer()
                    }
                    .font(.system(size: 11, design: .monospaced))
                }

                if filters.isEmpty {
                    Text("No filters were needed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Text("FILTERS (\(design.filters(channel: channel).count))")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Back to Target") { model.step = .target }
            if design.isStale {
                Text("The target has changed since this was calculated.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Continue to Apply") { model.step = .apply }
                .keyboardShortcut(.defaultAction)
                .disabled(design.fittedChannels.isEmpty)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private enum Emphasis { case good, neutral }

    private func reading(_ label: String, _ value: String,
                         caption: String, emphasis: Emphasis) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(emphasis == .good ? Color.green : Color.primary)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 160, alignment: .leading)
    }

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
}

// MARK: - Plot

/// Measured, target, and what the correction is predicted to produce.
///
/// The corrected trace is measured plus correction rather than a separate
/// prediction, so what is drawn is exactly what the filters do to what was
/// measured - no second model that could disagree with the first.
private struct ResponseComparisonPlot: View {
    let measured: [Double]
    let target: [Double]
    let correction: [Double]
    let frequencies: [Double]

    private var corrected: [Double] {
        guard measured.count == correction.count else { return [] }
        return zip(measured, correction).map(+)
    }

    /// Fitted to the traces, so a room with a 25 dB null is not drawn as a
    /// flat line pressed against the bottom of the box.
    private var scale: (centre: Double, halfRange: Double) {
        let all = measured + target + corrected
        guard let low = all.min(), let high = all.max() else { return (0, 12) }
        return ((low + high) / 2, max(8, (high - low) / 2 * 1.1))
    }

    var body: some View {
        let (centre, halfRange) = scale
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.12))
                gridLines(in: size, centre: centre, halfRange: halfRange)
                trace(measured, in: size, centre: centre, halfRange: halfRange)
                    .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
                trace(target, in: size, centre: centre, halfRange: halfRange)
                    .stroke(Color.accentColor.opacity(0.9),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                trace(corrected, in: size, centre: centre, halfRange: halfRange)
                    .stroke(Color.green, lineWidth: 2)
                axisLabels(in: size, centre: centre, halfRange: halfRange)
            }
        }
    }

    private func gridLines(in size: CGSize, centre: Double,
                           halfRange: Double) -> some View {
        ZStack {
            ForEach([20.0, 100.0, 1000.0, 10000.0], id: \.self) { hz in
                let x = position(ofHz: hz, in: size.width)
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            }
            ForEach(dbLines(centre: centre, halfRange: halfRange), id: \.self) { db in
                let y = position(ofDb: db, in: size.height, centre: centre,
                                 halfRange: halfRange)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private func axisLabels(in size: CGSize, centre: Double,
                            halfRange: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach([100.0, 1000.0, 10000.0], id: \.self) { hz in
                Text(hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .position(x: position(ofHz: hz, in: size.width) + 12,
                              y: size.height - 8)
            }
            ForEach(dbLines(centre: centre, halfRange: halfRange), id: \.self) { db in
                Text(String(format: "%+.0f", db - centre))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .position(x: 18, y: position(ofDb: db, in: size.height,
                                                 centre: centre, halfRange: halfRange))
            }
        }
    }

    private func dbLines(centre: Double, halfRange: Double) -> [Double] {
        let step: Double = halfRange > 15 ? 10 : 5
        var lines = [centre]
        var offset = step
        while offset < halfRange {
            lines.append(centre + offset)
            lines.append(centre - offset)
            offset += step
        }
        return lines.sorted()
    }

    private func trace(_ values: [Double], in size: CGSize,
                       centre: Double, halfRange: Double) -> Path {
        Path { path in
            guard values.count == frequencies.count else { return }
            for (index, value) in values.enumerated() {
                let point = CGPoint(
                    x: position(ofHz: frequencies[index], in: size.width),
                    y: min(max(position(ofDb: value, in: size.height, centre: centre,
                                        halfRange: halfRange), 0), size.height))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    private func position(ofDb db: Double, in height: CGFloat,
                          centre: Double, halfRange: Double) -> CGFloat {
        height / 2 - CGFloat((db - centre) / halfRange) * (height / 2)
    }

    private func position(ofHz hz: Double, in width: CGFloat) -> CGFloat {
        guard let low = frequencies.first, let high = frequencies.last, high > low else {
            return 0
        }
        let fraction = (log10(hz) - log10(low)) / (log10(high) - log10(low))
        return width * CGFloat(min(max(fraction, 0), 1))
    }
}
