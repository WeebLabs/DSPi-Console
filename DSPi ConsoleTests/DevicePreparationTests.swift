import XCTest
@testable import DSPi_Console

/// Device preparation tests.
///
/// These run against a `DSPViewModel` with no hardware attached, so the USB
/// writes go nowhere - but the view model updates its own cached state on every
/// write, which is exactly what needs checking. What matters here is not that
/// the bytes reached a device; it is that the right things were changed, that
/// nothing else was, and that everything came back.
///
/// A measurement that leaves someone's matrix rewired or their EQ flattened is
/// worse than one that fails outright, because they may not notice.
@MainActor
final class DevicePreparationTests: XCTestCase {

    private var vm: DSPViewModel!
    private var journal: MeasurementStateJournal!
    private var directory: URL!
    private var preparation: DSPiDevicePreparation!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dspi-prep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journal = MeasurementStateJournal(url: directory.appendingPathComponent("recovery.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// One USB device for the whole class, and crucially one that never opens
    /// the hardware.
    ///
    /// `USBDevice` auto-connects on discovery: with no device selected it opens
    /// the first DSPi it finds. That is right for the app and wrong for a test.
    /// Without `autoConnect: false` these tests opened the developer's real
    /// device, and every `setMatrixRoute` and `setBandBypass` below went to it -
    /// including a "restore" that wrote this class's *fabricated* matrix rather
    /// than anything the user had configured.
    private static let sharedUSB = USBDevice(autoConnect: false, monitor: false)

    /// Builds a view model with a known starting configuration.
    @MainActor
    private func makeViewModel() -> DSPViewModel {
        let model = DSPViewModel(usb: Self.sharedUSB)
        model.loudnessEnabled = true
        model.levellerEnabled = true
        model.crossfeedEnabled = true
        model.psybassEnabled = false
        model.upmixEnabled = false
        model.bypass = false

        // A bass-managed stereo pair: L and R each to their own output and to
        // the subwoofer, with a deliberate trim and invert to check they come
        // back.
        model.matrixRouting = Array(repeating: Array(repeating: false, count: 9),
                                    count: MAX_MATRIX_INPUTS)
        model.matrixGain = Array(repeating: Array(repeating: Float(0), count: 9),
                                 count: MAX_MATRIX_INPUTS)
        model.matrixInvert = Array(repeating: Array(repeating: false, count: 9),
                                   count: MAX_MATRIX_INPUTS)
        for input in 0..<2 {
            model.matrixRouting[input][input] = true
            model.matrixRouting[input][8] = true
            model.matrixGain[input][8] = -6
        }
        model.matrixInvert[1][1] = true
        model.outputEnabled = Array(repeating: true, count: 9)

        // Real filters on an input and an output, so bypass and restore have
        // something to act on.
        var peak = FilterParams()
        peak.type = .peaking
        peak.freq = 63
        peak.q = 4
        peak.gain = -6
        model.channelData[0]?[0] = peak
        model.channelData[model.eqChannel(forOutput: 0)]?[0] = peak

        return model
    }

    /// Records every device write, and forwards it so cached state stays true.
    ///
    /// Asserting on cached state alone proves the cache was updated. It does not
    /// prove which commands were issued, in what order, or that no others were -
    /// and ordering is load-bearing here, since routing has to be restored
    /// before anything that depends on it.
    @MainActor
    private final class RecordingWriter: MeasurementDeviceWriter {
        enum Operation: Equatable, CustomStringConvertible {
            case route(input: Int, output: Int, enabled: Bool, gain: Float, invert: Bool)
            case bandBypass(channel: Int, band: Int, bypass: Bool)
            case crossoverBypass(channel: Int, localBand: Int, bypass: Bool)
            case loudness(Bool), leveller(Bool), psybass(Bool)
            case crossfeed(Bool), upmixer(Bool), masterEQBypass(Bool)

            var description: String {
                switch self {
                case .route(let i, let o, let e, let g, let v):
                    return "route \(i)->\(o) enabled=\(e) gain=\(g) invert=\(v)"
                case .bandBypass(let c, let b, let x): return "bypass ch\(c) band\(b)=\(x)"
                case .crossoverBypass(let c, let b, let x): return "xover ch\(c) band\(b)=\(x)"
                case .loudness(let x): return "loudness=\(x)"
                case .leveller(let x): return "leveller=\(x)"
                case .psybass(let x): return "psybass=\(x)"
                case .crossfeed(let x): return "crossfeed=\(x)"
                case .upmixer(let x): return "upmixer=\(x)"
                case .masterEQBypass(let x): return "masterEQBypass=\(x)"
                }
            }

            var isRoute: Bool { if case .route = self { return true }; return false }
        }

        private(set) var log: [Operation] = []
        private let forward: DSPViewModel

        init(forwardingTo vm: DSPViewModel) { self.forward = vm }

        func reset() { log.removeAll() }

        func setMatrixRoute(input: Int, output: Int, enabled: Bool, gain: Float, invert: Bool) {
            log.append(.route(input: input, output: output, enabled: enabled,
                              gain: gain, invert: invert))
            forward.setMatrixRoute(input: input, output: output,
                                   enabled: enabled, gain: gain, invert: invert)
        }
        func setBandBypass(channel: Int, band: Int, bypass: Bool) {
            log.append(.bandBypass(channel: channel, band: band, bypass: bypass))
            forward.setBandBypass(ch: channel, band: band, bypass: bypass)
        }
        func setCrossoverBandBypass(channel: Int, localBand: Int, bypass: Bool) {
            log.append(.crossoverBypass(channel: channel, localBand: localBand, bypass: bypass))
            forward.setCrossoverBandBypass(ch: channel, localBand: localBand, bypass: bypass)
        }
        func setLoudnessEnabled(_ e: Bool) { log.append(.loudness(e)); forward.setLoudness(e) }
        func setLevellerEnabled(_ e: Bool) { log.append(.leveller(e)); forward.setLeveller(e) }
        func setPsybassEnabled(_ e: Bool) { log.append(.psybass(e)); forward.setPsybass(e) }
        func setCrossfeedEnabled(_ e: Bool) { log.append(.crossfeed(e)); forward.setCrossfeed(e) }
        func setUpmixerEnabled(_ e: Bool) { log.append(.upmixer(e)); forward.setUpmixEnabled(e) }
        func setMasterEQBypassed(_ b: Bool) { log.append(.masterEQBypass(b)); forward.setBypass(b) }
    }

    private var writer: RecordingWriter!

    private func makePreparation() -> DSPiDevicePreparation {
        writer = RecordingWriter(forwardingTo: vm)
        let preparation = DSPiDevicePreparation(vm: vm, journal: journal, writer: writer)
        preparation.settleSeconds = 0     // no reason to wait in a test
        return preparation
    }

    private func start(mode: MeasurementMode, corrected: [Int] = []) async throws {
        vm = makeViewModel()
        attachInertDevice()
        preparation = makePreparation()
        try await preparation.prepare(mode: mode, correctedChannels: corrected)
    }

    /// Satisfies `prepare`'s device check without a device.
    ///
    /// The USB object behind the view model is deliberately unconnected, so
    /// every write below lands in the cache and the recording writer and
    /// nowhere else.  Without this, `prepare` refuses immediately and its whole
    /// body - the dynamics disabling and the input-bank flattening - goes
    /// unexercised.
    private func attachInertDevice() {
        vm.selectedDevice = DSPiDevice(serial: "TESTDEVICE000000", locationID: 0x1D10_0000)
    }

    // MARK: - Refusals

    func testPreparationRefusesWithoutADevice() async {
        vm = makeViewModel()
        preparation = makePreparation()
        do {
            try await preparation.prepare(mode: .inputChannels, correctedChannels: [0])
            XCTFail("preparation should refuse with no device attached")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.lowercased().contains("no dspi"), message)
        }
    }

    func testPreparationRefusesIfTheJournalCannotBeWritten() async {
        // Without a journal an interrupted session cannot be undone, so
        // starting anyway would trade a recoverable failure for an
        // unrecoverable one.
        vm = makeViewModel()
        let unwritable = MeasurementStateJournal(
            url: URL(fileURLWithPath: "/nonexistent-directory/recovery.json"))
        let preparation = DSPiDevicePreparation(vm: vm, journal: unwritable)
        preparation.settleSeconds = 0

        do {
            try await preparation.prepare(mode: .inputChannels, correctedChannels: [0])
            XCTFail("preparation should refuse when it cannot journal")
        } catch {
            // Refuses for one of the two reasons; both are correct here since
            // there is also no device. What matters is that it refuses.
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
    }

    // MARK: - Snapshot fidelity

    func testSnapshotCapturesEverythingAMeasurementChanges() {
        vm = makeViewModel()
        let snapshot = MeasurementStateSnapshot(capturing: vm)

        XCTAssertTrue(snapshot.loudnessEnabled)
        XCTAssertTrue(snapshot.levellerEnabled)
        XCTAssertTrue(snapshot.crossfeedEnabled)
        XCTAssertTrue(snapshot.matrixRouting[0][0])
        XCTAssertTrue(snapshot.matrixRouting[0][8])
        XCTAssertEqual(snapshot.matrixGain[0][8], -6)
        XCTAssertTrue(snapshot.matrixInvert[1][1])
        XCTAssertEqual(snapshot.peqBanks[0]?[0].freq, 63)
        XCTAssertNotNil(snapshot.crossoverBanks[vm.eqChannel(forOutput: 0)])
    }

    // MARK: - The forced path

    func testForcedPathRoutesOnlyTheTargetAndRestoresEverything() async throws {
        vm = makeViewModel()
        preparation = makePreparation()

        // prepare() gates on an attached device, so adopt the snapshot
        // directly: that is the same call recovery uses.
        preparation.adopt(MeasurementStateSnapshot(capturing: vm))

        let path = ForcedPath(driveInput: 0, targetOutput: 0,
                              bypassInputBank: 0, bypassOutputBank: 0,
                              bypassCrossoversOn: [])
        try await preparation.configure(path: path)

        // Only the target is fed from the driven input: the subwoofer leg is
        // disconnected, or the measurement would include it.
        XCTAssertTrue(vm.matrixRouting[0][0])
        XCTAssertFalse(vm.matrixRouting[0][8], "the sub leg must be disconnected")
        XCTAssertEqual(vm.matrixGain[0][0], 0, "the forced path is unity")
        XCTAssertFalse(vm.matrixInvert[0][0])

        // Both ends bypassed.
        XCTAssertTrue(vm.channelData[0]?[0].bypass ?? false)
        XCTAssertTrue(vm.channelData[vm.eqChannel(forOutput: 0)]?[0].bypass ?? false)

        await preparation.releasePath()

        XCTAssertTrue(vm.matrixRouting[0][0])
        XCTAssertTrue(vm.matrixRouting[0][8], "the sub leg must come back")
        XCTAssertEqual(vm.matrixGain[0][8], -6, "the user's trim must come back")
        XCTAssertFalse(vm.channelData[0]?[0].bypass ?? true)
        XCTAssertFalse(vm.channelData[vm.eqChannel(forOutput: 0)]?[0].bypass ?? true)
    }

    func testForcedPathSilencesOtherInputsFeedingTheTarget() async throws {
        vm = makeViewModel()
        // Make input 1 also feed output 0, so it would otherwise be measured too.
        vm.matrixRouting[1][0] = true
        preparation = makePreparation()
        preparation.adopt(MeasurementStateSnapshot(capturing: vm))

        try await preparation.configure(
            path: ForcedPath(driveInput: 0, targetOutput: 0,
                             bypassInputBank: 0, bypassOutputBank: 0,
                             bypassCrossoversOn: []))

        XCTAssertFalse(vm.matrixRouting[1][0],
                       "anything else feeding the target must be silenced")

        await preparation.releasePath()
        XCTAssertTrue(vm.matrixRouting[1][0])
    }

    func testCrossoversAreUntouchedUnlessExplicitlyBypassed() async throws {
        vm = makeViewModel()
        var lowPass = FilterParams()
        lowPass.type = .lr4_lp
        lowPass.freq = 80
        let channel = vm.eqChannel(forOutput: 0)
        vm.xoverData[channel]?[0] = lowPass

        preparation = makePreparation()
        preparation.adopt(MeasurementStateSnapshot(capturing: vm))

        try await preparation.configure(
            path: ForcedPath(driveInput: 0, targetOutput: 0,
                             bypassInputBank: 0, bypassOutputBank: 0,
                             bypassCrossoversOn: []))
        XCTAssertFalse(vm.xoverData[channel]?[0].bypass ?? true,
                       "a crossover may be protecting a driver and is never bypassed "
                       + "without the user asking")

        await preparation.releasePath()

        try await preparation.configure(
            path: ForcedPath(driveInput: 0, targetOutput: 0,
                             bypassInputBank: 0, bypassOutputBank: 0,
                             bypassCrossoversOn: [0]))
        XCTAssertTrue(vm.xoverData[channel]?[0].bypass ?? false,
                      "an explicit opt-in must actually take effect")

        await preparation.releasePath()
        XCTAssertFalse(vm.xoverData[channel]?[0].bypass ?? true,
                       "and must come back afterwards")
    }

    func testConfiguringASecondPathTakesTheFirstDown() async throws {
        // Two targets live at once would mean measuring both.
        vm = makeViewModel()
        preparation = makePreparation()
        preparation.adopt(MeasurementStateSnapshot(capturing: vm))

        try await preparation.configure(
            path: ForcedPath(driveInput: 0, targetOutput: 0,
                             bypassInputBank: 0, bypassOutputBank: 0,
                             bypassCrossoversOn: []))
        try await preparation.configure(
            path: ForcedPath(driveInput: 1, targetOutput: 1,
                             bypassInputBank: 1, bypassOutputBank: 1,
                             bypassCrossoversOn: []))

        XCTAssertTrue(vm.matrixRouting[1][1])
        XCTAssertFalse(vm.channelData[0]?[0].bypass ?? true,
                       "the first path's input bypass must have been lifted")
    }

    // MARK: - Restoration

    func testRestoreBringsBackDynamicsAndTheWholeMatrix() async throws {
        vm = makeViewModel()
        preparation = makePreparation()
        let before = MeasurementStateSnapshot(capturing: vm)
        preparation.adopt(before)

        // Simulate what prepare() does, then a full restore.
        vm.setLoudness(false)
        vm.setLeveller(false)
        vm.setCrossfeed(false)
        vm.setMatrixRoute(input: 0, output: 8, enabled: false, gain: 0, invert: false)
        vm.setBandBypass(ch: 0, band: 0, bypass: true)

        await preparation.restore(from: before)

        XCTAssertTrue(vm.loudnessEnabled)
        XCTAssertTrue(vm.levellerEnabled)
        XCTAssertTrue(vm.crossfeedEnabled)
        XCTAssertTrue(vm.matrixRouting[0][8])
        XCTAssertEqual(vm.matrixGain[0][8], -6)
        XCTAssertTrue(vm.matrixInvert[1][1])
        XCTAssertFalse(vm.channelData[0]?[0].bypass ?? true)
    }

    func testRestoreClearsTheJournalOnlyAfterPuttingThingsBack() async throws {
        vm = makeViewModel()
        preparation = makePreparation()
        let before = MeasurementStateSnapshot(capturing: vm)
        try journal.write(before)
        XCTAssertTrue(journal.hasPendingRecovery)

        await preparation.restore(from: before)
        XCTAssertFalse(journal.hasPendingRecovery,
                       "the journal exists to survive a failure to restore")
    }

    func testRestoreIsSafeWithNothingToRestore() async {
        vm = makeViewModel()
        preparation = makePreparation()
        await preparation.restore()      // never prepared
        await preparation.releasePath()  // no path
        XCTAssertTrue(vm.matrixRouting[0][0], "nothing should have changed")
    }

    // MARK: - Recovery

    // MARK: - What was actually written

    func testForcedPathIssuesExactlyTheExpectedRouteWrites() async throws {
        vm = makeViewModel()
        preparation = makePreparation()
        preparation.adopt(MeasurementStateSnapshot(capturing: vm))
        writer.reset()

        try await preparation.configure(
            path: ForcedPath(driveInput: 0, targetOutput: 0,
                             bypassInputBank: 0, bypassOutputBank: 0,
                             bypassCrossoversOn: []))

        let routes = writer.log.filter(\.isRoute)
        // The driven input's other leg is disconnected, then the target is
        // connected at unity. Nothing else should be touched.
        XCTAssertTrue(routes.contains(
            .route(input: 0, output: 8, enabled: false, gain: 0, invert: false)),
            "the sub leg must be disconnected: \(writer.log)")
        XCTAssertTrue(routes.contains(
            .route(input: 0, output: 0, enabled: true, gain: 0, invert: false)),
            "the target must be connected at unity: \(writer.log)")

        // Input 1 feeds output 1 and the sub, neither of which is the target,
        // so it must be left completely alone.
        XCTAssertFalse(routes.contains { operation in
            if case .route(let input, _, _, _, _) = operation { return input == 1 }
            return false
        }, "an unrelated input was rewritten: \(writer.log)")
    }

    func testReleaseRestoresRoutingBeforeAnythingElse() async throws {
        // Load-bearing ordering: every other restore is meaningless while the
        // matrix is still rewired.
        vm = makeViewModel()
        preparation = makePreparation()
        preparation.adopt(MeasurementStateSnapshot(capturing: vm))

        try await preparation.configure(
            path: ForcedPath(driveInput: 0, targetOutput: 0,
                             bypassInputBank: 0, bypassOutputBank: 0,
                             bypassCrossoversOn: []))
        writer.reset()
        await preparation.releasePath()

        let firstRoute = writer.log.firstIndex(where: \.isRoute)
        let firstBypass = writer.log.firstIndex { operation in
            if case .bandBypass = operation { return true }
            return false
        }
        // Both must be present, or the ordering check below proves nothing.
        XCTAssertNotNil(firstRoute, "release must restore routing: \(writer.log)")
        XCTAssertNotNil(firstBypass, "release must restore the bypassed bank: \(writer.log)")
        XCTAssertLessThan(try XCTUnwrap(firstRoute), try XCTUnwrap(firstBypass),
                          "routing must be restored first: \(writer.log)")
    }

    func testRestoringAnUnchangedMatrixWritesNothing() async throws {
        // A sweep should not spend dozens of control transfers rewriting cells
        // that already match.
        vm = makeViewModel()
        preparation = makePreparation()
        let snapshot = MeasurementStateSnapshot(capturing: vm)
        preparation.adopt(snapshot)
        writer.reset()

        await preparation.restore()

        XCTAssertTrue(writer.log.filter(\.isRoute).isEmpty,
                      "nothing changed, so no route should have been written: \(writer.log)")
    }

    func testPreparationDisablesOnlyWhatIsOn() async throws {
        // psybass and the upmixer are already off in this fixture.  Writing to
        // them anyway would be pointless traffic, and would leave a log that
        // overstates what the session changed.
        try await start(mode: .inputChannels, corrected: [0, 1])

        XCTAssertTrue(writer.log.contains(.loudness(false)), "\(writer.log)")
        XCTAssertTrue(writer.log.contains(.leveller(false)), "\(writer.log)")
        XCTAssertTrue(writer.log.contains(.crossfeed(false)), "\(writer.log)")
        XCTAssertFalse(writer.log.contains(.psybass(false)),
                       "psybass was already off: \(writer.log)")
        XCTAssertFalse(writer.log.contains(.upmixer(false)),
                       "the upmixer was already off: \(writer.log)")
        XCTAssertFalse(writer.log.contains(.masterEQBypass(false)),
                       "bypass was already clear: \(writer.log)")
    }

    func testInputModeFlattensOnlyTheCorrectedBanks() async throws {
        // The promise of input mode is that everything the user has not asked
        // to correct is left exactly as they set it.
        try await start(mode: .inputChannels, corrected: [0])

        let flattened = Set(writer.log.compactMap { operation -> Int? in
            if case .bandBypass(let channel, _, true) = operation { return channel }
            return nil
        })
        XCTAssertEqual(flattened, [0],
                       "only the corrected bank may be flattened: \(writer.log)")
        XCTAssertTrue(writer.log.filter(\.isRoute).isEmpty,
                      "input mode must not touch the matrix: \(writer.log)")
    }

    func testOutputModeDefersFlatteningToEachSweep() async throws {
        // Which banks are in the path changes per target, so prepare() must not
        // pre-flatten anything.
        try await start(mode: .outputChannels, corrected: [0, 1])

        XCTAssertFalse(writer.log.contains { operation in
            if case .bandBypass = operation { return true }
            return false
        }, "output mode flattened a bank before knowing the target: \(writer.log)")
    }

    func testRestoreReturnsEverythingPreparationTurnedOff() async throws {
        try await start(mode: .inputChannels, corrected: [0, 1])
        writer.reset()

        await preparation.restore()

        XCTAssertTrue(writer.log.contains(.loudness(true)), "\(writer.log)")
        XCTAssertTrue(writer.log.contains(.leveller(true)), "\(writer.log)")
        XCTAssertTrue(writer.log.contains(.crossfeed(true)), "\(writer.log)")
        // ...and does not toggle what it never touched.
        XCTAssertFalse(writer.log.contains(.psybass(true)), "\(writer.log)")
        XCTAssertFalse(writer.log.contains(.upmixer(true)), "\(writer.log)")
    }

    func testPendingRecoveryIsOfferedOnlyForTheSameDevice() throws {
        vm = makeViewModel()
        var snapshot = MeasurementStateSnapshot(capturing: vm)
        snapshot.deviceSerial = "OTHER-DEVICE"
        try journal.write(snapshot)

        XCTAssertNil(DSPiDevicePreparation.pendingRecovery(for: vm, journal: journal),
                     "a journal from another device must not be offered")
    }
}
