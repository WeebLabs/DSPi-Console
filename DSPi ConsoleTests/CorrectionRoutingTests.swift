import XCTest
@testable import DSPi_Console

/// Routing and measurement-domain tests
/// (automated_room_correction_spec.md section 4.3).
///
/// The case that drove this design is 5.1/7.1 with bass management: front left
/// splits into a high-passed L speaker and a low-passed subwoofer, so driving
/// input L excites two drivers. An earlier version treated that fan-out as a
/// disqualifier, which blocked the main surround use case outright. It is the
/// normal case, and the input domain exists to serve it.
final class CorrectionRoutingTests: XCTestCase {

    /// `routing[input][output]`.
    private func matrix(inputs: Int = 8, outputs: Int = 9,
                        _ pairs: [(input: Int, output: Int)]) -> [[Bool]] {
        var routing = Array(repeating: Array(repeating: false, count: outputs), count: inputs)
        for pair in pairs { routing[pair.input][pair.output] = true }
        return routing
    }

    private func validator(_ routing: [[Bool]],
                           activeInputs: Int = 2,
                           outputs: Int = 9,
                           enabled: [Bool]? = nil,
                           upmixer: Bool = false,
                           addressable: Int? = nil) -> RoutingValidator {
        RoutingValidator(routing: routing,
                         activeInputCount: activeInputs,
                         outputCount: outputs,
                         outputEnabled: enabled ?? Array(repeating: true, count: outputs),
                         upmixerActive: upmixer,
                         addressableInputs: addressable)
    }

    /// 5.1 with bass management: six program channels, five speakers plus a
    /// subwoofer, every channel also feeding the sub.
    private func bassManagedFiveOne() -> RoutingValidator {
        let sub = 8
        var pairs: [(input: Int, output: Int)] = []
        for channel in 0..<5 {
            pairs.append((channel, channel))   // its own speaker
            pairs.append((channel, sub))       // and the subwoofer
        }
        pairs.append((5, sub))                 // LFE straight to the sub
        return validator(matrix(pairs), activeInputs: 6)
    }

    // MARK: - The surround case

    func testBassManagedSurroundIsFullyMeasurableByInput() {
        // The case the earlier design refused outright.
        let plan = bassManagedFiveOne().inputPlan()

        XCTAssertTrue(plan.isUsable)
        XCTAssertEqual(plan.targets.count, 6, "every program channel must be measurable")
        XCTAssertTrue(plan.obstacles.isEmpty)

        // Front left excites its own speaker and the subwoofer, and measuring
        // both together is the whole point.
        let frontLeft = try? XCTUnwrap(plan.target(at: 0))
        XCTAssertEqual(frontLeft?.driveInput, 0)
        XCTAssertEqual(frontLeft?.excitedOutputs, [0, 8])

        // LFE reaches only the sub.
        XCTAssertEqual(plan.target(at: 5)?.excitedOutputs, [8])
    }

    func testBassManagedSurroundCannotBeMeasuredPerDriver() {
        // The counterpart: no input reaches the L speaker alone, so per-driver
        // measurement genuinely cannot isolate it. The obstacle has to say so
        // in a way that points somewhere useful.
        let plan = bassManagedFiveOne().outputPlan()

        guard case .outputCannotBeIsolated(_, let sharedWith)? = plan.obstacle(at: 0) else {
            return XCTFail("expected an isolation obstacle, got \(String(describing: plan.obstacle(at: 0)))")
        }
        XCTAssertTrue(sharedWith.contains(8), "should name the subwoofer it is tied to")

        let text = plan.obstacle(at: 0)!.describe(outputName: { "Out \($0 + 1)" },
                                                  inputName: { "In \($0 + 1)" })
        XCTAssertTrue(text.lowercased().contains("bass management"), text)
        XCTAssertTrue(text.lowercased().contains("input channels"), text)
    }

    func testBassManagedSystemDefaultsToTheInputDomain() {
        XCTAssertEqual(bassManagedFiveOne().suggestedDomain(), .inputs)
    }

