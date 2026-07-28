import AVFoundation
import CoreAudio
import Foundation

/// An audio device as the measurement session sees it.
///
/// Identity is the CoreAudio UID, not the display name. Names collide (two
/// identical interfaces, or a hub reporting the same string) and change between
/// boots; the UID is what lets a saved project say which microphone produced a
/// measurement, and what lets the picker survive a replug.
struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let nominalSampleRate: Double
    let supportedSampleRates: [Double]

    var hasInput: Bool { inputChannels > 0 }
    var hasOutput: Bool { outputChannels > 0 }

    func supports(sampleRate: Double) -> Bool {
        supportedSampleRates.contains { abs($0 - sampleRate) < 1.0 }
    }
}

/// Enumerates CoreAudio devices and tracks hot-plug.
///
/// Deliberately not a view model: it holds no session state and makes no
/// choices, so the setup screen can own the choosing and this can be tested and
/// reused.
final class AudioDeviceCatalog: ObservableObject {
    @Published private(set) var devices: [AudioDeviceInfo] = []

    private var listener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "com.weeblabs.dspi.audio-devices")

    init(startListening: Bool = true) {
        refresh()
        if startListening { startHotPlugListener() }
    }

    deinit { stopHotPlugListener() }

    var inputDevices: [AudioDeviceInfo] { devices.filter(\.hasInput) }
    var outputDevices: [AudioDeviceInfo] { devices.filter(\.hasOutput) }

    func device(uid: String) -> AudioDeviceInfo? {
        devices.first { $0.uid == uid }
    }

    func refresh() {
        let discovered = Self.enumerate()
        if Thread.isMainThread {
            devices = discovered
        } else {
            DispatchQueue.main.async { [weak self] in self?.devices = discovered }
        }
    }

    // MARK: - Hot plug

    private func startHotPlugListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                           &address, queue, block)
    }

    private func stopHotPlugListener() {
        guard let listener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &address, queue, listener)
        self.listener = nil
    }

    // MARK: - Enumeration

    static func enumerate() -> [AudioDeviceInfo] {
        allDeviceIDs().compactMap(info(for:))
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &dataSize, &ids) == noErr else { return [] }
        return ids
    }

    static func info(for device: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = stringProperty(device, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = stringProperty(device, kAudioObjectPropertyName) ?? uid

        let inputs = channelCount(device, scope: kAudioObjectPropertyScopeInput)
        let outputs = channelCount(device, scope: kAudioObjectPropertyScopeOutput)
        guard inputs > 0 || outputs > 0 else { return nil }

        return AudioDeviceInfo(id: device,
                               uid: uid,
                               name: name,
                               inputChannels: inputs,
                               outputChannels: outputs,
                               nominalSampleRate: nominalSampleRate(device),
                               supportedSampleRates: supportedSampleRates(device))
    }

    static func channelCount(device: AudioObjectID, input: Bool) -> Int {
        channelCount(device, scope: input ? kAudioObjectPropertyScopeInput
                                          : kAudioObjectPropertyScopeOutput)
    }

    private static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return 0 }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize),
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, buffer) == noErr
        else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ device: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var rate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, &rate) == noErr
        else { return 0 }
        return rate
    }

    private static func supportedSampleRates(_ device: AudioObjectID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, &ranges) == noErr
        else { return [] }

        // A range with equal endpoints is a discrete rate; a true range means
        // the device will accept anything between, so both endpoints count.
        var rates: Set<Double> = []
        for range in ranges {
            rates.insert(range.mMinimum)
            rates.insert(range.mMaximum)
        }
        return rates.sorted()
    }
}

// MARK: - Microphone permission

/// Microphone authorization.
///
/// Kept separate from capture so the setup screen can show and resolve a denied
/// state before anything tries to open a device, rather than surfacing it as a
/// capture failure halfway through a measurement.
enum MicrophoneAccess {
    enum State: Equatable {
        case granted
        case denied
        case notDetermined
        case restricted

        var canRecord: Bool { self == .granted }

        /// What to tell the user, and whether there is anything they can do.
        var explanation: String? {
            switch self {
            case .granted:
                return nil
            case .notDetermined:
                return "DSPi Console needs permission to use the microphone."
            case .denied:
                return "Microphone access is turned off for DSPi Console. "
                     + "Turn it on in System Settings to measure your room."
            case .restricted:
                return "Microphone access is restricted on this Mac and cannot be "
                     + "changed here."
            }
        }

        /// Whether pointing the user at System Settings would help. It does not
        /// when the state is restricted by policy.
        var offersSystemSettings: Bool { self == .denied }
    }

    static var state: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Prompts only when the state is undetermined; asking again after a denial
    /// does nothing and the system will not re-prompt.
    static func request() async -> State {
        guard state == .notDetermined else { return state }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return state
    }

    static let systemSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
}
