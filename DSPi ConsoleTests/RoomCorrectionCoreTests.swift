import XCTest
@testable import DSPi_Console

/// End-to-end tests across the Swift/C++ boundary.
///
/// The core has its own 133-case suite on the C++ side; these do not repeat it.
/// What they check is the thing that suite cannot: that the ABI is wired up
/// correctly, that Swift memory management around the opaque handles is sound,
/// and that the filters coming back map onto the app's own `FilterParams` in a
/// form the existing EQ write path can send.
final class RoomCorrectionCoreTests: XCTestCase {

    private let grid = RoomCorrectionCore.Grid.display

    /// A room with one shared mode every position sees.
    private func sharedModeRoom(positions: Int) -> [[Double]] {
        let hz = grid.frequencies
        return (0..<positions).map { _ in
            hz.map { f -> Double in
                let octaves = log2(f / 52.0)
                return 75.0 + 8.0 * exp(-0.5 * pow(octaves / 0.22, 2))
            }
        }
    }

    // MARK: - Boundary

    func testAlgorithmVersionCrossesTheBoundary() {
        let version = RoomCorrectionCore.algorithmVersion
        XCTAssertFalse(version.isEmpty)
        XCTAssertTrue(version.hasPrefix("dspi_rc/"), "unexpected version string: \(version)")
    }

    func testGridMatchesTheCore() {
        let frequencies = grid.frequencies
        XCTAssertEqual(frequencies.count, grid.pointCount)
        XCTAssertGreaterThan(frequencies.count, 100)
        XCTAssertEqual(frequencies.first ?? 0, 20.0, accuracy: 1e-9)
        XCTAssertEqual(frequencies.last ?? 0, 20000.0, accuracy: 1e-9)
    }

    // MARK: - Sweep

