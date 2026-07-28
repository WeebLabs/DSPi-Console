import XCTest
@testable import DSPi_Console

/// Covers the step between the setup screen and the device: what the user
/// picked becoming the sweeps that actually run.
///
/// The crossover decision is the reason this needs its own tests.  It is the
/// only choice in the window that can destroy hardware, and a UI control that
/// looks like it is doing something while the sweep quietly runs the other way
/// would be worse than not offering it at all.
@MainActor
final class RoomCorrectionPlanTests: XCTestCase {

    /// One view model and one catalog for the whole class, on an unconnected
    /// USB object.  A live one receives connect callbacks and issues a full
    /// parameter fetch on the same serial queue the device tests use.
    private static let shared: (usb: USBDevice, catalog: AudioDeviceCatalog) = {
        (USBDevice(autoConnect: false, monitor: false),
         AudioDeviceCatalog(startListening: false))
    }()

    /// A bass-managed stereo pair: each input to its own output and to the sub.
    private func makeModel() -> RoomCorrectionModel {
        let vm = DSPViewModel(usb: Self.shared.usb)
        vm.matrixRouting = Array(repeating: Array(repeating: false, count: 9),
                                 count: MAX_MATRIX_INPUTS)
        vm.matrixGain = Array(repeating: Array(repeating: Float(0), count: 9),
                              count: MAX_MATRIX_INPUTS)
        vm.matrixInvert = Array(repeating: Array(repeating: false, count: 9),
                                count: MAX_MATRIX_INPUTS)
        for input in 0..<2 {
            vm.matrixRouting[input][input] = true
            vm.matrixRouting[input][8] = true
        }
        vm.outputEnabled = Array(repeating: true, count: 9)
        return RoomCorrectionModel(vm: vm, catalog: Self.shared.catalog)
    }

    private func putCrossover(_ type: FilterType, _ hz: Float,
                              onOutput output: Int, of model: RoomCorrectionModel) {
        var band = FilterParams()
        band.type = type
        band.freq = hz
        let channel = model.vm.eqChannel(forOutput: output)
        if model.vm.xoverData[channel] == nil {
            model.vm.xoverData[channel] = Array(repeating: FilterParams(), count: 4)
        }
        model.vm.xoverData[channel]?[0] = band
    }

    // MARK: - Disclosure surfacing

    func testInputModeNeverDisclosesACrossover() {
        // Input mode measures the system as configured, so a crossover is part
        // of what is being corrected rather than something in the way.
        let model = makeModel()
        model.mode = .outputChannels
        model.modeChanged()
        putCrossover(.lr4_hp, 80, onOutput: 0, of: model)
        XCTAssertFalse(model.crossoverDisclosures.isEmpty, "fixture check")

        model.mode = .inputChannels
        model.modeChanged()
        XCTAssertTrue(model.crossoverDisclosures.isEmpty)
    }

    func testOnlySelectedOutputsAreDisclosed() {
        let model = makeModel()
        model.mode = .outputChannels
        model.modeChanged()
        putCrossover(.lr4_hp, 80, onOutput: 0, of: model)
        putCrossover(.lr4_hp, 80, onOutput: 1, of: model)

        model.selectedTargets = [1]
        model.targetsChanged()

        XCTAssertEqual(model.crossoverDisclosures.map(\.outputIndex), [1])
    }

    // MARK: - Consent is not carried anywhere it was not given

    func testDeselectingATargetWithdrawsItsBypass() {
        // Otherwise re-selecting the speaker later would silently restore a
        // decision the user made about a different plan.
        let model = makeModel()
        model.mode = .outputChannels
        model.modeChanged()
        putCrossover(.lr4_hp, 80, onOutput: 0, of: model)
        model.bypassCrossoverOutputs = [0]

        model.selectedTargets.remove(0)
        model.targetsChanged()

        XCTAssertFalse(model.bypassCrossoverOutputs.contains(0))
    }

    func testChangingModeClearsEveryBypass() {
        // Indices mean different things in each mode, so a bypass carried
        // across would land on an unrelated channel.
        let model = makeModel()
        model.mode = .outputChannels
        model.modeChanged()
        model.bypassCrossoverOutputs = [0, 1]

        model.mode = .inputChannels
        model.modeChanged()

        XCTAssertTrue(model.bypassCrossoverOutputs.isEmpty)
    }

