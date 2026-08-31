import Foundation

// MARK: - Bundled images

/// A UF2 image shipped inside the app bundle.
///
/// Console bundles the firmware of its own version so the pair can never be
/// mismatched by a user who updates one and not the other.  See CLAUDE.md >
/// Releases for how the images get here.
struct FirmwareImage: Equatable {
    let chip: BootloaderBoard.Chip
    let url: URL
    let version: FirmwareVersion

    /// Locates the bundled image for a chip.
    ///
    /// Throws `bundledImageStale` when the image's version does not match the
    /// app's, which catches a release that bumped `MARKETING_VERSION` and
    /// forgot to refresh the `.uf2` files.  Failing loudly in development is
    /// the entire point: a stale image would otherwise ship and quietly
    /// downgrade every device it touched.
    static func bundled(for chip: BootloaderBoard.Chip,
                        in bundle: Bundle = .main) throws -> FirmwareImage {
        let candidates = (bundle.urls(forResourcesWithExtension: "uf2", subdirectory: "Firmware") ?? [])
            + (bundle.urls(forResourcesWithExtension: "uf2", subdirectory: nil) ?? [])

        guard let url = candidates.first(where: {
            $0.lastPathComponent.contains("-\(chip.assetToken)-")
        }) else {
            throw FirmwareInstallError.imageMissing(chip.displayName)
        }

        guard let version = versionFromAssetName(url.lastPathComponent) else {
            throw FirmwareInstallError.imageMissing(chip.displayName)
        }

        if let expected = FirmwareVersion.expected, version != expected {
            throw FirmwareInstallError.bundledImageStale(bundled: version.description,
                                                         expected: expected.description)
        }

        return FirmwareImage(chip: chip, url: url, version: version)
    }

    /// Pulls "1.1.7" out of "DSPi-RP2350-v1.1.7.uf2".
    static func versionFromAssetName(_ name: String) -> FirmwareVersion? {
        guard let marker = name.range(of: "-v", options: .backwards) else { return nil }
        let tail = name[marker.upperBound...].replacingOccurrences(of: ".uf2", with: "")
        return FirmwareVersion(tail)
    }
}

// MARK: - Errors

enum FirmwareInstallError: Error, Equatable {
    case noBoardFound
    case multipleBoards(Int)
    case volumeNotMounted(String)
    case imageMissing(String)
    case bundledImageStale(bundled: String, expected: String)
    case writeFailed(String)
    case deviceDidNotReturn
    case versionMismatch(expected: String, got: String)

    /// One sentence fit to show a user.
    var message: String {
        switch self {
        case .noBoardFound:
            return "No board in bootloader mode was found. Hold the BOOTSEL button while plugging the board in."
        case .multipleBoards(let count):
            return "\(count) boards are in bootloader mode. Disconnect all but the one you want to update."
        case .volumeNotMounted(let name):
            return "The board is connected but its \(name) drive has not appeared. If macOS asked for permission to access removable volumes, allow it and try again."
        case .imageMissing(let chip):
            return "This build of DSPi Console does not include firmware for the \(chip)."
        case .bundledImageStale(let bundled, let expected):
            return "The bundled firmware is version \(bundled) but this Console expects \(expected). The app was built incorrectly; do not install it."
        case .writeFailed(let detail):
            return "Writing the firmware failed: \(detail)"
        case .deviceDidNotReturn:
            return "The firmware was written but the device did not reappear. Unplug it, plug it back in, and check whether it works."
        case .versionMismatch(let expected, let got):
            return "The device came back running firmware \(got) instead of \(expected)."
        }
    }
}

// MARK: - Verification

/// Waits for a DSPi to enumerate after a flash and reports the version it
/// claims.  A protocol so tests can verify without hardware.
protocol FirmwareVerifying {
    func awaitDeviceVersion(timeout: TimeInterval) -> FirmwareVersion?
}

/// Polls the live view model.  Called from the installer's background queue,
/// so each read hops to the main thread where the published state is written.
struct ViewModelFirmwareVerifier: FirmwareVerifying {
    let vm: DSPViewModel

    func awaitDeviceVersion(timeout: TimeInterval) -> FirmwareVersion? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let version: FirmwareVersion? = DispatchQueue.main.sync {
                guard vm.isDeviceConnected, let v = vm.firmwareVersion else { return nil }
                return FirmwareVersion(v.major, v.minor, v.patch)
            }
            if let version { return version }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }
}

// MARK: - Installer

