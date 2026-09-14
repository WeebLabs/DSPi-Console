import XCTest
import Combine
@testable import DSPi_Console

/// Pure-logic tests for firmware versioning and the installer's decisions.
///
/// The installer is the one place in the app that can brick a board, and it
/// runs against hardware nobody can attach in CI, so everything it decides is
/// pushed behind a seam and tested here: which board it will act on, which it
/// refuses, whether a mid-write error is a reboot or a failure, and whether a
/// flash counts as successful. No device.
final class FirmwareInstallerTests: XCTestCase {

    // MARK: - Version parsing and ordering

    func testParsesPlainPointRelease() {
        XCTAssertEqual(FirmwareVersion("1.1.7"), FirmwareVersion(1, 1, 7))
    }

    /// The tag spelling carries the beta ordinal, which the device reports too;
    /// any other suffix still reads as a final release.
    func testParsesBetaSuffixAndIgnoresOthers() {
        XCTAssertEqual(FirmwareVersion("1.1.6-beta2"), FirmwareVersion(1, 1, 6, 2))
        XCTAssertEqual(FirmwareVersion("1.1.6-rc1"), FirmwareVersion(1, 1, 6))
    }

    func testMissingPatchIsZero() {
        XCTAssertEqual(FirmwareVersion("1.2"), FirmwareVersion(1, 2, 0))
    }

    func testRejectsNonNumeric() {
        XCTAssertNil(FirmwareVersion("unreleased"))
    }

    /// The whole reason the wire encoding was widened: patch runs past 9, and
    /// string ordering would get this backwards.
    func testOrdersPatchNumerically() {
        XCTAssertTrue(FirmwareVersion(1, 1, 9) < FirmwareVersion(1, 1, 10))
        XCTAssertTrue(FirmwareVersion(1, 1, 15) < FirmwareVersion(1, 2, 0))
    }

    // MARK: - Asset names

    func testReadsVersionFromAssetName() {
        XCTAssertEqual(FirmwareImage.versionFromAssetName("DSPi-RP2350-v1.1.7.uf2"),
                       FirmwareVersion(1, 1, 7))
        XCTAssertEqual(FirmwareImage.versionFromAssetName("DSPi-RP2040-v1.1.16.uf2"),
                       FirmwareVersion(1, 1, 16))
    }

    func testRejectsAssetNameWithoutVersion() {
        XCTAssertNil(FirmwareImage.versionFromAssetName("DSPi.uf2"))
    }

    // MARK: - Reboot versus failure

    /// The RP2 ROM loader resets itself as it takes the last blocks, so the
    /// volume vanishes under the final write. Reporting that as an error is
    /// the classic UF2 flasher bug.
    func testLateWriteErrorIsAReboot() {
        XCTAssertTrue(FirmwareInstaller.isRebootSignal(fractionWritten: 0.99,
                                                       volumeStillMounted: true))
    }

    func testVanishedVolumeIsARebootAtAnyPoint() {
        XCTAssertTrue(FirmwareInstaller.isRebootSignal(fractionWritten: 0.1,
                                                       volumeStillMounted: false))
    }

    /// An error early in the write, with the volume still there, is a real
    /// failure and must not be swallowed as a successful flash.
    func testEarlyWriteErrorIsAFailure() {
        XCTAssertFalse(FirmwareInstaller.isRebootSignal(fractionWritten: 0.4,
                                                        volumeStillMounted: true))
    }

    func testThresholdBoundary() {
        XCTAssertTrue(FirmwareInstaller.isRebootSignal(fractionWritten: FirmwareInstaller.rebootThreshold,
                                                       volumeStillMounted: true))
        XCTAssertFalse(FirmwareInstaller.isRebootSignal(fractionWritten: FirmwareInstaller.rebootThreshold - 0.01,
                                                        volumeStillMounted: true))
    }

    // MARK: - Which board it will act on

    func testNoBoardWaits() {
        let installer = makeInstaller(boards: [])
        installer.beginWatching()
        XCTAssertEqual(installer.state, .waitingForBoard)
    }

