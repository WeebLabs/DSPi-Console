//
//  HubDevice.swift
//  DSPi Console
//
//  The hub's view of one attached DSPi: how a command is executed against it
//  and how its identity reads.  A real device is a DeviceTransport (USBDevice);
//  tests inject a fake.  The router talks only to this, so nothing hub-side
//  depends on IOKit.  See networking_plan.md Phase 2.
//

import Foundation

/// Identity the hub publishes for a device (spec 7.4 `device.list`).
struct HubDeviceInfo: Equatable {
    var serial: String
    var platform: UInt8          // 0 RP2040, 1 RP2350, 2 STM32
    var firmware: String         // "1.1.7"
    var outputs: Int
    var inputs: Int?
    var wireVersion: Int?
    var link: LinkDeviceLink     // usb or uart
}

enum LinkDeviceLink: String, Codable, Equatable { case usb, uart }

/// One device the hub can drive.  Execution is synchronous and blocking; the
/// router calls it from that device's own serial queue, never the main thread.
protocol HubDevice: AnyObject {
    var info: HubDeviceInfo { get }
    /// Bumps when the underlying connection is replaced, so a result computed
    /// for one attachment is not attributed to the next.
    var generation: UInt64 { get }
    var isConnected: Bool { get }

    /// Run one vendor request and return the Link result.  A SET returns an
    /// empty payload on success; a GET returns the device's bytes.
    func execute(_ request: LinkCmdRequest) -> LinkCmdResponse
}
