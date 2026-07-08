//
//  HostAudioFormatMonitor.swift
//  DSPi Console
//
//  Watches the macOS CoreAudio representation of the connected DSPi and reports
//  the host-selected USB output channel count (2/4/6/8).
//
//  Why this exists: the firmware reports its ACTIVE input count from whatever USB
//  audio alternate setting the host currently has open.  When no app is playing,
//  macOS drops the streaming interface to alt 0 (zero-bandwidth, no endpoints)
//  and the firmware reports a stereo fallback - so Console would collapse to two
//  input strips even though the user has, say, an 8-channel format selected in
//  Audio MIDI Setup.  CoreAudio keeps reporting the user-selected format's
//  channel count while the device is idle, so we use it as the authoritative
//  "configured" count and fall back to the device report only when the CoreAudio
//  device can't be resolved.
//

import Foundation
import CoreAudio

/// Resolves the DSPi's CoreAudio output device and publishes its host-selected
/// channel count, updating live as the user changes format or (un)plugs the
/// device.  All CoreAudio work runs on a private serial queue; the callback is
/// delivered on the main thread.
final class HostAudioFormatMonitor {

    /// Fires on the main thread whenever the resolved channel count changes.
    /// `nil` means the DSPi CoreAudio device could not be found (the caller
    /// should fall back to the device-reported active count).
    var onChannelCountChanged: ((Int?) -> Void)?

    /// Case-insensitive token identifying the DSPi in a CoreAudio device UID or
    /// name.  The USB product string is "Weeb Labs DSPi"; the UID embeds it and
    /// is stable across an Audio-MIDI-Setup rename (which only changes the name).
    private let matchToken = "DSPi"

    private let queue = DispatchQueue(label: "com.foxdac.coreaudio.format")
    private var currentDevice = AudioObjectID(kAudioObjectUnknown)
    // Sentinel distinct from every real value (including nil) so the first
    // rescan always delivers an initial count.
    private var lastReported: Int?? = .some(-1)
    private var started = false

    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var deviceBlock: AudioObjectPropertyListenerBlock?

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self = self, !self.started else { return }
            self.started = true

            var addr = Self.address(kAudioHardwarePropertyDevices)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                // Already delivered on `queue`; the device set changed
                // (hot-plug), so re-resolve which object is the DSPi.
                self?.rescan()
            }
            self.systemBlock = block
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, self.queue, block)

            self.rescan()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self, self.started else { return }
            self.started = false

            if let block = self.systemBlock {
                var addr = Self.address(kAudioHardwarePropertyDevices)
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &addr, self.queue, block)
                self.systemBlock = nil
            }
            self.removeDeviceListener()
            self.currentDevice = AudioObjectID(kAudioObjectUnknown)
            self.lastReported = .some(-1)
        }
    }

    // MARK: - Resolution (all on `queue`)

    private func rescan() {
        let dev = findDSPiDevice() ?? AudioObjectID(kAudioObjectUnknown)
        if dev != currentDevice {
            removeDeviceListener()
            currentDevice = dev
            addDeviceListener()
        }
        report()
    }

    /// Reads the current device's channel count and notifies the callback if it
    /// changed since the last report.
    private func report() {
        let count: Int? = currentDevice == AudioObjectID(kAudioObjectUnknown)
            ? nil
            : outputChannelCount(currentDevice)

        guard lastReported != .some(count) else { return }
        lastReported = .some(count)
        let callback = onChannelCountChanged
        DispatchQueue.main.async { callback?(count) }
    }

    /// First USB output device whose UID or name contains `matchToken`.  We
    /// require a positive output-channel count so that, if the device presents
    /// separate input and output objects, we pick the output side (the DSPi is
    /// played *to* by the host).
    private func findDSPiDevice() -> AudioObjectID? {
        for dev in Self.allDeviceIDs() {
            guard transportType(dev) == kAudioDeviceTransportTypeUSB else { continue }
            guard let channels = outputChannelCount(dev), channels > 0 else { continue }
            let uid = stringProperty(dev, kAudioDevicePropertyDeviceUID) ?? ""
            let name = stringProperty(dev, kAudioObjectPropertyName) ?? ""
            if uid.localizedCaseInsensitiveContains(matchToken)
                || name.localizedCaseInsensitiveContains(matchToken) {
                return dev
            }
        }
        return nil
    }

    // MARK: - Per-device listener

    private func addDeviceListener() {
        guard currentDevice != AudioObjectID(kAudioObjectUnknown) else { return }
        var addr = Self.address(kAudioDevicePropertyStreamConfiguration,
                                kAudioObjectPropertyScopeOutput)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // The output stream layout changed (user picked a new format) -
            // channel count may have moved.
            self?.report()
        }
        deviceBlock = block
        AudioObjectAddPropertyListenerBlock(currentDevice, &addr, queue, block)
    }

    private func removeDeviceListener() {
        guard currentDevice != AudioObjectID(kAudioObjectUnknown),
              let block = deviceBlock else { return }
        var addr = Self.address(kAudioDevicePropertyStreamConfiguration,
                                kAudioObjectPropertyScopeOutput)
        AudioObjectRemovePropertyListenerBlock(currentDevice, &addr, queue, block)
        deviceBlock = nil
    }

    // MARK: - CoreAudio property helpers

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDeviceIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &dataSize, &ids) == noErr
        else { return [] }
        return ids
    }

    private func transportType(_ dev: AudioObjectID) -> UInt32? {
        var addr = Self.address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private func stringProperty(_ dev: AudioObjectID,
                                _ selector: AudioObjectPropertySelector) -> String? {
        var addr = Self.address(selector)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let string = value else { return nil }
        return string as String
    }

    /// Sum of channels across the output-scope stream configuration, i.e. the
    /// number of channels the host currently sends to the device.
    private func outputChannelCount(_ dev: AudioObjectID) -> Int? {
        var addr = Self.address(kAudioDevicePropertyStreamConfiguration,
                                kAudioObjectPropertyScopeOutput)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &dataSize, raw) == noErr
        else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        var channels = 0
        for buffer in list { channels += Int(buffer.mNumberChannels) }
        return channels
    }
}
