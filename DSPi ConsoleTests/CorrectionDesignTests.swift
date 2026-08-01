import XCTest
@testable import DSPi_Console

/// Covers the target step: what the presets mean, how anchors behave, and what
/// a fit does with a channel that has nothing usable in it.
@MainActor
final class CorrectionDesignTests: XCTestCase {

    private func makeDesign() -> CorrectionDesign {
        CorrectionDesign(grid: .display)
    }

    // MARK: - Anchors

    func testAnchorsStaySortedAndOnePerFrequency() {
        // Two anchors at one frequency is not a curve a user can mean, and
        // stacking them would make the second look ignored.
        let design = makeDesign()
        design.addAnchor(freqHz: 1000, gainDb: 2)
        design.addAnchor(freqHz: 100, gainDb: -3)
        design.addAnchor(freqHz: 1000, gainDb: 5)

        XCTAssertEqual(design.anchors.map(\.freqHz), [100, 1000])
        XCTAssertEqual(design.anchors.last?.gainDb, 5, "the later value must win")
    }

    func testNearlyIdenticalFrequenciesAreTreatedAsOneAnchor() {
        // Anchors a fraction of a hertz apart are the user aiming at the same
        // point twice, not asking for two.
        let design = makeDesign()
        design.addAnchor(freqHz: 1000, gainDb: 2)
        design.addAnchor(freqHz: 1000.2, gainDb: -1)

        XCTAssertEqual(design.anchors.count, 1)
        XCTAssertEqual(design.anchors.first?.gainDb, -1)
    }

    func testRemovingAndClearingAnchors() {
        let design = makeDesign()
        design.addAnchor(freqHz: 60, gainDb: 3)
        design.addAnchor(freqHz: 6000, gainDb: -2)

        let first = try? XCTUnwrap(design.anchors.first)
        design.removeAnchor(try! XCTUnwrap(first))
        XCTAssertEqual(design.anchors.map(\.freqHz), [6000])

        design.clearAnchors()
        XCTAssertTrue(design.anchors.isEmpty)
    }

    func testAPresetKeepsTheUsersAnchors() {
        // A preset replaces the macro shape, which is the point of it. The
        // anchors are the user's own edits and are not the preset's to discard.
        let design = makeDesign()
        design.addAnchor(freqHz: 45, gainDb: 4)
        design.preset = .studio

        XCTAssertEqual(design.anchors.count, 1)
        XCTAssertEqual(design.anchors.first?.gainDb, 4)
    }

    func testAPresetReplacesTheShape() {
        let design = makeDesign()
        design.preset = .flat
        let flatTilt = design.target.tiltDbPerOctave
        design.preset = .natural

        XCTAssertNotEqual(design.target.tiltDbPerOctave, flatTilt,
                          "choosing a preset must actually change the curve")
    }

    // MARK: - Points on the curve

    func testAPointLandsWhereItWasDropped() {
        // The whole premise of the interaction. Storing an offset and showing
        // it is what made anchors hard to reason about: you set one number and
        // saw a different one.
        let design = makeDesign()
        design.preset = .natural          // a shape with a real tilt to sit on

        design.addAnchor(atHz: 500, curveValueDb: 4)

        let anchor = try? XCTUnwrap(design.anchors.first)
        guard let anchor = anchor ?? nil else { return XCTFail("no point") }
        XCTAssertEqual(design.curveValue(of: anchor), 4, accuracy: 0.05)

        // And the drawn curve really does pass through it.
        let curve = design.previewTargetCurve()
        guard let bin = index(ofHz: 500, in: design.grid.frequencies) else {
            return XCTFail("no grid")
        }
        XCTAssertEqual(curve[bin], 4, accuracy: 0.2)
    }

    func testAPointOnASteeperShapeStillLandsWhereItWasDropped() {
        // The offset needed depends on the shape underneath, which is exactly
        // the arithmetic the user should never have to do.
        let design = makeDesign()
        design.target = RoomCorrectionCore.Target(preset: .flat)
        design.target.tiltDbPerOctave = -1.5

        design.addAnchor(atHz: 80, curveValueDb: 2)
        design.addAnchor(atHz: 6000, curveValueDb: -3)

        for anchor in design.anchors {
            let expected: Double = anchor.freqHz < 1000 ? 2 : -3
            XCTAssertEqual(design.curveValue(of: anchor), expected, accuracy: 0.1,
                           "point at \(anchor.freqHz) Hz")
        }
    }

