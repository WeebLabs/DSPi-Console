import SwiftUI

/// Design the house curve.
///
/// The macro controls are the ones almost everyone should use, so they are the
/// page. Anchors and fit limits are for people who know why they want them, so
/// they live behind a disclosure rather than competing for attention with the
/// tilt slider.
struct RoomCorrectionTargetView: View {
    @ObservedObject var model: RoomCorrectionModel
    @ObservedObject private var design: CorrectionDesign

    @State private var showAdvanced = false
    @State private var newAnchorHz = "1000"
    @State private var newAnchorDb = "0"

    init(model: RoomCorrectionModel) {
        self.model = model
        self.design = model.design
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    curveSection
                    Divider()
                    presetSection
                    Divider()
                    shapeSection
                    Divider()
                    advancedSection
                    if let message = design.errorMessage {
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
    }

    // MARK: - The curve

    private var curveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOUSE CURVE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            TargetCurvePlot(target: design.previewTargetCurve(),
                            measured: measuredCurve,
                            frequencies: design.grid.frequencies,
                            anchors: design.anchors)
                .frame(height: 200)

            Text(design.target.summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The measured average of the first fitted channel, for context.
    ///
    /// Drawn behind the target so the user can see what they are aiming at
    /// relative to what the room actually does, which is the difference between
    /// choosing a curve and guessing one.
    private var measuredCurve: [Double] {
        guard let channel = design.fittedChannels.first else { return [] }
        return design.curve(.powerAverage, channel: channel)
    }

    // MARK: - Presets

    private var presetSection: some View {
        formSection("STARTING POINT") {
            Picker("", selection: $design.preset) {
                ForEach(RoomCorrectionCore.TargetPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            Text(design.preset.explanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            note("A preset replaces the shape below. Anchors you have added are your "
                 + "own edits and are kept.")
        }
    }

    // MARK: - Shape

    private var shapeSection: some View {
        formSection("SHAPE") {
            slider("Tilt", value: Binding(
                get: { design.target.tiltDbPerOctave },
                set: { design.target.tiltDbPerOctave = $0 }),
                   range: -2...0.5, format: "%.2f dB/oct",
                   help: "How much the curve falls across the band. This is the single "
                       + "control that most changes how a system sounds.")

            slider("Bass lift", value: Binding(
                get: { design.target.bassGainDb },
                set: { design.target.bassGainDb = $0 }),
                   range: -6...12, format: "%.1f dB",
                   help: "Extra weight below the transition, on top of the tilt.")

            slider("Bass transition", value: Binding(
                get: { design.target.bassTransitionHz },
                set: { design.target.bassTransitionHz = $0 }),
                   range: 40...300, format: "%.0f Hz",
                   help: "Where the bass lift takes effect.")

            slider("Treble", value: Binding(
                get: { design.target.trebleGainDb },
                set: { design.target.trebleGainDb = $0 }),
                   range: -8...6, format: "%.1f dB",
                   help: "Lift or cut above the treble transition. Cutting here is far "
                       + "more often what a bright room needs.")

            slider("Treble transition", value: Binding(
                get: { design.target.trebleTransitionHz },
                set: { design.target.trebleTransitionHz = $0 }),
                   range: 2000...16000, format: "%.0f Hz",
                   help: "Where the treble adjustment begins.")

            slider("Shelf width", value: Binding(
                get: { design.target.shelfWidthOctaves },
                set: { design.target.shelfWidthOctaves = $0 }),
                   range: 0.5...3, format: "%.1f oct",
                   help: "How gradually the bass and treble shelves arrive. Wider is "
                       + "less audible as a transition.")
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 18) {
                anchorControls
                Divider()
                limitControls
                Divider()
                curtainControls
            }
            .padding(.top, 12)
        } label: {
            Text("ADVANCED")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }

    private var anchorControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Target anchors")
                .font(.system(size: 12, weight: .medium))
            note("Fixed points the curve is pulled through, on top of the shape above. "
                 + "Useful for a specific room problem the macro controls cannot "
                 + "express.")

            ForEach(design.anchors) { anchor in
                HStack(spacing: 10) {
                    Text(String(format: "%.0f Hz", anchor.freqHz))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 90, alignment: .leading)
                    Slider(value: Binding(
                        get: { anchor.gainDb },
                        set: { design.updateAnchor(anchor, gainDb: $0) }),
                           in: -12...12)
                        .frame(width: 200)
                    Text(String(format: "%+.1f dB", anchor.gainDb))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 70, alignment: .leading)
                    Button("Remove") { design.removeAnchor(anchor) }
                        .controlSize(.small)
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                TextField("Hz", text: $newAnchorHz)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                TextField("dB", text: $newAnchorDb)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Button("Add Anchor") {
                    guard let hz = Double(newAnchorHz), let db = Double(newAnchorDb),
                          hz >= design.grid.minHz, hz <= design.grid.maxHz else { return }
                    design.addAnchor(freqHz: hz, gainDb: db)
                }
                if !design.anchors.isEmpty {
                    Button("Clear All") { design.clearAnchors() }
                }
                Spacer()
            }
        }
    }

    private var limitControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Correction limits")
                .font(.system(size: 12, weight: .medium))

            slider("Maximum cut", value: Binding(
                get: { design.options.maxCutDb },
                set: { design.options.maxCutDb = $0 }),
                   range: 3...24, format: "%.0f dB",
                   help: "Cutting is cheap: it costs headroom but cannot ask the "
                       + "speaker for anything it cannot give.")

            slider("Maximum boost", value: Binding(
                get: { design.options.boostLimitDb },
                set: { design.options.boostLimitDb = $0 }),
                   range: 0...12, format: "%.0f dB",
                   help: "Boosting asks a driver for output it may not have. Zero, the "
                       + "default, means cut only - which is what most rooms want and "
                       + "what no room is harmed by.")

            Toggle("Allow shelving filters", isOn: Binding(
                get: { design.options.allowShelves },
                set: { design.options.allowShelves = $0 }))
                .font(.system(size: 12))

            note("Shelves fix a broad tonal tilt with one band where peaking filters "
                 + "would need several, leaving more of the budget for the room's "
                 + "actual problems.")
        }
    }

