//
//  HubTransport.swift
//  DSPi Console
//
//  A DeviceTransport backed by a LinkHub session, so the local Console UI
//  drives its device as an ordinary hub session, the same path a remote client
//  uses.  Commands go through the hub's router; "connected" means the hub has
//  a router for the device, not merely that USB opened it; device lists and
//  selection still mirror USBDevice, since the hub shares that one device.
//  See networking_plan.md Phase 1.
//

import Foundation
import Combine

final class HubTransport: DeviceTransport {
    private let hub: LinkHub
    private let usb: USBDevice
    private let localSession: LinkHubSession
    private let notifyFanout = NotificationFanout()

    /// The local UI is always session 1.
    var session: LinkSessionID { localSession.id }
    var generation: UInt64 { usb.generation }

    init(hub: LinkHub, usb: USBDevice) {
        self.hub = hub
        self.usb = usb
        self.localSession = hub.openSession(role: .admin, id: LinkHub.localSessionID)

        // Every relayed notification arrives with the hub's session attribution
        // and is re-published on this transport's fanout for the view model
        // and the monitor window.
        localSession.onNotify = { [weak self] frame in
            self?.notifyFanout.publish(LinkNotification(packet: frame.packet,
                                                        origin: frame.origin,
                                                        receivedAt: Date()))
        }
        // A RESYNC means the relay dropped frames for us, or the device came
        // back.  The view model already re-reads everything on
        // BULK_INVALIDATED, so a synthetic one is the whole recovery.
        localSession.onResync = { [weak self] _ in
            self?.notifyFanout.publish(LinkNotification(packet: Self.syntheticBulkInvalidated,
                                                        origin: 0, receivedAt: Date()))
        }
    }

    /// v2 BULK_INVALIDATED with source UNKNOWN (0): version, event, flags, seq,
    /// source, reserved x3.
    private static let syntheticBulkInvalidated = Data([0x02, 0x03, 0, 0, 0, 0, 0, 0])

    // MARK: - Connection state

    var isConnected: Bool { hub.isDeviceAttached }
    var isConnectedPublisher: AnyPublisher<Bool, Never> { hub.isDeviceAttachedPublisher }

    var availableDevices: [DSPiDevice] { usb.availableDevices }
    var availableDevicesPublisher: AnyPublisher<[DSPiDevice], Never> { usb.availableDevicesPublisher }
    var selectedDevice: DSPiDevice? { usb.selectedDevice }
    var selectedDevicePublisher: AnyPublisher<DSPiDevice?, Never> { usb.selectedDevicePublisher }
    var errorMessage: String? { usb.errorMessage }
    var errorMessagePublisher: AnyPublisher<String?, Never> { usb.errorMessagePublisher }

    func selectDevice(_ device: DSPiDevice) { usb.selectDevice(device) }
    func reconnect() { usb.reconnect() }
    func disconnect() { usb.disconnect() }
    func markDisconnected() { usb.markDisconnected() }

    // MARK: - Transfers, through the hub router

    func sendControlRequest(request: UInt8, value: UInt16, index: UInt16, data: Data) {
        let req = LinkCmdRequest(tag: 0, handle: hub.currentHandle, direction: .set,
                                 bRequest: request, wValue: value, wIndex: index, payload: data)
        hub.submit(req, from: localSession.id) { _ in }
    }

    func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16)
        -> Result<Data, LinkStatus> {
        let req = LinkCmdRequest(tag: 0, handle: hub.currentHandle, direction: .get,
                                 bRequest: request, wValue: value, wIndex: index, wLength: length)
        // The command layer calls this synchronously off the main thread and
        // expects the bytes back, so block on the hub's completion.  The router
        // always completes exactly once, and runs the device call on its own
        // queues, so this cannot deadlock against itself.
        let sem = DispatchSemaphore(value: 0)
        var out: Result<Data, LinkStatus> = .failure(.timeout)
        hub.submit(req, from: localSession.id) { response in
            out = response.status == .ok ? .success(response.payload) : .failure(response.status)
            sem.signal()
        }
        sem.wait()
        return out
    }

    func addNotificationObserver(_ handler: @escaping (LinkNotification) -> Void) -> AnyCancellable {
        notifyFanout.add(handler)
    }
}