    func testOneMountedBoardIsReady() {
        let board = BootloaderBoard(chip: .rp2350, volumeURL: URL(fileURLWithPath: "/Volumes/RP2350"))
        let installer = makeInstaller(boards: [board])
        installer.beginWatching()
        XCTAssertEqual(installer.state, .ready(board))
    }

    /// The drive always mounts a moment after the board enumerates, so a
    /// missing volume starts as waiting, not as an error.  Calling it a
    /// failure immediately rejected any board plugged in while the window was
    /// already open, a beat before its drive appeared.
    func testBoardWithoutVolumeWaitsRatherThanFailing() {
        let installer = makeInstaller(boards: [BootloaderBoard(chip: .rp2040, volumeURL: nil)])
        installer.beginWatching()
        XCTAssertEqual(installer.state, .waitingForVolume(.rp2040))
    }

    /// A drive that never turns up is the likely shape of a denied
    /// removable-volume prompt, and the user can act on that, so it does
    /// eventually become an error naming the drive.
    func testBoardWithoutVolumeFailsOnceTheWaitElapses() {
        let clock = TestClock()
        let locator = FakeBootloaderLocator(boards: [BootloaderBoard(chip: .rp2040, volumeURL: nil)])
        let installer = FirmwareInstaller(locator: locator,
                                          verifier: StubVerifier(version: nil),
                                          imageProvider: { _ in throw FirmwareInstallError.noBoardFound },
                                          now: { clock.now })
        installer.beginWatching()
        XCTAssertEqual(installer.state, .waitingForVolume(.rp2040))

        clock.advance(FirmwareInstaller.volumeWaitTimeout)
        locator.emit()
        XCTAssertEqual(installer.state, .failed(.volumeNotMounted("RPI-RP2")))
    }

    /// The bug this pair guards: a detection failure must not latch.  A drive
    /// that shows up late has to recover on its own, or the window stays stuck
    /// on an error while the drive sits mounted in Finder.
    func testLateArrivingDriveRecoversFromTheFailure() {
        let clock = TestClock()
        let locator = FakeBootloaderLocator(boards: [BootloaderBoard(chip: .rp2350, volumeURL: nil)])
        let installer = FirmwareInstaller(locator: locator,
                                          verifier: StubVerifier(version: nil),
                                          imageProvider: { _ in throw FirmwareInstallError.noBoardFound },
                                          now: { clock.now })
        installer.beginWatching()
        clock.advance(FirmwareInstaller.volumeWaitTimeout)
        locator.emit()
        XCTAssertEqual(installer.state, .failed(.volumeNotMounted("RP2350")))

        let mounted = BootloaderBoard(chip: .rp2350, volumeURL: URL(fileURLWithPath: "/Volumes/RP2350"))
        locator.boards = [mounted]
        locator.emit()
        XCTAssertEqual(installer.state, .ready(mounted))
    }

    /// Unplugging a board must clear the wait, so plugging a second one in
    /// starts its own grace period rather than inheriting an expired one.
    func testRemovingTheBoardResetsTheVolumeWait() {
        let clock = TestClock()
        let locator = FakeBootloaderLocator(boards: [BootloaderBoard(chip: .rp2040, volumeURL: nil)])
        let installer = FirmwareInstaller(locator: locator,
                                          verifier: StubVerifier(version: nil),
                                          imageProvider: { _ in throw FirmwareInstallError.noBoardFound },
                                          now: { clock.now })
        installer.beginWatching()
        clock.advance(FirmwareInstaller.volumeWaitTimeout - 1)

        locator.boards = []
        locator.emit()
        XCTAssertEqual(installer.state, .waitingForBoard)

        locator.boards = [BootloaderBoard(chip: .rp2040, volumeURL: nil)]
        locator.emit()
        XCTAssertEqual(installer.state, .waitingForVolume(.rp2040))
    }

