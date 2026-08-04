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

    func testFirstOrderPassIsMinus3dBAtCornerAndHalfAsSteep() {
        // Single-pole rolloff: -3 dB at fc, 6 dB/oct (so ~-20 dB a decade out),
        // and monotonic - no resonant peak whatever the (ignored) Q says.
        let lp1 = [FilterParams(type: .lowPass1, freq: 1000, q: 5.0)]
        let hp1 = [FilterParams(type: .highPass1, freq: 1000, q: 5.0)]

        XCTAssertEqual(mag(lp1, 1000), -3.01, accuracy: 0.2, "LP1 is -3 dB at fc")
        XCTAssertEqual(mag(hp1, 1000), -3.01, accuracy: 0.2, "HP1 is -3 dB at fc")
        XCTAssertEqual(mag(lp1, 50), 0, accuracy: 0.2, "LP1 passband is flat below fc")
        XCTAssertEqual(mag(hp1, 18000), 0, accuracy: 0.3, "HP1 passband is flat above fc")
        XCTAssertEqual(mag(lp1, 10000), -20, accuracy: 1.5, "LP1 loses ~20 dB a decade above fc")
        XCTAssertEqual(mag(hp1, 100), -20, accuracy: 1.5, "HP1 loses ~20 dB a decade below fc")

        // Half the slope of the second-order pair, two octaves out.
        let lp2 = [FilterParams(type: .lowPass, freq: 1000, q: 0.7071)]
        XCTAssertEqual(mag(lp1, 4000), mag(lp2, 4000) / 2, accuracy: 1.5,
                       "LP1 rolls off at half the rate of the 12 dB/oct low pass")
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

    // MARK: Linkwitz Transform (type 11)

    /// LT with fp < f0 boosts the low end: DC gain approaches 40*log10(f0/fp)
    /// and the response returns to unity above the driver corner.  freq = f0,
    /// gain = fp (Hz), qp = Qp.
    func testLinkwitzTransformDCBoostAndUnityAbove() {
        var lt = FilterParams(type: .linkwitzTransform, freq: 55, q: 1.1)
        lt.gain = 25          // fp in Hz
        lt.qp = 0.55
        let boost: Float = 40 * log10(55.0 / 25.0)  // ~13.7 dB
        XCTAssertEqual(mag([lt], 3), boost, accuracy: 0.4, "LT approaches DC boost well below fp")
        XCTAssertEqual(mag([lt], 15000), 0, accuracy: 0.2, "LT returns to unity well above f0")
    }

    /// When the target matches the driver (fp == f0, Qp == Q0) the numerator
    /// and denominator are identical, so the transform is transparent.
    func testLinkwitzTransformTransparentWhenTargetEqualsDriver() {
        var lt = FilterParams(type: .linkwitzTransform, freq: 60, q: 0.9)
        lt.gain = 60          // fp == f0
        lt.qp = 0.9           // Qp == Q0
        for f: Float in [10, 50, 100, 1000, 10000] {
            XCTAssertEqual(mag([lt], f), 0, accuracy: 0.05, "LT is flat at \(f) Hz when target == driver")
        }
    }

    /// fp <= 0 makes the LT band flat (matches firmware clamp semantics).
    func testLinkwitzTransformFlatWhenTargetFreqZero() {
        var lt = FilterParams(type: .linkwitzTransform, freq: 55, q: 1.1)
        lt.gain = 0           // fp <= 0
        for f: Float in [10, 100, 1000] {
            XCTAssertEqual(mag([lt], f), 0, accuracy: 1e-4, "LT with fp<=0 is flat at \(f) Hz")
        }
    }

    /// qp round-trips through the wire encoding (Qp x 512); 0 decodes to the
    /// 0.707 default, and non-LT bands never emit a qp.
    func testLinkwitzQpEncodeDecode() {
        var lt = FilterParams(type: .linkwitzTransform, freq: 55, q: 1.1)
        lt.gain = 25
        lt.qp = 0.55
        XCTAssertEqual(lt.qpEncoded, 282, "round(0.55 x 512)")
        XCTAssertEqual(FilterParams.decodeQp(282), 0.55, accuracy: 0.002)
        XCTAssertEqual(FilterParams.decodeQp(0), FilterParams.defaultQp, accuracy: 1e-6, "0 selects the 0.707 default")

        var pk = FilterParams(type: .peaking)
        pk.qp = 1.0
        XCTAssertEqual(pk.qpEncoded, 0, "non-LT bands never emit a qp")
    }

    // MARK: Type changes

    /// Switching into LT must not read the old dB gain as fp (Hz): a +6 dB
    /// peaking band would become fp = 6 Hz, a ~90 dB DC boost.  The seeded
    /// band is a neutral transform - flat until the user edits it.
    func testRetypingIntoLinkwitzSeedsNeutralTransform() {
        let peaking = FilterParams(type: .peaking, freq: 1000, q: 1.5, gain: 6.0)
        let lt = peaking.retyped(to: .linkwitzTransform)

        XCTAssertEqual(lt.gain, lt.freq, "fp seeded from f0, not from the old dB gain")
        XCTAssertEqual(lt.qp, lt.q, "Qp seeded from Q0")
        for f: Float in [10, 100, 1000, 10000] {
            XCTAssertEqual(mag([lt], f), 0, accuracy: 0.05, "seeded LT is flat at \(f) Hz")
        }
    }

    /// f0 and Q0 are clamped into the range the firmware accepts.
    func testRetypingIntoLinkwitzClampsDriverValues() {
        let steep = FilterParams(type: .peaking, freq: 2, q: 40, gain: -3)
        let lt = steep.retyped(to: .linkwitzTransform)
        XCTAssertEqual(lt.freq, FilterParams.minFreq, "f0 clamped up to the field minimum")
        XCTAssertEqual(lt.q, FilterParams.qRange.upperBound, "Q0 clamped to the firmware maximum")
    }

    /// Leaving LT drops fp so it can't be read as a large dB boost.
    func testRetypingOutOfLinkwitzClearsGain() {
        var lt = FilterParams(type: .linkwitzTransform, freq: 55, q: 1.1)
        lt.gain = 28          // fp in Hz
        XCTAssertEqual(lt.retyped(to: .peaking).gain, 0, "fp does not survive as +28 dB")
    }

    /// A change between two ordinary types leaves the values alone.
    func testRetypingBetweenOrdinaryTypesPreservesValues() {
        let peaking = FilterParams(type: .peaking, freq: 120, q: 0.9, gain: -4.5)
        let shelf = peaking.retyped(to: .lowShelf)
        XCTAssertEqual(shelf.freq, 120)
        XCTAssertEqual(shelf.q, 0.9)
        XCTAssertEqual(shelf.gain, -4.5)
    }

    // MARK: Firmware capability gates

    /// The first-order low/high pass types never bumped the wire format, and
    /// V27 is ambiguous (bumped on main while the filter branch was in flight,
    /// so early V27 builds lack the types).  V28 is the first version that
    /// always carries them, so that is where the picker may offer them.
    func testFirstOrderPassGateIsV28() {
        let vm = DSPViewModel()
        vm.isDeviceConnected = true

        vm.firmwareWireFormatVersion = 27
        XCTAssertFalse(vm.firmwareSupportsFirstOrderPass, "V27 is ambiguous, so treated as unsupported")
        XCTAssertFalse(vm.firmwareSupports(filterType: .lowPass1))
        XCTAssertFalse(vm.firmwareSupports(filterType: .highPass1))
        // The second-order pair is ancient and stays available either way.
        XCTAssertTrue(vm.firmwareSupports(filterType: .lowPass))
        XCTAssertTrue(vm.firmwareSupports(filterType: .highPass))

        vm.firmwareWireFormatVersion = 28
        XCTAssertTrue(vm.firmwareSupportsFirstOrderPass)
        XCTAssertTrue(vm.firmwareSupports(filterType: .lowPass1))
        XCTAssertTrue(vm.firmwareSupports(filterType: .highPass1))
    }
}
