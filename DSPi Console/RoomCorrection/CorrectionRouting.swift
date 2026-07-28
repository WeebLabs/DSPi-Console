import Foundation

/// What a measurement session drives, and where its filters go.
///
/// Everything here follows from one fact: **host playback can only drive
/// inputs.** The DSPi presents itself to CoreAudio as an output device whose
/// channels are the DSPi's USB *inputs*, so a sweep always enters at an input
/// and emerges wherever the matrix, crossovers and bass management send it.
///
/// Full design and reasoning: `Documentation/room_correction_measurement_modes.md`.
enum MeasurementMode: String, CaseIterable, Codable {
    /// Drive one input channel and measure the complete acoustic result of that
    /// program channel, across however many drivers reproduce it.
    ///
    /// What 3.1, 5.1 and 7.1 need, and what a multi-way speaker needs. Bass
    /// management splitting front left into a high-passed speaker and a
    /// low-passed subwoofer is the normal case, not an obstacle.
    case inputChannels

    /// Force a known path from one input to one target output, and measure that
    /// speaker alone.
    ///
    /// For individual speakers, and for systems where outputs feed different
    /// things. A multi-way speaker cannot be meaningfully corrected this way,
    /// since it measures drivers rather than their summed result.
    case outputChannels

    var displayName: String {
        switch self {
        case .inputChannels: return "Input channels"
        case .outputChannels: return "Output channels"
        }
    }

    var summary: String {
        switch self {
        case .inputChannels:
            return "Measure each program channel through your whole speaker system, "
                 + "including bass management, and correct the input. Use this for "
                 + "surround layouts and multi-way speakers."
        case .outputChannels:
            return "Measure each speaker on its own through a temporary direct path, "
                 + "and correct that output. Use this for individual speakers, or when "
                 + "outputs feed different things such as speakers and headphones."
        }
    }
}

/// One thing the session will measure.
struct MeasurementTarget: Identifiable, Equatable {
    /// Index in the mode's own numbering: an input index, or an output index.
    let index: Int
    /// USB input channel a sweep must be played into.
    let driveInput: Int
    /// Outputs that will make sound. More than one is normal in input mode and
    /// means bass management is doing its job.
    let excitedOutputs: [Int]

    var id: Int { index }
}

/// Why a target cannot be measured.
enum RoutingObstacle: Equatable {
    /// Nothing is routed from this input, so driving it would be silent.
    case inputReachesNothing(inputIndex: Int)
    /// The output is switched off in the matrix and would render silence.
    case outputDisabled(outputIndex: Int)
    /// The host cannot address the input needed to drive this target.
    case notAddressable(index: Int, addressableInputs: Int)
    /// The upmixer derives channels downstream of the input EQ, so a correction
    /// on one input also changes what is derived from it.
    case upmixerActive

    func describe(outputName: (Int) -> String, inputName: (Int) -> String) -> String {
        switch self {
        case .inputReachesNothing(let input):
            return "\(inputName(input)) is not routed to any enabled output, so it "
                 + "would play silence."
        case .outputDisabled(let output):
            return "\(outputName(output)) is switched off in the matrix mixer, so it "
                 + "would render silence."
        case .notAddressable(_, let addressable):
            return "The device is configured for \(addressable) channel"
                 + (addressable == 1 ? "" : "s")
                 + " in Audio MIDI Setup, so this one cannot be driven."
        case .upmixerActive:
            return "The stereo upmixer derives channels downstream of the input EQ, so "
                 + "correcting an input also changes the channels derived from it."
        }
    }
}

/// What a mode can measure, and what it cannot.
struct RoutingPlan: Equatable {
    let mode: MeasurementMode
    let targets: [MeasurementTarget]
    /// Keyed by the mode's index.
    let obstacles: [Int: RoutingObstacle]
    /// Applies to the plan rather than one target.
    let warnings: [RoutingObstacle]

    var isUsable: Bool { !targets.isEmpty }

