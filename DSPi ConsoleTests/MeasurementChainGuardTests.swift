import CoreAudio
import XCTest
@testable import DSPi_Console

/// Covers the rule that makes relative level measurement legitimate.
///
/// Every comparison in level matching is between channels measured through the
/// same chain, which is what lets the unknown chain gain cancel. Move the gain
/// halfway through and the result is not slightly worse, it is confidently
/// wrong - so this stops the session rather than warning about it.
///
/// CoreAudio offers no way to fake a gain change, so the property reads are
/// injected. That is the whole point: the class exists for what it does when a
/// change happens.
@MainActor
final class MeasurementChainGuardTests: XCTestCase {

    private let deviceID: AudioObjectID = 42

    private func guardWith(volume: Float?, rate: Double) -> MeasurementChainGuard {
        let value = MeasurementChainGuard()
        var currentVolume = volume
        var currentRate = rate
        value.readVolume = { _ in currentVolume }
        value.readSampleRate = { _ in currentRate }
        value.start(device: deviceID, uid: "UMIK-1")
        // Handles for the test to move afterwards.
        moveVolume = { currentVolume = $0 }
        moveRate = { currentRate = $0 }
        return value
    }

    private var moveVolume: ((Float?) -> Void)!
    private var moveRate: ((Double) -> Void)!

    // MARK: - Nothing changed

    func testAnUnchangedChainReportsNothing() {
        let sentry = guardWith(volume: 0.5, rate: 48000)
        XCTAssertNil(sentry.check(currentUID: "UMIK-1"))
        XCTAssertNil(sentry.violation)
        XCTAssertTrue(sentry.isWatching)
    }

    func testTinyVolumeJitterIsNotAChange() {
        // Property reads come back as floats and can wobble in the last digit;
        // stopping a session for that would make the guard unusable.
        let sentry = guardWith(volume: 0.5, rate: 48000)
        moveVolume(0.5019)
        XCTAssertNil(sentry.check(currentUID: "UMIK-1"))
    }

    func testADeviceWithNoInputVolumeIsNotAViolation()  {
        // Plenty of interfaces expose no settable input gain, and absence is
        // not a change.
        let sentry = guardWith(volume: nil, rate: 48000)
        XCTAssertNil(sentry.check(currentUID: "UMIK-1"))
    }

    // MARK: - Changes that invalidate the session

    func testAGainChangeIsCaught() {
        let sentry = guardWith(volume: 0.5, rate: 48000)
        moveVolume(0.8)

        guard case .volumeChanged(let from, let to) = sentry.check(currentUID: "UMIK-1") else {
            return XCTFail("expected a volume violation, got \(String(describing: sentry.violation))")
        }
        XCTAssertEqual(from, 0.5, accuracy: 0.001)
        XCTAssertEqual(to, 0.8, accuracy: 0.001)
    }

    func testTheGainExplanationSaysWhyItMatters() {
        let sentry = guardWith(volume: 0.5, rate: 48000)
        moveVolume(0.8)
        let text = sentry.check(currentUID: "UMIK-1")?.explanation ?? ""

        XCTAssertTrue(text.contains("50%"), text)
        XCTAssertTrue(text.contains("80%"), text)
        XCTAssertTrue(text.contains("different scale"),
                      "it has to say why a gain change spoils the comparison: \(text)")
    }

    func testASampleRateChangeIsCaught() {
        let sentry = guardWith(volume: 0.5, rate: 48000)
        moveRate(44100)

        guard case .sampleRateChanged = sentry.check(currentUID: "UMIK-1") else {
            return XCTFail("expected a rate violation")
        }
    }

    func testADifferentMicrophoneIsCaught() {
        let sentry = guardWith(volume: 0.5, rate: 48000)

        guard case .deviceChanged(let from, let to) = sentry.check(currentUID: "Built-in") else {
            return XCTFail("expected a device violation")
        }
        XCTAssertEqual(from, "UMIK-1")
        XCTAssertEqual(to, "Built-in")
    }

    func testAMicrophoneDisappearingIsCaught() {
        let sentry = guardWith(volume: 0.5, rate: 48000)
        guard case .deviceGone = sentry.check(currentUID: nil) else {
            return XCTFail("expected a disappearance")
        }
    }

    // MARK: - Behaviour around a violation

    func testTheFirstViolationIsKept() {
        // A second change should not overwrite the first: the user needs to
        // know what went wrong initially, not what went wrong most recently.
        let sentry = guardWith(volume: 0.5, rate: 48000)
        moveVolume(0.8)
        _ = sentry.check(currentUID: "UMIK-1")

        moveRate(44100)
        guard case .volumeChanged = sentry.check(currentUID: "UMIK-1") else {
            return XCTFail("the original violation should stand")
        }
    }

    func testStoppingClearsEverything() {
        let sentry = guardWith(volume: 0.5, rate: 48000)
        moveVolume(0.8)
        _ = sentry.check(currentUID: "UMIK-1")

        sentry.stop()
        XCTAssertFalse(sentry.isWatching)
        XCTAssertNil(sentry.violation)
        XCTAssertNil(sentry.check(currentUID: "anything"),
                     "a stopped guard has no baseline to compare against")
    }

    func testRestartingTakesAFreshBaseline() {
        // After the user puts the gain back, measuring again has to be allowed.
        let sentry = guardWith(volume: 0.5, rate: 48000)
        moveVolume(0.8)
        _ = sentry.check(currentUID: "UMIK-1")

        sentry.start(device: deviceID, uid: "UMIK-1")
        XCTAssertNil(sentry.check(currentUID: "UMIK-1"))
        XCTAssertEqual(sentry.baseline?.volume ?? 0, 0.8, accuracy: 0.001)
    }

    func testCheckingBeforeStartingIsHarmless() {
        let sentry = MeasurementChainGuard()
        XCTAssertNil(sentry.check(currentUID: "UMIK-1"))
        XCTAssertFalse(sentry.isWatching)
    }
}
