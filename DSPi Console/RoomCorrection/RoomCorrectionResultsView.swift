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
    @State private var showFixedPole = false

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
                        Divider()
                        fixedPoleSection
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
                comparison: design.parallelCurve(channel: channel),
                frequencies: design.grid.frequencies)

            HStack(spacing: 18) {
                legend("Measured", .secondary)
                legend("Target", .accentColor)
                legend("Corrected", .green)
                if !design.parallelCurve(channel: channel).isEmpty {
                    legend("Fixed-pole", .orange)
                }
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

    // MARK: - Fixed-pole comparison

    /// A research comparison, not a product choice.
    ///
    /// The design this draws cannot be written to a DSPi - the firmware DSP is
    /// a cascade with no accumulator, and the wire carries filter recipes
    /// rather than coefficients - so nothing here changes what Apply would do.
    /// It is here because the firmware question needs real measurements and
    /// this is where they are.
    private var fixedPoleSection: some View {
        DisclosureGroup(isExpanded: $showFixedPole) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { design.comparesFixedPole },
                    set: { design.comparesFixedPole = $0 })) {
                    Text("Design a fixed-pole bank alongside the correction")
                        .font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .padding(.top, 8)

                Text("Adds an orange trace to the response plot. It cannot be "
                     + "applied: the firmware runs a cascade and the wire carries "
                     + "filter recipes, not coefficients.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if design.comparesFixedPole {
                    HStack(spacing: 10) {
                        Text("Sections")
                            .font(.system(size: 12))
                            .frame(width: 70, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { design.parallelOptions.sections },
                            set: { design.parallelOptions.sections = $0 })) {
                            ForEach([10, 12, 16, 24, 32, 48], id: \.self) { count in
                                Text("\(count)").tag(count)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        Text("ten matches the hardware's PEQ budget")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    if design.isStale {
                        Text("Recalculate on the Target step to see it.")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }

                if let parallel = design.parallelMetrics(channel: channel),
                   let real = design.metrics(channel: channel) {
                    Divider()
                    HStack(alignment: .top, spacing: 26) {
                        reading("Correction error",
                                String(format: "%.2f dB", real.reliableWorstPositionRmseDb),
                                caption: "what will be applied", emphasis: .neutral)
                        reading("Fixed-pole error",
                                String(format: "%.2f dB", parallel.reliableWorstPositionRmseDb),
                                caption: "\(design.parallelSections(channel: channel).count) sections",
                                emphasis: parallel.reliableWorstPositionRmseDb
                                    < real.reliableWorstPositionRmseDb ? .good : .neutral)
                        if let trim = design.parallelTrimDb(channel: channel) {
                            reading("Its level cost",
                                    String(format: "%.1f dB", trim),
                                    caption: trim < -8
                                        ? "far more than the correction takes"
                                        : "preamp it would need",
                                    emphasis: trim < -8 ? .warning : .neutral)
                        }
                        Spacer()
                    }
                }
            }
        } label: {
            Text("FIXED-POLE COMPARISON")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
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

    private enum Emphasis { case good, neutral, warning }

    private func reading(_ label: String, _ value: String,
                         caption: String, emphasis: Emphasis) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(emphasis == .good ? Color.green
                                 : emphasis == .warning ? Color.orange : Color.primary)
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

/// Measured, target, what the correction is predicted to produce, and
/// optionally what a fixed-pole parallel bank would have produced instead.
///
/// The corrected trace is measured plus correction rather than a separate
/// prediction, so what is drawn is exactly what the filters do to what was
/// measured - no second model that could disagree with the first.
private struct ResponseComparisonPlot: View {
    let measured: [Double]
    let target: [Double]
    let correction: [Double]
    /// The fixed-pole bank's correction, or empty.  Drawn on the same terms as
    /// the real one - measured plus correction - so the two traces are
    /// comparable rather than one being a prediction and the other a model.
    var comparison: [Double] = []
    let frequencies: [Double]

    /// Measured plus correction, rather than a separate prediction: what is
    /// drawn is exactly what the filters do to what was measured, with no
    /// second model that could disagree with the first.
    private var corrected: [Double] {
        guard measured.count == correction.count else { return [] }
        return zip(measured, correction).map(+)
    }

    private var comparisonCorrected: [Double] {
        guard !comparison.isEmpty, measured.count == comparison.count else { return [] }
        return zip(measured, comparison).map(+)
    }

    /// One decade of frequency to 50 dB of level, per CTA-2034-A and IEC 60263.
    ///
    /// With a 20 Hz to 20 kHz grid that is three decades, so the plot is three
    /// times as wide as it is tall and the height is not independently
    /// choosable: making it taller means making the window wider.
    private var conformantAspect: Double {
        FrequencyAxis(frequencies: frequencies).decadeSpan
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let axis = FrequencyAxis(frequencies: frequencies)
            // Fixed 50 dB window, not an auto-fitted one.  CTA-2034-A ties the
            // vertical scale to the horizontal: one decade of frequency has to
            // occupy the same distance as 50 dB, so a range that grows to fit
            // the data would break the conformance the aspect ratio below
            // establishes.  Curves outside it ride the edge - `path` clamps -
            // which is the honest failure: a null deeper than the window still
            // reads as "off the bottom" rather than quietly rescaling
            // everything else to accommodate it.
            let scale = FrequencyPlotScale(
                centring: measured + target + corrected + comparisonCorrected,
                halfRange: FrequencyPlotScale.cea2034HalfRangeDb)
            ZStack {
                FrequencyPlotBackground(axis: axis, scale: scale)
                axis.path(measured, scale: scale, in: size)
                    .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
                axis.path(target, scale: scale, in: size)
                    .stroke(Color.accentColor.opacity(0.9),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                if !comparisonCorrected.isEmpty {
                    // Under the real correction, because that is the one the
                    // user is deciding about.
                    axis.path(comparisonCorrected, scale: scale, in: size)
                        .stroke(Color.orange.opacity(0.85), lineWidth: 1.5)
                }
                axis.path(corrected, scale: scale, in: size)
                    .stroke(Color.green, lineWidth: 2)
            }
        }
        .aspectRatio(conformantAspect, contentMode: .fit)
    }
}
