import XCTest
@testable import DSPi_Console

/// Pure-logic tests for the frequency-response math that drives the graph.
/// These check `DSPMath` against analytic landmarks (peak gain at fc, -3 dB at
/// a Butterworth cutoff, -6 dB at a Linkwitz-Riley crossover, an all-pass's
/// flat magnitude / -90 deg point) rather than re-deriving the same RBJ
/// formula, so they catch regressions in the evaluation independently of the
/// coefficient code. No hardware required.
final class DSPMathTests: XCTestCase {

    private func mag(_ filters: [FilterParams], _ f: Float) -> Float {
        DSPMath.responseAt(freq: f, filters: filters)
    }
    private func phase(_ filters: [FilterParams], _ f: Float) -> Float {
        DSPMath.phaseAt(freq: f, filters: filters)
    }

    // MARK: PEQ landmarks

    func testFlatFilterIsTransparent() {
        let flat = [FilterParams(type: .flat)]
        for f: Float in [20, 100, 1000, 5000, 18000] {
            XCTAssertEqual(mag(flat, f), 0, accuracy: 1e-4, "flat magnitude at \(f) Hz")
            XCTAssertEqual(phase(flat, f), 0, accuracy: 1e-4, "flat phase at \(f) Hz")
        }
    }

    func testPeakingGainAtCenterEqualsSetGain() {
        // A peaking filter's gain at fc equals its dB setting, for any Q.
        let peak = [FilterParams(type: .peaking, freq: 1000, q: 2.0, gain: 6.0)]
        XCTAssertEqual(mag(peak, 1000), 6.0, accuracy: 0.05, "peak gain at fc")
        XCTAssertEqual(mag(peak, 20), 0, accuracy: 0.3, "far below fc is transparent")
        XCTAssertEqual(mag(peak, 18000), 0, accuracy: 0.3, "far above fc is transparent")
    }

    func testButterworthLowPassIsMinus3dBAtCutoff() {
        let lp = [FilterParams(type: .lowPass, freq: 1000, q: 0.7071, gain: 0)]
        XCTAssertEqual(mag(lp, 1000), -3.01, accuracy: 0.3, "Q=0.707 LP is -3 dB at fc")
        XCTAssertEqual(mag(lp, 100), 0, accuracy: 0.5, "passband is flat")
        XCTAssertLessThan(mag(lp, 10000), -30, "a decade above fc is well attenuated")
    }

    func testNotchRejectsAtCenterOnly() {
        let notch = [FilterParams(type: .notch, freq: 1000, q: 5.0, gain: 0)]
        XCTAssertLessThan(mag(notch, 1000), -30, "deep null at fc")
        XCTAssertEqual(mag(notch, 100), 0, accuracy: 0.5, "transparent away from fc")
        XCTAssertEqual(mag(notch, 10000), 0, accuracy: 0.5, "transparent away from fc")
    }

    func testFirstOrderAllPassFlatMagnitudeAndMinus90AtFc() {
        let ap = [FilterParams(type: .allPass1, freq: 1000)]
        for f: Float in [100, 1000, 10000] {
            XCTAssertEqual(mag(ap, f), 0, accuracy: 1e-3, "all-pass magnitude is flat at \(f) Hz")
        }
        // 1st-order all-pass passes through -90 deg exactly at fc.
        XCTAssertEqual(phase(ap, 1000), -90, accuracy: 2.0, "all-pass phase at fc")
    }

    // MARK: Crossover cascade (guards the merge fix to phaseAt)

    func testLinkwitzRiley4LowPassShape() {
        let lr4 = [FilterParams(type: .lr4_lp, freq: 1000)]
        // Defining LR property: -6 dB at the crossover frequency.
        XCTAssertEqual(mag(lr4, 1000), -6.02, accuracy: 0.6, "LR4 LP is -6 dB at fc")
        XCTAssertEqual(mag(lr4, 125), 0, accuracy: 0.6, "passband (3 oct below) is flat")
        XCTAssertLessThan(mag(lr4, 8000), -40, "24 dB/oct: 3 oct above fc is deep down")
    }

    func testCrossoverOrderSteepness() {
        // LR4 (24 dB/oct) must roll off faster than LR2 (12 dB/oct) above fc -
        // confirms the cascade actually adds sections per order.
        let lr2 = [FilterParams(type: .lr2_lp, freq: 1000)]
        let lr4 = [FilterParams(type: .lr4_lp, freq: 1000)]
        XCTAssertLessThan(mag(lr4, 4000), mag(lr2, 4000) - 10,
                          "LR4 is markedly steeper than LR2 two octaves up")
    }

    /// Regression guard for the merge: `phaseAt` previously routed crossover
    /// types through `calculateCoefficients`, which returns flat for them, so
    /// crossover channels reported ~0 phase. After the fix it cascades the same
    /// sections as `responseAt`, so a 4th-order LP shows real phase near fc.
    func testCrossoverPhaseIsCascadedNotFlat() {
        let lr4 = [FilterParams(type: .lr4_lp, freq: 1000)]
        XCTAssertGreaterThan(abs(phase(lr4, 1000)), 90,
                             "LR4 LP must contribute real (non-flat) phase at fc")
    }
}
