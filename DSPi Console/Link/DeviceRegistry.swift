//
//  DeviceRegistry.swift
//  DSPi Console
//
//  Maps a device's stable serial to the small integer handle binary frames
//  use, holds the hub-stored friendly name (keyed by serial so it follows the
//  board between hubs and links), tracks online/offline/updating state with a
//  grace period, and emits device.added / removed / changed events.  Pure
//  logic; the hub feeds it connection changes.  See spec 7.4.
//

import Foundation

// LinkDeviceState is defined in LinkMessages.swift.

struct RegisteredDevice: Equatable {
    var handle: UInt8
    var info: HubDeviceInfo
    var name: String
    var state: LinkDeviceState
    var lockedBy: LinkSessionID?
}

enum DeviceRegistryEvent: Equatable {
    case added(RegisteredDevice)
    case removed(handle: UInt8, serial: String)
    case changed(RegisteredDevice)
}

final class DeviceRegistry {
    /// How long a known device keeps its handle after it drops, so a brief
    /// unplug or a firmware re-enumeration does not renumber it.
    var offlineGrace: TimeInterval = 60

    private var bySerial: [String: RegisteredDevice] = [:]
    private var nextHandle: UInt8 = 0
    private var offlineSince: [String: Date] = [:]
    private let lock = NSLock()
    private let names: DeviceNameStore

    /// Fired on every change; the hub relays these to sessions.
    var onEvent: ((DeviceRegistryEvent) -> Void)?

    init(nameStore: DeviceNameStore = DeviceNameStore()) {
        self.names = nameStore
    }

    /// Mark a device present with the given identity.  Assigns a handle the
    /// first time, reuses it if the same serial returns within the grace
    /// window, and updates identity fields (firmware after an update, wire
    /// version once read).  Emits added or changed.
    @discardableResult
    func deviceOnline(_ info: HubDeviceInfo, now: Date = Date()) -> RegisteredDevice {
        lock.lock()
        offlineSince[info.serial] = nil
        if var existing = bySerial[info.serial] {
            let wasChanged = existing.info != info || existing.state != .online
            existing.info = info
            existing.state = .online
            bySerial[info.serial] = existing
            lock.unlock()
            if wasChanged { emit(.changed(existing)) }
            return existing
        }
        let handle = allocateHandle()
        let device = RegisteredDevice(handle: handle, info: info,
                                      name: names.name(forSerial: info.serial) ?? Self.defaultName(info),
                                      state: .online, lockedBy: nil)
        bySerial[info.serial] = device
        lock.unlock()
        emit(.added(device))
        return device
    }

    /// The device dropped.  It stays listed as offline until the grace window
    /// elapses; call `reapOffline` on a timer to remove it after that.
    func deviceOffline(serial: String, now: Date = Date()) {
        lock.lock()
        guard var d = bySerial[serial], d.state != .offline else { lock.unlock(); return }
        d.state = .offline
        d.lockedBy = nil
        bySerial[serial] = d
        offlineSince[serial] = now
        lock.unlock()
        emit(.changed(d))
    }

    /// Remove any device that has been offline longer than the grace window.
    func reapOffline(now: Date = Date()) {
        lock.lock()
        let expired = offlineSince.filter { now.timeIntervalSince($0.value) >= offlineGrace }
        var removed: [(UInt8, String)] = []
        for (serial, _) in expired {
            if let d = bySerial[serial] {
                removed.append((d.handle, serial))
                bySerial[serial] = nil
            }
            offlineSince[serial] = nil
        }
        lock.unlock()
        for (h, s) in removed { emit(.removed(handle: h, serial: s)) }
    }

    func setState(serial: String, _ state: LinkDeviceState) {
        lock.lock()
        guard var d = bySerial[serial], d.state != state else { lock.unlock(); return }
        d.state = state
        bySerial[serial] = d
        lock.unlock()
        emit(.changed(d))
    }

    func setLockHolder(handle: UInt8, session: LinkSessionID?) {
        lock.lock()
        guard let serial = bySerial.first(where: { $0.value.handle == handle })?.key,
              var d = bySerial[serial], d.lockedBy != session else { lock.unlock(); return }
        d.lockedBy = session
        bySerial[serial] = d
        lock.unlock()
        emit(.changed(d))
    }

    func rename(handle: UInt8, to name: String) {
        lock.lock()
        guard let serial = bySerial.first(where: { $0.value.handle == handle })?.key,
              var d = bySerial[serial] else { lock.unlock(); return }
        d.name = name
        bySerial[serial] = d
        names.setName(name, forSerial: serial)
        lock.unlock()
        emit(.changed(d))
    }

    var devices: [RegisteredDevice] {
        lock.lock(); defer { lock.unlock() }
        return bySerial.values.sorted { $0.handle < $1.handle }
    }

    func device(handle: UInt8) -> RegisteredDevice? {
        lock.lock(); defer { lock.unlock() }
        return bySerial.values.first { $0.handle == handle }
    }

    func device(serial: String) -> RegisteredDevice? {
        lock.lock(); defer { lock.unlock() }
        return bySerial[serial]
    }

    // MARK: - Private

    /// Lowest handle not currently in use (0..254; 255 reserved).  Called
    /// under `lock`.
    private func allocateHandle() -> UInt8 {
        let used = Set(bySerial.values.map { $0.handle })
        for h in UInt8(0)...254 where !used.contains(h) { return h }
        return 254
    }

    private func emit(_ event: DeviceRegistryEvent) { onEvent?(event) }

    private static func defaultName(_ info: HubDeviceInfo) -> String {
        "DSPi " + String(info.serial.suffix(6))
    }
}

/// Persists friendly names by serial in UserDefaults, so a device keeps its
/// name across restarts and between the hosts that share it.
final class DeviceNameStore {
    private let defaults: UserDefaults
    private let key = "LinkDeviceNames"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func name(forSerial serial: String) -> String? {
        (defaults.dictionary(forKey: key) as? [String: String])?[serial]
    }

    func setName(_ name: String, forSerial serial: String) {
        var map = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        map[serial] = name
        defaults.set(map, forKey: key)
    }
}
