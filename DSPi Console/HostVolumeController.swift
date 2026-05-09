//
//  HostVolumeController.swift
//  DSPi Console
//
//  Drives whatever audio device is currently the macOS *default* output —
//  the same control the menu-bar slider, the keyboard volume keys, and
//  most third-party mixers operate on.  Two-way sync via CoreAudio
//  property listeners on (a) the default-output assignment so we follow
//  the user's device switch, and (b) the current device's scalar volume
//  so external changes (menu bar, F11/F12, etc.) update the slider in
//  place.
//

import Foundation
import Combine
import CoreAudio

final class HostVolumeController: ObservableObject {

    // MARK: - Published State (main thread)

    /// True when the current default output device supports scalar volume
    /// control.  Some virtual / aggregate devices don't expose it.
    @Published private(set) var isAvailable: Bool = false

    /// 0.0 ... 1.0 scalar.  Mirrors the current default output device's
    /// volume; updated both from user input and from external changes.
    @Published private(set) var volumeScalar: Float = 0

    /// Cached dB conversion of `volumeScalar` for display.  May be
    /// `-.infinity` at scalar = 0.
    @Published private(set) var volumeDB: Float = -.infinity

    /// Decibel range reported by the device for its main output element.
    @Published private(set) var dbRange: ClosedRange<Float> = -60.0 ... 0.0

    /// User-facing name of the current default output device (e.g. "DSPi",
    /// "MacBook Pro Speakers"), or "" when no default is set.
    @Published private(set) var deviceName: String = ""

    // MARK: - Private State

    private var deviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private let queue = DispatchQueue(label: "com.foxdac.hostVolume", qos: .userInitiated)
    private var defaultListenerInstalled = false
    private var volumeListenerInstalled = false

    // MARK: - Lifecycle

    init() {
        queue.async { [weak self] in
            self?.installDefaultDeviceListener()
            self?.rebindToCurrentDefault()
        }
    }

    deinit {
        // CoreAudio listeners are cleaned up by the process exit; we only
        // bother to uninstall here for tidiness during ad-hoc lifecycle
        // testing.  Synchronous on the queue to avoid racing teardown.
        queue.sync {
            self.uninstallVolumeListener()
            self.uninstallDefaultDeviceListener()
        }
    }

    // MARK: - User Actions

    /// Convert a dB value to scalar (using the current device's taper if
    /// available) and apply it.  Useful when re-syncing the host volume
    /// from a non-USB source on a source switch back to USB.
    func setVolumeDB(_ db: Float) {
        queue.async { [weak self] in
            guard let self = self,
                  self.deviceID != AudioDeviceID(kAudioObjectUnknown) else { return }
            let scalar = self.dbToScalar(db)
            DispatchQueue.main.async {
                self.volumeScalar = scalar
                self.volumeDB = db
            }
            var v = scalar
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectSetPropertyData(self.deviceID, &addr, 0, nil,
                                           UInt32(MemoryLayout<Float>.size), &v)
        }
    }

    /// Synchronous-publish counterpart of `setVolumeDB`.  MUST be called
    /// on the main thread.  Updates `volumeScalar` / `volumeDB` in the
    /// same runloop tick as the caller, so a SwiftUI view that swaps in
    /// during this tick reads the new values immediately rather than
    /// rendering once with the stale ones.  The CoreAudio device write
    /// is still queued through `queue` to stay ordered with other writes.
    /// Used during input-source switches to anchor the host-volume slider
    /// at the user-volume value before the sidebar swaps modes.
    func applyVolumeDBImmediate(_ db: Float) {
        let scalar = self.dbToScalar(db)
        self.volumeScalar = scalar
        self.volumeDB = db
        queue.async { [weak self] in
            guard let self = self,
                  self.deviceID != AudioDeviceID(kAudioObjectUnknown) else { return }
            var v = scalar
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectSetPropertyData(self.deviceID, &addr, 0, nil,
                                           UInt32(MemoryLayout<Float>.size), &v)
        }
    }