    /// Two boards must be refused outright rather than resolved by guessing;
    /// writing to the wrong one is not recoverable from the app.
    func testTwoBoardsAreRefused() {
        let installer = makeInstaller(boards: [
            BootloaderBoard(chip: .rp2040, volumeURL: URL(fileURLWithPath: "/Volumes/RPI-RP2")),
            BootloaderBoard(chip: .rp2350, volumeURL: nil),
        ])
        installer.beginWatching()
        XCTAssertEqual(installer.state, .failed(.multipleBoards(2)))
    }

    /// Once a write has begun the board vanishing IS the expected reboot, so
    /// detection has to stop touching the state.  Before a write, detection
    /// stays live - that asymmetry is the whole fix.
    func testDetectionDoesNotDisturbAWriteInProgress() {
        let locator = FakeBootloaderLocator(boards: [
            BootloaderBoard(chip: .rp2350, volumeURL: URL(fileURLWithPath: "/Volumes/RP2350"))
        ])
        let installer = FirmwareInstaller(locator: locator,
                                          verifier: StubVerifier(version: nil),
                                          imageProvider: { _ in throw FirmwareInstallError.noBoardFound })
        installer.beginWatching()
        installer.setStateForTesting(.writing(0.5), installing: true)
        locator.boards = []
        locator.emit()
        XCTAssertEqual(installer.state, .writing(0.5))
    }

    // MARK: - Committing to an update

    /// The hang this guards: with the board plugged in first, clicking Update
    /// changes no state, so anything that waits for `.ready` to *arrive* never
    /// fires and the window sits there forever.
    func testCommittingWithABoardAlreadyReadyStartsTheWrite() throws {
        let (volume, image) = try makeVolumeAndImage(version: FirmwareVersion(1, 1, 7))
        let board = BootloaderBoard(chip: .rp2350, volumeURL: volume)
        let installer = makeInstaller(boards: [board],
                                      verifier: StubVerifier(version: FirmwareVersion(1, 1, 7)),
                                      image: image)
        installer.beginWatching()
        XCTAssertEqual(installer.state, .ready(board))

        installer.installWhenReady()
        waitForSettledState(installer)
        XCTAssertEqual(installer.state, .verified(FirmwareVersion(1, 1, 7)))
    }

    /// The other order: commit first, board arrives later.
    func testCommittingBeforeTheBoardArrivesStartsTheWriteWhenItDoes() throws {
        let (volume, image) = try makeVolumeAndImage(version: FirmwareVersion(1, 1, 7))
        let locator = FakeBootloaderLocator(boards: [])
        let installer = FirmwareInstaller(locator: locator,
                                          verifier: StubVerifier(version: FirmwareVersion(1, 1, 7)),
                                          imageProvider: { _ in image })
        installer.beginWatching()

        installer.installWhenReady()
        XCTAssertEqual(installer.state, .waitingForBoard)

        locator.boards = [BootloaderBoard(chip: .rp2350, volumeURL: volume)]
        locator.emit()
        waitForSettledState(installer)
        XCTAssertEqual(installer.state, .verified(FirmwareVersion(1, 1, 7)))
    }

    /// Arming is a decision about this update, not standing permission: a
    /// board that turns up with nothing committed is never written to.
    func testAnUncommittedBoardIsNeverWritten() {
        let board = BootloaderBoard(chip: .rp2350, volumeURL: URL(fileURLWithPath: "/Volumes/RP2350"))
        let installer = makeInstaller(boards: [board])
        installer.beginWatching()
        XCTAssertEqual(installer.state, .ready(board))
        XCTAssertFalse(installer.isArmed)
    }

    // MARK: - A flash only counts when the device comes back

    func testSuccessRequiresTheDeviceToReturnRunningWhatWeWrote() throws {
        let (volume, image) = try makeVolumeAndImage(version: FirmwareVersion(1, 1, 7))
        let installer = makeInstaller(boards: [], verifier: StubVerifier(version: FirmwareVersion(1, 1, 7)),
                                      image: image)
        let board = BootloaderBoard(chip: .rp2350, volumeURL: volume)

        installer.install(board)
        waitForSettledState(installer)

        XCTAssertEqual(installer.state, .verified(FirmwareVersion(1, 1, 7)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: volume.appendingPathComponent(image.url.lastPathComponent).path))
    }

