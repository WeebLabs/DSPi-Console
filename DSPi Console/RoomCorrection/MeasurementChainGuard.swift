import CoreAudio
import Foundation

/// Watches the measurement chain for a change that would invalidate a session.
///
/// Every level comparison in this feature is relative: channels are compared to
/// each other through the same microphone, at the same position, through the
/// same input chain, and the unknown chain gain cancels because it is common to
/// all of them. That only holds while the chain does not change.
///
/// So the rule is load-bearing rather than advisory. A microphone gain moved
/// halfway through a level pass does not produce a slightly worse match, it
/// produces a confidently wrong one - which is the failure worth stopping for
/// rather than warning about.
///
/// See `Documentation/room_correction_level_calibration.md` section 2.
@MainActor
final class MeasurementChainGuard: ObservableObject {

    /// What was true when the session started.
    struct Baseline: Equatable {
        let deviceUID: String
        let volume: Float?
        let sampleRate: Double
    }

    enum Violation: Equatable {
        case deviceChanged(from: String, to: String)
        case volumeChanged(from: Float, to: Float)
        case sampleRateChanged(from: Double, to: Double)
        case deviceGone(String)

        /// Named plainly, because the user has to know which knob to put back.
        var explanation: String {
            switch self {
            case .deviceChanged(let from, let to):
                return "The measurement microphone changed from \(from) to \(to). "
                     + "Levels measured through one microphone cannot be compared with "
                     + "levels measured through another."
            case .volumeChanged(let from, let to):
                return String(format: "The microphone input gain changed from %.0f%% to "
                              + "%.0f%%. Every level measured before the change is on a "
                              + "different scale from every level measured after it.",
                              from * 100, to * 100)
            case .sampleRateChanged(let from, let to):
                return String(format: "The input sample rate changed from %.0f Hz to "
                              + "%.0f Hz.", from, to)
            case .deviceGone(let name):
                return "\(name) is no longer available."
            }
        }
    }

    @Published private(set) var baseline: Baseline?
    @Published private(set) var violation: Violation?

    /// True while a session is relying on the chain staying put.
    var isWatching: Bool { baseline != nil }

    private var device: AudioObjectID?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// Reads the properties this guard compares against.
    ///
    /// Injectable so the rules can be tested without a real device: CoreAudio
    /// has no way to fake a gain change, and the whole point of this class is
    /// what it does when one happens.
    var readVolume: (AudioObjectID) -> Float? = MeasurementChainGuard.inputVolume
    var readSampleRate: (AudioObjectID) -> Double = AudioDeviceCatalog.nominalSampleRate

    // MARK: - Lifecycle

    func start(device: AudioObjectID, uid: String) {
        stop()
        self.device = device
        baseline = Baseline(deviceUID: uid,
                            volume: readVolume(device),
                            sampleRate: readSampleRate(device))
        violation = nil
        installListeners(on: device)
    }

    func stop() {
        removeListeners()
        device = nil
        baseline = nil
        violation = nil
    }

    /// Checks the chain against the baseline.
    ///
    /// Called from the property listeners, and again before anything is
    /// measured: a listener can be installed a moment after a change and would
    /// otherwise miss it entirely.
    @discardableResult
    func check(currentUID: String?) -> Violation? {
        guard let baseline, let device else { return nil }
        if violation != nil { return violation }

        guard let currentUID else {
            violation = .deviceGone(baseline.deviceUID)
            return violation
        }
        if currentUID != baseline.deviceUID {
            violation = .deviceChanged(from: baseline.deviceUID, to: currentUID)
            return violation
        }

        let rate = readSampleRate(device)
        if rate > 0, baseline.sampleRate > 0, abs(rate - baseline.sampleRate) > 1 {
            violation = .sampleRateChanged(from: baseline.sampleRate, to: rate)
            return violation
        }

        // Only when the device actually reports a settable input volume. Plenty
        // do not, and absence is not a change.
        if let was = baseline.volume, let now = readVolume(device),
           abs(now - was) > 0.005 {
            violation = .volumeChanged(from: was, to: now)
            return violation
        }
        return nil
    }

    // MARK: - CoreAudio

    /// The input scope's master volume, where the device has one.
    static func inputVolume(_ device: AudioObjectID) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)

        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private func installListeners(on device: AudioObjectID) {
        let selectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
        ]

        for (selector, scope) in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(device, &address) else { continue }

            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.check(currentUID: self.baseline?.deviceUID)
                }
            }
            if AudioObjectAddPropertyListenerBlock(device, &address, nil, listener) == noErr {
                listeners.append((address, listener))
            }
        }
    }

    private func removeListeners() {
        guard let device else { listeners = []; return }
        for (address, listener) in listeners {
            var mutable = address
            AudioObjectRemovePropertyListenerBlock(device, &mutable, nil, listener)
        }
        listeners = []
    }

    deinit { }
}
