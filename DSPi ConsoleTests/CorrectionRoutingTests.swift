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

    func testBassManagedSurroundCanNowBeMeasuredPerSpeakerToo() {
        // The earlier design refused this, because no input reaches the L
        // speaker alone. Output mode no longer hunts for an isolating path, it
        // forces one, so every enabled output is measurable.
        let plan = bassManagedFiveOne().outputPlan()

        XCTAssertEqual(plan.targets.count, 9, "every enabled output is reachable")
        XCTAssertTrue(plan.obstacles.isEmpty)

        // Only the target output is excited: the forced path routes nothing else.
        XCTAssertEqual(plan.target(at: 0)?.excitedOutputs, [0])
        XCTAssertEqual(plan.target(at: 8)?.excitedOutputs, [8])
    }

    func testForcedPathBypassesBothEndsButNotTheCrossover() {
        // The asymmetry that matters: the correction replaces the output PEQ,
        // so bypassing it is consistent. It does not replace the crossover, so
        // bypassing that would describe a response the speaker never produces.
        let path = bassManagedFiveOne().forcedPath(forOutput: 2)

        XCTAssertEqual(path.targetOutput, 2)
        XCTAssertEqual(path.bypassInputBank, path.driveInput)
        XCTAssertEqual(path.bypassOutputBank, 2)
        XCTAssertTrue(path.bypassCrossoversOn.isEmpty, "never bypassed by default")
    }

    func testCrossoverBypassIsOnlyEverOptIn() {
        let path = bassManagedFiveOne().forcedPath(forOutput: 2, bypassCrossovers: true)
        XCTAssertEqual(path.bypassCrossoversOn, [2])
    }

    func testForcedPathPrefersAnInputAlreadyWiredToTheOutput() {
        // Purely so the temporary configuration differs as little as possible
        // from what the user had.
        let subject = validator(matrix([(0, 0), (1, 1), (2, 2)]), activeInputs: 3)
        XCTAssertEqual(subject.forcedPath(forOutput: 2).driveInput, 2)

        // Where nothing is wired to it, fall back to an input that exists.
        let unwired = validator(matrix([(0, 0)]), activeInputs: 2)
        XCTAssertEqual(unwired.forcedPath(forOutput: 5).driveInput, 0)
    }

    func testBassManagedSystemDefaultsToInputMode() {
        // Both modes work now, but a bass-managed system is a system, and
        // measuring it as one is what the user almost certainly wants.
        XCTAssertEqual(bassManagedFiveOne().suggestedMode(), .inputChannels)
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
        // Two outputs on a two-output platform, so the counts are unambiguous.
        let subject = validator(matrix(inputs: 2, outputs: 2, [(0, 0), (1, 1)]), outputs: 2)

        let outputs = subject.outputPlan()
        XCTAssertEqual(outputs.targets.count, 2)
        XCTAssertEqual(outputs.target(at: 0)?.driveInput, 0,
                       "the forced path prefers the input already wired to it")
        XCTAssertEqual(outputs.target(at: 1)?.driveInput, 1)

        let inputs = subject.inputPlan()
        XCTAssertEqual(inputs.targets.count, 2)

        // A plain stereo pair is the familiar per-speaker mental model.
        XCTAssertEqual(subject.suggestedMode(), .outputChannels)
    }

    func testAnInputThatReachesNothingIsNotMeasurable() {
        let plan = validator(matrix([(0, 0)]), activeInputs: 2).inputPlan()
        XCTAssertEqual(plan.targets.count, 1)
        guard case .inputReachesNothing? = plan.obstacle(at: 1) else {
            return XCTFail("expected a reaches-nothing obstacle")
        }
    }

    func testEverySpeakerIsMeasurableWhenOutputsFeedDifferentThings() {
        // Speakers on outputs 0/1, headphones on 2/3. All four measurable, and
        // each excites only itself.
        let plan = validator(matrix([(0, 0), (1, 1), (2, 2), (3, 3)]),
                             activeInputs: 4).outputPlan()
        for output in 0..<4 {
            XCTAssertEqual(plan.target(at: output)?.excitedOutputs, [output])
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
        // Output mode refuses it too, for the honest reason.
        guard case .outputDisabled? = subject.outputPlan().obstacle(at: 0) else {
            return XCTFail("a disabled output should say it is disabled")
        }
    }

    func testDisabledOutputsAreExcludedFromFanout() {
        // The sub is switched off, so front left is a plain one-to-one path
        // again and becomes isolatable.
        var enabled = Array(repeating: true, count: 9)
        enabled[8] = false
        let subject = validator(matrix([(0, 0), (0, 8), (1, 1), (1, 8)]), enabled: enabled)

        XCTAssertEqual(subject.outputsFedBy(0), [0],
                       "a disabled output must not count as fan-out")

        // Output mode reaches every enabled output; only the disabled one is
        // refused, and for the honest reason.
        let plan = subject.outputPlan()
        XCTAssertNil(plan.target(at: 8))
        guard case .outputDisabled? = plan.obstacle(at: 8) else {
            return XCTFail("the disabled subwoofer should say so")
        }
        XCTAssertNotNil(plan.target(at: 0))
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

    func testOutputModeSurvivesAStereoCoreAudioMode() {
        // Output mode drives one path at a time, so a stereo-configured device
        // can still measure every output. This is the reason for stepping
        // rather than wiring several paths at once.
        let subject = validator(matrix([(0, 0), (1, 1), (2, 2)]),
                                activeInputs: 3, addressable: 2)
        XCTAssertEqual(subject.outputPlan().targets.count, 9)
        // Output 2's usual feed is not addressable, so it falls back.
        XCTAssertLessThan(subject.forcedPath(forOutput: 2).driveInput, 2)
    }

    func testNothingIsMeasurableWithNoAddressableChannels() {
        let subject = validator(matrix([(0, 0)]), addressable: 0)
        XCTAssertFalse(subject.outputPlan().isUsable)
        XCTAssertFalse(subject.inputPlan().isUsable)
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
            .outputDisabled(outputIndex: 3),
            .notAddressable(index: 4, addressableInputs: 2),
            .upmixerActive
        ]
        for obstacle in obstacles {
            let text = obstacle.describe(outputName: outputName, inputName: inputName)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("index"), text)
        }

        let disabled = RoutingObstacle.outputDisabled(outputIndex: 8)
        XCTAssertTrue(disabled.describe(outputName: outputName, inputName: inputName)
            .contains("Subwoofer"))
    }

    func testDomainsDescribeWhenToUseThem() {
        for domain in MeasurementMode.allCases {
            XCTAssertFalse(domain.displayName.isEmpty)
            XCTAssertFalse(domain.summary.isEmpty)
        }
        XCTAssertTrue(MeasurementMode.inputChannels.summary.lowercased().contains("surround"))
    }

    func testAnEmptyMatrixStillAllowsOutputMode() {
        // Nothing is wired, so no input reaches anything and input mode has
        // nothing to measure. Output mode is unaffected: it builds the path it
        // needs rather than relying on one existing, which is the whole point
        // of forcing it.
        let empty = validator(matrix(inputs: 2, outputs: 2, []), activeInputs: 2, outputs: 2)
        XCTAssertFalse(empty.inputPlan().isUsable)
        XCTAssertTrue(empty.outputPlan().isUsable)
        XCTAssertEqual(empty.suggestedMode(), .outputChannels)
    }

    func testOutOfRangeQueriesAreHarmless() {
        let subject = validator(matrix(inputs: 2, outputs: 2, [(0, 0)]),
                                activeInputs: 2, outputs: 2)
        XCTAssertEqual(subject.outputsFedBy(99), [])
        XCTAssertEqual(subject.inputsFeeding(99), [])
        XCTAssertFalse(subject.isOutputUsable(99))
        XCTAssertEqual(subject.outputsFedBy(-1), [])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Crossover disclosure

extension CorrectionRoutingTests {

    func testCrossoverDisclosureStatesBothConsequences() {
        // The user is choosing whether to bypass a filter that may be
        // protecting a driver. Both consequences have to be on the screen: the
        // hardware risk, and that the correction will not match once the
        // crossover comes back.
        let highPass = CrossoverDisclosure(outputIndex: 1,
                                           description: "8th-order high-pass at 2.0 kHz",
                                           isHighPass: true,
                                           cornerHz: 2000)
        let consequences = highPass.bypassConsequences(sweepStartHz: 20)
        XCTAssertEqual(consequences.count, 2)
        XCTAssertTrue(consequences[0].contains("20 Hz"), consequences[0])
        XCTAssertTrue(consequences[0].lowercased().contains("no high-pass protection"),
                      consequences[0])
        XCTAssertTrue(consequences[1].lowercased().contains("differ"), consequences[1])
    }

    func testLowPassDisclosureOmitsTheProtectionWarning() {
        // A low-pass does not protect a driver from a sweep, so claiming it
        // does would be crying wolf.
        let lowPass = CrossoverDisclosure(outputIndex: 8,
                                          description: "4th-order low-pass at 80 Hz",
                                          isHighPass: false,
                                          cornerHz: 80)
        let consequences = lowPass.bypassConsequences(sweepStartHz: 20)
        XCTAssertEqual(consequences.count, 1)
        XCTAssertTrue(consequences[0].lowercased().contains("differ"))
    }
}