    /// A clean copy that produces no working device is a failure. Only the
    /// re-enumeration can tell the two apart.
    func testDeviceNeverReturningIsAFailure() throws {
        let (volume, image) = try makeVolumeAndImage(version: FirmwareVersion(1, 1, 7))
        let installer = makeInstaller(boards: [], verifier: StubVerifier(version: nil), image: image)

        installer.install(BootloaderBoard(chip: .rp2350, volumeURL: volume))
        waitForSettledState(installer)

        XCTAssertEqual(installer.state, .failed(.deviceDidNotReturn))
    }

    func testDeviceReturningOnTheWrongVersionIsAFailure() throws {
        let (volume, image) = try makeVolumeAndImage(version: FirmwareVersion(1, 1, 7))
        let installer = makeInstaller(boards: [], verifier: StubVerifier(version: FirmwareVersion(1, 1, 6)),
                                      image: image)

        installer.install(BootloaderBoard(chip: .rp2350, volumeURL: volume))
        waitForSettledState(installer)

        XCTAssertEqual(installer.state, .failed(.versionMismatch(expected: "1.1.7", got: "1.1.6")))
    }

    func testInstallWithoutAVolumeFailsBeforeWriting() {
        let installer = makeInstaller(boards: [])
        installer.install(BootloaderBoard(chip: .rp2040, volumeURL: nil))
        XCTAssertEqual(installer.state, .failed(.volumeNotMounted("RPI-RP2")))
    }

    /// A release that bumped the app version and forgot the images must fail
    /// loudly here rather than shipping and downgrading every device it meets.
    func testStaleBundledImageIsRefused() throws {
        let (volume, image) = try makeVolumeAndImage(version: FirmwareVersion(1, 1, 7))
        let installer = FirmwareInstaller(
            locator: FakeBootloaderLocator(boards: []),
            verifier: StubVerifier(version: nil),
            imageProvider: { _ in
                throw FirmwareInstallError.bundledImageStale(bundled: "1.1.6", expected: "1.1.7")
            })
        _ = image

        installer.install(BootloaderBoard(chip: .rp2350, volumeURL: volume))
        XCTAssertEqual(installer.state, .failed(.bundledImageStale(bundled: "1.1.6", expected: "1.1.7")))
    }

    // MARK: - Life after an install

    /// The outcome of a flash has to stay on screen long enough to be read:
    /// the board rebooting out of BOOTSEL right after a success is the normal
    /// ending, not a change that may erase the green tick.
    func testVerifiedStateSurvivesTheBoardDisappearing() throws {
        let (volume, image) = try makeVolumeAndImage(version: FirmwareVersion(1, 1, 7))
        let locator = FakeBootloaderLocator(boards: [BootloaderBoard(chip: .rp2350, volumeURL: volume)])
        let installer = FirmwareInstaller(locator: locator,
                                          verifier: StubVerifier(version: FirmwareVersion(1, 1, 7)),
                                          imageProvider: { _ in image })
        installer.beginWatching()
        installer.installWhenReady()
        waitForSettledState(installer)
        XCTAssertEqual(installer.state, .verified(FirmwareVersion(1, 1, 7)))

        locator.boards = []
        locator.emit()
        XCTAssertEqual(installer.state, .verified(FirmwareVersion(1, 1, 7)))
    }

    /// The reported hang: a finished install froze detection for the life of
    /// the installer, so the window sat on its terminal state ignoring every
    /// plug and unplug. `reset()` is the door back to detection.
    func testResetAfterAVerifiedInstallReturnsToDetection() throws {
        let (volume, image) = try makeVolumeAndImage(version: FirmwareVersion(1, 1, 7))
        let locator = FakeBootloaderLocator(boards: [BootloaderBoard(chip: .rp2350, volumeURL: volume)])
        let installer = FirmwareInstaller(locator: locator,
                                          verifier: StubVerifier(version: FirmwareVersion(1, 1, 7)),
                                          imageProvider: { _ in image })
        installer.beginWatching()
        installer.installWhenReady()
        waitForSettledState(installer)

        locator.boards = []
        installer.reset()
        XCTAssertEqual(installer.state, .waitingForBoard)
    }