    func testMovingAPointTakesItToTheNewPlace() {
        let design = makeDesign()
        design.preset = .natural
        design.addAnchor(atHz: 200, curveValueDb: 0)

        let anchor = try? XCTUnwrap(design.anchors.first)
        guard let anchor = anchor ?? nil else { return XCTFail("no point") }
        design.moveAnchor(anchor, toHz: 900, curveValueDb: -5)

        let moved = try? XCTUnwrap(design.anchors.first)
        guard let moved = moved ?? nil else { return XCTFail("no point") }
        XCTAssertEqual(moved.freqHz, 900, accuracy: 0.5)
        XCTAssertEqual(design.curveValue(of: moved), -5, accuracy: 0.1)
    }

    func testDraggingAPointOntoAnotherLeavesOne() {
        // Two points at one frequency is not a curve anyone can mean, and the
        // one underneath would be unreachable.
        let design = makeDesign()
        design.addAnchor(atHz: 300, curveValueDb: 2)
        design.addAnchor(atHz: 900, curveValueDb: -2)

        let mover = try? XCTUnwrap(design.anchors.last)
        guard let mover = mover ?? nil else { return XCTFail("no point") }
        design.moveAnchor(mover, toHz: 300, curveValueDb: 5)

        XCTAssertEqual(design.anchors.count, 1)
        XCTAssertEqual(design.curveValue(of: design.anchors[0]), 5, accuracy: 0.1)
    }

    func testAPointIsALocalEditRatherThanAGlobalShift() {
        // The failure that made a single anchor useless: held flat beyond the
        // outermost point, one point offset the whole curve, and auto-level
        // then removed exactly that.
        let design = makeDesign()
        design.target = RoomCorrectionCore.Target(preset: .flat)
        let before = design.previewTargetCurve()

        design.addAnchor(atHz: 500, curveValueDb: 6)
        let after = design.previewTargetCurve()

        guard let near = index(ofHz: 500, in: design.grid.frequencies),
              let far = index(ofHz: 60, in: design.grid.frequencies) else {
            return XCTFail("no grid")
        }
        XCTAssertGreaterThan(after[near], before[near] + 3)
        XCTAssertEqual(after[far], before[far], accuracy: 0.01,
                       "three octaves away nothing should have moved")
    }

    func testResetClearsThePointsAndTheShape() {
        let design = makeDesign()
        design.preset = .studio
        design.target.tiltDbPerOctave = -1.9
        design.addAnchor(atHz: 100, curveValueDb: 5)

        design.resetCurve()

        XCTAssertTrue(design.anchors.isEmpty)
        XCTAssertEqual(design.target.tiltDbPerOctave,
                       RoomCorrectionCore.Target(preset: .studio).tiltDbPerOctave,
                       accuracy: 1e-9,
                       "reset returns to the chosen preset, not to a different one")
    }

    // MARK: - Staleness

    func testEditingTheTargetMarksTheFitStale() {
        // A user who has changed the tilt and not recalculated is looking at a
        // correction for a different curve, and should be told.
        let design = makeDesign()
        design.target.tiltDbPerOctave = -0.9
        XCTAssertTrue(design.isStale)

        design.addAnchor(freqHz: 80, gainDb: 2)
        XCTAssertTrue(design.isStale)
    }

    // MARK: - The target curve itself

    func testTheTargetCurvePreviewsWithoutAnyMeasurement() {
        // Most of the deciding happens before anything is measured, so the
        // curve has to be drawable then.
        let design = makeDesign()
        let curve = design.previewTargetCurve()

        XCTAssertEqual(curve.count, design.grid.pointCount)
        XCTAssertTrue(curve.allSatisfy { $0.isFinite })
    }

