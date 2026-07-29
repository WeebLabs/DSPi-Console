import AudioToolbox
import CoreAudio
import Foundation

/// Capture and playback for a measurement.
///
/// These are protocols first and CoreAudio second. The spec requires the
/// measurement logic to sit above a backend seam so a WASAPI implementation can
/// replace this on Windows without the session noticing (section 9.2), and the
/// two sides must not assume a shared clock, a shared device, or a common start
/// instant - because they have none of those.
protocol AudioCaptureBackend: AnyObject {
    /// Begin recording from `device`, channel `channelIndex`, at its own rate.
    func start(device: AudioDeviceInfo, channelIndex: Int) throws
    /// Stop and return everything captured, in capture order.
    func stop() -> [Float]
    var isRunning: Bool { get }
    /// Rate the device actually ran at, which is not necessarily what was asked.
    var sampleRate: Double { get }
    /// Peak seen since the last reset, for the level meter.
    func peakAndReset() -> Float
    /// Non-zero if the device reported dropped input. A measurement with
    /// dropouts is invalid rather than merely degraded.
    var overloadCount: Int { get }
}

protocol AudioPlaybackBackend: AnyObject {
    /// Play `samples` into one channel slot of `device`, all other slots
    /// silent, and call `completion` when the buffer has been fully rendered.
    func play(samples: [Float],
              device: AudioDeviceInfo,
              channelIndex: Int,
              completion: @escaping (Result<Void, Error>) -> Void) throws
    func stop()
    var isRunning: Bool { get }
    /// Non-zero if the render callback ever ran dry. Like a capture dropout,
    /// this invalidates the measurement rather than degrading it.
    var underrunCount: Int { get }
}

enum AudioEngineError: LocalizedError {
    case deviceUnavailable(String)
    case channelOutOfRange(requested: Int, available: Int)
    case rateMismatch(requested: Double, actual: Double)
    case coreAudio(String, OSStatus)
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable(let name):
            return "\(name) is no longer available."
        case .channelOutOfRange(let requested, let available):
            return "Channel \(requested + 1) is not present; the device has \(available)."
        case .rateMismatch(let requested, let actual):
            // This one matters more than it looks: a resampled reference no
            // longer matches what the device emitted, and the deconvolution
            // silently produces a wrong answer rather than failing.
            return String(format: "The device is running at %.0f Hz but the sweep was "
                          + "prepared for %.0f Hz. Set the device to %.0f Hz in Audio MIDI "
                          + "Setup, or regenerate the sweep.", actual, requested, requested)
        case .coreAudio(let what, let status):
            return "\(what) failed (CoreAudio error \(status))."
        case .alreadyRunning:
            return "The audio engine is already running."
        }
    }
}

// MARK: - Shared AUHAL plumbing

private enum AUHAL {
    static func makeUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioEngineError.coreAudio("finding the HAL audio unit", -1)
        }
        var unit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            throw AudioEngineError.coreAudio("creating the HAL audio unit", status)
        }
        return unit
    }

    static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw AudioEngineError.coreAudio(what, status) }
    }

    /// Non-interleaved float32, which is what both callbacks below work in and
    /// what the core expects.
    static func floatFormat(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                        | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
    }
}

// MARK: - Capture

/// CoreAudio HAL capture.
///
/// Opens a chosen device explicitly rather than the system default, because a
/// measurement recorded from whatever happened to be default is worthless and
/// the user would have no way to tell.
final class HALCaptureBackend: AudioCaptureBackend {
    private var unit: AudioUnit?
    private var channelIndex = 0
    private var deviceChannels = 0

    /// Written only by the audio callback, read after stop(). Pre-sized so the
    /// callback never allocates.
    private var storage: UnsafeMutablePointer<Float>?
    private var capacity = 0
    private var written = 0
    private var peak: Float = 0
    private var overloads = 0

    private(set) var sampleRate: Double = 0
    private(set) var isRunning = false