    /// Arming must not outlive the write it authorised: a second board seen
    /// after a reset was decided about exactly zero times, so it may become
    /// ready but never start writing on its own.
    func testASecondBoardAfterResetNeedsAFreshCommit() throws {
        let (volume, image) = try makeVolumeAndImage(version: FirmwareVersion(1, 1, 7))
        let locator = FakeBootloaderLocator(boards: [BootloaderBoard(chip: .rp2350, volumeURL: volume)])
        let installer = FirmwareInstaller(locator: locator,
                                          verifier: StubVerifier(version: FirmwareVersion(1, 1, 7)),
                                          imageProvider: { _ in image })
        installer.beginWatching()
        installer.installWhenReady()
        waitForSettledState(installer)
        installer.reset()

        let second = BootloaderBoard(chip: .rp2040, volumeURL: URL(fileURLWithPath: "/Volumes/RPI-RP2"))
        locator.boards = [second]
        locator.emit()
        XCTAssertEqual(installer.state, .ready(second))
        XCTAssertFalse(installer.isArmed)
    }

    /// A failure raised before any byte moved - here a missing image - used to
    /// last one poll tick: the board was still attached, so detection put
    /// `.ready` straight back over it, leaving a disabled button and no error.
    func testPreWriteFailureHoldsOverContinuedDetection() {
        let board = BootloaderBoard(chip: .rp2350, volumeURL: URL(fileURLWithPath: "/Volumes/RP2350"))
        let locator = FakeBootloaderLocator(boards: [board])
        let installer = FirmwareInstaller(locator: locator,
                                          verifier: StubVerifier(version: nil),
                                          imageProvider: { chip in
                                              throw FirmwareInstallError.imageMissing(chip.displayName)
                                          })
        installer.beginWatching()
        installer.installWhenReady()
        XCTAssertEqual(installer.state, .failed(.imageMissing(BootloaderBoard.Chip.rp2350.displayName)))

        locator.emit()
        XCTAssertEqual(installer.state, .failed(.imageMissing(BootloaderBoard.Chip.rp2350.displayName)))

        installer.reset()
        XCTAssertEqual(installer.state, .ready(board))
        XCTAssertFalse(installer.isArmed)
    }

    /// Try Again after a genuine write failure has to actually start over;
    /// before `reset()` it restarted the watch against a permanently frozen
    /// state machine, which looked alive and did nothing.
    func testResetAfterAWriteFailureRecovers() throws {
        let (_, image) = try makeVolumeAndImage(version: FirmwareVersion(1, 1, 7))
        let ghostVolume = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let locator = FakeBootloaderLocator(boards: [])
        let installer = FirmwareInstaller(locator: locator,
                                          verifier: StubVerifier(version: nil),
                                          imageProvider: { _ in image })
        installer.beginWatching()
        installer.install(BootloaderBoard(chip: .rp2350, volumeURL: ghostVolume))
        waitForSettledState(installer)
        guard case .failed(.writeFailed) = installer.state else {
            return XCTFail("expected a write failure, got \(installer.state)")
        }

        let good = BootloaderBoard(chip: .rp2350, volumeURL: URL(fileURLWithPath: "/Volumes/RP2350"))
        locator.boards = [good]
        installer.reset()
        XCTAssertEqual(installer.state, .ready(good))
    }

