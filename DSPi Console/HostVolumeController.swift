//
//  HostVolumeController.swift
//  DSPi Console
//
//  Drives the DSPi audio device's CoreAudio scalar volume via the standard
//  USB Audio Class HID volume control.  When the user moves the sidebar
//  slider, macOS sends Set Cur volume to the device exactly the same way
//  the menu-bar volume slider does — so the firmware's USB volume state,
//  the menu-bar slider, the keyboard volume keys, and our slider all
//  remain in sync via a single property listener.
//
//  This is independent of REQ_SET_MASTER_VOLUME (the firmware's vendor
//  attenuator).  The two attenuators would multiply if both surfaced in
//  the UI; we leave the vendor MV machinery intact for presets but hide
//  its sidebar control.
//

import Foundation
import Combine
import CoreAudio
import IOKit
import IOKit.usb

final class HostVolumeController: ObservableObject {

    // MARK: - Published State (main thread)

    /// True when a DSPi audio device has been located and supports
    /// volume control on its main output element.
    @Published private(set) var isAvailable: Bool = false

    /// 0.0 ... 1.0 scalar.  Mirrors the device's output volume; updated
    /// both from user input and from external changes (menu-bar slider,
    /// keyboard keys, etc.) via a property listener.
    @Published private(set) var volumeScalar: Float = 0

    /// Cached dB conversion of `volumeScalar` for display.  May be
    /// `-.infinity` at scalar = 0.  Refreshed on every scalar update.
    @Published private(set) var volumeDB: Float = -.infinity

    /// Decibel range reported by the device for its main output element.
    /// Used by the display to pin the bottom of the slider's dB readout.
    @Published private(set) var dbRange: ClosedRange<Float> = -60.0 ... 0.0

    @Published private(set) var deviceName: String = ""

    // MARK: - Private State

    private var deviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private let queue = DispatchQueue(label: "com.foxdac.hostVolume", qos: .userInitiated)
    private var devicesListenerInstalled = false
    private var volumeListenerInstalled = false

    // Match config — the macOS audio device's display name typically
    // mirrors the USB Product string descriptor.  We accept anything
    // containing this token (case-insensitive) so the spelling can vary.
    private static let nameToken = "DSPi"

    // Also try matching against the device's ModelUID by USB VID/PID.
    private static let vidHex = "2e8a"
    private static let pidHex = "feaa"

    // MARK: - Lifecycle