    func testSevenOneIsFullyMeasurableByInput() {
        let sub = 8
        var pairs: [(input: Int, output: Int)] = []
        for channel in 0..<7 {
            pairs.append((channel, channel))
            pairs.append((channel, sub))
        }
        pairs.append((7, sub))
        let plan = validator(matrix(pairs), activeInputs: 8).inputPlan()

        XCTAssertEqual(plan.targets.count, 8)
        XCTAssertTrue(plan.obstacles.isEmpty)
    }

    func testThreeOneIsFullyMeasurableByInput() {
        let sub = 8
        let plan = validator(matrix([(0, 0), (0, sub), (1, 1), (1, sub),
                                     (2, 2), (2, sub), (3, sub)]),
                             activeInputs: 4).inputPlan()
        XCTAssertEqual(plan.targets.count, 4)
    }

    // MARK: - The per-driver case

    func testOneToOneStereoCanBeMeasuredEitherWay() {
        let subject = validator(matrix([(0, 0), (1, 1)]))

        let outputs = subject.outputPlan()
        XCTAssertEqual(outputs.targets.count, 2)
        XCTAssertEqual(outputs.target(at: 0)?.driveInput, 0,
                       "measuring output 0 means driving the input that reaches it")
        XCTAssertEqual(outputs.target(at: 1)?.driveInput, 1)

        let inputs = subject.inputPlan()
        XCTAssertEqual(inputs.targets.count, 2)

        // A plain stereo pair is the familiar per-driver mental model.
        XCTAssertEqual(subject.suggestedDomain(), .outputs)
    }

    func testSpeakersAndHeadphonesOnSeparateOutputsStayPerDriver() {
        // Inputs 0/1 to the speakers, inputs 2/3 to the headphone pair. Each
        // output has its own feed, so all four isolate.
        let subject = validator(matrix([(0, 0), (1, 1), (2, 2), (3, 3)]), activeInputs: 4)
        let plan = subject.outputPlan()
        XCTAssertEqual(plan.targets.map(\.index), [0, 1, 2, 3])

        // The platform has nine outputs and only four are wired, so the rest
        // legitimately carry an obstacle. What matters is that it is the
        // honest one - nothing feeds them - rather than an isolation failure.
        for output in 4..<9 {
            guard case .outputHasNoInput? = plan.obstacle(at: output) else {
                return XCTFail("output \(output) should report having no input")
            }
        }
    }

    func testAnOutputSharedByADownmixCannotBeIsolated() {
        // Two inputs both feeding output 0 and nothing else: driving either
        // excites only output 0, so it *can* be isolated.
        let shared = validator(matrix([(0, 0), (1, 0)])).outputPlan()
        XCTAssertEqual(shared.targets.count, 1)
        XCTAssertEqual(shared.target(at: 0)?.excitedOutputs, [0])

        // But an input that also feeds elsewhere cannot isolate it.
        let spread = validator(matrix([(0, 0), (0, 1)]), activeInputs: 1).outputPlan()
        guard case .outputCannotBeIsolated? = spread.obstacle(at: 0) else {
            return XCTFail("expected an isolation obstacle")
        }
    }

    // MARK: - Unroutable and disabled

    func testAnInputThatReachesNothingIsNotMeasurable() {
        let plan = validator(matrix([(0, 0)]), activeInputs: 2).inputPlan()
        XCTAssertEqual(plan.targets.count, 1)
        guard case .inputReachesNothing? = plan.obstacle(at: 1) else {
            return XCTFail("expected a reaches-nothing obstacle")
        }
    }

    func testADisabledOutputIsNotAudibleAndDoesNotCount() {
        // An output switched off in the matrix renders silence, so an input
        // that only feeds it reaches nothing.
        var enabled = Array(repeating: true, count: 9)
        enabled[0] = false
        let subject = validator(matrix([(0, 0), (1, 1)]), enabled: enabled)

        XCTAssertFalse(subject.isOutputUsable(0))
        guard case .inputReachesNothing? = subject.inputPlan().obstacle(at: 0) else {
            return XCTFail("an input feeding only a disabled output reaches nothing")
        }
        XCTAssertEqual(subject.outputPlan().targets.map(\.index), [1])
    }