    /// How long a single capture may run before it stops itself. A measurement
    /// that never ends is a hung session, and the buffer is preallocated, so
    /// this also bounds memory.
    var maximumSeconds: Double = 120.0

    var overloadCount: Int { overloads }

    deinit { teardown() }

    func start(device: AudioDeviceInfo, channelIndex: Int) throws {
        guard !isRunning else { throw AudioEngineError.alreadyRunning }
        guard device.inputChannels > 0 else {
            throw AudioEngineError.deviceUnavailable(device.name)
        }
        guard channelIndex >= 0 && channelIndex < device.inputChannels else {
            throw AudioEngineError.channelOutOfRange(requested: channelIndex,
                                                     available: device.inputChannels)
        }

        let unit = try AUHAL.makeUnit()
        self.unit = unit
        self.channelIndex = channelIndex
        self.deviceChannels = device.inputChannels

        var enable: UInt32 = 1
        try AUHAL.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                             kAudioUnitScope_Input, 1, &enable,
                                             UInt32(MemoryLayout<UInt32>.size)),
                        "enabling input")
        var disable: UInt32 = 0
        try AUHAL.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                             kAudioUnitScope_Output, 0, &disable,
                                             UInt32(MemoryLayout<UInt32>.size)),
                        "disabling output")

        var deviceID = device.id
        try AUHAL.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                             kAudioUnitScope_Global, 0, &deviceID,
                                             UInt32(MemoryLayout<AudioDeviceID>.size)),
                        "selecting the input device")

        // Take the device's own rate rather than imposing one. Imposing a rate
        // inserts a converter, and a converter in the capture path is a source
        // of error the analysis cannot see.
        let rate = AudioDeviceCatalog.nominalSampleRate(device.id)
        sampleRate = rate > 0 ? rate : device.nominalSampleRate

        var format = AUHAL.floatFormat(sampleRate: sampleRate, channels: device.inputChannels)
        try AUHAL.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                             kAudioUnitScope_Output, 1, &format,
                                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                        "setting the capture format")

        capacity = Int(sampleRate * maximumSeconds)
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        storage?.initialize(repeating: 0, count: capacity)
        written = 0
        peak = 0
        overloads = 0

        var callback = AURenderCallbackStruct(
            inputProc: captureCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try AUHAL.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                             kAudioUnitScope_Global, 0, &callback,
                                             UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                        "installing the capture callback")

        try AUHAL.check(AudioUnitInitialize(unit), "initializing capture")
        try AUHAL.check(AudioOutputUnitStart(unit), "starting capture")
        isRunning = true
    }

    func stop() -> [Float] {
        guard let unit else { return [] }
        if isRunning {
            AudioOutputUnitStop(unit)
            isRunning = false
        }
        let count = written
        var result = [Float](repeating: 0, count: count)
        if let storage, count > 0 {
            result.withUnsafeMutableBufferPointer { buffer in
                buffer.baseAddress?.update(from: storage, count: count)
            }
        }
        teardown()
        return result
    }

    func peakAndReset() -> Float {
        let value = peak
        peak = 0
        return value
    }

    private func teardown() {
        if let unit {
            if isRunning { AudioOutputUnitStop(unit) }
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        isRunning = false
        storage?.deallocate()
        storage = nil
        capacity = 0
    }

    /// Called on the real-time thread. Allocates nothing, takes no locks, and
    /// touches no Swift runtime machinery beyond simple stores.
    fileprivate func append(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard let storage, channelIndex < buffers.count else { return }
        guard let source = buffers[channelIndex].mData?.assumingMemoryBound(to: Float.self) else {
            return
        }
        let room = capacity - written
        let count = min(frames, room)
        if count <= 0 { return }

        var localPeak = peak
        for index in 0..<count {
            let sample = source[index]
            storage[written + index] = sample
            let magnitude = abs(sample)
            if magnitude > localPeak { localPeak = magnitude }
        }
        peak = localPeak
        written += count
    }

    fileprivate func noteOverload() { overloads += 1 }

    fileprivate var audioUnit: AudioUnit? { unit }
    fileprivate var inputChannels: Int { deviceChannels }
}

