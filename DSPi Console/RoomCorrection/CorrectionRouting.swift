import Foundation

/// What a measurement session measures, and where its filters go.
///
/// Everything here follows from one fact about the signal path: **host playback
/// can only drive inputs.** The DSPi presents itself to CoreAudio as an output
/// device whose channels are the DSPi's USB *inputs*, so a sweep always enters
/// at an input and comes out wherever the matrix, crossovers and bass
/// management send it.
///
/// That leaves two genuinely different things a user can want, and the
/// difference is not cosmetic.
///
/// See `Documentation/automated_room_correction_spec.md` section 4.3.
enum MeasurementDomain: String, CaseIterable, Codable {
    /// Drive one input channel and measure the complete acoustic result of
    /// that program channel, across however many drivers reproduce it.
    ///
    /// This is what a 5.1, 7.1 or 3.1 system needs. Bass management splits the
    /// front left channel into a high-passed L speaker and a low-passed
    /// subwoofer; driving input L and measuring what the room produces
    /// captures both, which is exactly the response that channel's correction
    /// should be built from. Fan-out is the normal case here, not a problem.
    case inputs

    /// Drive an input that reaches only one output, and measure that driver
    /// alone.
    ///
    /// This is what per-driver work needs: correcting one speaker without
    /// touching another fed from the same source, or a system where different
    /// outputs feed different things - speakers on one pair, headphones on
    /// another. It requires a path that isolates the output, which is what the
    /// validator checks.
    case outputs

    var displayName: String {
        switch self {
        case .inputs: return "Input channels"
        case .outputs: return "Output channels"
        }
    }

    var summary: String {
        switch self {
        case .inputs:
            return "Measure each program channel through your whole speaker system, "
                 + "including bass management, and correct the input. Use this for "
                 + "surround layouts where crossovers live on the outputs."
        case .outputs:
            return "Measure each speaker on its own and correct that output. Use this "
                 + "when outputs feed different things, such as speakers on one pair "
                 + "and headphones on another."
        }
    }
}

/// One thing the session will measure.
struct MeasurementTarget: Identifiable, Equatable {
    /// Index in the domain's own numbering: an input index, or an output index.
    let index: Int
    /// The USB input channel a sweep must be played into to excite it.
    let driveInput: Int
    /// Outputs that will actually make sound. More than one is normal in the
    /// input domain and means bass management is doing its job.
    let excitedOutputs: [Int]

    var id: Int { index }
}

/// Why a target cannot be measured.
enum RoutingObstacle: Equatable {
    /// Nothing is routed from this input, so driving it would be silent.
    case inputReachesNothing(inputIndex: Int)

    /// No input reaches this output at all.
    case outputHasNoInput(outputIndex: Int)

    /// Every input that feeds this output also feeds others, so the output
    /// cannot be excited on its own. Bass management produces this, and it is
    /// the signal that the input domain is the right choice rather than a
    /// reason to give up.
    case outputCannotBeIsolated(outputIndex: Int, sharedWith: [Int])

    /// The upmixer derives channels downstream of the input EQ, so a
    /// correction on one input also changes the channels derived from it.
    case upmixerActive

    func describe(outputName: (Int) -> String, inputName: (Int) -> String) -> String {
        switch self {
        case .inputReachesNothing(let input):
            return "\(inputName(input)) is not routed to any enabled output, so it "
                 + "would play silence."
        case .outputHasNoInput(let output):
            return "\(outputName(output)) has no input routed to it."
        case .outputCannotBeIsolated(let output, let sharedWith):
            let names = sharedWith.map(outputName).joined(separator: ", ")
            return "\(outputName(output)) cannot be measured on its own: every input "
                 + "that feeds it also feeds \(names). This is what bass management "
                 + "looks like - measure input channels instead."
        case .upmixerActive:
            return "The stereo upmixer derives channels downstream of the input EQ, so "
                 + "correcting an input also changes the channels derived from it."
        }
    }
}

/// What can be measured in a given domain, and what cannot.
struct RoutingPlan: Equatable {
    let domain: MeasurementDomain
    let targets: [MeasurementTarget]
    /// Keyed by the domain's index.
    let obstacles: [Int: RoutingObstacle]
    /// Applies to the whole plan rather than one target.
    let warnings: [RoutingObstacle]

    var isUsable: Bool { !targets.isEmpty }

    func target(at index: Int) -> MeasurementTarget? {
        targets.first { $0.index == index }
    }

    func obstacle(at index: Int) -> RoutingObstacle? { obstacles[index] }
}

