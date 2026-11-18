import XCTest
@testable import DSPi_Console

/// The probe that tells a 1.1.7 board from a 1.1.6 one, the gate that keeps
/// paged requests off a board until the probe has run, and the pieces around
/// them.  A 1.1.6 board runs any paged request as an unrelated old opcode, so
/// these are the tests that keep a factory reset from happening by accident.
final class DeviceProtocolTests: XCTestCase {

    // MARK: Probe

    private struct Call: Equatable { let request: UInt8; let index: UInt16; let length: UInt16 }

    /// Runs the probe against scripted answers, in order, and records the calls.
    private func probe(_ answers: [Result<Data, LinkStatus>]) -> (ProtocolProbe.Outcome, [Call]) {
        var calls: [Call] = []
        var queue = answers
        let outcome = ProtocolProbe.run { request, index, length in
            calls.append(Call(request: request, index: index, length: length))
            return queue.isEmpty ? .failure(.noDevice) : queue.removeFirst()
        }
        return (outcome, calls)
    }

    private func protocolInfo(major: UInt8, minor: UInt8 = 0, magic: [UInt8] = ProtocolProbe.magic) -> Data {
        Data(magic + [major, minor, 0x0C, 0x00, 0x40, 0x00, 0x00, 0x01, 0, 0, 0, 0])
    }

    private let probeCall = Call(request: 0x10, index: 0x0102, length: 16)
    private let platformCall = Call(request: 0x7F, index: 2, length: 7)
    /// RP2350, 1.1.6 final, 9 outputs, full-width minor/patch/beta.
    private let platform116 = Data([1, 1, 0x16, 9, 1, 6, 0])

    func testPagedBoard() {
        let (outcome, calls) = probe([.success(protocolInfo(major: 1, minor: 0))])
        XCTAssertEqual(outcome, .paged(major: 1, minor: 0))
        XCTAssertEqual(calls, [probeCall], "the probe is the only request, and it goes first")
    }

    func testNewerProtocolMajorIsUnsupported() {
        let (outcome, calls) = probe([.success(protocolInfo(major: 2))])
        XCTAssertEqual(outcome, .unsupported(major: 2))
        XCTAssertEqual(calls, [probeCall])
    }

    func testReplyWithoutMagicIsNotReady() {
        let (outcome, _) = probe([.success(protocolInfo(major: 1, magic: [0, 0, 0, 0]))])
        XCTAssertEqual(outcome, .notReady)
        XCTAssertEqual(probe([.success(Data([0x44, 0x53]))]).0, .notReady, "a short reply is not a verdict")
    }

    func testStallThenPlatformIsLegacy() {
        let (outcome, calls) = probe([.failure(.error), .success(platform116)])
        XCTAssertEqual(outcome, .legacy(platformReply: platform116))
        XCTAssertEqual(calls, [probeCall, platformCall])
    }

    func testShortPlatformReplyFromOldFirmwareIsStillLegacy() {
        // Firmware before 1.1.6 beta 3 answers GET_PLATFORM with 4 bytes.
        let short = Data([0, 1, 0x15, 5])
        XCTAssertEqual(probe([.failure(.error), .success(short)]).0, .legacy(platformReply: short))
    }

    func testStallWithoutAValidPlatformIsNotReady() {
        // A board still booting may STALL everything; never call it legacy.
        XCTAssertEqual(probe([.failure(.error), .failure(.error)]).0, .notReady)
        XCTAssertEqual(probe([.failure(.error), .success(Data([1, 1, 0x16]))]).0, .notReady)
        XCTAssertEqual(probe([.failure(.error), .failure(.timeout)]).0, .notReady)
    }

    func testTimeoutOrDeadLinkIsNotReadyAndSendsNothingElse() {
        for failure in [LinkStatus.timeout, .noDevice, .locked] {
            let (outcome, calls) = probe([.failure(failure)])
            XCTAssertEqual(outcome, .notReady, "\(failure)")
            XCTAssertEqual(calls, [probeCall], "\(failure): no old opcode after a non-STALL failure")
        }
    }

    // MARK: Transfer status

