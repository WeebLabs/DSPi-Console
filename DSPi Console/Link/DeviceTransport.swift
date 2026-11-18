//
//  DeviceTransport.swift
//  DSPi Console
//
//  The seam between the application and whatever carries its vendor
//  commands to a DSPi: the USB device driver today, an in-process DSPi Link
//  hub session or a WebSocket to a remote hub later.  DSPViewModel and the
//  tool windows talk only to this protocol.  See
//  Documentation/dspi_link_protocol_spec.md and networking_plan.md.
//

import Foundation
import Combine

/// Identifies one DSPi Link session on a hub.  Notifications carry the
/// session the hub attributes a change to, so a client can drop the echo of
/// its own writes and apply everyone else's.  0 means "unknown".
typealias LinkSessionID = UInt16

/// Status of one tunnelled command.  0x00..0x07 are the firmware's
/// CTRL_STATUS_* codes and must never diverge from them; 0x80 and above are
/// Link-level (spec section 8.1).  0x10..0x1A are the paged protocol's
/// VC_ERR_* result codes (client update guide, section 4).  `.error` is a
/// refusal whose reason is unknown, which 1.1.7 itself never reports.
enum LinkStatus: UInt8, Error, Equatable {
    case ok          = 0x00
    case busy        = 0x01
    case error       = 0x02
    case blocked     = 0x03
    case bulkLocked  = 0x04
    case crcError    = 0x05
    case oversize    = 0x06
    case frameError  = 0x07
    case vcUnknown     = 0x10   // no such page or command on this build
    case vcDirection   = 0x11   // the command has no GET, or no SET
    case vcLength      = 0x12   // wrong SET payload length
    case vcAddress     = 0x13   // wValue out of range
    case vcValue       = 0x14   // payload value out of range, or NaN
    case vcUnsupported = 0x15   // a valid value this platform cannot do
    case vcBlocked     = 0x16   // not allowed on this transport
    case vcBusy        = 0x17   // try again shortly
    case vcState       = 0x18   // not allowed in the current state
    case vcPinInvalid  = 0x19   // the GPIO cannot be used for this function
    case vcPinInUse    = 0x1A   // the GPIO is already claimed
    case noDevice    = 0x80
    case denied      = 0x81
    case timeout     = 0x82
    case tooLarge    = 0x83
    case rateLimited = 0x84
    case locked      = 0x85
    case unsupported = 0x86
    case badFrame    = 0x87

    /// Text for a user, for the statuses a user can act on.  LOCKED is the
    /// one shared wording for "another session holds the device".
    var userMessage: String? {
        switch self {
        case .locked: return DeviceLock.lockedMessage
        default: return nil
        }
    }

    /// True for the statuses a caller should simply retry after a short wait.
    var isRetryable: Bool {
        switch self {
        case .busy, .bulkLocked, .crcError, .timeout, .rateLimited, .vcBusy: return true
        default: return false
        }
    }

    /// A paged-protocol result code from the device.
    var isVendorResult: Bool { (0x10...0x1A).contains(rawValue) }

    /// A status from a Link frame.  0x08..0x7F belong to the firmware and are
    /// forwarded verbatim (spec 1.3, section 8.1); one this build does not
    /// name is still a refusal, so it reads as `.error` (refused, reason
    /// unknown) rather than failing the frame.  nil only outside that range.
    init?(decoding raw: UInt8) {
        if let known = LinkStatus(rawValue: raw) { self = known; return }
        guard (0x08...0x7F).contains(raw) else { return nil }
        self = .error
    }
}

/// One notification packet from a device, as the transport delivered it.
/// `packet` is the verbatim v2 packet (byte 0 = 0x02); v1 packets and idle
/// keep-alives are never delivered.
struct LinkNotification {
    let packet: Data
    /// Session the change is attributed to, or 0 when unknown.  A transport
    /// that is the only host on its link (USB) attributes every HOST_SET and
    /// BULK_SET packet to its own session, since nobody else could have
    /// written it; the hub refines this per session later.
    let origin: LinkSessionID
    let receivedAt: Date

    var version: UInt8 { packet.first ?? 0 }
    var eventID: UInt8 { packet.count > 1 ? packet[packet.startIndex + 1] : 0 }
    /// ParamSource byte of a PARAM_CHANGED packet, or nil for other events.
    var paramSource: UInt8? {
        guard eventID == 0x02, packet.count >= 9 else { return nil }
        return packet[packet.startIndex + 8]
    }