    private var curtainControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Correction band")
                .font(.system(size: 12, weight: .medium))

            slider("Low limit", value: Binding(
                get: { design.target.lowCurtainHz },
                set: { design.target.lowCurtainHz = $0 }),
                   range: 15...80, format: "%.0f Hz",
                   help: "Below this nothing is corrected. Chasing a null under a "
                       + "speaker's usable range spends the whole budget on a band "
                       + "nobody hears.")

            slider("High limit", value: Binding(
                get: { design.target.highCurtainHz },
                set: { design.target.highCurtainHz = $0 }),
                   range: 2000...20000, format: "%.0f Hz",
                   help: "Above this nothing is corrected. High-frequency detail in a "
                       + "measurement is mostly where the microphone was, not what "
                       + "the room does.")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Back") { model.step = .measurements }
            if design.isFitting {
                ProgressView().controlSize(.small)
                Text("Calculating.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if let message = design.errorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if design.isStale && !design.fits.isEmpty {
                Text("The target has changed since this was calculated.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Calculate Correction") { recompute() }
                .keyboardShortcut(.defaultAction)
                .disabled(design.isFitting || model.run.usablePositionCount == 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private func recompute() {
        design.recompute(from: model.run.session,
                         channels: model.selectedTargets.sorted(),
                         sampleRateHz: model.vm.sampleRateHz > 0
                            ? Double(model.vm.sampleRateHz) : 48000,
                         platform: RoomCorrectionCore.Platform(
                            platformName: model.vm.platformName))
        if !design.fits.isEmpty { model.step = .results }
    }

    // MARK: - Helpers

    private func slider(_ label: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        format: String,
                        help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .frame(width: 130, alignment: .leading)
                Slider(value: value, in: range)
                    .frame(width: 240)
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 90, alignment: .leading)
                Spacer()
            }
            .font(.system(size: 12))
            Text(help)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 130)
        }
    }

    private func formSection<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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

/// The target curve, over the measured average where one exists.
///
/// The vertical scale is fitted to what is drawn rather than fixed: a warm
/// preset with bass lift spans well over 18 dB end to end, and a fixed window
/// clips it flat against the top of the box.
private struct TargetCurvePlot: View {
    let target: [Double]
    let measured: [Double]
    let frequencies: [Double]
    let anchors: [CorrectionDesign.Anchor]

