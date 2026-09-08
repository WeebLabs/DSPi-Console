//
//  HubTransport.swift
//  DSPi Console
//
//  A DeviceTransport backed by a LinkHub session, so the local Console UI
//  drives its device as an ordinary hub session, the same path a remote client
//  will use.  For the one local device it forwards commands straight to the
//  hub's router and mirrors USBDevice's connection and device-list state, so
//  the view model sees no behavioural change.  See networking_plan.md Phase 1.
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
    var isConnected: Bool { usb.isConnected }

    init(hub: LinkHub, usb: USBDevice) {
        self.hub = hub
        self.usb = usb
        self.localSession = hub.openSession(role: .admin, id: 1)
        // The local UI receives every relayed notification through the hub,
        // carrying the hub's session attribution, and re-publishes it on its
        // own fanout for the view model and the monitor window.
        localSession.onNotify = { [weak self] frame in
            self?.notifyFanout.publish(LinkNotification(packet: frame.packet,
                                                        origin: frame.origin,
                                                        receivedAt: Date()))
        }
    }

    // Connection and device-list state stay sourced from USBDevice: the hub
    // shares its one device, so the picker and status dot read the same values
    // they always did.  Phase 5 merges remote devices into these lists.
    var isConnectedPublisher: AnyPublisher<Bool, Never> { usb.isConnectedPublisher }
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
        let req = LinkCmdRequest(tag: 0, handle: LinkHub.localHandle, direction: .set,
                                 bRequest: request, wValue: value, wIndex: index, payload: data)
        hub.submit(req, from: localSession.id) { _ in }
    }

    func getControlResult(request: UInt8, value: UInt16, index: UInt16, length: UInt16)
        -> Result<Data, LinkStatus> {
        let req = LinkCmdRequest(tag: 0, handle: LinkHub.localHandle, direction: .get,
                                 bRequest: request, wValue: value, wIndex: index, wLength: length)
        // The command layer calls this synchronously off the main thread and
        // expects the bytes back, so block on the hub's async completion.  The
        // router runs on the device's serial queue, never this thread, so
        // there is no self-deadlock.
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