    func testADownwardTiltActuallyFalls() {
        let design = makeDesign()
        design.target = RoomCorrectionCore.Target(preset: .flat)
        design.target.tiltDbPerOctave = -1.0
        design.target.bassGainDb = 0
        design.target.trebleGainDb = 0

        let curve = design.previewTargetCurve()
        let frequencies = design.grid.frequencies
        let low = try? XCTUnwrap(index(ofHz: 100, in: frequencies))
        let high = try? XCTUnwrap(index(ofHz: 8000, in: frequencies))

        guard let low = low ?? nil, let high = high ?? nil else { return XCTFail("no grid") }
        XCTAssertGreaterThan(curve[low], curve[high],
                             "a downward tilt must be higher at 100 Hz than at 8 kHz")

        // Roughly one dB per octave over the six or so octaves between them.
        let octaves = log2(8000.0 / 100.0)
        XCTAssertEqual(curve[low] - curve[high], octaves, accuracy: 1.5)
    }

    func testBassLiftRaisesTheBottomAndLeavesTheTopAlone() {
        let design = makeDesign()
        design.target = RoomCorrectionCore.Target(preset: .flat)
        let before = design.previewTargetCurve()

        design.target.bassGainDb = 6
        design.target.bassTransitionHz = 80
        let after = design.previewTargetCurve()

        let frequencies = design.grid.frequencies
        guard let low = index(ofHz: 30, in: frequencies),
              let high = index(ofHz: 5000, in: frequencies) else { return XCTFail("no grid") }

        XCTAssertGreaterThan(after[low] - before[low], 3, "the bass should have lifted")
        XCTAssertEqual(after[high], before[high], accuracy: 0.5,
                       "a bass shelf must not move the treble")
    }

    func testAnAnchorPullsTheCurveTowardsIt() {
        let design = makeDesign()
        design.target = RoomCorrectionCore.Target(preset: .flat)
        let before = design.previewTargetCurve()

        design.addAnchor(freqHz: 500, gainDb: 5)
        let after = design.previewTargetCurve()

        guard let at500 = index(ofHz: 500, in: design.grid.frequencies) else {
            return XCTFail("no grid")
        }
        XCTAssertGreaterThan(after[at500], before[at500] + 1,
                             "an anchor that changes nothing is a control that lies")
    }

    // MARK: - Summaries

    func testTheSummaryDescribesTheTiltInWords() {
        // The numbers are precise but abstract; someone choosing between curves
        // is better served knowing -0.8 dB/oct is "noticeably warm".
        var target = RoomCorrectionCore.Target(preset: .flat)
        target.tiltDbPerOctave = 0
        target.bassGainDb = 0
        target.trebleGainDb = 0
        XCTAssertTrue(target.summary.contains("flat"), target.summary)

        target.tiltDbPerOctave = -0.8
        XCTAssertTrue(target.summary.contains("warm"), target.summary)

        target.tiltDbPerOctave = -1.5
        XCTAssertTrue(target.summary.contains("strongly"), target.summary)
    }

    func testTheSummaryMentionsBassAndTrebleOnlyWhenTheyAreSet() {
        var target = RoomCorrectionCore.Target(preset: .flat)
        target.tiltDbPerOctave = 0
        target.bassGainDb = 0
        target.trebleGainDb = 0
        XCTAssertFalse(target.summary.contains("lift"), target.summary)

        target.bassGainDb = 5
        target.bassTransitionHz = 100
        XCTAssertTrue(target.summary.contains("below"), target.summary)

        target.trebleGainDb = -3
        target.trebleTransitionHz = 8000
        XCTAssertTrue(target.summary.contains("above"), target.summary)
    }

    func testEveryPresetExplainsItself() {
        for preset in RoomCorrectionCore.TargetPreset.allCases {
            XCTAssertFalse(preset.displayName.isEmpty)
            XCTAssertGreaterThan(preset.explanation.count, 40,
                                 "\(preset.displayName) needs a real explanation")
        }
    }

    // MARK: - Fitting