    /// Mid-install there is no outcome to dismiss, and unfreezing detection
    /// would let the rebooting board's disappearance overwrite the write in
    /// progress - the exact bug the freeze exists to prevent.
    func testResetIsRefusedMidInstall() {
        let locator = FakeBootloaderLocator(boards: [])
        let installer = FirmwareInstaller(locator: locator,
                                          verifier: StubVerifier(version: nil),
                                          imageProvider: { _ in throw FirmwareInstallError.noBoardFound })
        installer.beginWatching()

        installer.setStateForTesting(.writing(0.5), installing: true)
        installer.reset()
        XCTAssertEqual(installer.state, .writing(0.5))

        installer.setStateForTesting(.waitingForDevice, installing: true)
        installer.reset()
        XCTAssertEqual(installer.state, .waitingForDevice)
        locator.emit()
        XCTAssertEqual(installer.state, .waitingForDevice)
    }

    /// Seven jumps of a progress bar over a whole flash read as a stall, not
    /// as progress; the chunk size has to keep the bar visibly moving.
    func testProgressMovesInFineSteps() throws {
        let (volume, image) = try makeVolumeAndImage(version: FirmwareVersion(1, 1, 7))
        let installer = makeInstaller(boards: [],
                                      verifier: StubVerifier(version: FirmwareVersion(1, 1, 7)),
                                      image: image)
        var fractions = Set<Double>()
        let watcher = installer.$state.sink { state in
            if case .writing(let f) = state { fractions.insert(f) }
        }
        defer { watcher.cancel() }

        installer.install(BootloaderBoard(chip: .rp2350, volumeURL: volume))
        waitForSettledState(installer)

        XCTAssertEqual(installer.state, .verified(FirmwareVersion(1, 1, 7)))
        // The 256 KB test image should produce a distinct fraction for each
        // chunk; a return to 64 KB chunks drops this to four.
        XCTAssertGreaterThanOrEqual(fractions.count, 12)
    }

    // MARK: - The real bundle

    /// Proves the shipping app actually carries an image for each chip and
    /// that both match the app's own version. This is the release checklist
    /// enforced as a test: bump MARKETING_VERSION without refreshing the UF2s
    /// and this fails rather than shipping a downgrade.
    func testBundleCarriesMatchingImagesForBothChips() throws {
        for chip in BootloaderBoard.Chip.allCases {
            let image = try FirmwareImage.bundled(for: chip)
            XCTAssertEqual(image.version, FirmwareVersion.expected,
                           "bundled \(chip.assetToken) image is not the app's version")
            XCTAssertTrue(FileManager.default.fileExists(atPath: image.url.path))
        }
    }

    // MARK: - Helpers

    private func makeInstaller(boards: [BootloaderBoard],
                               verifier: FirmwareVerifying = StubVerifier(version: nil),
                               image: FirmwareImage? = nil) -> FirmwareInstaller {
        FirmwareInstaller(locator: FakeBootloaderLocator(boards: boards),
                          verifier: verifier,
                          imageProvider: { chip in
                              if let image { return image }
                              throw FirmwareInstallError.imageMissing(chip.displayName)
                          })
    }

    /// A scratch directory standing in for the mounted volume, plus a small
    /// file standing in for the UF2.
    private func makeVolumeAndImage(version: FirmwareVersion) throws -> (URL, FirmwareImage) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dspi-firmware-tests-\(UUID().uuidString)")
        let volume = root.appendingPathComponent("volume")
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let imageURL = root.appendingPathComponent("DSPi-RP2350-v\(version).uf2")
        try Data(repeating: 0xAB, count: 256 * 1024).write(to: imageURL)

        return (volume, FirmwareImage(chip: .rp2350, url: imageURL, version: version))
    }

    /// The install runs on a background queue and publishes to main; spin the
    /// run loop until it stops moving.
    private func waitForSettledState(_ installer: FirmwareInstaller) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            switch installer.state {
            case .verified, .failed: return
            default: continue
            }
        }
    }
}

// MARK: - Doubles

private struct StubVerifier: FirmwareVerifying {
    let version: FirmwareVersion?
    func awaitDeviceVersion(timeout: TimeInterval) -> FirmwareVersion? { version }
}

/// A clock the test moves by hand, so the volume-wait timeout is exercised
/// without any test actually waiting for it.
private final class TestClock {
    private(set) var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}
