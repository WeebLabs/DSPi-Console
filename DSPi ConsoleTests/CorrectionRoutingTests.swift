import XCTest
@testable import DSPi_Console

/// Routing validation for the correction destination
/// (automated_room_correction_spec.md section 4.3).
///
/// An input-side correction is only well posed when the chosen input reaches
/// the measured output injectively. These tests are the gate on that, and the
/// cases they cover are the ones that actually occur: bass management, a
/// downmix, and the upmixer.
final class CorrectionRoutingTests: XCTestCase {

    /// `routing[input][output]`, matching DSPViewModel.matrixRouting.
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
                           upmixer: Bool = false) -> RoutingValidator {
        RoutingValidator(routing: routing,
                         activeInputCount: activeInputs,
                         outputCount: outputs,
                         outputEnabled: enabled ?? Array(repeating: true, count: outputs),
                         upmixerActive: upmixer)
    }

    // MARK: - The clean case

    func testOneToOneStereoAllowsAnInputSideCorrection() {
        // L to output 0, R to output 1, nothing else.
        let routing = matrix([(0, 0), (1, 1)])
        let resolution = validator(routing).resolve(measuredOutputs: [0, 1])

        XCTAssertTrue(resolution.allowsInputDestination)
        XCTAssertEqual(resolution.obstacles, [])
        XCTAssertEqual(resolution.inputForOutput, [0: 0, 1: 1])
        XCTAssertEqual(resolution.defaultDestination, .inputs)
    }

    func testSevenPointOneMapsOneToOne() {
        let pairs = (0..<8).map { (input: $0, output: $0) }
        let resolution = validator(matrix(pairs), activeInputs: 8)
            .resolve(measuredOutputs: Array(0..<8))

        XCTAssertTrue(resolution.allowsInputDestination)
        XCTAssertEqual(resolution.inputForOutput.count, 8)
    }

    // MARK: - Bass management

    func testBassManagementBlocksAnInputSideCorrection() {
        // The motivating case from the spec: L feeds both its own output and
        // the subwoofer, so correcting input L would also change what the sub
        // receives, while the correction came from the L speaker alone.
        let routing = matrix([(0, 0), (1, 1), (0, 8), (1, 8)])
        let resolution = validator(routing).resolve(measuredOutputs: [0, 1])

        XCTAssertFalse(resolution.allowsInputDestination)
        XCTAssertEqual(resolution.defaultDestination, .outputs)
        XCTAssertTrue(resolution.obstacles.contains(
            .inputFeedsMultipleOutputs(inputIndex: 0, outputIndices: [0, 8])))
    }

    func testFanoutCountsEvenWhenTheExtraOutputIsNotMeasured() {
        // The subwoofer is not in the measured set, but applying a correction
        // to input L would still change it. Evaluating fan-out only across the
        // selected outputs would miss this and produce a silently wrong result.
        let routing = matrix([(0, 0), (0, 8)])
        let resolution = validator(routing, activeInputs: 1).resolve(measuredOutputs: [0])

        XCTAssertFalse(resolution.allowsInputDestination)
        XCTAssertTrue(resolution.obstacles.contains(
            .inputFeedsMultipleOutputs(inputIndex: 0, outputIndices: [0, 8])))
    }

    // MARK: - Downmix

    func testDownmixBlocksAnInputSideCorrection() {
        // Two inputs summed into one output: the measured response cannot be
        // attributed to either.
        let routing = matrix([(0, 0), (1, 0)])
        let resolution = validator(routing).resolve(measuredOutputs: [0])

        XCTAssertFalse(resolution.allowsInputDestination)
        XCTAssertTrue(resolution.obstacles.contains(
            .outputFedByMultipleInputs(outputIndex: 0, inputIndices: [0, 1])))
    }

    // MARK: - Upmixer

    func testUpmixerBlocksAnInputSideCorrectionEvenWhenRoutingIsClean() {
        // The upmixer sits downstream of input EQ, so correcting L/R also
        // changes the derived centre and surrounds. The routing itself looks
        // perfectly one-to-one, which is exactly why this needs its own check.
        let routing = matrix([(0, 0), (1, 1)])
        let resolution = validator(routing, upmixer: true).resolve(measuredOutputs: [0, 1])

        XCTAssertFalse(resolution.allowsInputDestination)
        XCTAssertTrue(resolution.obstacles.contains(.upmixerActive))
    }

    // MARK: - Unroutable and disabled outputs

    func testOutputWithNoInputIsNotMeasurable() {
        let routing = matrix([(0, 0)])
        let subject = validator(routing)

        XCTAssertEqual(subject.measurableOutputs(), [0])
        XCTAssertNotNil(subject.unmeasurableReason(for: 1))
        XCTAssertNil(subject.unmeasurableReason(for: 0))
    }

    func testDisabledOutputIsNotMeasurableAndSaysWhy() {
        // A matrix-disabled output renders silence. Discovering that at measure
        // time would present as a mystifying "no signal" failure, so setup has
        // to block it with the reason.
        var enabled = Array(repeating: true, count: 9)
        enabled[1] = false
        let subject = validator(matrix([(0, 0), (1, 1)]), enabled: enabled)

        XCTAssertEqual(subject.measurableOutputs(), [0])
        let reason = subject.unmeasurableReason(for: 1) ?? ""
        XCTAssertTrue(reason.lowercased().contains("disabled"), reason)
    }

    func testUnroutedOutputInTheMeasuredSetIsAnObstacle() {
        let resolution = validator(matrix([(0, 0)])).resolve(measuredOutputs: [0, 5])
        XCTAssertFalse(resolution.allowsInputDestination)
        XCTAssertTrue(resolution.obstacles.contains(.outputHasNoInput(outputIndex: 5)))
    }

    // MARK: - Boundaries

    func testInactiveInputsAreIgnored() {
        // Only the live input layout counts. A route from an input the current
        // layout does not carry must not create a phantom obstacle.
        let routing = matrix([(0, 0), (1, 1), (5, 0)])
        let resolution = validator(routing, activeInputs: 2).resolve(measuredOutputs: [0, 1])

        XCTAssertTrue(resolution.allowsInputDestination)
        XCTAssertEqual(resolution.inputForOutput, [0: 0, 1: 1])
    }

    func testEmptyMeasurementSetOffersOutputs() {
        let resolution = validator(matrix([(0, 0)])).resolve(measuredOutputs: [])
        XCTAssertFalse(resolution.allowsInputDestination)
        XCTAssertEqual(resolution.defaultDestination, .outputs)
    }

    func testResolutionSurvivesOutOfRangeIndices() {
        let subject = validator(matrix(inputs: 2, outputs: 4, [(0, 0)]),
                                activeInputs: 2, outputs: 4)
        XCTAssertNotNil(subject.unmeasurableReason(for: 99))
        let resolution = subject.resolve(measuredOutputs: [99])
        XCTAssertFalse(resolution.allowsInputDestination)
    }

    // MARK: - Messages

    func testObstaclesExplainThemselvesInUserTerms() {
        // These strings go straight into the setup screen, so they must name
        // the channels rather than print indices.
        let outputName: (Int) -> String = { $0 == 8 ? "Subwoofer" : "Out \($0 + 1)" }
        let inputName: (Int) -> String = { ["USB L", "USB R"][safe: $0] ?? "In \($0 + 1)" }

        let bassManagement = RoutingObstacle.inputFeedsMultipleOutputs(inputIndex: 0,
                                                                       outputIndices: [0, 8])
        let text = bassManagement.describe(outputName: outputName, inputName: inputName)
        XCTAssertTrue(text.contains("USB L"), text)
        XCTAssertTrue(text.contains("Subwoofer"), text)
        XCTAssertFalse(text.contains("index"), text)

        for obstacle: RoutingObstacle in [
            .outputFedByMultipleInputs(outputIndex: 0, inputIndices: [0, 1]),
            .outputHasNoInput(outputIndex: 3),
            .upmixerActive
        ] {
            XCTAssertFalse(obstacle.describe(outputName: outputName, inputName: inputName).isEmpty)
        }
    }

    func testDestinationsDescribeWhenToUseThem() {
        for destination in CorrectionDestination.allCases {
            XCTAssertFalse(destination.displayName.isEmpty)
            XCTAssertFalse(destination.explanation.isEmpty)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