    func testOnlyAStallMapsToError() {
        // 0xe000404f is what a firmware STALL produced on real hardware.
        XCTAssertEqual(USBDevice.status(for: IOReturn(bitPattern: 0xe000404f)), .error)
        XCTAssertEqual(USBDevice.status(for: IOReturn(bitPattern: 0xe0005000)), .error)
        XCTAssertEqual(USBDevice.status(for: kIOReturnTimeout), .timeout)
        XCTAssertEqual(USBDevice.status(for: IOReturn(bitPattern: 0xe0004051)), .timeout,
                       "DeviceRequestTO's timeout must not read as a STALL")
        XCTAssertEqual(USBDevice.status(for: kIOReturnNoDevice), .noDevice)
        XCTAssertEqual(USBDevice.status(for: kIOReturnAborted), .timeout,
                       "an unexpected failure is transient, never a refusal")
    }

    // MARK: Gate

    private let legacy = DeviceProtocolState.legacy(FirmwareVersion(1, 1, 6, 0))
    private let paged = DeviceProtocolState.paged(major: 1, minor: 0)

    func testProbeIsAdmittedInEveryState() {
        for state in [DeviceProtocolState.unknown, legacy, paged, .unsupported(major: 2)] {
            XCTAssertTrue(ProtocolGate.admits(request: 0x10, index: 0x0102, isGet: true, state: state), "\(state)")
        }
    }

    func testPagedRequestsReachOnlyAPagedBoard() {
        // ROUTE.MASTER_VOLUME_SAVED is 0x0553; on 1.1.6 that number is FACTORY_RESET.
        let cmd = VC.ROUTE.MASTER_VOLUME_SAVED
        for state in [DeviceProtocolState.unknown, legacy, .unsupported(major: 2)] {
            XCTAssertFalse(ProtocolGate.admits(request: cmd.number, index: cmd.usbIndex, isGet: true, state: state), "\(state)")
            XCTAssertFalse(ProtocolGate.admits(request: 0x30, index: VC.SYS.ENTER_BOOTLOADER.usbIndex, isGet: false, state: state))
        }
        XCTAssertTrue(ProtocolGate.admits(request: cmd.number, index: cmd.usbIndex, isGet: true, state: paged))
        XCTAssertFalse(ProtocolGate.admits(request: 0x10, index: 0x0102, isGet: false, state: legacy),
                       "only the probe's GET is exempt, not a SET to the same number")
    }

    func testPageZeroAdmitsOnlyTheTwoOldOpcodes() {
        // Unprobed: only the old GET_PLATFORM, which the probe falls back to.
        XCTAssertTrue(ProtocolGate.admits(request: 0x7F, index: 2, isGet: true, state: .unknown))
        XCTAssertFalse(ProtocolGate.admits(request: 0xF0, index: 2, isGet: true, state: .unknown))
        XCTAssertFalse(ProtocolGate.admits(request: 0x7F, index: 2, isGet: false, state: .unknown))
        // Legacy: GET_PLATFORM and the old ENTER_BOOTLOADER, both as GETs.
        XCTAssertTrue(ProtocolGate.admits(request: 0x7F, index: 2, isGet: true, state: legacy))
        XCTAssertTrue(ProtocolGate.admits(request: 0xF0, index: 2, isGet: true, state: legacy))
        XCTAssertFalse(ProtocolGate.admits(request: 0xF0, index: 2, isGet: false, state: legacy))
        // 0x42 was SET_EQ_PARAM and 0x53 FACTORY_RESET on 1.1.6.
        for state in [DeviceProtocolState.unknown, legacy] {
            XCTAssertFalse(ProtocolGate.admits(request: 0x42, index: 0, isGet: false, state: state), "\(state)")
            XCTAssertFalse(ProtocolGate.admits(request: 0x53, index: 2, isGet: true, state: state), "\(state)")
        }
        // Paged or a newer major: nothing at page 0.
        for state in [paged, DeviceProtocolState.unsupported(major: 2)] {
            for request: UInt8 in [0x7F, 0xF0, 0x42] {
                XCTAssertFalse(ProtocolGate.admits(request: request, index: 2, isGet: true, state: state), "\(state)")
                XCTAssertFalse(ProtocolGate.admits(request: request, index: 2, isGet: false, state: state), "\(state)")
            }
        }
    }

    // MARK: Last result

    /// SYS.LAST_RESULT record: id, direction, code, wValue, reserved.
    private func record(id: UInt16, get: Bool, code: UInt8, value: UInt16) -> Data {
        Data([UInt8(id & 0xFF), UInt8(id >> 8), get ? 1 : 0, code,
              UInt8(value & 0xFF), UInt8(value >> 8), 0, 0])
    }

