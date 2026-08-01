import CoreAudio
import XCTest
@testable import DSPi_Console

/// The rules for holding a measurement microphone at unity.
///
/// CoreAudio offers no way to present a device that has a volume control but
/// refuses to set it, or one whose decibel range stops short of unity, so the
/// control is faked and the decisions are tested rather than the plumbing.
@MainActor
final class MicrophoneGainTests: XCTestCase {

    private final class FakeControl: MicrophoneGainControl {
        var present = true
        var settable = true
        /// Per device, because holding a second microphone has to put the first
        /// one back rather than carry its value across.
        var values: [AudioObjectID: Float] = [:]
        /// Scalar that means 0 dB, or nil for a device with no decibel scale.
        var unity: Float? = 0.75
        var isMuted: Bool? = false
        var muteSettable = true
        /// Refuses every write, as a device with a read-only control does.
        var refuseWrites = false

        private(set) var writes: [Float] = []
        private(set) var muteWrites: [Bool] = []

        var value: Float {
            get { values[1] ?? 0.4 }
            set { values[1] = newValue }
        }

        func hasVolume(_ device: AudioObjectID) -> Bool { present }
        func isVolumeSettable(_ device: AudioObjectID) -> Bool { present && settable }

        func scalar(_ device: AudioObjectID) -> Float? {
            present ? (values[device] ?? 0.4) : nil
        }

        func setScalar(_ device: AudioObjectID, _ newValue: Float) -> Bool {
            guard present, settable, !refuseWrites else { return false }
            writes.append(newValue)
            values[device] = newValue
            return true
        }

        func unityScalar(_ device: AudioObjectID) -> Float? { unity }

        func decibels(_ device: AudioObjectID, forScalar scalar: Float) -> Double? {
            // A plausible mapping for the fake: unity sits at 0 dB and the
            // control runs to +12 dB at the top.
            guard let unity, unity > 0 else { return nil }
            return Double(scalar - unity) / Double(1 - unity) * 12
        }

        func muted(_ device: AudioObjectID) -> Bool? { isMuted }

        func setMuted(_ device: AudioObjectID, _ muted: Bool) -> Bool {
            guard muteSettable else { return false }
            muteWrites.append(muted)
            isMuted = muted
            return true
        }
    }

    private var control: FakeControl!
    private var gain: MicrophoneGain!

    override func setUp() {
        super.setUp()
        control = FakeControl()
        gain = MicrophoneGain(control: control)
    }

    // MARK: - Holding

    func testUnityIsZeroDecibelsNotTheTopOfTheControl() {
        // The whole point. A device with an input preamp puts positive gain at
        // the top of its range, and measuring into that spends headroom for
        // nothing.
        let outcome = gain.hold(device: 1)

        XCTAssertEqual(control.writes, [0.75])
        XCTAssertEqual(outcome, .held(decibels: 0))
    }

    func testADeviceWithNoDecibelScaleGoesToFullScale() {
        // Full scale is the only position on an opaque 0...1 control that is
        // certainly not attenuating.
        control.unity = nil
        let outcome = gain.hold(device: 1)

        XCTAssertEqual(control.writes, [1.0])
        XCTAssertEqual(outcome, .held(decibels: nil))
    }

    func testAnImplausibleTranslationNeverWritesSilence() {
        // A device that publishes a decibel scale but answers nonsense must not
        // end up with its input written to zero. The sweeps would still run and
        // every level in the campaign would be wrong.
        for answer in [Float(0), -1, 2, .nan, .infinity] {
            control = FakeControl()
            control.unity = answer
            gain = MicrophoneGain(control: control)

            _ = gain.hold(device: 1)

            XCTAssertEqual(control.writes, [1.0], "unity answered \(answer)")
        }
    }

    func testAMicrophoneWithNoSoftwareGainIsLeftAlone() {
        control.present = false
        let outcome = gain.hold(device: 1)

        XCTAssertEqual(outcome, .fixedByHardware)
        XCTAssertTrue(outcome.isPinned, "the hardware sets it and nothing can move it")
        XCTAssertTrue(control.writes.isEmpty)
    }

    func testAControlThatWillNotBeSetIsReportedRatherThanAssumed() {
        control.settable = false
        let outcome = gain.hold(device: 1)

        XCTAssertEqual(outcome, .notSettable(scalar: 0.4))
        XCTAssertFalse(outcome.isPinned,
                       "the measurement is on a gain the user could move")
        XCTAssertTrue(control.writes.isEmpty)
    }

    func testAWriteThatSilentlyFailsIsAlsoReported() {
        control.refuseWrites = true
        let outcome = gain.hold(device: 1)

        XCTAssertEqual(outcome, .notSettable(scalar: 0.4))
        XCTAssertFalse(outcome.isPinned)
    }

    func testAMutedMicrophoneIsUnmuted() {
        control.isMuted = true
        _ = gain.hold(device: 1)

        XCTAssertEqual(control.muteWrites, [false])
        XCTAssertEqual(control.isMuted, false)
    }

    func testAnUnmutedMicrophoneIsNotTouched() {
        _ = gain.hold(device: 1)
        XCTAssertTrue(control.muteWrites.isEmpty)
    }

    // MARK: - Putting it back

    func testReleasePutsTheSystemSettingBack() {
        _ = gain.hold(device: 1)
        XCTAssertEqual(control.value, 0.75)

        gain.release()

        XCTAssertEqual(control.value, 0.4, "the user's own setting, exactly")
        XCTAssertNil(gain.outcome)
    }

    func testReleasePutsMuteBack() {
        control.isMuted = true
        _ = gain.hold(device: 1)
        gain.release()

        XCTAssertEqual(control.isMuted, true)
    }

    func testAFailedHoldLeavesNothingBehind() {
        // A refused volume write must not leave the microphone unmuted when it
        // was found muted: half a change is worse than none.
        control.refuseWrites = true
        control.isMuted = true
        _ = gain.hold(device: 1)

        XCTAssertEqual(control.isMuted, true)
    }

    func testHoldingASecondMicrophonePutsTheFirstOneBack() {
        control.values = [1: 0.4, 2: 0.9]
        _ = gain.hold(device: 1)
        _ = gain.hold(device: 2)

        XCTAssertEqual(control.values[1], 0.4, "the first is not left held")
        XCTAssertEqual(control.values[2], 0.75)

        gain.release()
        XCTAssertEqual(control.values[2], 0.9, "and the second goes back too")
    }

    func testReleaseWithoutAHoldDoesNothing() {
        gain.release()
        XCTAssertTrue(control.writes.isEmpty)
        XCTAssertTrue(control.muteWrites.isEmpty)
    }
}