/// Reads the live matrix and works out what each domain can measure.
///
/// Pure logic over a snapshot rather than the view model, so it tests without a
/// device and so a saved project can re-validate the routing it was calculated
/// against before anything is written back.
struct RoutingValidator {
    /// `routing[input][output]`, as `DSPViewModel.matrixRouting` holds it.
    let routing: [[Bool]]
    let activeInputCount: Int
    let outputCount: Int
    /// Outputs disabled in the matrix produce silence and cannot be measured.
    let outputEnabled: [Bool]
    let upmixerActive: Bool
    /// Channels the host can actually address on the playback device. Fewer
    /// than the matrix has means the configured CoreAudio mode is the limit.
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

    /// Outputs an input feeds, ignoring ones that are switched off.
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

    /// What the input domain can measure.
    ///
    /// Nearly everything: an input is measurable as long as it reaches
    /// something audible. Fan-out across several drivers is the point rather
    /// than an obstacle.
    func inputPlan() -> RoutingPlan {
        var targets: [MeasurementTarget] = []
        var obstacles: [Int: RoutingObstacle] = [:]

        for input in 0..<min(activeInputCount, addressableInputs) {
            let outputs = outputsFedBy(input)
            if outputs.isEmpty {
                obstacles[input] = .inputReachesNothing(inputIndex: input)
                continue
            }
            targets.append(MeasurementTarget(index: input,
                                             driveInput: input,
                                             excitedOutputs: outputs))
        }

        return RoutingPlan(domain: .inputs,
                           targets: targets,
                           obstacles: obstacles,
                           warnings: upmixerActive ? [.upmixerActive] : [])
    }

    /// What the output domain can measure.
    ///
    /// An output is only measurable on its own if some input reaches it and
    /// nothing else. Where that fails, the obstacle names the outputs it is
    /// tied to and points at the input domain, because a system with bass
    /// management is not broken - it is just not a per-driver system.
    func outputPlan() -> RoutingPlan {
        var targets: [MeasurementTarget] = []
        var obstacles: [Int: RoutingObstacle] = [:]

        for output in 0..<outputCount {
            guard isOutputUsable(output) else {
                obstacles[output] = .outputHasNoInput(outputIndex: output)
                continue
            }

            let feeders = inputsFeeding(output).filter { $0 < addressableInputs }
            if feeders.isEmpty {
                obstacles[output] = .outputHasNoInput(outputIndex: output)
                continue
            }

            // An input that reaches this output and nothing else lets us excite
            // it alone.
            if let isolating = feeders.first(where: { outputsFedBy($0) == [output] }) {
                targets.append(MeasurementTarget(index: output,
                                                 driveInput: isolating,
                                                 excitedOutputs: [output]))
            } else {
                let shared = Set(feeders.flatMap { outputsFedBy($0) })
                    .subtracting([output]).sorted()
                obstacles[output] = .outputCannotBeIsolated(outputIndex: output,
                                                            sharedWith: shared)
            }
        }

        return RoutingPlan(domain: .outputs,
                           targets: targets,
                           obstacles: obstacles,
                           warnings: upmixerActive ? [.upmixerActive] : [])
    }

    func plan(for domain: MeasurementDomain) -> RoutingPlan {
        domain == .inputs ? inputPlan() : outputPlan()
    }

    /// Which domain to offer first.
    ///
    /// The input domain whenever a system looks bass-managed or multichannel,
    /// because that is the case the output domain cannot serve at all. A plain
    /// one-to-one stereo pair can use either, and the output domain is the more
    /// familiar mental model there, so it wins.
    func suggestedDomain() -> MeasurementDomain {
        let outputs = outputPlan()
        let inputs = inputPlan()
        if !outputs.isUsable { return .inputs }
        // Anything the output domain cannot isolate means drivers are shared,
        // which is bass management or similar.
        let hasSharedDrivers = outputs.obstacles.values.contains {
            if case .outputCannotBeIsolated = $0 { return true }
            return false
        }
        if hasSharedDrivers { return .inputs }
        return inputs.targets.count > 2 ? .inputs : .outputs
    }
}

extension RoutingValidator {
    /// Build from the live view model.
    ///
    /// `addressableInputs` comes from the configured CoreAudio mode: the
    /// session can only drive channels the host can actually send to, and a
    /// device configured for stereo cannot be measured as 7.1 however the
    /// matrix is wired.
    init(viewModel: DSPViewModel, addressableInputs: Int? = nil) {
        self.init(routing: viewModel.matrixRouting,
                  activeInputCount: viewModel.numMatrixInputs,
                  outputCount: viewModel.numOutputChannels,
                  outputEnabled: viewModel.outputEnabled,
                  upmixerActive: viewModel.upmixActive,
                  addressableInputs: addressableInputs)
    }
}
