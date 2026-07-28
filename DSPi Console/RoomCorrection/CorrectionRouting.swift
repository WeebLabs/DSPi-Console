import Foundation

/// Where a room correction's filters are written.
///
/// Measurement is always per physical output, because that is where the
/// speakers are and it is fixed by the hardware. The destination is a separate
/// choice, because the right answer depends on the system: speakers on one
/// output pair and headphones on another need an output-side correction, or it
/// would leak onto the headphones; a surround layout with bass management on
/// the outputs needs an input-side one, so the output banks stay free for the
/// crossover work they already do.
///
/// See `Documentation/automated_room_correction_spec.md` section 4.3.
enum CorrectionDestination: String, CaseIterable, Codable {
    case outputs
    case inputs

    var displayName: String {
        switch self {
        case .outputs: return "Output channels"
        case .inputs: return "Input channels"
        }
    }

    var explanation: String {
        switch self {
        case .outputs:
            return "Filters are written to each measured speaker's own output bank. "
                 + "Use this when different outputs feed different things, such as "
                 + "speakers on one pair and headphones on another."
        case .inputs:
            return "Filters are written to the input channels feeding the measured "
                 + "speakers, upstream of the matrix. Use this when bass management "
                 + "or crossovers live on the outputs and should stay there."
        }
    }
}

/// Why an input-side correction is not available for a given selection.
///
/// These are refusals rather than warnings. An input-side correction is only
/// well posed when the chosen input reaches the measured output injectively;
/// where it is not, the correction derived from one speaker would be applied to
/// a signal feeding something else as well.
enum RoutingObstacle: Equatable {
    /// One input drives several outputs. Bass management is the common case:
    /// L splits into L-high plus Sub, so correcting input L also alters what
    /// the subwoofer receives, while the correction came from the L speaker
    /// alone.
    case inputFeedsMultipleOutputs(inputIndex: Int, outputIndices: [Int])

    /// Several inputs are summed into one output, so its measured response
    /// cannot be attributed to any single input.
    case outputFedByMultipleInputs(outputIndex: Int, inputIndices: [Int])

    /// No input reaches this output at all, so there is nothing upstream to
    /// correct.
    case outputHasNoInput(outputIndex: Int)

    /// The upmixer derives centre and surround channels from stereo and sits
    /// downstream of input EQ, so correcting L/R would also change the derived
    /// channels.
    case upmixerActive

    func describe(outputName: (Int) -> String, inputName: (Int) -> String) -> String {
        switch self {
        case .inputFeedsMultipleOutputs(let input, let outputs):
            let names = outputs.map(outputName).joined(separator: ", ")
            return "\(inputName(input)) feeds more than one output (\(names)), so a "
                 + "correction on it would also change the others."
        case .outputFedByMultipleInputs(let output, let inputs):
            let names = inputs.map(inputName).joined(separator: ", ")
            return "\(outputName(output)) is fed by more than one input (\(names)), so its "
                 + "measured response cannot be attributed to a single input."
        case .outputHasNoInput(let output):
            return "\(outputName(output)) has no input routed to it."
        case .upmixerActive:
            return "The stereo upmixer is active and derives channels downstream of the "
                 + "input EQ, so correcting an input would also change the channels "
                 + "derived from it."
        }
    }
}

/// The resolved mapping for a set of measured outputs.
struct RoutingResolution: Equatable {
    /// Measured output index to the single input feeding it, when one-to-one.
    let inputForOutput: [Int: Int]
    /// Everything preventing an input-side correction. Empty means it is
    /// available.
    let obstacles: [RoutingObstacle]

    var allowsInputDestination: Bool { obstacles.isEmpty && !inputForOutput.isEmpty }

    /// The destination to offer by default. Outputs always work, so they are
    /// the fallback whenever inputs are not available.
    var defaultDestination: CorrectionDestination {
        allowsInputDestination ? .inputs : .outputs
    }
}

/// Reads the live matrix and decides which destinations are usable.
///
/// Pure logic over a snapshot rather than a view model, so it is testable
/// without a device and so a saved project can re-validate the routing it was
/// calculated against before anything is written back.
struct RoutingValidator {
    /// `routing[input][output]`, as `DSPViewModel.matrixRouting` holds it.
    let routing: [[Bool]]
    let activeInputCount: Int
    let outputCount: Int
    /// Outputs that are disabled in the matrix produce silence, so they cannot
    /// be measured at all.
    let outputEnabled: [Bool]
    let upmixerActive: Bool

    init(routing: [[Bool]],
         activeInputCount: Int,
         outputCount: Int,
         outputEnabled: [Bool],
         upmixerActive: Bool) {
        self.routing = routing
        self.activeInputCount = activeInputCount
        self.outputCount = outputCount
        self.outputEnabled = outputEnabled
        self.upmixerActive = upmixerActive
    }

    /// Outputs that can be measured at all.
    func measurableOutputs() -> [Int] {
        (0..<outputCount).filter { output in
            guard output < outputEnabled.count, outputEnabled[output] else { return false }
            return inputsFeeding(output).isEmpty == false
        }
    }

    /// Why an output cannot be measured, if it cannot.
    func unmeasurableReason(for output: Int) -> String? {
        guard output < outputCount else { return "Not present on this device." }
        if output >= outputEnabled.count || !outputEnabled[output] {
            return "Disabled in the matrix mixer, so it would render silence."
        }
        if inputsFeeding(output).isEmpty {
            return "No input is routed to it, so nothing would play."
        }
        return nil
    }

    func inputsFeeding(_ output: Int) -> [Int] {
        (0..<min(activeInputCount, routing.count)).filter { input in
            output < routing[input].count && routing[input][output]
        }
    }

    func outputsFedBy(_ input: Int) -> [Int] {
        guard input < routing.count else { return [] }
        return (0..<min(outputCount, routing[input].count)).filter { routing[input][$0] }
    }

    /// Resolve the mapping for the outputs the user chose to measure.
    ///
    /// Note that `outputsFedBy` is evaluated against the whole matrix, not just
    /// the selected outputs: an input that also feeds a subwoofer the user did
    /// not select still disqualifies an input-side correction, because applying
    /// it would change the subwoofer too.
    func resolve(measuredOutputs: [Int]) -> RoutingResolution {
        var mapping: [Int: Int] = [:]
        var obstacles: [RoutingObstacle] = []

        if upmixerActive {
            obstacles.append(.upmixerActive)
        }

        for output in measuredOutputs {
            let inputs = inputsFeeding(output)
            if inputs.isEmpty {
                obstacles.append(.outputHasNoInput(outputIndex: output))
                continue
            }
            if inputs.count > 1 {
                obstacles.append(.outputFedByMultipleInputs(outputIndex: output,
                                                            inputIndices: inputs))
                continue
            }

            let input = inputs[0]
            let fanout = outputsFedBy(input)
            if fanout.count > 1 {
                obstacles.append(.inputFeedsMultipleOutputs(inputIndex: input,
                                                            outputIndices: fanout))
                continue
            }
            mapping[output] = input
        }

        return RoutingResolution(inputForOutput: mapping, obstacles: obstacles)
    }
}

extension RoutingValidator {
    /// Build from the live view model.
    ///
    /// Kept as a separate initializer so the validator itself stays free of the
    /// view model and remains testable without a device.
    init(viewModel: DSPViewModel) {
        self.init(routing: viewModel.matrixRouting,
                  activeInputCount: viewModel.numMatrixInputs,
                  outputCount: viewModel.numOutputChannels,
                  outputEnabled: viewModel.outputEnabled,
                  upmixerActive: viewModel.upmixActive)
    }
}
