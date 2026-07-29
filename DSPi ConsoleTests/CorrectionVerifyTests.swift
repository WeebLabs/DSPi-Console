import XCTest
@testable import DSPi_Console

/// Covers what a verification result means.
///
/// The sweep itself is the measurement path, already covered elsewhere. What is
/// specific here is the judgement: whether the measured response agreeing with
/// the prediction is decided on shape rather than level, and whether a channel
/// that cannot honestly be compared says so instead of failing.
final class CorrectionVerifyTests: XCTestCase {

    private func result(worst: Double, rms: Double,
                        crossoverBypassed: Bool = false) -> VerificationResult {
        VerificationResult(speakerIndex: 0,
                           measuredDb: [], predictedDb: [], targetDb: [],
                           worstDeviationDb: worst,
                           rmsDeviationDb: rms,
                           crossoverWasBypassed: crossoverBypassed)
    }

    func testACloseMatchAgreesWithThePrediction() {
        let value = result(worst: 2.5, rms: 0.9)
        XCTAssertTrue(value.agreesWithPrediction)
        XCTAssertTrue(value.summary.contains("matches"), value.summary)
        XCTAssertTrue(value.summary.contains("0.9"), value.summary)
    }

    func testALargeDisagreementPointsAtThePathRatherThanTheCorrection() {
        // A verification failure almost never means the filters are wrong. It
        // means the sweep did not go where it was supposed to, so the advice
        // has to send the user to the routing rather than back to the target.
        let value = result(worst: 12, rms: 6)
        XCTAssertFalse(value.agreesWithPrediction)
        XCTAssertTrue(value.summary.contains("routing"), value.summary)
    }

    func testTheThresholdIsOnTheRmsRatherThanTheWorstBin() {
        // One bin missing by a lot is a null moving a few centimetres. Judging
        // on the worst bin would fail almost every honest verification.
        let value = result(worst: 9, rms: 1.2)
        XCTAssertTrue(value.agreesWithPrediction,
                      "a single bad bin must not fail an otherwise good match")
    }

    func testABypassedCrossoverIsExplainedRatherThanFailed() {
        // Verification measures the real configuration with the crossover back
        // on, so it cannot match a prediction made without it. Reporting that
        // as a failure would blame the user for a choice the app offered them.
        let value = result(worst: 14, rms: 8, crossoverBypassed: true)
        XCTAssertTrue(value.summary.contains("crossover"), value.summary)
        XCTAssertFalse(value.summary.contains("routing"),
                       "it must not send the user chasing a routing problem")
    }

    func testTheBoundaryIsInclusive() {
        XCTAssertTrue(result(worst: 5, rms: 3.0).agreesWithPrediction)
        XCTAssertFalse(result(worst: 5, rms: 3.01).agreesWithPrediction)
    }
}