    func testDisabledOutputsAreExcludedFromFanout() {
        // The sub is switched off, so front left is a plain one-to-one path
        // again and becomes isolatable.
        var enabled = Array(repeating: true, count: 9)
        enabled[8] = false
        let subject = validator(matrix([(0, 0), (0, 8), (1, 1), (1, 8)]), enabled: enabled)

        XCTAssertEqual(subject.outputsFedBy(0), [0])
        XCTAssertEqual(subject.outputPlan().targets.count, 2)
    }

    // MARK: - What the host can address

    func testAStereoCoreAudioModeLimitsWhatCanBeDriven() {
        // The matrix may be wired for 7.1, but a device configured for stereo
        // cannot be measured as 7.1 however it is wired: the host has nowhere
        // to send the other channels.
        let sub = 8
        var pairs: [(input: Int, output: Int)] = []
        for channel in 0..<7 { pairs.append((channel, channel)); pairs.append((channel, sub)) }

        let full = validator(matrix(pairs), activeInputs: 8).inputPlan()
        XCTAssertEqual(full.targets.count, 7)

        let limited = validator(matrix(pairs), activeInputs: 8, addressable: 2).inputPlan()
        XCTAssertEqual(limited.targets.count, 2,
                       "only the channels the host can address are measurable")
    }

    func testAddressableLimitAlsoConstrainsPerDriverMeasurement() {
        let subject = validator(matrix([(0, 0), (1, 1), (2, 2)]),
                                activeInputs: 3, addressable: 2)
        XCTAssertEqual(subject.outputPlan().targets.map(\.index), [0, 1])
    }

    // MARK: - Upmixer

    func testUpmixerIsAWarningRatherThanARefusal() {
        // It changes what a correction affects, but it does not make the
        // measurement impossible, and refusing outright would block a
        // legitimate setup.
        let plan = validator(matrix([(0, 0), (1, 1)]), upmixer: true).inputPlan()
        XCTAssertTrue(plan.isUsable)
        XCTAssertTrue(plan.warnings.contains(.upmixerActive))
    }

    // MARK: - Messages and boundaries

    func testEveryObstacleExplainsItselfInUserTerms() {
        let outputName: (Int) -> String = { $0 == 8 ? "Subwoofer" : "Out \($0 + 1)" }
        let inputName: (Int) -> String = { ["Front L", "Front R"][safe: $0] ?? "In \($0 + 1)" }

        let obstacles: [RoutingObstacle] = [
            .inputReachesNothing(inputIndex: 0),
            .outputHasNoInput(outputIndex: 3),
            .outputCannotBeIsolated(outputIndex: 0, sharedWith: [8]),
            .upmixerActive
        ]
        for obstacle in obstacles {
            let text = obstacle.describe(outputName: outputName, inputName: inputName)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("index"), text)
        }

        let isolation = RoutingObstacle.outputCannotBeIsolated(outputIndex: 0, sharedWith: [8])
        XCTAssertTrue(isolation.describe(outputName: outputName, inputName: inputName)
            .contains("Subwoofer"))
    }

    func testDomainsDescribeWhenToUseThem() {
        for domain in MeasurementDomain.allCases {
            XCTAssertFalse(domain.displayName.isEmpty)
            XCTAssertFalse(domain.summary.isEmpty)
        }
        XCTAssertTrue(MeasurementDomain.inputs.summary.lowercased().contains("surround"))
    }

    func testEmptyAndOutOfRangeInputsAreHarmless() {
        let empty = validator(matrix(inputs: 2, outputs: 2, []), activeInputs: 2, outputs: 2)
        XCTAssertFalse(empty.inputPlan().isUsable)
        XCTAssertFalse(empty.outputPlan().isUsable)
        XCTAssertEqual(empty.outputsFedBy(99), [])
        XCTAssertEqual(empty.inputsFeeding(99), [])
        XCTAssertFalse(empty.isOutputUsable(99))
        // With nothing measurable either way, fall back rather than trap.
        XCTAssertEqual(empty.suggestedDomain(), .inputs)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
