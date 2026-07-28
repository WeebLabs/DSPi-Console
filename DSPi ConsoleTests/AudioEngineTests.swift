import CoreAudio
import XCTest
@testable import DSPi_Console

/// Audio layer tests.
///
/// Most of what these backends do can only be proven with hardware, and the
/// live-device tier already exists for that. What is worth pinning here is the
/// part that runs *before* a device is touched: the guards that refuse an
/// invalid request, and the messages the user sees when they do. Those are the
/// paths a hardware test would never reach, and they are where a silent wrong
/// answer would otherwise originate.
final class AudioEngineTests: XCTestCase {

    private func fakeDevice(inputs: Int, outputs: Int, rate: Double = 48000) -> AudioDeviceInfo {
        AudioDeviceInfo(id: AudioObjectID(0),
                        uid: "test-uid",
                        name: "Test Device",
                        inputChannels: inputs,
                        outputChannels: outputs,
                        nominalSampleRate: rate,
                        supportedSampleRates: [44100, 48000, 96000])
    }

    // MARK: - Device info

    func testDeviceReportsRateSupport() {
        let device = fakeDevice(inputs: 1, outputs: 0)
        XCTAssertTrue(device.supports(sampleRate: 48000))
        XCTAssertTrue(device.supports(sampleRate: 44100))
        XCTAssertFalse(device.supports(sampleRate: 88200))
        XCTAssertTrue(device.hasInput)
        XCTAssertFalse(device.hasOutput)
    }

    func testEnumerationRunsAndReturnsCoherentEntries() {
        // Cannot assert a particular device exists, but every entry that does
        // must be internally consistent, and identity must be the UID rather
        // than the name.
        let devices = AudioDeviceCatalog.enumerate()
        for device in devices {
            XCTAssertFalse(device.uid.isEmpty, "a device without a UID cannot be remembered")
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertTrue(device.hasInput || device.hasOutput,
                          "\(device.name) reports no channels in either direction")
        }
        let uids = devices.map(\.uid)
        XCTAssertEqual(uids.count, Set(uids).count, "device UIDs must be unique")
    }

    func testCatalogSplitsInputsAndOutputs() {
        let catalog = AudioDeviceCatalog(startListening: false)
        XCTAssertTrue(catalog.inputDevices.allSatisfy(\.hasInput))
        XCTAssertTrue(catalog.outputDevices.allSatisfy(\.hasOutput))
        for device in catalog.devices {
            XCTAssertEqual(catalog.device(uid: device.uid)?.uid, device.uid)
        }
        XCTAssertNil(catalog.device(uid: "no-such-device"))
    }

    // MARK: - Capture guards

    func testCaptureRefusesADeviceWithNoInputs() {
        let backend = HALCaptureBackend()
        XCTAssertThrowsError(try backend.start(device: fakeDevice(inputs: 0, outputs: 2),
                                               channelIndex: 0))
        XCTAssertFalse(backend.isRunning)
    }

    func testCaptureRefusesAChannelThatDoesNotExist() {
        let backend = HALCaptureBackend()
        XCTAssertThrowsError(try backend.start(device: fakeDevice(inputs: 2, outputs: 0),
                                               channelIndex: 5)) { error in
            guard case AudioEngineError.channelOutOfRange(let requested, let available)? =
                    error as? AudioEngineError else {
                return XCTFail("expected a channel-range error, got \(error)")
            }
            XCTAssertEqual(requested, 5)
            XCTAssertEqual(available, 2)
        }
        XCTAssertThrowsError(try backend.start(device: fakeDevice(inputs: 2, outputs: 0),
                                               channelIndex: -1))
    }

    func testStoppingACaptureThatNeverStartedIsHarmless() {
        let backend = HALCaptureBackend()
        XCTAssertEqual(backend.stop().count, 0)
        XCTAssertEqual(backend.peakAndReset(), 0)
        XCTAssertEqual(backend.overloadCount, 0)
    }

    // MARK: - Playback guards

    func testPlaybackRefusesADeviceWithNoOutputs() {
        let backend = HALPlaybackBackend()
        XCTAssertThrowsError(try backend.play(samples: [0, 0, 0],
                                              device: fakeDevice(inputs: 2, outputs: 0),
                                              channelIndex: 0) { _ in })
    }

    func testPlaybackRefusesAChannelThatDoesNotExist() {
        let backend = HALPlaybackBackend()
        XCTAssertThrowsError(try backend.play(samples: [0, 0, 0],
                                              device: fakeDevice(inputs: 0, outputs: 2),
                                              channelIndex: 9) { _ in })
    }

    func testStoppingPlaybackThatNeverStartedIsHarmless() {
        let backend = HALPlaybackBackend()
        backend.stop()
        XCTAssertFalse(backend.isRunning)
        XCTAssertEqual(backend.underrunCount, 0)
    }

    // MARK: - Messages

    func testRateMismatchExplainsWhatToDo() {
        // The most consequential error in the whole audio layer: a resampled
        // reference no longer matches what the device emitted, so the
        // deconvolution produces a confidently wrong answer rather than
        // failing. The message has to name both rates and the fix.
        let error = AudioEngineError.rateMismatch(requested: 48000, actual: 44100)
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("44100"), message)
        XCTAssertTrue(message.contains("48000"), message)
        XCTAssertTrue(message.contains("Audio MIDI Setup"), message)
    }

    func testEveryAudioErrorExplainsItself() {
        let errors: [AudioEngineError] = [
            .deviceUnavailable("UMIK-1"),
            .channelOutOfRange(requested: 3, available: 2),
            .rateMismatch(requested: 48000, actual: 96000),
            .coreAudio("starting capture", -10875),
            .alreadyRunning
        ]
        for error in errors {
            let message = error.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty, "\(error) has no message")
            XCTAssertFalse(message.contains("Optional("), message)
        }
    }

    func testDeviceUnavailableNamesTheDevice() {
        let message = AudioEngineError.deviceUnavailable("UMIK-1").errorDescription ?? ""
        XCTAssertTrue(message.contains("UMIK-1"), message)
    }

    // MARK: - Microphone permission

    func testPermissionStateReadsWithoutPrompting() {
        // Reading must never prompt; only an explicit request may.
        let state = MicrophoneAccess.state
        XCTAssertTrue([.granted, .denied, .notDetermined, .restricted].contains(state))
    }

    func testOnlyGrantedCanRecord() {
        XCTAssertTrue(MicrophoneAccess.State.granted.canRecord)
        for state: MicrophoneAccess.State in [.denied, .notDetermined, .restricted] {
            XCTAssertFalse(state.canRecord)
        }
    }

    func testDeniedStatesExplainThemselvesAndOfferAWayForward() {
        XCTAssertNil(MicrophoneAccess.State.granted.explanation)
        for state: MicrophoneAccess.State in [.denied, .notDetermined, .restricted] {
            XCTAssertFalse(state.explanation?.isEmpty ?? true, "\(state) has no explanation")
        }
        // System Settings helps a denial, but not a policy restriction, and
        // offering it there would send the user somewhere that cannot help.
        XCTAssertTrue(MicrophoneAccess.State.denied.offersSystemSettings)
        XCTAssertFalse(MicrophoneAccess.State.restricted.offersSystemSettings)
        XCTAssertFalse(MicrophoneAccess.State.granted.offersSystemSettings)
        XCTAssertNotNil(MicrophoneAccess.systemSettingsURL)
    }
}