    // MARK: - The choice reaching the sweep

    func testAPlanBypassesExactlyTheOutputsTheUserOptedIn() throws {
        let model = makeModel()
        model.mode = .outputChannels
        model.modeChanged()
        model.selectedTargets = [0, 1]
        model.bypassCrossoverOutputs = [1]

        let plans = try model.speakerPlans()
        let bypassed = plans.reduce(into: [Int: [Int]]()) { result, plan in
            result[plan.speakerIndex] = plan.forcedPath?.bypassCrossoversOn
        }

        XCTAssertEqual(bypassed[0], [], "no opt-in, so no bypass")
        XCTAssertEqual(bypassed[1], [1])
    }

    func testTheDefaultPlanBypassesNothing() throws {
        let model = makeModel()
        model.mode = .outputChannels
        model.modeChanged()
        model.selectedTargets = [0, 1]

        let plans = try model.speakerPlans()
        XCTAssertTrue(plans.allSatisfy { $0.forcedPath?.bypassCrossoversOn.isEmpty ?? false },
                      "a crossover must never be bypassed without being asked for")
    }

    func testInputModePlansForceNothingAtAll() throws {
        let model = makeModel()
        model.mode = .inputChannels
        model.modeChanged()
        // Even if a stale bypass somehow survived, input mode has no path to
        // apply it through.
        model.bypassCrossoverOutputs = [0, 1]

        let plans = try model.speakerPlans()
        XCTAssertFalse(plans.isEmpty)
        XCTAssertTrue(plans.allSatisfy { $0.forcedPath == nil })
        XCTAssertEqual(plans.map(\.playbackChannel), plans.map(\.speakerIndex),
                       "an input is driven directly")
    }

    func testPlansCarryTheChosenSweepLengthAndRole() throws {
        let model = makeModel()
        model.mode = .inputChannels
        model.modeChanged()
        model.selectedTargets = [0, 1]
        model.sweepSeconds = 12
        model.targetRoles[1] = .subwoofer

        let plans = try model.speakerPlans()
        XCTAssertEqual(plans.map(\.role), [.fullRange, .subwoofer])
        for plan in plans {
            XCTAssertEqual(plan.sweep.durationSeconds, 12, accuracy: 1e-9)
        }
        // A subwoofer sweep must not start where a full-range one does.
        let sub = try XCTUnwrap(plans.first { $0.role == .subwoofer })
        let full = try XCTUnwrap(plans.first { $0.role == .fullRange })
        XCTAssertLessThan(sub.sweep.endHz, full.sweep.endHz,
                          "a sub is not swept to 20 kHz")
    }

    func testPlansAreOrderedAndCoverEverySelectedTarget() throws {
        let model = makeModel()
        model.mode = .inputChannels
        model.modeChanged()
        model.selectedTargets = [1, 0]

        let plans = try model.speakerPlans()
        XCTAssertEqual(plans.map(\.speakerIndex), [0, 1],
                       "stable order, so a run is reproducible")
    }

    // MARK: - What the results screen is told

    func testOnlyActuallyBypassedCrossoversAreCarriedToResults() {
        let model = makeModel()
        model.mode = .outputChannels
        model.modeChanged()
        putCrossover(.lr4_hp, 80, onOutput: 0, of: model)
        putCrossover(.bw2_lp, 100, onOutput: 1, of: model)
        model.selectedTargets = [0, 1]
        model.bypassCrossoverOutputs = [0]

        XCTAssertEqual(model.bypassedForMeasurement.map(\.outputIndex), [0])
        XCTAssertEqual(model.bypassedForMeasurement.first?.description,
                       "LR4 high-pass at 80 Hz",
                       "the results screen needs the specifics, not just a flag")
    }

    func testASubwooferTargetLowersTheQuotedSweepStart() {
        // The warning tells the user what will hit an unprotected driver, so
        // the figure has to be the lowest the run will actually reach.
        let model = makeModel()
        model.selectedTargets = [0]
        XCTAssertEqual(model.sweepStartHz, 20)

        model.targetRoles[0] = .subwoofer
        XCTAssertEqual(model.sweepStartHz, 10)
    }
}