    func target(at index: Int) -> MeasurementTarget? { targets.first { $0.index == index } }
    func obstacle(at index: Int) -> RoutingObstacle? { obstacles[index] }
}

/// The temporary device configuration one output-mode sweep needs.
///
/// Output mode does not hunt for a path that happens to exist; it makes one.
/// Stated as a value so it can be applied, restored and tested without a device.
struct ForcedPath: Equatable {
    /// USB input to drive.
    let driveInput: Int
    /// The only output that should be routed from it.
    let targetOutput: Int
    /// Input PEQ bank to bypass: the driven input is synthetic, so whatever the
    /// user has on it is irrelevant and would only colour the measurement.
    let bypassInputBank: Int
    /// Output PEQ bank to bypass. Safe because the correction replaces it.
    let bypassOutputBank: Int
    /// Crossovers the user chose to bypass. Empty unless they opted in.
    let bypassCrossoversOn: [Int]
}

/// Reads the live matrix and works out what each mode can measure.
///
/// Pure logic over a snapshot rather than the view model, so it tests without a
/// device and so a saved project can re-validate before anything is written.
struct RoutingValidator {
    /// `routing[input][output]`, as `DSPViewModel.matrixRouting` holds it.
    let routing: [[Bool]]
    let activeInputCount: Int
    let outputCount: Int
    let outputEnabled: [Bool]
    let upmixerActive: Bool
    /// Channels the host can address on the playback device, from the
    /// configured CoreAudio mode.
    let addressableInputs: Int

    init(routing: [[Bool]],
         activeInputCount: Int,
         outputCount: Int,
         outputEnabled: [Bool],
         upmixerActive: Bool,
         addressableInputs: Int? = nil) {
        self.routing = routing
        self.activeInputCount = activeInputCount
        self.outputCount = outputCount
        self.outputEnabled = outputEnabled
        self.upmixerActive = upmixerActive
        self.addressableInputs = addressableInputs ?? activeInputCount
    }

    // MARK: Matrix queries

    func isOutputUsable(_ output: Int) -> Bool {
        output >= 0 && output < outputCount
            && output < outputEnabled.count && outputEnabled[output]
    }

    /// Outputs an input feeds, ignoring ones switched off.
    func outputsFedBy(_ input: Int) -> [Int] {
        guard input >= 0, input < routing.count else { return [] }
        return (0..<min(outputCount, routing[input].count))
            .filter { routing[input][$0] && isOutputUsable($0) }
    }

    func inputsFeeding(_ output: Int) -> [Int] {
        (0..<min(activeInputCount, routing.count)).filter { input in
            output < routing[input].count && routing[input][output]
        }
    }

    // MARK: Plans

    /// What input mode can measure: an input that reaches something audible.
    func inputPlan() -> RoutingPlan {
        var targets: [MeasurementTarget] = []
        var obstacles: [Int: RoutingObstacle] = [:]

        for input in 0..<activeInputCount {
            if input >= addressableInputs {
                obstacles[input] = .notAddressable(index: input,
                                                   addressableInputs: addressableInputs)
                continue
            }
            let outputs = outputsFedBy(input)
            if outputs.isEmpty {
                obstacles[input] = .inputReachesNothing(inputIndex: input)
                continue
            }
            targets.append(MeasurementTarget(index: input,
                                             driveInput: input,
                                             excitedOutputs: outputs))
        }

        return RoutingPlan(mode: .inputChannels,
                           targets: targets,
                           obstacles: obstacles,
                           warnings: upmixerActive ? [.upmixerActive] : [])
    }

    /// What output mode can measure.
    ///
    /// Every enabled output, because the path is forced rather than discovered.
    /// The only requirements are that the output is switched on and that the
    /// host can address at least one input to drive it with.
    func outputPlan() -> RoutingPlan {
        var targets: [MeasurementTarget] = []
        var obstacles: [Int: RoutingObstacle] = [:]

        guard addressableInputs > 0 else {
            for output in 0..<outputCount {
                obstacles[output] = .notAddressable(index: output, addressableInputs: 0)
            }
            return RoutingPlan(mode: .outputChannels, targets: [],
                               obstacles: obstacles, warnings: [])
        }

        for output in 0..<outputCount {
            guard isOutputUsable(output) else {
                obstacles[output] = .outputDisabled(outputIndex: output)
                continue
            }
            targets.append(MeasurementTarget(index: output,
                                             driveInput: driveInput(for: output),
                                             excitedOutputs: [output]))
        }

        return RoutingPlan(mode: .outputChannels,
                           targets: targets,
                           obstacles: obstacles,
                           warnings: [])
    }