enum FirmwareInstallState: Equatable {
    case idle
    /// Nothing in BOOTSEL yet.
    case waitingForBoard
    /// Board on the bus but its drive has not mounted.  Ordinary for a second
    /// or two after it appears, so this is a waiting state, not a failure.
    case waitingForVolume(BootloaderBoard.Chip)
    /// Exactly one board, volume mounted, ready to be written when the user says so.
    case ready(BootloaderBoard)
    /// Writing, with the fraction of the image sent so far.
    case writing(Double)
    /// Bytes are out and the board is rebooting; waiting for it to enumerate.
    case waitingForDevice
    case verified(FirmwareVersion)
    case failed(FirmwareInstallError)
}

/// Detects a board in BOOTSEL, writes the bundled UF2 to it, and confirms the
/// device came back running what we wrote.
///
/// Deliberately does none of the deciding: it never flashes on its own, never
/// chooses between two attached boards, and never touches presets.  Callers
/// own the confirmation UI.  Used by the Getting Started wizard, by
/// Tools > Firmware Update, and by the version-mismatch banner.
final class FirmwareInstaller: ObservableObject {
    @Published private(set) var state: FirmwareInstallState = .idle

    /// Fraction of the image that must be out before a write error is read as
    /// the board rebooting rather than as a failure.  The RP2 ROM loader
    /// reboots itself as it takes the last blocks, so the volume disappears
    /// underneath the final write; every UF2 flasher that reports that as an
    /// error is wrong.  Paired with a check that the volume really did vanish,
    /// so an early genuine failure still surfaces.
    static let rebootThreshold = 0.95

    /// How long to wait for the board to come back after a write.
    static let verifyTimeout: TimeInterval = 15

    /// How long a board may sit on the USB bus with no drive before we call it
    /// a failure.  The mount always lags enumeration; treating that gap as an
    /// error meant a board plugged in while the window was open was rejected
    /// a moment before its drive appeared.
    static let volumeWaitTimeout: TimeInterval = 8

    /// Whether a write error means the board rebooted, which is the ordinary
    /// ending, rather than that the write failed.
    ///
    /// Two independent signals, either sufficient: nearly all the bytes are
    /// out, or the volume has actually disappeared.  The fraction alone would
    /// miss a board that resets early; the mount check alone would miss the
    /// window where the volume is on its way out but still stat-able.
    static func isRebootSignal(fractionWritten: Double, volumeStillMounted: Bool) -> Bool {
        fractionWritten >= rebootThreshold || !volumeStillMounted
    }

    private let locator: BootloaderLocating
    private let verifier: FirmwareVerifying
    private let imageProvider: (BootloaderBoard.Chip) throws -> FirmwareImage
    private let now: () -> Date
    private let queue = DispatchQueue(label: "com.foxdac.firmware-install")

    /// Set once a write begins.  From then on the board disappearing is the
    /// expected reboot, so detection stops touching the state.  Before that,
    /// detection stays live: a failure it reported is only ever a description
    /// of what is plugged in right now, and must give way when that changes.
    private var installing = false

    /// When the current board was first seen without a drive.
    private var volumeWaitStarted: Date?

    /// The user has committed to an update, so the next ready board is written
    /// without asking again.  Kept here rather than in the view because the
    /// board may be ready before the user commits, or commit before the board
    /// is ready, and only one of those two orders is a state *change*.
    private var armed = false

    init(locator: BootloaderLocating,
         verifier: FirmwareVerifying,
         imageProvider: @escaping (BootloaderBoard.Chip) throws -> FirmwareImage
            = { try FirmwareImage.bundled(for: $0) },
         now: @escaping () -> Date = Date.init) {
        self.locator = locator
        self.verifier = verifier
        self.imageProvider = imageProvider
        self.now = now
    }

    // MARK: Detection

    /// Begin watching for boards.  `state` tracks what is attached until
    /// `install` is called.
    func beginWatching() {
        locator.onChange = { [weak self] boards in
            self?.applyBoards(boards)
        }
        locator.start()
        applyBoards(locator.currentBoards())
    }

    func stopWatching() {
        locator.onChange = nil
        locator.stop()
    }

    /// Maps what is attached onto a state.
    ///
    /// Stops entirely once a write has begun: from that point the board
    /// vanishing is the expected reboot, not a change worth reacting to.
    /// Until then it always runs, including over a failure it reported
    /// itself, so a board whose drive shows up late recovers on its own.
    private func applyBoards(_ boards: [BootloaderBoard]) {
        guard !installing else { return }

        let next: FirmwareInstallState
        switch boards.count {
        case 0:
            volumeWaitStarted = nil
            next = .waitingForBoard
        case 1:
            if boards[0].volumeURL != nil {
                volumeWaitStarted = nil
                next = .ready(boards[0])
            } else {
                // The drive mounts a moment after the board enumerates, so
                // hold in a waiting state and only call it a failure once it
                // is clear the drive is not coming.
                let started = volumeWaitStarted ?? now()
                volumeWaitStarted = started
                next = now().timeIntervalSince(started) >= Self.volumeWaitTimeout
                    ? .failed(.volumeNotMounted(boards[0].chip.volumeName))
                    : .waitingForVolume(boards[0].chip)
            }
        default:
            volumeWaitStarted = nil
            next = .failed(.multipleBoards(boards.count))
        }
        publish(next)

        // Committed before the board arrived: write it now that it is here.
        if armed, case .ready(let board) = next { install(board) }
    }

