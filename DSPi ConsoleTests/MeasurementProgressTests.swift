import XCTest
@testable import DSPi_Console

/// Covers the measurement chart's accumulation rules: what counts, per whom,
/// and when an average starts to mean anything.
@MainActor
final class MeasurementProgressTests: XCTestCase {

    private let grid = RoomCorrectionCore.Grid.standard

    /// `widthDenominator` is the peak's width in fractions of an octave. The
    /// default is broad; a real room mode at Q=20 is nearer 1/14.
    private func curve(peakAt hz: Double, gainDb: Double, level: Double = 75,
                       widthDenominator: Double = 3) -> [Double] {
        grid.frequencies.map { f in
            level + gainDb * exp(-pow(log2(f / hz) * widthDenominator, 2))
        }
    }

    private func measurement(speaker: Int,
                             magnitudes: [Double],
                             usable: Bool = true) -> MeasurementSession.SpeakerMeasurement {
        MeasurementSession.SpeakerMeasurement(
            speakerIndex: speaker,
            magnitudesDb: usable ? magnitudes : [],
            quality: CaptureQuality(),
            verdict: usable ? .pass : .fail(["Too close to the noise floor."]),
            latencySeconds: 0.01)
    }

    private func position(_ name: String,
                          _ measurements: [MeasurementSession.SpeakerMeasurement],
                          enabled: Bool = true) -> MeasurementSession.Position {
        var value = MeasurementSession.Position(name: name, measurements: measurements,
                                                weight: 1)
        value.enabled = enabled
        return value
    }

    private func accumulate(_ positions: [MeasurementSession.Position],
                            speakers: [Int] = [0, 1]) -> [SpeakerAccumulation] {
        MeasurementProgress.accumulate(positions: positions, speakers: speakers, grid: grid)
    }

    // MARK: - Per speaker

    func testEachSpeakerAveragesOnlyItsOwnMeasurements() {
        // Averaging across speakers would combine different transducers in
        // different places and describe neither.
        let left = curve(peakAt: 60, gainDb: 10)
        let right = curve(peakAt: 900, gainDb: -10)
        let result = accumulate([
            position("A", [measurement(speaker: 0, magnitudes: left),
                           measurement(speaker: 1, magnitudes: right)]),
            position("B", [measurement(speaker: 0, magnitudes: left),
                           measurement(speaker: 1, magnitudes: right)]),
        ])

        XCTAssertEqual(result.map(\.speakerIndex), [0, 1])
        let leftAverage = try? XCTUnwrap(result[0].average)
        let rightAverage = try? XCTUnwrap(result[1].average)

        // Each average keeps its own speaker's feature and not the other's.
        guard let bin = index(ofHz: 60), let other = index(ofHz: 900),
              let leftAverage = leftAverage ?? nil, let rightAverage = rightAverage ?? nil
        else { return XCTFail("no averages") }
        XCTAssertGreaterThan(leftAverage[bin], leftAverage[other] + 5)
        XCTAssertLessThan(rightAverage[other], rightAverage[bin] - 5)
    }

    func testASpeakerWithNothingUsableIsOmittedRatherThanShownEmpty() {
        // An empty axis invites the reading that the speaker measured flat.
        let good = curve(peakAt: 100, gainDb: 6)
        let result = accumulate([
            position("A", [measurement(speaker: 0, magnitudes: good),
                           measurement(speaker: 1, magnitudes: [], usable: false)]),
        ])
        XCTAssertEqual(result.map(\.speakerIndex), [0])
    }

    func testPositionCountsAreTrackedPerSpeaker() {
        // A sweep can fail for one speaker at a position the other measured
        // fine. A single global count would overstate whichever is behind.
        let good = curve(peakAt: 100, gainDb: 6)
        let result = accumulate([
            position("A", [measurement(speaker: 0, magnitudes: good),
                           measurement(speaker: 1, magnitudes: good)]),
            position("B", [measurement(speaker: 0, magnitudes: good),
                           measurement(speaker: 1, magnitudes: [], usable: false)]),
            position("C", [measurement(speaker: 0, magnitudes: good),
                           measurement(speaker: 1, magnitudes: good)]),
        ])

        XCTAssertEqual(result.first { $0.speakerIndex == 0 }?.positionCount, 3)
        XCTAssertEqual(result.first { $0.speakerIndex == 1 }?.positionCount, 2)
    }

    // MARK: - What counts

    func testAFailedSweepDoesNotContributeToTheAverage() {
        let good = curve(peakAt: 100, gainDb: 6)
        let result = accumulate([
            position("A", [measurement(speaker: 0, magnitudes: good)]),
            position("B", [measurement(speaker: 0, magnitudes: [], usable: false)]),
        ], speakers: [0])

        XCTAssertEqual(result.first?.positionCount, 1)
        XCTAssertNil(result.first?.average,
                     "one usable position is not two, however many were attempted")
    }

