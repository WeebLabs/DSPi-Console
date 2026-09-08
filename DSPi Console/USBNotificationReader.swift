//
//  USBNotificationReader.swift
//  DSPi Console
//
//  Reads notification packets from the device's bulk IN endpoint (EP 0x83 on
//  the vendor interface) and publishes them through the owning USBDevice's
//  NotificationFanout.  This used to live inside InterruptMonitor; it moved
//  here so the notification stream belongs to the transport, where the view
//  model, the monitor window and (later) the DSPi Link hub all subscribe to
//  the same one.  See notification_protocol_v2_spec.md in the firmware repo.
//

import Foundation
import IOKit
import IOKit.usb

/// EP 0x83 max packet size.  IOKit reports the actual size of each read.
private let NOTIFY_EP_MAX_PKT: UInt32 = 64
private let NOTIFY_EP_ADDRESS: UInt8 = 0x83
private let NOTIFY_EVT_IDLE: UInt8 = 0x00
private let NOTIFY_V2_VERSION: UInt8 = 0x02
private let NOTIFY_EVT_PARAM_CHANGED: UInt8 = 0x02
private let NOTIFY_EVT_BULK_INVALIDATED: UInt8 = 0x03
private let NOTIFY_EVT_CS_AUX: UInt8 = 0x0C
private let PARAM_SRC_HOST_SET: UInt8 = 1
private let PARAM_SRC_BULK_SET: UInt8 = 2

final class USBNotificationReader {
    /// One reader session per start().  The session owns its vendor-interface
    /// handle and cancellation flag, so a superseded reader (device switch,
    /// stop/start cycle) winds down on its own without touching the current
    /// session's handle.
    private final class ReaderSession {
        let interface: USBDevice.InterfaceInterfacePtr
        let pipeRef: UInt8
        let generation: UInt64
        var thread: Thread?
        // Written by stop(), read on the reader thread.  Swift Bool reads are
        // effectively atomic on the supported archs.
        var cancelled = false

        // Serializes interface teardown against stop()'s AbortPipe: on unplug
        // the reader can see a device-gone read error and Release the handle
        // on its own thread at the same moment the termination path calls
        // stop().  Abort and close must never overlap or run after Release.
        private let interfaceLock = NSLock()
        private var interfaceClosed = false

        init(interface: USBDevice.InterfaceInterfacePtr, pipeRef: UInt8, generation: UInt64) {
            self.interface = interface
            self.pipeRef = pipeRef
            self.generation = generation
        }

        func abortPipe() {
            interfaceLock.lock()
            defer { interfaceLock.unlock() }
            guard !interfaceClosed else { return }
            _ = interface.pointee!.pointee.AbortPipe(interface, pipeRef)
        }

        func closeInterface() {
            interfaceLock.lock()
            defer { interfaceLock.unlock() }
            guard !interfaceClosed else { return }
            interfaceClosed = true
            _ = interface.pointee!.pointee.USBInterfaceClose(interface)
            _ = interface.pointee!.pointee.Release(interface)
        }
    }

    private unowned let usb: USBDevice
    private let fanout: NotificationFanout
    private let sessionLock = NSLock()
    private var currentSession: ReaderSession?

    /// True while a reader thread is attached to the current device.
    private(set) var isActive = false
    /// Why the last start() failed, for the monitor window.
    private(set) var lastError: String?

    /// Delays between attempts to claim the vendor interface.  Interfaces are
    /// published a little after the device itself, so a start() issued the
    /// instant we connect (especially on the re-enumeration after a firmware
    /// flash) can find nothing to open.
    private static let interfaceRetryDelays: [TimeInterval] = [0.1, 0.2, 0.4, 0.8]

    init(usb: USBDevice, fanout: NotificationFanout) {
        self.usb = usb
        self.fanout = fanout
    }

    // MARK: - Lifecycle (any thread except serialQueue; opening the interface
    // takes serialQueue.sync)

    func start() { start(attempt: 0) }