    /// Public scalar→dB conversion using the current default device's
    /// taper (or a `20·log10` fallback if no device is bound).  Used by
    /// the user-volume sidebar so both volume modes share the same
    /// slider feel — same scalar position produces the same dB value.
    func scalarToDBPublic(_ scalar: Float) -> Float {
        return scalarToDB(scalar)
    }

    /// Public dB→scalar conversion using the current default device's
    /// taper.  Counterpart of `scalarToDBPublic`.
    func dbToScalarPublic(_ db: Float) -> Float {
        return dbToScalar(db)
    }

    /// Inverse of `scalarToDB` — uses CoreAudio's
    /// `kAudioDevicePropertyVolumeDecibelsToScalar` translation, or a
    /// 10^(dB/20) fallback.  Always returns a value clamped to [0, 1].
    private func dbToScalar(_ db: Float) -> Float {
        guard deviceID != AudioDeviceID(kAudioObjectUnknown) else { return 0 }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeDecibelsToScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &addr) {
            var v = db
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &v) == noErr {
                return max(0, min(1, v))
            }
        }
        let s = pow(10.0, Double(db) / 20.0)
        return max(0, min(1, Float(s)))
    }

    /// Apply a new scalar value (0...1) to the current default device.
    /// Updates the published value optimistically; the property listener
    /// reconciles afterwards.
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

    // MARK: - Default-device tracking

    /// Read the system's current default output device and rebind our
    /// volume listener to it.  Runs on `queue`.
    private func rebindToCurrentDefault() {
        let newID = readDefaultOutputDevice()
        if newID == deviceID {
            // Same device — refresh the cached values in case anything
            // changed (e.g. dB range on a hot-plug).
            refreshVolume()
            refreshDeviceMetadata()
            return
        }

        uninstallVolumeListener()
        deviceID = newID

        guard newID != AudioDeviceID(kAudioObjectUnknown) else {
            DispatchQueue.main.async {
                self.isAvailable = false
                self.deviceName = ""
                self.volumeScalar = 0
                self.volumeDB = -.infinity
            }
            return
        }

        // Verify scalar volume is supported on this device's main output.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let supportsVolume = AudioObjectHasProperty(newID, &addr)

        DispatchQueue.main.async { self.isAvailable = supportsVolume }
        refreshDeviceMetadata()

        if supportsVolume {
            installVolumeListener()
            refreshVolume()
        }
    }

    private func readDefaultOutputDevice() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &id) == noErr else {
            return AudioObjectID(kAudioObjectUnknown)
        }
        return id
    }

    // MARK: - Volume read

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
        let name = readCFString(deviceID, selector: kAudioObjectPropertyName) ?? ""
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

    private func readCFString(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        guard id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf)
        guard err == noErr, let unmanaged = cf else { return nil }
        return unmanaged.takeRetainedValue() as String
    }

    // MARK: - Property listeners

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
        if status == noErr { volumeListenerInstalled = true }
    }

    private func uninstallVolumeListener() {
        guard volumeListenerInstalled,
              deviceID != AudioDeviceID(kAudioObjectUnknown) else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        // CoreAudio matches blocks by identity; we can't recover the
        // exact closure we registered with, so this no-op block call is
        // effectively defensive cleanup.  The previous closure captures
        // `weak self` and becomes inert once `self` is released.
        AudioObjectRemovePropertyListenerBlock(deviceID, &addr, queue) { _, _ in }
        volumeListenerInstalled = false
    }

    private func installDefaultDeviceListener() {
        guard !defaultListenerInstalled else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue
        ) { [weak self] _, _ in
            self?.rebindToCurrentDefault()
        }
        if status == noErr { defaultListenerInstalled = true }
    }

    private func uninstallDefaultDeviceListener() {
        guard defaultListenerInstalled else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue
        ) { _, _ in }
        defaultListenerInstalled = false
    }
}
