import AppKit
import CoreAudio
import Foundation

/// Reads and writes a microphone's software input gain.
///
/// A protocol so the rules above can be tested. CoreAudio offers no way to fake
/// a device that has a volume control but refuses to set it, or one whose dB
/// range does not reach unity, and those are the cases worth getting right.
protocol MicrophoneGainControl {
    func hasVolume(_ device: AudioObjectID) -> Bool
    func isVolumeSettable(_ device: AudioObjectID) -> Bool
    func scalar(_ device: AudioObjectID) -> Float?
    func setScalar(_ device: AudioObjectID, _ value: Float) -> Bool
    /// The scalar position that means 0 dB, or nil when the device does not
    /// publish a decibel scale.
    func unityScalar(_ device: AudioObjectID) -> Float?
    func decibels(_ device: AudioObjectID, forScalar scalar: Float) -> Double?
    func muted(_ device: AudioObjectID) -> Bool?
    func setMuted(_ device: AudioObjectID, _ muted: Bool) -> Bool
}

/// Holds the measurement microphone at unity gain for the length of a session.
///
/// Everything downstream reads absolute dBFS: the noise floor, the level check's
/// headroom and SNR, and the per-channel levels the balance pass compares. All
/// of them are quietly scaled by the system input slider, which is a control the
/// user may never have touched deliberately and which some applications move on
/// their own. Inheriting it means a measurement campaign is calibrated against
/// whatever that slider happened to be at, and a correction calculated at 40%
/// is not the one calculated at 100%.
///
/// Unity means 0 dB, not the top of the control. A device with an input preamp
/// puts positive gain at the top of its range, and running a measurement into
/// that trades headroom for nothing. Where the device publishes a decibel scale
/// the 0 dB position is used; where it publishes only an opaque 0...1 scalar,
/// full scale is the only position that is certainly not attenuating.
///
/// The setting is system-wide and persists, so it is put back on quit and
/// whenever a different microphone is taken up. It is deliberately not put back
/// when the window closes: a campaign outlives that, and every level in one is
/// comparable only while the gain stays where it was for the first sweep.
/// Nothing can restore it if the process dies outright, which is the one case
/// this cannot cover.
@MainActor
final class MicrophoneGain: ObservableObject {

    enum Outcome: Equatable {
        /// No software input gain at all. Common, and the good case: the level
        /// is whatever the hardware does and nothing can move it.
        case fixedByHardware
        /// Held, at the gain actually achieved. Nil decibels when the device
        /// publishes no decibel scale and the scalar was simply put to full.
        case held(decibels: Double?)
        /// The device has a control that will not take a write.
        case notSettable(scalar: Float)

        /// Whether measurements taken now are on a gain we control.
        var isPinned: Bool {
            switch self {
            case .fixedByHardware, .held: return true
            case .notSettable: return false
            }
        }

        var explanation: String {
            switch self {
            case .fixedByHardware:
                return "This microphone has no software input gain, so its level is "
                     + "set by the hardware and cannot drift."
            case .held(let decibels):
                guard let decibels else {
                    return "Input gain held at full scale for the session, so the "
                         + "system input slider cannot scale the measurement. It is "
                         + "put back when you close this window."
                }
                return String(format: "Input gain held at %.1f dB for the session, so "
                              + "the system input slider cannot scale the measurement. "
                              + "It is put back when you close this window.", decibels)
            case .notSettable(let scalar):
                return String(format: "This microphone reports an input gain of %.0f%% "
                              + "but will not let it be set, so the measurement is on "
                              + "whatever gain it is at. Check it before measuring, and "
                              + "do not change it afterwards.", scalar * 100)
            }
        }
    }

    @Published private(set) var outcome: Outcome?

    private let control: MicrophoneGainControl
    /// What to put back, and on which device.
    private var restoration: (device: AudioObjectID, scalar: Float?, muted: Bool?)?
    private var terminationObserver: NSObjectProtocol?

    init(control: MicrophoneGainControl = CoreAudioMicrophoneGain()) {
        self.control = control
        // The setting outlives the process, so quitting mid-session must not
        // leave the user's microphone somewhere they did not put it.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.release() }
            }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: - Holding

