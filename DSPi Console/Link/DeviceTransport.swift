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
/// Link-level (spec section 8.1).
enum LinkStatus: UInt8, Error, Equatable {
    case ok          = 0x00
    case busy        = 0x01
    case error       = 0x02
    case blocked     = 0x03
    case bulkLocked  = 0x04
    case crcError    = 0x05
    case oversize    = 0x06
    case frameError  = 0x07
    case noDevice    = 0x80
    case denied      = 0x81
    case timeout     = 0x82
    case tooLarge    = 0x83
    case rateLimited = 0x84
    case locked      = 0x85
    case unsupported = 0x86
    case badFrame    = 0x87

    /// True for the statuses a caller should simply retry after a short wait.
    var isRetryable: Bool {
        switch self {
        case .busy, .bulkLocked, .crcError, .timeout, .rateLimited: return true
        default: return false
        }
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
    /// each event puts it: PARAM_CHANGED and CS_AUX at 8, BULK_INVALIDATED at 4.
    var isHostSourced: Bool {
        let offset: Int
        switch eventID {
        case 0x02, 0x0C: offset = 8
        case 0x03: offset = 4
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

    /// Subscribe to the device's notification stream.  Delivered on the main
    /// thread.  Drop the cancellable to unsubscribe.
    func addNotificationObserver(_ handler: @escaping (LinkNotification) -> Void) -> AnyCancellable
}

extension DeviceTransport {
    func getControlRequest(request: UInt8, value: UInt16, index: UInt16, length: UInt16) -> Data? {
        if case .success(let data) = getControlResult(request: request, value: value, index: index, length: length) {
            return data
        }
        return nil
    }
}
