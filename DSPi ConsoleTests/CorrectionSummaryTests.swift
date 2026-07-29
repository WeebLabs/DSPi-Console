import XCTest
@testable import DSPi_Console

/// Covers the judgement the results screen makes: whether a correction is worth
/// applying, and what the user should be warned about before they do.
final class CorrectionSummaryTests: XCTestCase {

    // MARK: - Outcome

    func testAClearImprovementIsReportedAsOne() {
        let summary = CorrectionSummary(channel: 0, before: 6.4, after: 2.1,
                                        filterCount: 8)
        XCTAssertEqual(summary.outcome, .improved)
        XCTAssertEqual(summary.improvementDb, 4.3, accuracy: 1e-9)
        XCTAssertEqual(summary.improvementPercent, 67, accuracy: 1)
    }

    func testASmallChangeIsNotDressedUpAsASuccess() {
        // A tenth of a decibel is real arithmetic and inaudible. Calling it an
        // improvement teaches the user to distrust the number.
        let summary = CorrectionSummary(channel: 0, before: 2.0, after: 1.5,
                                        filterCount: 3)
        XCTAssertEqual(summary.outcome, .marginal)
        XCTAssertTrue(summary.explanation.contains("may not hear"),
                      summary.explanation)
    }

    func testNoImprovementIsSaidPlainly() {
        let summary = CorrectionSummary(channel: 0, before: 1.4, after: 1.4,
                                        filterCount: 0)
        XCTAssertEqual(summary.outcome, .noBenefit)
        XCTAssertTrue(summary.headline.lowercased().contains("no improvement"),
                      summary.headline)
        XCTAssertTrue(summary.explanation.contains("not do much"), summary.explanation)
    }

    func testAWorseResultIsNeverReportedAsProgress() {
        // The fit should not make things worse, but if it ever does, a negative
        // improvement rendered as a percentage would read as a large gain.
        let summary = CorrectionSummary(channel: 0, before: 2.0, after: 3.5,
                                        filterCount: 4)
        XCTAssertEqual(summary.outcome, .noBenefit)
        XCTAssertEqual(summary.improvementPercent, 0,
                       "a regression must not be shown as a positive percentage")
    }

    func testAnAlreadyPerfectRoomDoesNotDivideByZero() {
        let summary = CorrectionSummary(channel: 0, before: 0, after: 0,
                                        filterCount: 0)
        XCTAssertEqual(summary.improvementPercent, 0)
        XCTAssertEqual(summary.outcome, .noBenefit)
    }

    // MARK: - Cautions

    func testBoostIsAlwaysCalledOut() {
        // Boost is the one thing here that can ask a driver for output it does
        // not have, so it is never silent.
        let summary = CorrectionSummary(channel: 0, before: 6, after: 2,
                                        filterCount: 6, maxBoostDb: 3.5)
        XCTAssertTrue(summary.cautions.contains { $0.contains("Boosts by up to") },
                      "\(summary.cautions)")
        XCTAssertTrue(summary.cautions.first?.contains("headroom") ?? false,
                      "boost must be the first caution: \(summary.cautions)")
    }

    func testACutOnlyCorrectionRaisesNoBoostCaution() {
        let summary = CorrectionSummary(channel: 0, before: 6, after: 2,
                                        filterCount: 6, maxBoostDb: 0, maxCutDb: 8)
        XCTAssertFalse(summary.cautions.contains { $0.contains("Boosts") },
                       "\(summary.cautions)")
    }

    func testTrimIsExplainedRatherThanJustReported() {
        // A user seeing their level drop needs to know it is the cost of the
        // correction, not a fault.
        let summary = CorrectionSummary(channel: 0, before: 6, after: 2,
                                        filterCount: 6, trimDb: -4.5)
        let caution = summary.cautions.first { $0.contains("level") }
        XCTAssertNotNil(caution, "\(summary.cautions)")
        XCTAssertTrue(caution?.contains("not a fault") ?? false, caution ?? "")
        XCTAssertTrue(caution?.contains("4.5") ?? false,
                      "the amount must be stated: \(caution ?? "")")
    }