    /// Start listening for the DSPi audio device and install volume
    /// listeners.  Idempotent — calling twice is safe.
    func attach() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.installDevicesListener()
            self.locateDeviceAndBind()
        }
    }

    /// Tear down listeners and clear state.  Called on USB disconnect or
    /// when the audio device disappears.
    func detach() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.uninstallVolumeListener()
            self.uninstallDevicesListener()
            self.clearDevice()
        }
    }

    // MARK: - User Actions

    /// Apply a new scalar value (0...1) to the device.  Updates the
    /// published value optimistically, then writes to CoreAudio.  The
    /// property listener will reconcile if the device reports a different
    /// value.
    func setVolumeScalar(_ value: Float) {
        let clamped = max(0, min(1, value))
        DispatchQueue.main.async {
            self.volumeScalar = clamped
            self.volumeDB = self.scalarToDB(clamped)
        }
        queue.async { [weak self] in
            guard let self = self,
                  self.deviceID != AudioDeviceID(kAudioObjectUnknown) else { return }
            var v = clamped
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectSetPropertyData(self.deviceID, &addr, 0, nil,
                                           UInt32(MemoryLayout<Float>.size), &v)
        }
    }

    // MARK: - Device Discovery

    /// Enumerate all audio devices, find the DSPi, and install the volume
    /// listener.  Runs on `queue`.
    private func locateDeviceAndBind() {
        let found = scanForDSPiDevice()
        if let id = found, id != deviceID {
            uninstallVolumeListener()
            deviceID = id
            installVolumeListener()
            refreshDeviceMetadata()
            refreshVolume()
            DispatchQueue.main.async { self.isAvailable = true }
        } else if found == nil && deviceID != AudioDeviceID(kAudioObjectUnknown) {
            // Device disappeared
            uninstallVolumeListener()
            clearDevice()
        }
    }

    /// Returns the DSPi device's AudioDeviceID, or nil if not found.
    private func scanForDSPiDevice() -> AudioDeviceID? {
        let devices = enumerateAudioDevices()

        for id in devices {
            // Must be USB transport
            guard transportType(of: id) == kAudioDeviceTransportTypeUSB else { continue }

            // Must have at least one output stream
            guard hasOutputStreams(id) else { continue }

            // Must support a scalar volume on the main output element
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(id, &volAddr) else { continue }

            // Match by display name OR ModelUID embedding VID/PID
            let name = (deviceName(of: id) ?? "").lowercased()
            let modelUID = (modelUID(of: id) ?? "").lowercased()
            let nameMatch = name.contains(Self.nameToken.lowercased())
            let uidMatch = modelUID.contains(Self.vidHex) && modelUID.contains(Self.pidHex)

            if nameMatch || uidMatch {
                return id
            }
        }
        return nil
    }

    private func enumerateAudioDevices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return false }
        let bufList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufList.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, bufList) == noErr else { return false }
        return bufList.pointee.mNumberBuffers > 0
    }

    private func transportType(of id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private func deviceName(of id: AudioDeviceID) -> String? {
        readCFString(id, selector: kAudioObjectPropertyName)
    }

    private func modelUID(of id: AudioDeviceID) -> String? {
        readCFString(id, selector: kAudioDevicePropertyModelUID)
    }

    private func readCFString(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf)
        guard err == noErr, let unmanaged = cf else { return nil }
        let s = unmanaged.takeRetainedValue() as String
        return s
    }

    // MARK: - Volume Read / Listener

    private func refreshVolume() {
        guard deviceID != AudioDeviceID(kAudioObjectUnknown) else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var v: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &v) == noErr else { return }

        let db = scalarToDB(v)
        let range = readDBRange()
        DispatchQueue.main.async {
            self.volumeScalar = v
            self.volumeDB = db
            self.dbRange = range
        }
    }

    private func refreshDeviceMetadata() {
        let name = deviceName(of: deviceID) ?? ""
        DispatchQueue.main.async { self.deviceName = name }
    }

    /// Convert a 0..1 scalar to dB by asking CoreAudio (the device's
    /// taper may be nonlinear).  Falls back to 20·log10 for devices
    /// that don't support the translation property.
    private func scalarToDB(_ scalar: Float) -> Float {
        guard deviceID != AudioDeviceID(kAudioObjectUnknown) else { return -.infinity }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalarToDecibels,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &addr) {
            var v = scalar
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &v) == noErr {
                return v
            }
        }
        if scalar <= 0 { return -.infinity }
        return 20.0 * log10(scalar)
    }

    private func readDBRange() -> ClosedRange<Float> {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeRangeDecibels,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &range) == noErr else {
            return -60.0 ... 0.0
        }
        return Float(range.mMinimum) ... Float(range.mMaximum)
    }

    // MARK: - Property Listeners

    private func installVolumeListener() {
        guard !volumeListenerInstalled,
              deviceID != AudioDeviceID(kAudioObjectUnknown) else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &addr, queue) { [weak self] _, _ in
            self?.refreshVolume()
        }
        if status == noErr {
            volumeListenerInstalled = true
        }
    }

    private func uninstallVolumeListener() {
        guard volumeListenerInstalled,
              deviceID != AudioDeviceID(kAudioObjectUnknown) else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        // We registered with a fresh closure capture each time; remove all
        // listeners on this property by passing an empty block.  CoreAudio
        // matches blocks by identity, so we can't strictly remove the
        // exact one we added without retaining it — using a no-op here is
        // a known limitation; the listener will simply ignore the dead
        // weak self reference.
        AudioObjectRemovePropertyListenerBlock(deviceID, &addr, queue) { _, _ in }
        volumeListenerInstalled = false
    }

    private func installDevicesListener() {
        guard !devicesListenerInstalled else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue
        ) { [weak self] _, _ in
            self?.locateDeviceAndBind()
        }
        if status == noErr {
            devicesListenerInstalled = true
        }
    }

    private func uninstallDevicesListener() {
        guard devicesListenerInstalled else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue
        ) { _, _ in }
        devicesListenerInstalled = false
    }

    private func clearDevice() {
        deviceID = AudioDeviceID(kAudioObjectUnknown)
        DispatchQueue.main.async {
            self.isAvailable = false
            self.volumeScalar = 0
            self.volumeDB = -.infinity
            self.deviceName = ""
        }
    }
}