private let captureCallback: AURenderCallback = {
    refCon, actionFlags, timeStamp, busNumber, frameCount, _ in

    let backend = Unmanaged<HALCaptureBackend>.fromOpaque(refCon).takeUnretainedValue()
    guard let unit = backend.audioUnit else { return noErr }

    let channels = backend.inputChannels
    let bufferListSize = MemoryLayout<AudioBufferList>.size
        + (channels - 1) * MemoryLayout<AudioBuffer>.size
    let raw = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize,
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }

    let list = UnsafeMutableAudioBufferListPointer(
        raw.assumingMemoryBound(to: AudioBufferList.self))
    list.count = channels

    // Ask the unit to hand back its own buffers rather than copying into ours:
    // mData = nil means "give me your pointer", which avoids an allocation on
    // the real-time thread.
    for index in 0..<channels {
        list[index] = AudioBuffer(mNumberChannels: 1,
                                  mDataByteSize: frameCount * 4,
                                  mData: nil)
    }

    let status = AudioUnitRender(unit, actionFlags, timeStamp, busNumber, frameCount,
                                 list.unsafeMutablePointer)
    if status != noErr {
        backend.noteOverload()
        return status
    }
    backend.append(list, frames: Int(frameCount))
    return noErr
}

// MARK: - Playback

/// CoreAudio HAL playback into a single channel slot.
///
/// The rate is verified rather than requested. Authoring a sweep at one rate
/// and letting CoreAudio resample it on the way out means the reference no
/// longer matches what the device emitted, and the deconvolution produces a
/// confidently wrong answer, so a mismatch is refused up front.
final class HALPlaybackBackend: AudioPlaybackBackend {
    private var unit: AudioUnit?
    private var samples: [Float] = []
    private var position = 0
    private var channelIndex = 0
    private var deviceChannels = 0
    private var completion: ((Result<Void, Error>) -> Void)?
    private var underruns = 0
    private var finished = false
    private var overloadListener: AudioObjectPropertyListenerBlock?
    private var listeningTo: AudioDeviceID?

    private(set) var isRunning = false
    var underrunCount: Int { underruns }

    deinit { teardown() }

    func play(samples: [Float],
              device: AudioDeviceInfo,
              channelIndex: Int,
              completion: @escaping (Result<Void, Error>) -> Void) throws {
        try play(samples: samples, device: device, channelIndex: channelIndex,
                 expectedSampleRate: nil, completion: completion)
    }