    func testAChannelWithNoMeasurementsIsSkippedRatherThanFitted() {
        // A correction derived from nothing is worse than no correction,
        // because it is applied with the same confidence.
        let design = makeDesign()
        let session = MeasurementSession(capture: InertCapture(),
                                         playback: InertPlayback(),
                                         preparation: InertPreparation())

        design.recompute(from: session, channels: [0, 1],
                         sampleRateHz: 48000, platform: .rp2350)

        XCTAssertTrue(design.fits.isEmpty)
        XCTAssertTrue(design.fittedChannels.isEmpty)
        XCTAssertFalse(design.isStale, "the recompute still happened")
    }

    func testCurvesComeBackOnTheGridTheyAreDrawnAgainst() throws {
        // Measurements are analysed on the session's grid, so a fit only
        // accepts positions of that length and the plots must index curves by
        // the same one. A design holding its own grid made every fit throw for
        // a length mismatch, silently, and Calculate Correction did nothing.
        //
        // The stub magnitudes are built on the *session's* grid, which is what
        // the measurement path actually produces. Building them on the design's
        // grid instead is what let the earlier version of this test pass while
        // the real path was broken.
        let design = CorrectionDesign(grid: .display)
        let session = MeasurementSession(capture: InertCapture(),
                                         playback: InertPlayback(),
                                         preparation: InertPreparation(),
                                         grid: .standard)
        XCTAssertNotEqual(session.grid.pointCount, design.grid.pointCount,
                          "this test is only meaningful if they start out different")

        let magnitudes = session.grid.frequencies.map { hz -> Double in
            let octavesFrom80 = log2(hz / 80.0)
            return -6.0 * exp(-octavesFrom80 * octavesFrom80)
        }

        session.stubPositions([
            .init(name: "Main",
                  measurements: [MeasurementSession.SpeakerMeasurement(
                    speakerIndex: 0,
                    magnitudesDb: magnitudes,
                    quality: CaptureQuality(),
                    verdict: .pass,
                    latencySeconds: 0.01)],
                  weight: 1),
        ])

        design.recompute(from: session, channels: [0],
                         sampleRateHz: 48000, platform: .rp2350)

        XCTAssertEqual(design.fittedChannels, [0], design.errorMessage ?? "")
        XCTAssertEqual(design.grid.pointCount, session.grid.pointCount,
                       "the design must adopt the grid its measurements are on")
        for curve in [RoomCorrectionCore.Curve.target, .powerAverage, .correction] {
            XCTAssertEqual(design.curve(curve, channel: 0).count,
                           design.grid.frequencies.count,
                           "\(curve) came back on a different grid than it is plotted on")
        }
    }

    // MARK: - Apply plans

    /// A design with one fitted channel, for plan construction.
    private func fittedDesign() -> (CorrectionDesign, MeasurementSession) {
        let design = CorrectionDesign()
        let session = MeasurementSession(capture: InertCapture(),
                                         playback: InertPlayback(),
                                         preparation: InertPreparation())
        let magnitudes = session.grid.frequencies.map { hz -> Double in
            8.0 * exp(-pow(log2(hz / 90.0) * 6, 2))
        }
        session.stubPositions((0..<3).map { index in
            .init(name: "P\(index)",
                  measurements: [MeasurementSession.SpeakerMeasurement(
                    speakerIndex: 0, magnitudesDb: magnitudes,
                    quality: CaptureQuality(), verdict: .pass, latencySeconds: 0.01)],
                  weight: 1)
        })
        design.recompute(from: session, channels: [0],
                         sampleRateHz: 48000, platform: .rp2350)
        return (design, session)
    }