    func testSweepRendersAtTheRequestedLength() throws {
        var sweep = try RoomCorrectionCore.SweepSpec(sampleRateHz: 48000, role: .fullRange)
        sweep.durationSeconds = 2.0
        let samples = try sweep.render()

        XCTAssertEqual(samples.count, try sweep.totalSamples)
        // Pre-roll is silent, so the buffer must not open with the sweep.
        XCTAssertEqual(samples.first ?? 1, 0.0, accuracy: 1e-9)

        let peak = samples.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.01)
        XCTAssertLessThanOrEqual(peak, 1.0)
    }

    func testPeakLevelConvertsBetweenDbfsAndAmplitude() throws {
        var sweep = try RoomCorrectionCore.SweepSpec(sampleRateHz: 48000, role: .fullRange)
        sweep.peakLevelDbfs = -20.0
        XCTAssertEqual(sweep.peakLevelDbfs, -20.0, accuracy: 1e-9)

        sweep.durationSeconds = 1.5
        let peak = try sweep.render().map { abs($0) }.max() ?? 0
        XCTAssertEqual(Double(peak), pow(10.0, -20.0 / 20.0), accuracy: 0.01)
    }

    func testSubwooferRoleUsesANarrowerLongerSweep() throws {
        let full = try RoomCorrectionCore.SweepSpec(sampleRateHz: 48000, role: .fullRange)
        let sub = try RoomCorrectionCore.SweepSpec(sampleRateHz: 48000, role: .subwoofer)
        XCTAssertLessThan(sub.endHz, full.endHz)
        XCTAssertGreaterThan(sub.durationSeconds, full.durationSeconds)
    }

    func testAnalyzingAnUnfilteredSweepGivesAFlatResponse() throws {
        var sweep = try RoomCorrectionCore.SweepSpec(sampleRateHz: 48000, role: .fullRange)
        sweep.durationSeconds = 3.0
        let playback = try sweep.render()

        let analysis = try RoomCorrectionCore.analyze(recording: playback, sweep: sweep, grid: grid)
        XCTAssertEqual(analysis.magnitudesDb.count, grid.pointCount)
        // Latency is the spec's own pre-roll, since nothing else delayed it.
        XCTAssertEqual(analysis.latencySeconds, sweep.preRollSeconds, accuracy: 0.005)

        let hz = grid.frequencies
        for (index, frequency) in hz.enumerated() where frequency > 100 && frequency < 10000 {
            XCTAssertEqual(analysis.magnitudesDb[index], 0.0, accuracy: 2.0,
                           "unexpected level at \(frequency) Hz")
        }
    }

    // MARK: - Calibration

    func testCalibrationParsesAndApplies() throws {
        let contents = """
        "Sens Factor =-1.6690dB, SERNO: 7012345"
        20.0   0.0
        1000.0 3.0
        20000.0 0.0
        """
        let calibration = try RoomCorrectionCore.Calibration(contents: contents)
        XCTAssertEqual(calibration.pointCount, 3)
        XCTAssertEqual(calibration.sensitivityDb ?? 0, -1.6690, accuracy: 1e-4)
        XCTAssertTrue(calibration.covers(minHz: 100, maxHz: 10000))
        XCTAssertFalse(calibration.covers(minHz: 10, maxHz: 10000))

        // The file describes the microphone's deviation, so application
        // subtracts: a mic reading 3 dB hot pulls the measurement down.
        var magnitudes = [80.0, 80.0, 80.0]
        try calibration.apply(to: &magnitudes, frequencies: [20.0, 1000.0, 20000.0])
        XCTAssertEqual(magnitudes[0], 80.0, accuracy: 1e-6)
        XCTAssertEqual(magnitudes[1], 77.0, accuracy: 1e-6)
        XCTAssertEqual(magnitudes[2], 80.0, accuracy: 1e-6)
    }

    func testCalibrationRejectsAnUnusableFileWithAMessage() {
        XCTAssertThrowsError(try RoomCorrectionCore.Calibration(contents: "not a calibration")) {
            error in
            let message = (error as? RoomCorrectionCore.CoreError)?.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty, "a rejection must explain itself")
        }
    }

    func testCalibrationSurfacesRepairWarnings() throws {
        // Out-of-order rows parse, but the user should be told they were sorted.
        let calibration = try RoomCorrectionCore.Calibration(contents: "1000 1.0\n20 0.0\n5000 2.0")
        XCTAssertFalse(calibration.warnings.isEmpty)
    }

    // MARK: - Fitting

    func testFitProducesFiltersTheDeviceCanAccept() throws {
        let fit = try RoomCorrectionCore.Fit(grid: grid, sampleRateHz: 48000, platform: .rp2350)
        for (index, response) in sharedModeRoom(positions: 4).enumerated() {
            try fit.addPosition(magnitudesDb: response, weight: index == 0 ? 2.0 : 1.0)
        }
        try fit.setTarget(RoomCorrectionCore.Target(preset: .natural))
        try fit.fit()

        let filters = try fit.filters
        XCTAssertFalse(filters.isEmpty)
        XCTAssertLessThanOrEqual(filters.count, 10)

        for filter in filters {
            // Firmware clamps silently, so anything outside these would be
            // altered on arrival and the prediction would be wrong.
            XCTAssertGreaterThanOrEqual(filter.freq, 10.0)
            XCTAssertLessThanOrEqual(filter.freq, 48000.0 * 0.45)
            XCTAssertGreaterThanOrEqual(filter.q, 0.1)
            XCTAssertLessThanOrEqual(filter.q, 20.0)
            XCTAssertTrue(filter.type == .peaking || filter.type == .lowShelf
                          || filter.type == .highShelf,
                          "unexpected generated type \(filter.type)")
        }

        // Default policy is cut-only.
        let metrics = try fit.metrics
        XCTAssertLessThanOrEqual(metrics.maxCombinedCorrectionDb, -0.5 + 1e-6)
        XCTAssertLessThanOrEqual(try fit.trimDb, 0.0)
    }

    func testFitImprovesOnTheUncorrectedResponse() throws {
        let fit = try RoomCorrectionCore.Fit(grid: grid, sampleRateHz: 48000, platform: .rp2350)
        for response in sharedModeRoom(positions: 5) {
            try fit.addPosition(magnitudesDb: response)
        }
        try fit.setTarget(RoomCorrectionCore.Target(preset: .natural))
        try fit.fit()

        let corrected = try fit.metrics
        let uncorrected = try fit.uncorrectedMetrics
        XCTAssertLessThan(corrected.reliableWorstPositionRmseDb,
                          uncorrected.reliableWorstPositionRmseDb)
    }

    func testCurvesAreAvailableForPlotting() throws {
        let fit = try RoomCorrectionCore.Fit(grid: grid, sampleRateHz: 48000, platform: .rp2350)
        for response in sharedModeRoom(positions: 3) {
            try fit.addPosition(magnitudesDb: response)
        }
        try fit.setTarget(RoomCorrectionCore.Target(preset: .natural))
        try fit.fit()

        for curve in [RoomCorrectionCore.Curve.target, .powerAverage, .spread,
                      .reliability, .correction, .maskWeight,
                      .position(0), .predicted(0)] {
            let values = try fit.curve(curve)
            XCTAssertEqual(values.count, grid.pointCount, "wrong length for \(curve)")
            XCTAssertTrue(values.allSatisfy { $0.isFinite }, "non-finite value in \(curve)")
        }
    }

    func testSinglePositionCannotEstimateATransition() throws {
        // The strongest argument for measuring more than one position: one seat
        // cannot tell a room mode from a cancellation. The UI must be able to
        // say so rather than present the fallback as a measurement.
        let fit = try RoomCorrectionCore.Fit(grid: grid, sampleRateHz: 48000, platform: .rp2350)
        try fit.addPosition(magnitudesDb: sharedModeRoom(positions: 1)[0])
        try fit.setTarget(RoomCorrectionCore.Target(preset: .natural))
        try fit.fit()

        let transition = try fit.transition
        XCTAssertFalse(transition.estimated)
        XCTAssertGreaterThan(transition.hz, 0)
    }

    func testFittingWithoutATargetFailsWithAMessage() throws {
        let fit = try RoomCorrectionCore.Fit(grid: grid, sampleRateHz: 48000, platform: .rp2350)
        try fit.addPosition(magnitudesDb: sharedModeRoom(positions: 1)[0])
        XCTAssertThrowsError(try fit.fit()) { error in
            let message = (error as? RoomCorrectionCore.CoreError)?.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testMismatchedPositionLengthIsRejected() throws {
        let fit = try RoomCorrectionCore.Fit(grid: grid, sampleRateHz: 48000, platform: .rp2350)
        XCTAssertThrowsError(try fit.addPosition(magnitudesDb: [1.0, 2.0, 3.0]))
    }

    func testResultsAreUnavailableBeforeFitting() throws {
        let fit = try RoomCorrectionCore.Fit(grid: grid, sampleRateHz: 48000, platform: .rp2350)
        try fit.addPosition(magnitudesDb: sharedModeRoom(positions: 1)[0])
        XCTAssertThrowsError(try fit.filters)
        XCTAssertThrowsError(try fit.metrics)
    }

    func testFittingIsDeterministicAcrossSessions() throws {
        func run() throws -> [FilterParams] {
            let fit = try RoomCorrectionCore.Fit(grid: grid, sampleRateHz: 48000, platform: .rp2350)
            for response in sharedModeRoom(positions: 4) {
                try fit.addPosition(magnitudesDb: response)
            }
            try fit.setTarget(RoomCorrectionCore.Target(preset: .natural))
            try fit.fit()
            return try fit.filters
        }

        let first = try run()
        let second = try run()
        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.freq, b.freq, accuracy: 1e-6)
            XCTAssertEqual(a.q, b.q, accuracy: 1e-6)
            XCTAssertEqual(a.gain, b.gain, accuracy: 1e-6)
        }
    }

    func testManySessionsDoNotLeakOrCrash() throws {
        // Exercises the handle lifecycle: each Fit owns a C++ session and frees
        // it in deinit, and a leak or double-free here would be invisible in the
        // C++ suite.
        for _ in 0..<40 {
            let fit = try RoomCorrectionCore.Fit(grid: grid, sampleRateHz: 48000, platform: .rp2350)
            for response in sharedModeRoom(positions: 2) {
                try fit.addPosition(magnitudesDb: response)
            }
            try fit.setTarget(RoomCorrectionCore.Target(preset: .flat))
            try fit.fit()
            _ = try fit.filters
        }
    }
}