    /// True when the firmware tags the change as a host or bulk write
    /// (PARAM_SRC_HOST_SET 1, PARAM_SRC_BULK_SET 2), which is the only kind a
    /// hub can attribute to one of its sessions.  Reads the source byte where
    /// each event puts it: PARAM_CHANGED and CS_AUX at 8, BULK_INVALIDATED at
    /// 4, RTA_CONFIG at 16, the two name events at 5.
    var isHostSourced: Bool {
        let offset: Int
        switch eventID {
        case 0x02, 0x0C: offset = 8
        case 0x03: offset = 4
        case NOTIFY_EVT_RTA_CONFIG: offset = 16
        case NOTIFY_EVT_INPUT_SOURCE_NAME, NOTIFY_EVT_DEVICE_NAME: offset = 5
        default: return false
        }
        guard packet.count > offset else { return false }
        let source = packet[packet.startIndex + offset]
        return source == 1 || source == 2
    }
}

/// Fans one notification stream out to any number of observers on the main
/// thread.  Observers hold the returned cancellable; dropping it unsubscribes.
final class NotificationFanout {
    private var handlers: [UUID: (LinkNotification) -> Void] = [:]
    private let lock = NSLock()

    func add(_ handler: @escaping (LinkNotification) -> Void) -> AnyCancellable {
        let id = UUID()
        lock.lock(); handlers[id] = handler; lock.unlock()
        return AnyCancellable { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); self.handlers.removeValue(forKey: id); self.lock.unlock()
        }
    }

    /// Deliver on the main thread, in registration-independent order.
    func publish(_ notification: LinkNotification) {
        lock.lock(); let snapshot = Array(handlers.values); lock.unlock()
        guard !snapshot.isEmpty else { return }
        if Thread.isMainThread {
            snapshot.forEach { $0(notification) }
        } else {
            DispatchQueue.main.async { snapshot.forEach { $0(notification) } }
        }
    }

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return handlers.isEmpty }
}

/// What the application needs from a link to a DSPi.  The two transfer calls
/// keep the exact shapes the command layer already uses; everything else is
/// the connection and device-selection state the view model observes.
protocol DeviceTransport: AnyObject {
    /// This transport's own session id, for echo suppression.
    var session: LinkSessionID { get }

    /// Bumps whenever the underlying device connection is replaced, so work
    /// queued for one device is not delivered to the next (existing pattern).
    var generation: UInt64 { get }

    var isConnected: Bool { get }
    var isConnectedPublisher: AnyPublisher<Bool, Never> { get }

    var availableDevices: [DSPiDevice] { get }
    var availableDevicesPublisher: AnyPublisher<[DSPiDevice], Never> { get }

    var selectedDevice: DSPiDevice? { get }
    var selectedDevicePublisher: AnyPublisher<DSPiDevice?, Never> { get }

    var errorMessage: String? { get }
    var errorMessagePublisher: AnyPublisher<String?, Never> { get }

    func selectDevice(_ device: DSPiDevice)
    func reconnect()
    func disconnect()

    /// Declare the link dead from the caller's side (a bulk read that failed
    /// outright).  Replaces writing `isConnected = false` on the USB object.
    func markDisconnected()

    /// Fire-and-forget SET (host to device).
    func sendControlRequest(request: UInt8, value: UInt16, index: UInt16, data: Data)

    /// Blocking GET (device to host).  nil on any failure; use
    /// `getControlResult` when the failure kind matters.
    func getControlRequest(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Data?

    /// Blocking GET that reports why it failed.
    func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Result<Data, LinkStatus>

    /// SET that reports its outcome without blocking the caller.  `completion`
    /// runs once, on an arbitrary queue.  `.ok` means the device accepted the
    /// write, which for a deferred command means queued, not applied.
    func sendControlResult(request: UInt8, value: UInt16, index: UInt16, data: Data,
                           completion: @escaping (LinkStatus) -> Void)

    /// Send the old 1.1.6 ENTER_BOOTLOADER to a board on this transport that
    /// was classified legacy, the only way to update it without BOOTSEL.
    /// `.unsupported` when there is no such board or it is not local.
    func enterLegacyBootloader() -> LinkStatus

    /// Whether the connected board implements `command` (SYS.PAGE_COMMANDS);
    /// nil when not known, as for a remote board.
    func implements(_ command: VendorCommand, set: Bool) -> Bool?

    /// The connected board's vendor protocol generation.
    var deviceProtocol: DeviceProtocolState { get }
    var deviceProtocolPublisher: AnyPublisher<DeviceProtocolState, Never> { get }

    /// Subscribe to the device's notification stream.  Delivered on the main
    /// thread.  Drop the cancellable to unsubscribe.
    func addNotificationObserver(_ handler: @escaping (LinkNotification) -> Void) -> AnyCancellable

    /// Take the hub's exclusive device lock (spec 7.7) so other sessions'
    /// commands answer LOCKED until `releaseDeviceLock`.  Blocking; call off
    /// the main thread.  False when another session holds it.  The release
    /// never blocks.
    func acquireDeviceLock(reason: String, timeout: TimeInterval) -> Bool
    func releaseDeviceLock()
}

/// A write the device turned down.
struct VendorRefusal: Equatable {
    let command: VendorCommand
    let value: UInt16
    let status: LinkStatus