    // MARK: Install

    /// Records the user's decision to update, and writes as soon as there is a
    /// board to write to - immediately if one is already ready.
    ///
    /// This is the only way callers should start an install.  Waiting for
    /// `.ready` to *arrive* misses the common case where the board was plugged
    /// in first and the state is already `.ready` when the user clicks.
    func installWhenReady() {
        armed = true
        if case .ready(let board) = state { install(board) }
    }

    /// Whether an update has been committed to but not yet started.
    var isArmed: Bool { armed }

    /// Writes the bundled image for `board` and verifies the result.
    /// Call only from a state of `.ready`, after the user has confirmed.
    func install(_ board: BootloaderBoard) {
        guard let volumeURL = board.volumeURL else {
            publish(.failed(.volumeNotMounted(board.chip.volumeName)))
            return
        }

        let image: FirmwareImage
        do {
            image = try imageProvider(board.chip)
        } catch let error as FirmwareInstallError {
            publish(.failed(error))
            return
        } catch {
            publish(.failed(.writeFailed(error.localizedDescription)))
            return
        }

        installing = true
        publish(.writing(0))

        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.writeImage(image, to: volumeURL) { fraction in
                    self.publish(.writing(fraction))
                }
            } catch let error as FirmwareInstallError {
                self.publish(.failed(error))
                return
            } catch {
                self.publish(.failed(.writeFailed(error.localizedDescription)))
                return
            }

            self.publish(.waitingForDevice)

            // The copy returning proves nothing.  Success is the device coming
            // back and telling us it is running what we wrote.
            guard let reported = self.verifier.awaitDeviceVersion(timeout: Self.verifyTimeout) else {
                self.publish(.failed(.deviceDidNotReturn))
                return
            }
            guard reported == image.version else {
                self.publish(.failed(.versionMismatch(expected: image.version.description,
                                                      got: reported.description)))
                return
            }
            self.publish(.verified(reported))
        }
    }

    /// Streams the image onto the volume in chunks, reporting progress.
    ///
    /// Returns normally when the board reboots mid-write, which is the ordinary
    /// ending: past `rebootThreshold`, or once the volume has actually gone, a
    /// write error means the ROM loader took the last block and reset. Before
    /// that, an error is a real failure and is thrown.
    private func writeImage(_ image: FirmwareImage,
                            to volumeURL: URL,
                            progress: @escaping (Double) -> Void) throws {
        let fm = FileManager.default
        let total = ((try? fm.attributesOfItem(atPath: image.url.path)[.size]) as? NSNumber)?.intValue ?? 0
        let destination = volumeURL.appendingPathComponent(image.url.lastPathComponent)

        guard let source = try? FileHandle(forReadingFrom: image.url) else {
            throw FirmwareInstallError.writeFailed("could not read the bundled image")
        }
        defer { try? source.close() }

        guard fm.createFile(atPath: destination.path, contents: nil),
              let sink = try? FileHandle(forWritingTo: destination) else {
            throw FirmwareInstallError.writeFailed("could not open \(volumeURL.lastPathComponent) for writing")
        }

        var written = 0
        while true {
            let chunk = (try? source.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty { break }

            do {
                try sink.write(contentsOf: chunk)
            } catch {
                let fraction = total > 0 ? Double(written) / Double(total) : 0
                if Self.isRebootSignal(fractionWritten: fraction,
                                       volumeStillMounted: fm.fileExists(atPath: volumeURL.path)) {
                    return
                }
                throw FirmwareInstallError.writeFailed(error.localizedDescription)
            }

            written += chunk.count
            progress(total > 0 ? Double(written) / Double(total) : 0)
        }

        // Both can throw once the board has gone, and by here every byte is
        // out, so neither failure means anything.
        try? sink.synchronize()
        try? sink.close()
    }

    #if DEBUG
    /// Test hook: drives the state machine directly, and can mark a write as
    /// begun, so transitions that only happen mid-install are reachable
    /// without actually writing anything.
    func setStateForTesting(_ next: FirmwareInstallState, installing: Bool = false) {
        state = next
        self.installing = installing
    }
    #endif

    private func publish(_ next: FirmwareInstallState) {
        if Thread.isMainThread {
            guard state != next else { return }
            state = next
        } else {
            DispatchQueue.main.async { self.state = next }
        }
    }
}
