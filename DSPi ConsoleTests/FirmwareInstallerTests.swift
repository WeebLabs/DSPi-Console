import XCTest
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

    /// Builds predating the point-release policy still have to compare, and a
    /// suffix carries no information the device could report anyway.
    func testIgnoresLegacySuffix() {
        XCTAssertEqual(FirmwareVersion("1.1.6-beta2"), FirmwareVersion(1, 1, 6))
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