    private func start(attempt: Int) {
        // Always (re)attach to the currently open device: a switch to another
        // device never publishes isConnected == false, so the reader must
        // follow every successful open, not just the first.
        stop()
        lastError = nil

        let generation = usb.generation
        guard let interface = usb.openVendorInterface() else {
            if attempt < Self.interfaceRetryDelays.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.interfaceRetryDelays[attempt]) { [weak self] in
                    guard let self = self, self.usb.generation == generation else { return }
                    self.sessionLock.lock()
                    let idle = self.currentSession == nil
                    self.sessionLock.unlock()
                    if idle { self.start(attempt: attempt + 1) }
                }
                return
            }
            lastError = "Could not open vendor interface (is the device connected?)"
            return
        }

        guard let pipeRef = Self.findPipeRef(interface: interface, epAddress: NOTIFY_EP_ADDRESS) else {
            lastError = "Notification EP 0x83 not found on vendor interface"
            _ = interface.pointee!.pointee.USBInterfaceClose(interface)
            _ = interface.pointee!.pointee.Release(interface)
            return
        }

        let session = ReaderSession(interface: interface, pipeRef: pipeRef, generation: generation)
        sessionLock.lock()
        currentSession = session
        isActive = true
        sessionLock.unlock()

        let thread = Thread { [weak self] in
            self?.runReadLoop(session: session)
        }
        thread.name = "DSPi Notification Reader"
        thread.qualityOfService = .userInitiated
        session.thread = thread
        thread.start()
    }

    func stop() {
        sessionLock.lock()
        guard let session = currentSession else { sessionLock.unlock(); return }
        currentSession = nil
        isActive = false
        sessionLock.unlock()

        session.cancelled = true
        // Wake the reader out of its (up to 500 ms) blocking read so its
        // interface handle closes promptly, then give it a brief moment to
        // finish: an immediate follow-up start() on the same device would
        // otherwise race the old handle's close and fail with exclusive access.
        session.abortPipe()
        if let thread = session.thread {
            let deadline = Date().addingTimeInterval(0.1)
            while !thread.isFinished && Date() < deadline {
                usleep(2000)
            }
        }
    }

    // MARK: - Read loop (reader thread)

    private func runReadLoop(session: ReaderSession) {
        let interface = session.interface
        let pipeRef = session.pipeRef
        var buffer = [UInt8](repeating: 0, count: Int(NOTIFY_EP_MAX_PKT))

        while !session.cancelled {
            var size: UInt32 = NOTIFY_EP_MAX_PKT
            // ReadPipeTO timeouts are in milliseconds.
            let result = buffer.withUnsafeMutableBufferPointer { bufPtr -> IOReturn in
                interface.pointee!.pointee.ReadPipeTO(
                    interface, pipeRef, bufPtr.baseAddress, &size,
                    /* noDataTimeout */ 500, /* completionTimeout */ 500)
            }

            if session.cancelled { break }

            switch result {
            case kIOReturnSuccess:
                if size == 0 { continue }
                deliver(Array(buffer.prefix(Int(size))), session: session)
            case kIOReturnTimeout:
                continue
            case kIOReturnAborted, kIOReturnNotResponding, kIOReturnNoDevice:
                session.cancelled = true
            default:
                // Recoverable stall: clear and continue.
                _ = interface.pointee!.pointee.ClearPipeStall(interface, pipeRef)
            }
        }

        session.closeInterface()
        sessionLock.lock()
        if currentSession === session {
            // Only the current session may report itself stopped; a
            // superseded reader must not clobber its replacement's state.
            currentSession = nil
            isActive = false
        }
        sessionLock.unlock()
    }

    /// Publish one packet.  Idle keep-alives (single-byte 0x00) arrive after
    /// 100 ms without an event, only to keep the pipe active, and are
    /// dropped; v1 packets are dropped too,
    /// since every v1 event has a v2 twin.  A packet read from a superseded
    /// session (device switched underneath it) is dropped, because it
    /// describes a device the app is no longer showing.
    private func deliver(_ bytes: [UInt8], session: ReaderSession) {
        if bytes.count == 1 && bytes[0] == NOTIFY_EVT_IDLE { return }
        guard bytes.first == NOTIFY_V2_VERSION else { return }
        guard usb.generation == session.generation else { return }

        let packet = Data(bytes)
        fanout.publish(LinkNotification(packet: packet,
                                        origin: Self.attributedOrigin(packet, session: usb.session),
                                        receivedAt: Date()))
    }

    /// On USB this app is the only host, so a change the firmware tags as a
    /// host or bulk write can only have been ours.  Everything else (GPIO,
    /// preset, UAC1, UART, I2C, internal) belongs to someone else.
    static func attributedOrigin(_ packet: Data, session: LinkSessionID) -> LinkSessionID {
        guard packet.count >= 5 else { return 0 }
        let sourceOffset: Int
        switch packet[packet.startIndex + 1] {
        case NOTIFY_EVT_PARAM_CHANGED, NOTIFY_EVT_CS_AUX: sourceOffset = 8
        case NOTIFY_EVT_BULK_INVALIDATED: sourceOffset = 4
        default: return 0
        }
        guard packet.count > sourceOffset else { return 0 }
        let source = packet[packet.startIndex + sourceOffset]
        return (source == PARAM_SRC_HOST_SET || source == PARAM_SRC_BULK_SET) ? session : 0
    }

    // MARK: - Interface helpers

    private static func findPipeRef(interface: USBDevice.InterfaceInterfacePtr, epAddress: UInt8) -> UInt8? {
        var numEndpoints: UInt8 = 0
        let res = interface.pointee!.pointee.GetNumEndpoints(interface, &numEndpoints)
        guard res == kIOReturnSuccess, numEndpoints > 0 else { return nil }

        // Pipe 0 is control; real pipes are 1..numEndpoints.
        for pipeRef in 1...numEndpoints {
            var direction: UInt8 = 0
            var number: UInt8 = 0
            var transferType: UInt8 = 0
            var maxPacketSize: UInt16 = 0
            var interval: UInt8 = 0
            let r = interface.pointee!.pointee.GetPipeProperties(
                interface, pipeRef, &direction, &number, &transferType, &maxPacketSize, &interval)
            if r != kIOReturnSuccess { continue }
            // direction 1 = IN; transferType 2 = bulk, 3 = interrupt.  The
            // device moved from interrupt to bulk after a DCD crash on
            // RP2040/2350; accept either.
            if direction == 1 && number == (epAddress & 0x7F) && (transferType == 2 || transferType == 3) {
                return pipeRef
            }
        }
        return nil
    }
}