    /// Centre and half-range, in dB, chosen to fit what is actually drawn.
    ///
    /// A fixed window clips: a warm preset with bass lift covers well over 18 dB
    /// end to end, and a curve pinned flat against the top of its box tells the
    /// user nothing about the shape they just chose.
    private var scale: (centre: Double, halfRange: Double) {
        let values = target.isEmpty ? measuredCentred : target
        guard let low = values.min(), let high = values.max() else { return (0, 9) }
        let centre = (low + high) / 2
        // Never tighter than +-6 dB, so a nearly flat curve does not have its
        // own rounding blown up into a dramatic-looking wiggle.
        let halfRange = max(6, (high - low) / 2 * 1.25)
        return (centre, halfRange)
    }

    /// The measured curve re-referenced to its own mean, so it sits behind the
    /// target rather than wherever its absolute level happens to be.
    private var measuredCentred: [Double] {
        guard !measured.isEmpty else { return [] }
        let mean = measured.reduce(0, +) / Double(measured.count)
        return measured.map { $0 - mean + scaleCentreForMeasured }
    }

    /// Measured content is referenced to the target's centre so both curves
    /// share one axis.
    private var scaleCentreForMeasured: Double {
        guard let low = target.min(), let high = target.max() else { return 0 }
        return (low + high) / 2
    }

    var body: some View {
        let (centre, halfRange) = scale
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.12))
                grid(in: size, centre: centre, halfRange: halfRange)
                if measured.count == frequencies.count && !measured.isEmpty {
                    path(measuredCentred, in: size, centre: centre, halfRange: halfRange)
                        .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                }
                if target.count == frequencies.count && !target.isEmpty {
                    path(target, in: size, centre: centre, halfRange: halfRange)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
                anchorMarks(in: size, centre: centre, halfRange: halfRange)
                labels(in: size, centre: centre, halfRange: halfRange)
            }
        }
    }

    // MARK: - Furniture

    private func grid(in size: CGSize, centre: Double, halfRange: Double) -> some View {
        // Decade lines and a few dB lines. A full third-octave grid behind a
        // two-line plot is more ink than information.
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
                .stroke(Color.primary.opacity(db == centre ? 0.18 : 0.08), lineWidth: 1)
            }
        }
    }

    private func labels(in size: CGSize, centre: Double, halfRange: Double) -> some View {
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
                    .position(x: 18,
                              y: position(ofDb: db, in: size.height, centre: centre,
                                          halfRange: halfRange))
            }
        }
    }

    /// Round dB gridlines inside the visible range, relative to its centre.
    private func dbLines(centre: Double, halfRange: Double) -> [Double] {
        let step: Double = halfRange > 15 ? 10 : (halfRange > 8 ? 5 : 2)
        var lines: [Double] = [centre]
        var offset = step
        while offset < halfRange {
            lines.append(centre + offset)
            lines.append(centre - offset)
            offset += step
        }
        return lines.sorted()
    }

    private func anchorMarks(in size: CGSize, centre: Double,
                             halfRange: Double) -> some View {
        ForEach(anchors) { anchor in
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .position(x: position(ofHz: anchor.freqHz, in: size.width),
                          y: min(max(position(ofDb: centre + anchor.gainDb,
                                              in: size.height, centre: centre,
                                              halfRange: halfRange), 3),
                                 size.height - 3))
        }
    }

    // MARK: - Mapping

    private func path(_ values: [Double], in size: CGSize,
                      centre: Double, halfRange: Double) -> Path {
        Path { path in
            for (index, value) in values.enumerated() where index < frequencies.count {
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

    /// Log frequency, because that is how hearing works and how every other
    /// tool in this field draws it - a linear axis would put half the picture
    /// above 10 kHz, where almost nothing worth correcting happens.
    private func position(ofHz hz: Double, in width: CGFloat) -> CGFloat {
        guard let low = frequencies.first, let high = frequencies.last, high > low else {
            return 0
        }
        let fraction = (log10(hz) - log10(low)) / (log10(high) - log10(low))
        return width * CGFloat(min(max(fraction, 0), 1))
    }
}
