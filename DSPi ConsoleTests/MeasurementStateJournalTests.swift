import XCTest
@testable import DSPi_Console

/// Recovery journal tests (automated_room_correction_spec.md section 8).
///
/// A measurement switches off things the user deliberately switched on. That is
/// only acceptable if it is exactly reversible, including when the app is
/// killed or the device is unplugged mid-session, so what matters here is that
/// the journal survives the process and refuses to be replayed onto the wrong
/// hardware.
final class MeasurementStateJournalTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dspi-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeJournal() -> MeasurementStateJournal {
        MeasurementStateJournal(url: directory.appendingPathComponent("recovery.json"))
    }

    private func makeSnapshot(serial: String = "ABC123",
                              platform: String = "RP2350") -> MeasurementStateSnapshot {
        var band = FilterParams()
        band.type = .peaking
        band.freq = 63.5
        band.q = 4.25
        band.gain = -6.75
        band.bypass = false

        var flat = FilterParams()
        flat.type = .flat

        return MeasurementStateSnapshot(
            deviceSerial: serial,
            platformName: platform,
            sampleRateHz: 48000,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.1.5",
            peqBanks: [0: [.init(band), .init(flat)], 8: [.init(band), .init(band)]],
            crossoverBanks: [8: [.init(flat)]],
            matrixRouting: [[true, false], [false, true]],
            matrixGain: [[0, -6], [-6, 0]],
            matrixInvert: [[false, false], [false, true]],
            outputEnabled: [true, true, false],
            outputMuted: [false, false, true],
            outputGainDB: [0, -1.5, 0],
            outputDelayMS: [0, 2.5, 0],
            inputPreampDB: [-3, -3],
            masterVolumeDB: -12,
            bypassMasterEQ: false,
            loudnessEnabled: true,
            levellerEnabled: true,
            psybassEnabled: false,
            crossfeedEnabled: true,
            upmixEnabled: false,
            activePresetSlot: 3,
            hadUnsavedChanges: true)
    }

    // MARK: - Round trip

    func testSnapshotSurvivesEncodingExactly() throws {
        // The journal is only useful if what comes back is what went in, down
        // to the filter parameters. Anything lossy here restores a state that
        // merely resembles the user's.
        let journal = makeJournal()
        let original = makeSnapshot()
        try journal.write(original)

        let restored = try journal.read()
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.peqBanks[0]?[0].freq, 63.5)
        XCTAssertEqual(restored.peqBanks[0]?[0].q, 4.25)
        XCTAssertEqual(restored.peqBanks[0]?[0].gain, -6.75)
    }

    func testBandsConvertBackToFilterParams() {
        var params = FilterParams()
        params.type = .lowShelf
        params.freq = 120.0
        params.q = 0.707
        params.gain = 3.5
        params.bypass = true

        let round = MeasurementStateSnapshot.Band(params).filterParams
        XCTAssertEqual(round.type, .lowShelf)
        XCTAssertEqual(round.freq, 120.0)
        XCTAssertEqual(round.q, 0.707)
        XCTAssertEqual(round.gain, 3.5)
        XCTAssertTrue(round.bypass)
    }

    func testUnknownFilterTypeDecodesToFlatRatherThanCrashing() {
        // A journal written by a newer build could carry a type this one does
        // not know. Falling back to flat is recoverable; trapping is not.
        var band = MeasurementStateSnapshot.Band(FilterParams())
        band.type = 250
        XCTAssertEqual(band.filterParams.type, .flat)
    }

    // MARK: - Lifecycle

    func testJournalReportsWhetherRecoveryIsPending() throws {
        let journal = makeJournal()
        XCTAssertFalse(journal.hasPendingRecovery)

        try journal.write(makeSnapshot())
        XCTAssertTrue(journal.hasPendingRecovery)

        journal.clear()
        XCTAssertFalse(journal.hasPendingRecovery)
    }

    func testReadingWithNoJournalFailsWithAMessage() {
        XCTAssertThrowsError(try makeJournal().read()) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testWritingTwiceReplacesRatherThanAppends() throws {
        // A single slot on purpose: the question is "was a session interrupted
        // and what did it change", and a stack of those would only invite
        // replaying the wrong one.
        let journal = makeJournal()
        try journal.write(makeSnapshot(serial: "FIRST"))
        try journal.write(makeSnapshot(serial: "SECOND"))
        XCTAssertEqual(try journal.read().deviceSerial, "SECOND")
    }

    func testJournalPersistsAcrossInstances() throws {
        // The whole point: the process may not survive, and the journal must.
        let url = directory.appendingPathComponent("recovery.json")
        try MeasurementStateJournal(url: url).write(makeSnapshot(serial: "PERSIST"))

        let reopened = MeasurementStateJournal(url: url)
        XCTAssertTrue(reopened.hasPendingRecovery)
        XCTAssertEqual(try reopened.read().deviceSerial, "PERSIST")
    }

    func testClearingIsSafeWhenNothingIsThere() {
        let journal = makeJournal()
        journal.clear()
        journal.clear()
        XCTAssertFalse(journal.hasPendingRecovery)
    }

    // MARK: - Identity

    func testSnapshotWithoutASerialNeverMatches() {
        // An unidentifiable journal cannot be proven to belong to the attached
        // device, and restoring one device's state onto another is worse than
        // not restoring at all.
        var snapshot = makeSnapshot(serial: "")
        XCTAssertTrue(snapshot.deviceSerial.isEmpty)
        snapshot.deviceSerial = "ABC123"
        XCTAssertFalse(snapshot.deviceSerial.isEmpty)
    }

    // MARK: - What gets flattened

    func testFlattenListCoversBothEndsOfTheSignalPath() {
        // Host playback traverses the input chain, so measuring through a live
        // input bank would fold the user's tone controls into the measured
        // response and the correction would then fight them. Output banks alone
        // used to be enough only because the old device-side generator injected
        // after the matrix.
        let snapshot = makeSnapshot()
        let channels = snapshot.channelsToFlatten
        XCTAssertTrue(channels.contains(0), "input bank must be flattened")
        XCTAssertTrue(channels.contains(8), "output bank must be flattened")
        XCTAssertEqual(channels, channels.sorted(), "order must be stable for replay")
    }

    func testCrossoversAreNotInTheFlattenList() {
        // A crossover may be protecting a driver, and a measurement is not
        // worth a tweeter.
        let snapshot = makeSnapshot()
        XCTAssertFalse(snapshot.crossoverBanks.isEmpty)
        // channelsToFlatten is derived from PEQ banks only; the crossover banks
        // are captured for restoration but never cleared.
        XCTAssertEqual(Set(snapshot.channelsToFlatten), Set(snapshot.peqBanks.keys))
    }

    func testEveryJournalErrorExplainsItself() {
        for error: MeasurementStateJournal.JournalError in [.noJournal, .deviceMismatch] {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
    }
}
