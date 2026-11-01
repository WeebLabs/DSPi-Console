//
//  DeviceRegistry.swift
//  DSPi Console
//
//  Maps a device's stable serial to the small integer handle binary frames
//  use, resolves each device's friendly name (the board's own name where the
//  firmware stores one, else the hub-stored name), tracks online/offline/
//  updating state with a grace period, and emits device.added / removed /
//  changed events.  Pure logic; the hub feeds it.  See spec 7.4 and
//  device_name_spec.md section 5.
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
            let name = resolveName(info)
            let wasChanged = existing.info != info || existing.state != .online || existing.name != name
            existing.info = info
            existing.name = name
            existing.state = .online
            bySerial[info.serial] = existing
            lock.unlock()
            if wasChanged { emit(.changed(existing)) }
            return existing
        }
        let handle = allocateHandle()
        let device = RegisteredDevice(handle: handle, info: info, name: resolveName(info),
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

    /// The board stored a name (NOTIFY_EVT_DEVICE_NAME).  On name-capable
    /// firmware this is the only writer of the registry name, and it retires
    /// the hub-stored entry so a later clear is never undone by adoption.
    func boardNameStored(serial: String, name: String) {
        lock.lock()
        guard var d = bySerial[serial] else { lock.unlock(); return }
        names.removeName(forSerial: serial)
        d.info.boardName = name
        let resolved = name.isEmpty ? Self.defaultName(d.info) : name
        let changed = d.name != resolved
        d.name = resolved
        bySerial[serial] = d
        lock.unlock()
        if changed { emit(.changed(d)) }
    }

    /// The board accepted the adoption write, so the stored entry is done with.
    func adoptionAccepted(serial: String) {
        names.removeName(forSerial: serial)
    }

    /// The hub-stored name to write to a name-capable board that reports none,
    /// once (spec section 5); nil when there is nothing to adopt.
    func adoptionName(for info: HubDeviceInfo) -> String? {
        guard info.boardName == "", let stored = names.name(forSerial: info.serial) else { return nil }
        let ascii = DSPViewModel.sanitizeInputSourceName(stored)
        return ascii.isEmpty ? nil : ascii
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

    /// Board name when set, else the hub-stored name, else the default.  A
    /// non-empty board name retires the stored entry.  Called under `lock`.
    private func resolveName(_ info: HubDeviceInfo) -> String {
        if let board = info.boardName, !board.isEmpty {
            names.removeName(forSerial: info.serial)
            return board
        }
        return names.name(forSerial: info.serial) ?? Self.defaultName(info)
    }

    private static func defaultName(_ info: HubDeviceInfo) -> String {
        "DSPi " + String(info.serial.suffix(6))
    }
}

/// Persists hub-side friendly names by serial in UserDefaults.  Only boards
/// whose firmware cannot store a name rely on it; for the rest an entry is
/// held just until it has been adopted onto the board.
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

    func removeName(forSerial serial: String) {
        guard var map = defaults.dictionary(forKey: key) as? [String: String],
              map.removeValue(forKey: serial) != nil else { return }
        defaults.set(map, forKey: key)
    }
}