    func testTheCompensationIsAnOffsetFromTheBaselineNotFromZero() throws {
        // Two channels sitting at different gains must each keep their own
        // starting point, or applying correction rebalances the system.
        let (design, _) = fittedDesign()
        let plans = design.applyPlans(mode: .inputChannels,
                                      eqChannel: { $0 + 2 },
                                      baselineOutputGainDb: { _ in 0 },
                                      baselinePreampDb: { channel in
                                          channel == 0 ? -6 : 0
                                      })
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plan.originalGainDb, -6)
        XCTAssertEqual(plan.compensatedGainDb,
                       plan.originalGainDb
                           + Float(plan.trimDb - plan.levelChangeDb
                                   + plan.commonDatumDb + plan.levelMatchDb),
                       accuracy: 0.001)
    }

    func testAPlanCarriesTheTrimTheFitAsked() throws {
        // The bands are the untrimmed cascade. Whatever headroom the fit took
        // to keep the combined response under its ceiling has to travel with
        // them, or the device runs hotter than anything that was gated.
        let (design, _) = fittedDesign()
        let plans = design.applyPlans(mode: .inputChannels,
                                      eqChannel: { $0 + 2 },
                                      baselineOutputGainDb: { _ in 0 },
                                      baselinePreampDb: { _ in 0 })
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plan.trimDb, design.trimDb(channel: 0), accuracy: 1e-9)
        XCTAssertLessThanOrEqual(plan.trimDb, 0)
    }

    func testNoAppliedGainIsEverPositive() throws {
        // The rule the scheme exists to keep, checked against a real fit rather
        // than a hand-built plan.
        let (design, _) = fittedDesign()
        for mode in [MeasurementMode.inputChannels, .outputChannels] {
            let plans = design.applyPlans(mode: mode,
                                          eqChannel: { $0 + 2 },
                                          baselineOutputGainDb: { _ in 0 },
                                          baselinePreampDb: { _ in 0 })
            for plan in plans {
                XCTAssertLessThanOrEqual(plan.compensatedGainDb, 0,
                                         "\(mode) channel \(plan.speakerIndex)")
                XCTAssertLessThanOrEqual(plan.bypassedGainDb, 0)
            }
        }
    }

    // MARK: - Fit limits

    func testTheCutLimitIsShownAsAPositiveMagnitude() {
        // The core's convention is signed - cuts negative, boosts positive -
        // but "maximum cut: -12 dB" on a slider that only goes positive is
        // simply wrong on screen.
        var options = RoomCorrectionCore.FitOptions()
        XCTAssertLessThan(options.cutLimitDb, 0, "the core wants a negative limit")
        XCTAssertEqual(options.maxCutDb, -options.cutLimitDb,
                       "the UI-facing value is the same limit, positively signed")

        options.maxCutDb = 18
        XCTAssertEqual(options.cutLimitDb, -18, "and converts back on the way in")
        XCTAssertEqual(options.maxCutDb, 18)
    }

    func testTheCutLimitCannotBeDrivenToZero() {
        // The core refuses a non-negative cut limit and fails the whole fit,
        // so a slider must not be able to reach one.
        var options = RoomCorrectionCore.FitOptions()
        options.maxCutDb = 0
        XCTAssertLessThan(options.cutLimitDb, 0)

        // A positive value written to the signed property is what the slider
        // used to do, and it must not survive round-tripping either.
        options.maxCutDb = -6
        XCTAssertLessThan(options.cutLimitDb, 0, "a sign slip must not invert the limit")
    }

    func testAFitStillSucceedsAfterTheCutLimitIsChanged() throws {
        // The real failure: setting this from the UI wrote a positive limit,
        // which the core rejects outright, so touching the slider broke the
        // whole calculation rather than just looking odd.
        let design = CorrectionDesign()
        let session = MeasurementSession(capture: InertCapture(),
                                         playback: InertPlayback(),
                                         preparation: InertPreparation())
        let magnitudes = session.grid.frequencies.map { hz -> Double in
            -7.0 * exp(-pow(log2(hz / 70.0), 2))
        }
        session.stubPositions([
            .init(name: "Main",
                  measurements: [MeasurementSession.SpeakerMeasurement(
                    speakerIndex: 0, magnitudesDb: magnitudes,
                    quality: CaptureQuality(), verdict: .pass, latencySeconds: 0.01)],
                  weight: 1),
        ])

        design.options.maxCutDb = 18
        design.recompute(from: session, channels: [0],
                         sampleRateHz: 48000, platform: .rp2350)

        XCTAssertEqual(design.fittedChannels, [0],
                       design.errorMessage ?? "the fit was rejected")
    }

    // MARK: - Strength

    func testStrengthDefaultsToFullAndClampsToItsValidRange() {
        // The core refuses a strength of zero or above one and fails the whole
        // fit, so the property must not be able to carry one there.
        var options = RoomCorrectionCore.FitOptions()
        XCTAssertEqual(options.strength, 1.0, "full correction is the default")

        options.strength = 0
        XCTAssertGreaterThan(options.strength, 0)
        options.strength = 3
        XCTAssertEqual(options.strength, 1.0)
    }

    func testAGentlerStrengthCorrectsLessInTheSameDirection() throws {
        // What a user actually expects from the control: turning it down does
        // less of the same thing, not something different.
        func peakCut(strength: Double) throws -> Double {
            let design = CorrectionDesign()
            let session = MeasurementSession(capture: InertCapture(),
                                             playback: InertPlayback(),
                                             preparation: InertPreparation())
            let magnitudes = session.grid.frequencies.map { hz -> Double in
                8.0 * exp(-pow(log2(hz / 120.0) * 2.5, 2))
            }
            session.stubPositions((0..<3).map { index in
                .init(name: "P\(index)",
                      measurements: [MeasurementSession.SpeakerMeasurement(
                        speakerIndex: 0, magnitudesDb: magnitudes,
                        quality: CaptureQuality(), verdict: .pass, latencySeconds: 0.01)],
                      weight: 1)
            })
            design.options.strength = strength
            design.recompute(from: session, channels: [0],
                             sampleRateHz: 48000, platform: .rp2350)
            XCTAssertEqual(design.fittedChannels, [0], design.errorMessage ?? "")

            let correction = design.curve(.correction, channel: 0)
            let bin = try XCTUnwrap(design.grid.frequencies.enumerated()
                .min { abs($0.element - 120) < abs($1.element - 120) }?.offset)
            return correction[bin]
        }

        let full = try peakCut(strength: 1.0)
        let gentle = try peakCut(strength: 0.4)

        XCTAssertLessThan(full, -1.0, "a full correction should cut the peak")
        XCTAssertLessThan(gentle, -0.1, "a gentle one should still cut it")
        XCTAssertGreaterThan(gentle, full, "but by less")
    }

    func testARecomputeThatProducesNothingSaysSo() {
        // A button that runs, fails and stays quiet is worse than one that is
        // disabled: the user has no idea whether anything happened.
        let design = CorrectionDesign()
        let session = MeasurementSession(capture: InertCapture(),
                                         playback: InertPlayback(),
                                         preparation: InertPreparation())

        design.recompute(from: session, channels: [0, 1],
                         sampleRateHz: 48000, platform: .rp2350)

        XCTAssertTrue(design.fits.isEmpty)
        XCTAssertNotNil(design.errorMessage,
                        "a recompute that produced nothing must say why")
        XCTAssertTrue(design.errorMessage?.contains("Measurements") ?? false,
                      design.errorMessage ?? "")
    }

    func testReadingBackAnUnfittedChannelIsEmptyRatherThanACrash() {
        let design = makeDesign()
        XCTAssertTrue(design.curve(.target, channel: 3).isEmpty)
        XCTAssertTrue(design.filters(channel: 3).isEmpty)
        XCTAssertEqual(design.trimDb(channel: 3), 0)
        XCTAssertNil(design.metrics(channel: 3))
    }

    // MARK: - Helpers

    private func index(ofHz hz: Double, in frequencies: [Double]) -> Int? {
        guard !frequencies.isEmpty else { return nil }
        return frequencies.enumerated()
            .min { abs($0.element - hz) < abs($1.element - hz) }?.offset
    }

    private final class InertCapture: AudioCaptureBackend {
        var isRunning = false
        var sampleRate: Double = 48000
        var overloadCount = 0
        func start(device: AudioDeviceInfo, channelIndex: Int) throws {}
        func stop() -> [Float] { [] }
        func peakAndReset() -> Float { 0 }
    }

    private final class InertPlayback: AudioPlaybackBackend {
        var isRunning = false
        var underrunCount = 0
        func play(samples: [Float], device: AudioDeviceInfo, channelIndex: Int,
                  completion: @escaping (Result<Void, Error>) -> Void) throws {}
        func stop() {}
    }

    private final class InertPreparation: DevicePreparing {
        func prepare(mode: MeasurementMode, correctedChannels: [Int]) async throws {}
        func restore() async {}
    }
}