    /// Worth telling the user: the device itself said no.  Not a lost link, a
    /// lock (which has its own notice), the phase-3 refusal of paged requests
    /// to remote hubs, or VC_ERR_BUSY, which is a retry matter.
    var isReportable: Bool { status == .error || (status.isVendorResult && status != .vcBusy) }

    /// Plain words for the reason.
    var reason: String {
        switch status {
        case .vcValue: return "value out of range"
        case .vcState: return "not allowed in the current state"
        case .vcUnsupported: return "not supported on this board"
        case .vcAddress: return "no such channel, output or slot"
        case .vcUnknown: return "not supported by this firmware"
        case .vcLength, .vcDirection: return "malformed request"
        case .vcBlocked: return "not allowed over this connection"
        case .vcPinInvalid: return "that pin cannot be used for this"
        case .vcPinInUse: return "that pin is already in use"
        case .vcBusy: return "the device was busy"
        default: return "reason unknown"
        }
    }
}

/// Shows the latest refused write for a few seconds, next to the lock notice,
/// and publishes each one so the view model can re-read the device.
final class DeviceRefusalNotice: ObservableObject {
    @Published private(set) var message: String?
    @Published private(set) var detail: String?
    let refusals = PassthroughSubject<VendorRefusal, Never>()
    private var clearWork: DispatchWorkItem?

    func post(_ refusal: VendorRefusal) {
        guard refusal.status != .ok else { return }
        guard refusal.isReportable else {
            if refusal.status == .vcBusy {
                print("[VENDOR] \(refusal.command) wValue \(refusal.value) dropped: device busy")
            }
            return
        }
        print("[VENDOR] \(refusal.command) wValue \(refusal.value) refused: \(refusal.reason)")
        DispatchQueue.main.async {
            self.message = "Device refused a change: \(refusal.reason)"
            self.detail = "\(refusal.command) (wValue \(refusal.value)): \(refusal.reason)"
            self.refusals.send(refusal)
            self.clearWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.message = nil; self?.detail = nil }
            self.clearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }
}

enum DeviceRefusal {
    static let notice = DeviceRefusalNotice()
}

/// Carries a status from a completion that may land after a timed-out wait.
final class StatusBox {
    private var value: LinkStatus?
    private let lock = NSLock()
    func set(_ v: LinkStatus) { lock.lock(); if value == nil { value = v }; lock.unlock() }
    func get() -> LinkStatus? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Shared wording and limits for the device lock.
enum DeviceLock {
    static let lockedMessage = "Another console is applying changes"
    /// Hubs cap a lock at 60 s (spec 7.7).
    static let maxTimeout: TimeInterval = 60

    /// Most recent LOCKED rejection of an ordinary command, for the status
    /// row.  Posted by the transports, so no command needs its own error path.
    static let notice = DeviceLockNotice()
}

/// Briefly shows that a command was refused because another session holds
/// the lock.  Clears itself a few seconds after the last refusal.
final class DeviceLockNotice: ObservableObject {
    @Published private(set) var message: String?
    private var clearWork: DispatchWorkItem?

    func post() {
        DispatchQueue.main.async {
            self.message = DeviceLock.lockedMessage
            self.clearWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.message = nil }
            self.clearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }
}

extension DeviceTransport {
    /// True when a notification's origin names this transport's own session,
    /// so the change is the echo of a write already applied locally.  Origin
    /// 0 is "unattributed" (a knob turn, the OS volume slider, a hub that did
    /// not tell us our id) and is never ours, even while our own session id
    /// is still 0.
    func isOwnWrite(origin: LinkSessionID) -> Bool {
        origin != 0 && origin == session
    }