    func testADisabledPositionIsExcluded() {
        // Disabling a position excludes it from the fit, so it must leave the
        // chart too or the two disagree about what is being corrected.
        let good = curve(peakAt: 100, gainDb: 6)
        let result = accumulate([
            position("A", [measurement(speaker: 0, magnitudes: good)]),
            position("B", [measurement(speaker: 0, magnitudes: good)], enabled: false),
        ], speakers: [0])

        XCTAssertEqual(result.first?.positionCount, 1)
    }

    func testAnUnselectedSpeakerIsNotShown() {
        let good = curve(peakAt: 100, gainDb: 6)
        let result = accumulate([
            position("A", [measurement(speaker: 0, magnitudes: good),
                           measurement(speaker: 1, magnitudes: good)]),
        ], speakers: [1])
        XCTAssertEqual(result.map(\.speakerIndex), [1])
    }

    // MARK: - When an average appears

    func testOnePositionHasNoAverageOrSpread() {
        // The "average" of one measurement is that measurement relabelled.
        let result = accumulate([
            position("A", [measurement(speaker: 0, magnitudes: curve(peakAt: 100, gainDb: 6))]),
        ], speakers: [0])

        XCTAssertEqual(result.first?.positionCount, 1)
        XCTAssertNil(result.first?.average)
        XCTAssertNil(result.first?.spread)
        XCTAssertTrue(result.first?.statusLine.contains("from the second") ?? false,
                      result.first?.statusLine ?? "")
    }

    func testTwoPositionsAverageButShowNoSpreadBand() {
        // At two the band is only the gap between two traces already drawn, and
        // a deviation from two samples looks more precise than it is.
        let good = curve(peakAt: 100, gainDb: 6)
        let result = accumulate([
            position("A", [measurement(speaker: 0, magnitudes: good)]),
            position("B", [measurement(speaker: 0, magnitudes: good.map { $0 + 2 })]),
        ], speakers: [0])

        XCTAssertNotNil(result.first?.average)
        XCTAssertNil(result.first?.spread)
    }

    func testThreePositionsShowTheSpreadBand() {
        let good = curve(peakAt: 100, gainDb: 6)
        let result = accumulate([
            position("A", [measurement(speaker: 0, magnitudes: good)]),
            position("B", [measurement(speaker: 0, magnitudes: good.map { $0 + 2 })]),
            position("C", [measurement(speaker: 0, magnitudes: good.map { $0 - 2 })]),
        ], speakers: [0])

        XCTAssertNotNil(result.first?.average)
        let spread = try? XCTUnwrap(result.first?.spread)
        XCTAssertEqual((spread ?? nil)?.count, grid.pointCount)
        XCTAssertTrue((spread ?? nil)?.allSatisfy { $0 >= 0 } ?? false,
                      "a deviation cannot be negative")
    }

    // MARK: - The average itself

    func testTheAverageIsPowerDomainSoOneNullDoesNotDominate() {
        // The same reason the fit averages in the power domain: a dB mean lets
        // one seat's deep cancellation drag the estimate far below the energy
        // the listening area actually receives.
        guard let bin = index(ofHz: 55) else { return XCTFail("no grid") }
        var nulled = [Double](repeating: 75, count: grid.pointCount)
        nulled[bin] = 45

        let result = accumulate([
            position("A", [measurement(speaker: 0,
                                       magnitudes: [Double](repeating: 75,
                                                            count: grid.pointCount))]),
            position("B", [measurement(speaker: 0,
                                       magnitudes: [Double](repeating: 75,
                                                            count: grid.pointCount))]),
            position("C", [measurement(speaker: 0, magnitudes: nulled)]),
        ], speakers: [0])

        let average = try? XCTUnwrap(result.first?.average)
        guard let average = average ?? nil else { return XCTFail("no average") }
        XCTAssertGreaterThan(average[bin], 68,
                             "a dB-domain mean would land near 65 dB here")
    }

    func testSmoothingChangesWhatIsDrawnAndNotHowManyPositionsCount() {
        // A narrow mode, which is what smoothing width actually trades against.
        let good = curve(peakAt: 200, gainDb: 12, widthDenominator: 14)
        let positions = [
            position("A", [measurement(speaker: 0, magnitudes: good)]),
            position("B", [measurement(speaker: 0, magnitudes: good)]),
        ]
        let fine = MeasurementProgress.accumulate(positions: positions, speakers: [0],
                                                  grid: grid,
                                                  smoothing: .fixed(denominator: 48))
        let coarse = MeasurementProgress.accumulate(positions: positions, speakers: [0],
                                                    grid: grid,
                                                    smoothing: .fixed(denominator: 3))

        XCTAssertEqual(fine.first?.positionCount, coarse.first?.positionCount)
        guard let bin = index(ofHz: 200),
              let fineAverage = fine.first?.average,
              let coarseAverage = coarse.first?.average else { return XCTFail("no averages") }
        XCTAssertGreaterThan(fineAverage[bin], coarseAverage[bin] + 1,
                             "broad smoothing should flatten a narrow peak")
    }

    // MARK: - Helpers

    private func index(ofHz hz: Double) -> Int? {
        grid.frequencies.enumerated()
            .min { abs($0.element - hz) < abs($1.element - hz) }?.offset
    }
}