    /// Takes the microphone to unity and keeps it there.
    ///
    /// Must run before the chain guard takes its baseline, or the guard sees
    /// this write as the very drift it exists to catch.
    @discardableResult
    func hold(device: AudioObjectID) -> Outcome {
        release()

        guard control.hasVolume(device) else {
            outcome = .fixedByHardware
            return .fixedByHardware
        }
        let before = control.scalar(device)
        let wasMuted = control.muted(device)

        guard control.isVolumeSettable(device) else {
            let result = Outcome.notSettable(scalar: before ?? 0)
            outcome = result
            return result
        }

        // 0 dB where the device says where that is, full scale otherwise.
        //
        // The translation is not trusted blindly. A device that publishes the
        // property but answers with zero, a negative, or something outside the
        // scalar range would otherwise have its input written to silence, which
        // is the worst possible outcome here: the sweeps still run and every
        // level is wrong. Anything implausible falls back to full scale, which
        // is at least certainly not attenuating.
        let translated = control.unityScalar(device)
        let plausible = translated.flatMap {
            $0.isFinite && $0 > 0.01 && $0 <= 1 ? $0 : nil
        }
        let written = control.setScalar(device, plausible ?? 1)
        if wasMuted == true { _ = control.setMuted(device, false) }

        guard written, let now = control.scalar(device) else {
            let result = Outcome.notSettable(scalar: before ?? 0)
            outcome = result
            // Nothing took, but the mute may have; put that back.
            if wasMuted == true { _ = control.setMuted(device, true) }
            return result
        }

        restoration = (device, before, wasMuted)
        let result = Outcome.held(decibels: control.decibels(device, forScalar: now))
        outcome = result
        return result
    }

    /// Puts the system setting back exactly as it was found.
    func release() {
        defer { outcome = nil }
        guard let restoration else { return }
        self.restoration = nil
        if let scalar = restoration.scalar {
            _ = control.setScalar(restoration.device, scalar)
        }
        if let muted = restoration.muted {
            _ = control.setMuted(restoration.device, muted)
        }
    }
}

// MARK: - CoreAudio

/// The live control, on the device's input scope.
struct CoreAudioMicrophoneGain: MicrophoneGainControl {

    private func address(_ selector: AudioObjectPropertySelector)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeInput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func hasVolume(_ device: AudioObjectID) -> Bool {
        var target = address(kAudioDevicePropertyVolumeScalar)
        return AudioObjectHasProperty(device, &target)
    }

    func isVolumeSettable(_ device: AudioObjectID) -> Bool {
        var target = address(kAudioDevicePropertyVolumeScalar)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &target, &settable) == noErr
        else { return false }
        return settable.boolValue
    }

    func scalar(_ device: AudioObjectID) -> Float? {
        read(device, address(kAudioDevicePropertyVolumeScalar))
    }

    func setScalar(_ device: AudioObjectID, _ value: Float) -> Bool {
        var target = address(kAudioDevicePropertyVolumeScalar)
        var written = Float32(value)
        return AudioObjectSetPropertyData(device, &target, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size),
                                          &written) == noErr
    }

    func unityScalar(_ device: AudioObjectID) -> Float? {
        // A translation property: the value goes in and comes back converted.
        translate(device, address(kAudioDevicePropertyVolumeDecibelsToScalar), from: 0)
    }

    func decibels(_ device: AudioObjectID, forScalar scalar: Float) -> Double? {
        translate(device, address(kAudioDevicePropertyVolumeScalarToDecibels),
                  from: scalar).map(Double.init)
    }

    func muted(_ device: AudioObjectID) -> Bool? {
        var target = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &target) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &target, 0, nil, &size, &value) == noErr
        else { return nil }
        return value != 0
    }

    func setMuted(_ device: AudioObjectID, _ muted: Bool) -> Bool {
        var target = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &target) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &target, &settable) == noErr,
              settable.boolValue else { return false }
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(device, &target, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size),
                                          &value) == noErr
    }

    private func read(_ device: AudioObjectID,
                      _ target: AudioObjectPropertyAddress) -> Float? {
        var target = target
        guard AudioObjectHasProperty(device, &target) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &target, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private func translate(_ device: AudioObjectID,
                           _ target: AudioObjectPropertyAddress,
                           from input: Float) -> Float? {
        var target = target
        guard AudioObjectHasProperty(device, &target) else { return nil }
        var value = Float32(input)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &target, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }
}