    func testLastResultNamingOurRequestGivesItsCode() {
        let cmd = VC.FILTER.BAND
        let reply = record(id: cmd.id, get: false, code: 0x17, value: 0x0203)
        XCTAssertEqual(VendorLastResult.status(from: reply, request: cmd.number, index: cmd.usbIndex,
                                               value: 0x0203, isGet: false), .vcBusy)
        XCTAssertTrue(LinkStatus.vcBusy.isRetryable)
    }

    func testLastResultForAnotherRequestIsUnknownRefusal() {
        let cmd = VC.FILTER.BAND
        let other = record(id: cmd.id, get: false, code: 0x12, value: 0x0203)
        XCTAssertEqual(VendorLastResult.status(from: other, request: cmd.number, index: cmd.usbIndex,
                                               value: 0x0204, isGet: false), .error, "different wValue")
        XCTAssertEqual(VendorLastResult.status(from: other, request: cmd.number, index: cmd.usbIndex,
                                               value: 0x0203, isGet: true), .error, "different direction")
        let wrongID = record(id: VC.ROUTE.OUTPUT_GAIN.id, get: false, code: 0x12, value: 0x0203)
        XCTAssertEqual(VendorLastResult.status(from: wrongID, request: cmd.number, index: cmd.usbIndex,
                                               value: 0x0203, isGet: false), .error, "different command")
        let ok = record(id: cmd.id, get: false, code: 0x00, value: 0x0203)
        XCTAssertEqual(VendorLastResult.status(from: ok, request: cmd.number, index: cmd.usbIndex,
                                               value: 0x0203, isGet: false), .error, "an OK record cannot explain a STALL")
        XCTAssertEqual(VendorLastResult.status(from: Data([1, 2]), request: cmd.number, index: cmd.usbIndex,
                                               value: 0, isGet: false), .error, "short record")
    }

    // MARK: Local refusals

    func testRegistryRefusesMistakesBeforeTheBus() {
        typealias T = USBDevice
        XCTAssertEqual(T.localRefusal(VendorCommand(0x0001), isGet: true, payload: nil), .vcUnknown)
        XCTAssertEqual(T.localRefusal(VC.SYS.ENTER_BOOTLOADER, isGet: true, payload: nil), .vcDirection)
        XCTAssertEqual(T.localRefusal(VC.SYS.PROTOCOL_INFO, isGet: false, payload: Data()), .vcDirection)
        XCTAssertEqual(T.localRefusal(VC.FILTER.BAND, isGet: false, payload: Data(count: 18)), .vcLength,
                       "the old 18-byte Linkwitz packet is refused")
        XCTAssertNil(T.localRefusal(VC.FILTER.BAND, isGet: false, payload: Data(count: 16)))
        XCTAssertEqual(T.localRefusal(VC.SYS.ENTER_BOOTLOADER, isGet: false, payload: Data([1])), .vcLength,
                       "a zero-length SET takes no payload")
        XCTAssertNil(T.localRefusal(VC.SYS.ENTER_BOOTLOADER, isGet: false, payload: Data()))
    }

    // MARK: Hub