    func testAnUnestimatedTransitionIsDisclosed() {
        // A single position cannot tell a mode from a cancellation. Presenting
        // the fallback as a measurement would be inventing a number.
        let summary = CorrectionSummary(channel: 0, before: 6, after: 2,
                                        filterCount: 6, transitionEstimated: false)
        XCTAssertTrue(summary.cautions.contains { $0.contains("could not be estimated") },
                      "\(summary.cautions)")
    }

    func testAnEstimatedTransitionRaisesNoCaution() {
        let summary = CorrectionSummary(channel: 0, before: 6, after: 2,
                                        filterCount: 6, transitionEstimated: true)
        XCTAssertFalse(summary.cautions.contains { $0.contains("could not be estimated") })
    }

    func testACleanCorrectionHasNothingToWarnAbout() {
        let summary = CorrectionSummary(channel: 0, before: 6, after: 1.5,
                                        filterCount: 7, trimDb: 0, maxBoostDb: 0,
                                        maxCutDb: 6, transitionEstimated: true)
        XCTAssertTrue(summary.cautions.isEmpty, "\(summary.cautions)")
    }

    // MARK: - Which error figure is reported

    func testTheReliableErrorIsReportedRatherThanTheRaw() throws {
        // The raw worst-position error includes bands where the positions
        // disagree so completely that no filter could serve them all. Reporting
        // it would make every correction look like a failure.
        var corrected = dspi_rc_metrics()
        corrected.raw_worst_position_rmse_db = 9.0
        corrected.reliable_worst_position_rmse_db = 2.0
        corrected.active_filter_count = 6

        var uncorrected = dspi_rc_metrics()
        uncorrected.raw_worst_position_rmse_db = 14.0
        uncorrected.reliable_worst_position_rmse_db = 7.0

        let summary = CorrectionSummary(channel: 1,
                                        metrics: RoomCorrectionCore.Metrics(corrected),
                                        uncorrected: RoomCorrectionCore.Metrics(uncorrected),
                                        trimDb: -2,
                                        transitionHz: 180,
                                        transitionEstimated: true)

        XCTAssertEqual(summary.before, 7.0)
        XCTAssertEqual(summary.after, 2.0)
        XCTAssertEqual(summary.filterCount, 6)
    }

    func testBoostAndCutAreReadFromTheCombinedCorrection() {
        var metrics = dspi_rc_metrics()
        metrics.max_combined_correction_db = 2.5
        metrics.min_combined_correction_db = -9.0

        let summary = CorrectionSummary(channel: 0,
                                        metrics: RoomCorrectionCore.Metrics(metrics),
                                        uncorrected: RoomCorrectionCore.Metrics(dspi_rc_metrics()),
                                        trimDb: 0, transitionHz: 0,
                                        transitionEstimated: false)
        XCTAssertEqual(summary.maxBoostDb, 2.5)
        XCTAssertEqual(summary.maxCutDb, 9.0)
    }

    func testACutOnlyFitReportsZeroBoostRatherThanANegativeOne() {
        // max_combined_correction_db is negative when every band is cut, and a
        // "boosts by up to -3 dB" caution would be nonsense.
        var metrics = dspi_rc_metrics()
        metrics.max_combined_correction_db = -3.0
        metrics.min_combined_correction_db = -11.0

        let summary = CorrectionSummary(channel: 0,
                                        metrics: RoomCorrectionCore.Metrics(metrics),
                                        uncorrected: RoomCorrectionCore.Metrics(dspi_rc_metrics()),
                                        trimDb: 0, transitionHz: 0,
                                        transitionEstimated: true)
        XCTAssertEqual(summary.maxBoostDb, 0)
        XCTAssertTrue(summary.cautions.isEmpty, "\(summary.cautions)")
    }
}