    func getControlRequest(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Data? {
        if case .success(let data) = getControlResult(request: request, value: value, index: index, length: length) {
            return data
        }
        return nil
    }

    // MARK: Paged commands

    /// GET a paged command.  `value` is the command's address, 0 for none.
    func get(_ command: VendorCommand, value: UInt16 = 0, length: UInt16) -> Result<Data, LinkStatus> {
        if let refusal = Self.localRefusal(command, isGet: true, payload: nil) { return .failure(refusal) }
        // A command this build lacks: answer as the board would, without
        // spending a transfer on it.
        if implements(command, set: false) == false { return .failure(.vcUnknown) }
        return getControlResult(request: command.number, value: value, index: command.usbIndex, length: length)
    }

    /// GET a paged command, nil on any failure.
    func getData(_ command: VendorCommand, value: UInt16 = 0, length: UInt16) -> Data? {
        if case .success(let data) = get(command, value: value, length: length) { return data }
        return nil
    }

    /// SET of a paged command that does not wait for the device, for live
    /// drags and for writes the UI has already shown.  1.1.6 accepted most bad
    /// writes silently; 1.1.7 refuses them, so a refusal is still reported, to
    /// `DeviceRefusal.notice`, which tells the user and lets the view model
    /// re-read what the device really holds.  Use `set` to handle it yourself.
    func send(_ command: VendorCommand, value: UInt16 = 0, data: Data = Data()) {
        if let refusal = Self.localRefusal(command, isGet: false, payload: data) {
            DeviceRefusal.notice.post(VendorRefusal(command: command, value: value, status: refusal))
            return
        }
        sendControlResult(request: command.number, value: value, index: command.usbIndex,
                          data: data) { status in
            DeviceRefusal.notice.post(VendorRefusal(command: command, value: value, status: status))
        }
    }

    /// SET of a paged command that reports the outcome.  `completion` runs on
    /// an arbitrary queue.
    func set(_ command: VendorCommand, value: UInt16 = 0, data: Data = Data(),
             completion: @escaping (LinkStatus) -> Void) {
        if let refusal = Self.localRefusal(command, isGet: false, payload: data) {
            completion(refusal)
            return
        }
        sendControlResult(request: command.number, value: value, index: command.usbIndex,
                          data: data, completion: completion)
    }

    /// Blocking form of `set`, for flows that need the verdict before going
    /// on (flash saves, preset flows, pin changes).  Blocks like a GET does, so
    /// prefer calling it off the main thread.
    func setAndWait(_ command: VendorCommand, value: UInt16 = 0, data: Data = Data(),
                    timeout: TimeInterval = 10) -> LinkStatus {
        let box = StatusBox()
        if Thread.isMainThread {
            // A transport may complete on the main queue (NetworkTransport
            // does), so a semaphore here would wait out the timeout instead.
            set(command, value: value, data: data) { box.set($0) }
            let deadline = Date().addingTimeInterval(timeout)
            while box.get() == nil, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return box.get() ?? .timeout
        }
        let sem = DispatchSemaphore(value: 0)
        set(command, value: value, data: data) { box.set($0); sem.signal() }
        guard sem.wait(timeout: .now() + timeout) == .success else { return .timeout }
        return box.get() ?? .timeout
    }

    /// Refuse locally what the registry says the device would refuse, so a
    /// mistake in the app never costs a bus round trip or a flash-busy wait.
    static func localRefusal(_ command: VendorCommand, isGet: Bool, payload: Data?) -> LinkStatus? {
        guard let info = VendorCommandRegistry.info(for: command) else { return .vcUnknown }
        if isGet { return info.hasGet ? nil : .vcDirection }
        guard info.hasSet else { return .vcDirection }
        let count = payload?.count ?? 0
        guard count >= info.setMin, count <= info.setMax else { return .vcLength }
        return nil
    }

    /// Only a local USB board can be updated from its legacy state (decision 2
    /// of the paged-protocol port plan); remote transports and fakes refuse.
    func enterLegacyBootloader() -> LinkStatus { .unsupported }

    func implements(_ command: VendorCommand, set: Bool) -> Bool? { nil }

    func implements(_ command: VendorCommand) -> Bool? { implements(command, set: false) }

    /// With no hub there is nobody to lock out (USB, test fakes).
    func acquireDeviceLock(reason: String, timeout: TimeInterval) -> Bool { true }
    func releaseDeviceLock() {}

    /// Run `body` holding the device lock, released on every exit.  nil, with
    /// `body` never run, when another session holds the lock.
    func withDeviceLock<T>(reason: String, timeout: TimeInterval, _ body: () throws -> T) rethrows -> T? {
        guard acquireDeviceLock(reason: reason, timeout: timeout) else { return nil }
        defer { releaseDeviceLock() }
        return try body()
    }
}