    /// Playback with an explicit rate contract. The session always uses this
    /// form, because the sweep it renders is only valid at one rate.
    func play(samples: [Float],
              device: AudioDeviceInfo,
              channelIndex: Int,
              expectedSampleRate: Double?,
              completion: @escaping (Result<Void, Error>) -> Void) throws {
        guard !isRunning else { throw AudioEngineError.alreadyRunning }
        guard device.outputChannels > 0 else {
            throw AudioEngineError.deviceUnavailable(device.name)
        }
        guard channelIndex >= 0 && channelIndex < device.outputChannels else {
            throw AudioEngineError.channelOutOfRange(requested: channelIndex,
                                                     available: device.outputChannels)
        }

        let actualRate = AudioDeviceCatalog.nominalSampleRate(device.id)
        if let expected = expectedSampleRate, abs(actualRate - expected) > 1.0 {
            throw AudioEngineError.rateMismatch(requested: expected, actual: actualRate)
        }

        let unit = try AUHAL.makeUnit()
        self.unit = unit
        self.samples = samples
        self.position = 0
        self.channelIndex = channelIndex
        self.deviceChannels = device.outputChannels
        self.completion = completion
        self.underruns = 0
        self.finished = false

        var deviceID = device.id
        try AUHAL.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                             kAudioUnitScope_Global, 0, &deviceID,
                                             UInt32(MemoryLayout<AudioDeviceID>.size)),
                        "selecting the output device")

        let rate = actualRate > 0 ? actualRate : device.nominalSampleRate
        var format = AUHAL.floatFormat(sampleRate: rate, channels: device.outputChannels)
        try AUHAL.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                             kAudioUnitScope_Input, 0, &format,
                                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                        "setting the playback format")

        var callback = AURenderCallbackStruct(
            inputProc: playbackCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try AUHAL.check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                             kAudioUnitScope_Input, 0, &callback,
                                             UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                        "installing the playback callback")

        try AUHAL.check(AudioUnitInitialize(unit), "initializing playback")
        startWatchingForOverloads(on: device.id)
        try AUHAL.check(AudioOutputUnitStart(unit), "starting playback")
        isRunning = true
    }

    /// The real dropout signal for output.
    ///
    /// CoreAudio reports an overrun of the IO cycle on the device rather than
    /// through the render callback, so this is the only place a genuine
    /// playback dropout can be observed.
    private func startWatchingForOverloads(on device: AudioDeviceID) {
        stopWatchingForOverloads()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.underruns += 1
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, nil, listener)
        if status == noErr {
            overloadListener = listener
            listeningTo = device
        }
    }

    private func stopWatchingForOverloads() {
        guard let overloadListener, let listeningTo else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(listeningTo, &address, nil, overloadListener)
        self.overloadListener = nil
        self.listeningTo = nil
    }

    func stop() {
        guard isRunning else { return }
        teardown()
        // A stop before the buffer finished is a cancellation, not a success.
        deliver(.failure(CancellationError()))
    }

    private func teardown() {
        stopWatchingForOverloads()
        if let unit {
            if isRunning { AudioOutputUnitStop(unit) }
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        isRunning = false
    }

    private func deliver(_ result: Result<Void, Error>) {
        guard let completion else { return }
        self.completion = nil
        DispatchQueue.main.async { completion(result) }
    }

    /// Sets up the render state without opening a device, so the callback's
    /// buffer accounting can be tested without audio hardware.
    func prepareForRenderTest(samples: [Float], channelIndex: Int, channels: Int) {
        self.samples = samples
        self.position = 0
        self.channelIndex = channelIndex
        self.deviceChannels = channels
        self.underruns = 0
        self.finished = false
    }

    func renderForTest(into list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        render(into: list, frames: frames)
    }

    /// Real-time thread.
    fileprivate func render(into list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        for index in 0..<list.count {
            if let data = list[index].mData {
                memset(data, 0, Int(list[index].mDataByteSize))
            }
        }
        guard channelIndex < list.count,
              let destination = list[channelIndex].mData?.assumingMemoryBound(to: Float.self)
        else { return }

        let remaining = samples.count - position
        if remaining <= 0 {
            if !finished {
                finished = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.teardown()
                    self.deliver(.success(()))
                }
            }
            return
        }

        // A short final block is not an underrun. The buffer length is rarely
        // a multiple of the hardware block size, so the last callback of every
        // playback asks for more than is left - which was counted as a dropout
        // and made the level check fail every single time.
        //
        // With the whole signal preloaded there is no underrun condition here
        // at all; a genuine dropout is the IO cycle overrunning, which arrives
        // through the processor-overload listener instead.
        let count = min(frames, remaining)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            destination.update(from: base + position, count: count)
        }
        position += count
    }
}

private let playbackCallback: AURenderCallback = {
    refCon, _, _, _, frameCount, ioData in

    let backend = Unmanaged<HALPlaybackBackend>.fromOpaque(refCon).takeUnretainedValue()
    guard let ioData else { return noErr }
    let list = UnsafeMutableAudioBufferListPointer(ioData)
    backend.render(into: list, frames: Int(frameCount))
    return noErr
}