    /// A switch publishes no `false`; the old board's router must go at once,
    /// not when the new board finally attaches, or it keeps sending to the new
    /// board while that board's protocol is unknown.
    func testSwitchDetachesTheOldBoardBeforeProbingTheNewOne() {
        let auth = LinkAuthStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString).json"))
        let hub = LinkHub(usb: USBDevice(startMonitoring: false),
                          policy: LinkPolicy.bundled ?? LinkPolicy.empty, auth: auth)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))   // the inert USBDevice's initial false
        hub.identityRetryDelays = [0]

        let a = LinkFakeDevice()
        let probing = DispatchSemaphore(value: 0)
        let switched = NSLock()
        var isSwitched = false
        hub.usbDeviceFactory = { _ in
            switched.lock(); let s = isSwitched; switched.unlock()
            guard s else { return a }
            probing.wait()          // the new board's probe is still running
            return nil
        }

        hub.usbConnectionChanged(connected: true, generation: 1)
        let deadline = Date().addingTimeInterval(3)
        while !hub.isDeviceAttached, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(hub.isDeviceAttached)

        switched.lock(); isSwitched = true; switched.unlock()
        hub.usbConnectionChanged(connected: true, generation: 2)
        XCTAssertFalse(hub.isDeviceAttached, "detached synchronously, before the new board answers")
        probing.signal()
    }

    // MARK: Phase 3 review fixes

    /// USBDevice publishes a new board's protocol before the hub hears of the
    /// switch, so a hub device must answer only for the connection it was
    /// attached for, never for whatever is open now.
    func testHubDeviceIsBoundToItsConnection() {
        let usb = USBDevice(startMonitoring: false)
        let info = HubDeviceInfo(serial: "AAAA", platform: 1, firmware: "1.1.7", outputs: 9,
                                 inputs: nil, wireVersion: nil, link: .usb)
        let device = USBHubDevice(usb: usb, info: info, generation: usb.generation &+ 7)
        XCTAssertEqual(device.generation, usb.generation &+ 7, "bound, not read live from USB")
        XCTAssertFalse(device.isConnected)
        let get = device.execute(LinkCmdRequest(tag: 1, handle: 0, direction: .get,
                                                bRequest: VC.SYS.PLATFORM.number, wValue: 0,
                                                wIndex: VC.SYS.PLATFORM.usbIndex, wLength: 7))
        XCTAssertEqual(get.status, .noDevice)
    }

    func testOnlyAPagedBoardIsAttached() {
        XCTAssertTrue(USBHubDevice.attaches(.paged(major: 1, minor: 0)))
        XCTAssertFalse(USBHubDevice.attaches(.legacy(platformReply: platform116)))
        XCTAssertFalse(USBHubDevice.attaches(.unsupported(major: 2)))
        XCTAssertFalse(USBHubDevice.attaches(.notReady))
    }

    /// A board probed as legacy is never attached, and the hub stops probing it
    /// rather than retrying as it would for a board that is still booting.
    func testHubNeverAttachesASettledLegacyBoard() {
        let auth = LinkAuthStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString).json"))
        let hub = LinkHub(usb: USBDevice(startMonitoring: false),
                          policy: LinkPolicy.bundled ?? LinkPolicy.empty, auth: auth)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        hub.identityRetryDelays = [0, 0.01, 0.01, 0.01]
        let lock = NSLock()
        var probes = 0
        hub.usbDeviceFactory = { _ in lock.lock(); probes += 1; lock.unlock(); return nil }
        hub.stopsProbing = { _ in true }      // as USBDevice reports after a legacy verdict

        hub.usbConnectionChanged(connected: true, generation: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        lock.lock(); let seen = probes; lock.unlock()
        XCTAssertEqual(seen, 1, "one probe, then no retries")
        XCTAssertFalse(hub.isDeviceAttached)
    }

    func testNamesAreCutOnUTF8BytesWithoutSplittingACharacter() {
        XCTAssertEqual(DSPViewModel.utf8Prefix("Living Room", maxBytes: 31), "Living Room")
        let long = String(repeating: "é", count: 20)          // 2 bytes each, 40 in all
        let cut = DSPViewModel.utf8Prefix(long, maxBytes: 31)
        XCTAssertEqual(cut, String(repeating: "é", count: 15))
        XCTAssertLessThanOrEqual(cut.utf8.count, 31)
        XCTAssertEqual(DSPViewModel.utf8Prefix("ab😀", maxBytes: 4), "ab", "a 4-byte character is not split")
    }

    /// NetworkTransport completes on the main queue; a main-thread setAndWait
    /// must still get the answer instead of waiting out its timeout.
    func testSetAndWaitOnTheMainThreadSeesAMainQueueCompletion() {
        let client = LinkClientFake()
        let transport = NetworkTransport(client: client, hubID: "hub-1", hubName: "Studio",
                                         tokens: LinkTokenStore(service: "test-\(UUID().uuidString)"),
                                         clientName: "Tester")
        client.responder = { LinkCmdResponse(tag: $0.tag, status: .ok) }
        transport.bind(serial: "AAAA")
        client.setDevices([LinkDeviceInfo(handle: 1, serial: "AAAA", name: nil, state: .online,
                                           protocolVersion: LinkDeviceProtocol(major: 1, minor: 0))])
        client.setState(.ready)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let started = Date()
        XCTAssertEqual(transport.setAndWait(VC.STORE.PRESET_SAVE, value: 1, timeout: 3), .ok)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}