    /// Which input to drive for an output-mode sweep.
    ///
    /// Prefers an input already wired to that output, purely so the forced
    /// configuration differs as little as possible from what the user had.
    /// Falls back to input 0, which is always addressable when anything is.
    func driveInput(for output: Int) -> Int {
        let existing = inputsFeeding(output).first { $0 < addressableInputs }
        return existing ?? 0
    }

    /// The temporary configuration one output-mode sweep needs.
    func forcedPath(forOutput output: Int,
                    bypassCrossovers: Bool = false) -> ForcedPath {
        let input = driveInput(for: output)
        return ForcedPath(driveInput: input,
                          targetOutput: output,
                          bypassInputBank: input,
                          bypassOutputBank: output,
                          bypassCrossoversOn: bypassCrossovers ? [output] : [])
    }

    func plan(for mode: MeasurementMode) -> RoutingPlan {
        mode == .inputChannels ? inputPlan() : outputPlan()
    }

    /// Which mode to offer first.
    ///
    /// Input mode whenever a system looks multichannel or bass-managed, since
    /// that is the case output mode cannot serve. A plain stereo pair can use
    /// either, and per-speaker is the more familiar model there.
    func suggestedMode() -> MeasurementMode {
        let inputs = inputPlan()
        guard inputs.isUsable else { return .outputChannels }

        let hasFanout = inputs.targets.contains { $0.excitedOutputs.count > 1 }
        if hasFanout { return .inputChannels }
        return inputs.targets.count > 2 ? .inputChannels : .outputChannels
    }
}

extension RoutingValidator {
    /// Build from the live view model.
    ///
    /// `addressableInputs` comes from the configured CoreAudio mode: a device
    /// configured for stereo cannot be measured as 7.1 however the matrix is
    /// wired.
    init(viewModel: DSPViewModel, addressableInputs: Int? = nil) {
        self.init(routing: viewModel.matrixRouting,
                  activeInputCount: viewModel.numMatrixInputs,
                  outputCount: viewModel.numOutputChannels,
                  outputEnabled: viewModel.outputEnabled,
                  upmixerActive: viewModel.upmixActive,
                  addressableInputs: addressableInputs)
    }
}

// MARK: - Crossover disclosure

/// A crossover the user should be told about before measuring.
///
/// Room correction never bypasses one by default. An automatic bypass would be
/// inert exactly when justified, since a user measuring genuinely full-range
/// speakers has no crossovers, and consequential exactly when it is not: it can
/// destroy a driver behind a protection filter, or produce a correction that
/// demands output in a band the crossover removes.
struct CrossoverDisclosure: Identifiable, Equatable {
    let outputIndex: Int
    /// Human-readable, e.g. "8th-order high-pass at 2.0 kHz".
    let description: String
    /// True for a high-pass, which is the case that can protect a driver.
    let isHighPass: Bool
    /// Corner frequency, for the warning text.
    let cornerHz: Double

    var id: Int { outputIndex }

    /// What bypassing this one would mean, stated so the user can decide.
    func bypassConsequences(sweepStartHz: Double) -> [String] {
        var consequences: [String] = []
        if isHighPass {
            consequences.append(String(
                format: "The sweep will play from %.0f Hz through this driver at "
                      + "measurement level, with no high-pass protection.",
                sweepStartHz))
        }
        consequences.append("The correction will be derived from this speaker without "
                            + "its crossover. Once the crossover is switched back on, "
                            + "the corrected response will differ from what was measured.")
        return consequences
    }
}
