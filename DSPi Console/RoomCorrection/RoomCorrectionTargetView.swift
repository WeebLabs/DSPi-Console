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

            slider("Strength", value: Binding(
                get: { design.options.strength * 100 },
                set: { design.options.strength = $0 / 100 }),
                   range: 20...100, format: "%.0f%%",
                   help: "How much of the gap between your room and the target to "
                       + strengthDescription)

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

    /// Names what the current setting means, since a percentage on its own does
    /// not tell anyone whether they have gone too far.
    private var strengthDescription: String {
        switch design.options.strength {
        case ..<0.45:
            return "close. At this setting the correction is a light touch - "
                 + "useful when a full correction measures well but sounds "
                 + "over-processed."
        case ..<0.8:
            return "close. Partial correction, which often keeps more of a "
                 + "speaker's character while still fixing the worst of the room."
        default:
            return "close. Full correction, which is the right default: the fit "
                 + "already declines to chase what it cannot fix."
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
private struct TargetCurvePlot: View {
    let target: [Double]
    let measured: [Double]
    let frequencies: [Double]
    let anchors: [CorrectionDesign.Anchor]

    /// The measured curve re-referenced to the target's centre, so it sits
    /// behind the target rather than wherever its absolute level happens to
    /// be - which says nothing about shape.
    private var measuredCentred: [Double] {
        guard !measured.isEmpty, let low = target.min(), let high = target.max() else {
            return []
        }
        let mean = measured.reduce(0, +) / Double(measured.count)
        let targetCentre = (low + high) / 2
        return measured.map { $0 - mean + targetCentre }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let axis = FrequencyAxis(frequencies: frequencies)
            let scale = FrequencyPlotScale(fitting: target.isEmpty ? measuredCentred : target,
                                           minimumHalfRange: 6, padding: 1.25)
            ZStack {
                FrequencyPlotBackground(axis: axis, scale: scale)
                axis.path(measuredCentred, scale: scale, in: size)
                    .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                axis.path(target, scale: scale, in: size)
                    .stroke(Color.accentColor, lineWidth: 2)

                ForEach(anchors) { anchor in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .position(x: axis.x(forHz: anchor.freqHz, in: size.width),
                                  y: scale.clampedY(forDb: scale.centre + anchor.gainDb,
                                                    in: size.height))
                }
            }
        }
    }
}
