//
//  LinkLockUsageTests.swift
//  DSPi ConsoleTests
//
//  The Console flows that take the DSPi Link device lock (spec 7.7), driven
//  through a view model bound to a HubTransport over a fake device: each flow
//  holds the lock while it talks to the device, releases it on every exit,
//  shuts a second session out meanwhile, and touches nothing when it cannot
//  get the lock.  Also the transport lock pair on its own.
//

import XCTest
@testable import DSPi_Console

final class LinkLockUsageTests: XCTestCase {

    private struct Rig {
        let hub: LinkHub
        let device: LinkFakeDevice
        let transport: HubTransport
        let vm: DSPViewModel
        let remote: LinkHubSession
    }

    private func makeRig() -> Rig {
        let usb = USBDevice(startMonitoring: false)
        let auth = LinkAuthStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("lock-\(UUID().uuidString).json"))
        let hub = LinkHub(usb: usb, policy: LinkPolicy.bundled ?? .empty, auth: auth)
        let device = LinkFakeDevice()
        device.responsePayload = Data([0])
        hub.attachDevice(device)
        let transport = HubTransport(hub: hub, usb: usb)
        let vm = DSPViewModel(transport: transport)
        let remote = hub.openSession(role: .control)
        settle()
        return Rig(hub: hub, device: device, transport: transport, vm: vm, remote: remote)
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func holder(_ rig: Rig) -> LinkSessionID? {
        rig.hub.registry.device(handle: rig.hub.currentHandle)?.lockedBy
    }

    /// A master-volume SET from the remote session, answered synchronously
    /// when refused.  Safe to call from inside the fake device's responder.
    private func probe(_ rig: Rig) -> LinkStatus {
        let req = LinkCmdRequest(tag: 1, handle: rig.hub.currentHandle, direction: .set,
                                 bRequest: 0xD2, wValue: 0, wIndex: 2, payload: Data([0, 0, 0, 0]))
        let sem = DispatchSemaphore(value: 0)
        let box = StatusBox()
        rig.hub.submit(req, from: rig.remote.id) { box.set($0.status); sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
        return box.get() ?? .timeout
    }

    private final class StatusBox {
        private var value: LinkStatus?
        private let lock = NSLock()
        func set(_ v: LinkStatus) { lock.lock(); value = v; lock.unlock() }
        func get() -> LinkStatus? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Records, for each command with `code`, who held the lock and what a
    /// second session got, then answers with `answer`.
    private final class Recorder {
        private let lock = NSLock()
        private var holders: [LinkSessionID?] = []
        private var probes: [LinkStatus] = []
        func record(_ h: LinkSessionID?, _ p: LinkStatus) {
            lock.lock(); holders.append(h); probes.append(p); lock.unlock()
        }
        var seenHolders: [LinkSessionID?] { lock.lock(); defer { lock.unlock() }; return holders }
        var seenProbes: [LinkStatus] { lock.lock(); defer { lock.unlock() }; return probes }
    }

    private func instrument(_ rig: Rig, code: UInt8,
                            answer: @escaping (LinkCmdRequest) -> LinkCmdResponse) -> Recorder {
        let rec = Recorder()
        rig.device.responder = { [unowned self] req in
            if req.bRequest == code { rec.record(self.holder(rig), self.probe(rig)) }
            return answer(req)
        }
        return rec
    }

    private func ok(_ req: LinkCmdRequest, _ payload: Data = Data([0])) -> LinkCmdResponse {
        LinkCmdResponse(tag: req.tag, status: .ok, payload: req.direction == .get ? payload : Data())
    }

    private func offMain<T>(_ body: @escaping () -> T) -> T {
        let e = expectation(description: "off main")
        var out: T?
        DispatchQueue.global().async { out = body(); e.fulfill() }
        wait(for: [e], timeout: 10)
        return out!
    }

    private func executed(_ rig: Rig, _ code: UInt8) -> Int {
        rig.device.executedCodes.filter { $0 == code }.count
    }

    // MARK: Transport lock pair

    func testHubTransportLockShutsOutOtherSessions() {
        let rig = makeRig()
        XCTAssertTrue(rig.transport.acquireDeviceLock(reason: "test", timeout: 5))
        XCTAssertEqual(holder(rig), LinkHub.localSessionID)
        XCTAssertEqual(probe(rig), .locked)
        rig.transport.releaseDeviceLock()
        XCTAssertNil(holder(rig))
        XCTAssertEqual(probe(rig), .ok)
    }

    func testHubTransportRefusedWhileAnotherSessionHoldsTheLock() {
        let rig = makeRig()
        XCTAssertTrue(rig.hub.acquireLock(session: rig.remote.id, timeout: 5))
        XCTAssertFalse(rig.transport.acquireDeviceLock(reason: "test", timeout: 5))
        XCTAssertEqual(holder(rig), rig.remote.id, "a refused acquire leaves the holder alone")
    }

    func testWithDeviceLockReleasesWhenTheBodyThrows() {
        struct Boom: Error {}
        let rig = makeRig()
        XCTAssertThrowsError(try rig.transport.withDeviceLock(reason: "test", timeout: 5) { () throws -> Int in
            XCTAssertEqual(self.holder(rig), LinkHub.localSessionID)
            throw Boom()
        })
        XCTAssertNil(holder(rig))
    }

    func testUSBDeviceLockIsANoOp() {
        let usb = USBDevice(startMonitoring: false)
        XCTAssertTrue(usb.acquireDeviceLock(reason: "test", timeout: 5))
        usb.releaseDeviceLock()
    }

    func testLockedStatusHasTheSharedMessage() {
        XCTAssertEqual(LinkStatus.locked.userMessage, "Another console is applying changes")
        XCTAssertNil(LinkStatus.error.userMessage)
    }

    // MARK: Preset save and copy

    func testSavePresetHoldsTheLockAndReleasesIt() {
        let rig = makeRig()
        let rec = instrument(rig, code: REQ_PRESET_SAVE) { self.ok($0) }
        let status = offMain { rig.vm.savePreset(slot: 2) }
        XCTAssertEqual(status, PRESET_OK)
        XCTAssertEqual(rec.seenHolders, [LinkHub.localSessionID])
        XCTAssertEqual(rec.seenProbes, [.locked])
        XCTAssertNil(holder(rig))
    }

    func testSavePresetReleasesWhenTheDeviceFails() {
        let rig = makeRig()
        let rec = instrument(rig, code: REQ_PRESET_SAVE) {
            LinkCmdResponse(tag: $0.tag, status: .error)
        }
        let status = offMain { rig.vm.savePreset(slot: 2) }
        XCTAssertEqual(status, 0xFF)
        XCTAssertEqual(rec.seenHolders, [LinkHub.localSessionID])
        XCTAssertNil(holder(rig))
    }

    func testSavePresetDoesNotTouchTheDeviceWhenLocked() {
        let rig = makeRig()
        XCTAssertTrue(rig.hub.acquireLock(session: rig.remote.id, timeout: 5))
        let status = offMain { rig.vm.savePreset(slot: 2) }
        XCTAssertEqual(status, PRESET_STATUS_LOCKED)
        XCTAssertEqual(executed(rig, REQ_PRESET_SAVE), 0)
        XCTAssertEqual(presetFailureText(status), DeviceLock.lockedMessage)
        XCTAssertEqual(holder(rig), rig.remote.id)
    }

    func testCopyPresetHoldsOneLockAcrossBothSaves() {
        let rig = makeRig()
        // GET_ACTIVE reports the last slot saved, which is how copyPreset
        // learns each deferred save has finished.
        let lastSaved = StatusBoxInt()
        let rec = Recorder()
        rig.device.responder = { [unowned self] req in
            switch req.bRequest {
            case REQ_PRESET_SAVE:
                rec.record(self.holder(rig), self.probe(rig))
                lastSaved.set(Int(req.wValue))
                return self.ok(req)
            case REQ_PRESET_GET_ACTIVE:
                return self.ok(req, Data([UInt8(lastSaved.get())]))
            default:
                return self.ok(req)
            }
        }
        let status = offMain { rig.vm.copyPreset(from: 1, to: 4) }
        XCTAssertEqual(status, PRESET_OK)
        XCTAssertEqual(rec.seenHolders, [LinkHub.localSessionID, LinkHub.localSessionID],
                       "both saves under the lock, not released between them")
        XCTAssertEqual(rec.seenProbes, [.locked, .locked])
        XCTAssertNil(holder(rig))
    }

    func testCopyPresetReleasesWhenTheFirstSaveFails() {
        let rig = makeRig()
        let rec = instrument(rig, code: REQ_PRESET_SAVE) { self.ok($0, Data([PRESET_ERR_FLASH_WRITE])) }
        let status = offMain { rig.vm.copyPreset(from: 1, to: 4) }
        XCTAssertEqual(status, PRESET_ERR_FLASH_WRITE)
        XCTAssertEqual(rec.seenHolders.count, 1)
        XCTAssertNil(holder(rig))
    }

    private final class StatusBoxInt {
        private var value = -1
        private let lock = NSLock()
        func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
        func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: Output configuration and flash saves

    func testSaveOutputConfigHoldsTheLock() {
        let rig = makeRig()
        let rec = instrument(rig, code: REQ_SAVE_OUTPUT_CONFIG) { self.ok($0) }
        XCTAssertTrue(offMain { rig.vm.saveOutputConfig() })
        XCTAssertEqual(rec.seenHolders, [LinkHub.localSessionID])
        XCTAssertEqual(rec.seenProbes, [.locked])
        XCTAssertNil(holder(rig))
    }

    func testSaveOutputConfigReleasesOnDeviceError() {
        let rig = makeRig()
        _ = instrument(rig, code: REQ_SAVE_OUTPUT_CONFIG) { LinkCmdResponse(tag: $0.tag, status: .error) }
        let result = offMain { rig.vm.saveOutputConfigResult() }
        guard case .failure(.error) = result else { return XCTFail("expected .error, got \(result)") }
        XCTAssertNil(holder(rig))
    }

    func testSaveOutputConfigReportsLockedAndSendsNothing() {
        let rig = makeRig()
        XCTAssertTrue(rig.hub.acquireLock(session: rig.remote.id, timeout: 5))
        let result = offMain { rig.vm.saveOutputConfigResult() }
        guard case .failure(.locked) = result else { return XCTFail("expected .locked, got \(result)") }
        XCTAssertEqual(executed(rig, REQ_SAVE_OUTPUT_CONFIG), 0)
    }

    func testSaveParamsHoldsTheLockAndRefusesWhenLocked() {
        let rig = makeRig()
        XCTAssertTrue(rig.vm.isDeviceConnected)
        let rec = instrument(rig, code: REQ_SAVE_PARAMS) { self.ok($0, Data([FLASH_OK])) }
        XCTAssertEqual(offMain { rig.vm.saveParams() }, FLASH_OK)
        XCTAssertEqual(rec.seenHolders, [LinkHub.localSessionID])
        XCTAssertNil(holder(rig))

        XCTAssertTrue(rig.hub.acquireLock(session: rig.remote.id, timeout: 5))
        XCTAssertEqual(offMain { rig.vm.saveParams() }, FLASH_ERR_WRITE)
        XCTAssertEqual(executed(rig, REQ_SAVE_PARAMS), 1, "the refused save never reached the device")
    }

    // MARK: IR learn

    private func learnAnswer(state: UInt8) -> (LinkCmdRequest) -> LinkCmdResponse {
        { req in
            guard req.bRequest == REQ_CS_IR_LEARN else { return self.ok(req) }
            if req.wValue == CS_IR_LEARN_READ {
                return self.ok(req, Data([state, 1, 0, 0, 0x78, 0x56, 0x34, 0x12]))
            }
            return self.ok(req, Data([0]))
        }
    }

    func testIrLearnHoldsTheLockFromArmUntilTheResult() {
        let rig = makeRig()
        rig.device.responder = learnAnswer(state: CS_IR_LEARN_STATE_ARMED)
        XCTAssertEqual(offMain { rig.vm.csIrLearnArm() }, .armed)
        XCTAssertEqual(holder(rig), LinkHub.localSessionID)
        XCTAssertEqual(probe(rig), .locked, "another session is shut out for the learn window")

        _ = offMain { rig.vm.csIrLearnRead() }
        XCTAssertEqual(holder(rig), LinkHub.localSessionID, "still armed, still held")

        rig.device.responder = learnAnswer(state: CS_IR_LEARN_STATE_DONE)
        let result = offMain { rig.vm.csIrLearnRead() }
        XCTAssertEqual(result?.state, CS_IR_LEARN_STATE_DONE)
        XCTAssertNil(holder(rig), "the result ends the learn")
    }

    func testIrLearnReleasesOnTimeoutResult() {
        let rig = makeRig()
        rig.device.responder = learnAnswer(state: CS_IR_LEARN_STATE_TIMEOUT)
        XCTAssertEqual(offMain { rig.vm.csIrLearnArm() }, .armed)
        _ = offMain { rig.vm.csIrLearnRead() }
        XCTAssertNil(holder(rig))
    }

    func testIrLearnReleasesOnCancel() {
        let rig = makeRig()
        rig.device.responder = learnAnswer(state: CS_IR_LEARN_STATE_ARMED)
        XCTAssertEqual(offMain { rig.vm.csIrLearnArm() }, .armed)
        offMain { rig.vm.csIrLearnCancel() }
        XCTAssertNil(holder(rig))
    }

    func testIrLearnArmStallReleasesAndReportsNoReceiver() {
        let rig = makeRig()
        rig.device.responder = { req in
            req.bRequest == REQ_CS_IR_LEARN ? LinkCmdResponse(tag: req.tag, status: .error) : self.ok(req)
        }
        XCTAssertEqual(offMain { rig.vm.csIrLearnArm() }, .noReceiver)
        XCTAssertNil(holder(rig))
    }

    func testIrLearnEndIsIdempotent() {
        let rig = makeRig()
        rig.device.responder = learnAnswer(state: CS_IR_LEARN_STATE_ARMED)
        XCTAssertEqual(offMain { rig.vm.csIrLearnArm() }, .armed)
        rig.vm.csIrLearnEnd()
        XCTAssertNil(holder(rig))
        // A later flow's lock must survive a stray second end.
        XCTAssertTrue(rig.transport.acquireDeviceLock(reason: "later", timeout: 5))
        rig.vm.csIrLearnEnd()
        XCTAssertEqual(holder(rig), LinkHub.localSessionID)
        rig.transport.releaseDeviceLock()
    }

    func testIrLearnArmRefusedWhenLocked() {
        let rig = makeRig()
        XCTAssertTrue(rig.hub.acquireLock(session: rig.remote.id, timeout: 5))
        XCTAssertEqual(offMain { rig.vm.csIrLearnArm() }, .locked)
        XCTAssertEqual(executed(rig, REQ_CS_IR_LEARN), 0)
    }

    // MARK: Firmware install

    func testFirmwareInstallLocksBeforeTheRebootAndReleases() {
        let rig = makeRig()
        let rec = instrument(rig, code: REQ_ENTER_BOOTLOADER) { self.ok($0) }
        let e = expectation(description: "rebooted")
        rig.vm.enterBootloaderForInstall { sent in XCTAssertTrue(sent); e.fulfill() }
        wait(for: [e], timeout: 5)
        XCTAssertEqual(rec.seenHolders, [LinkHub.localSessionID])
        XCTAssertEqual(rec.seenProbes, [.locked])
        XCTAssertEqual(holder(rig), LinkHub.localSessionID, "held until the install ends")
        rig.vm.releaseFirmwareInstallLock()
        XCTAssertNil(holder(rig))
    }

    func testFirmwareInstallRefusedWhenLockedSendsNoReboot() {
        let rig = makeRig()
        XCTAssertTrue(rig.hub.acquireLock(session: rig.remote.id, timeout: 5))
        let e = expectation(description: "refused")
        rig.vm.enterBootloaderForInstall { sent in XCTAssertFalse(sent); e.fulfill() }
        wait(for: [e], timeout: 5)
        XCTAssertEqual(executed(rig, REQ_ENTER_BOOTLOADER), 0)
        rig.vm.releaseFirmwareInstallLock()
        XCTAssertEqual(holder(rig), rig.remote.id, "releasing a lock never taken leaves the holder alone")
    }

    func testInstallerAbandonReportsDeviceLocked() {
        let installer = FirmwareInstaller(locator: NoBoardLocator(), verifier: NeverVerifier())
        installer.installWhenReady()
        installer.abandon(.deviceLocked)
        XCTAssertEqual(installer.state, .failed(.deviceLocked))
        XCTAssertFalse(installer.isArmed)
        XCTAssertTrue(FirmwareInstallError.deviceLocked.message.hasPrefix(DeviceLock.lockedMessage))
    }

    // MARK: Configuration import

    private func applyDocument(_ rig: Rig) -> PresetApplyReport {
        let doc = PresetDocument.capture(from: rig.vm)
        let e = expectation(description: "applied")
        var report: PresetApplyReport?
        PresetDocumentApply.apply(doc, to: rig.vm, options: PresetApplyOptions()) {
            report = $0
            e.fulfill()
        }
        wait(for: [e], timeout: 20)
        return report!
    }

    func testConfigurationImportHoldsTheLockForTheWholeApply() {
        let rig = makeRig()
        let rec = instrument(rig, code: REQ_SET_PREAMP_CH) { self.ok($0) }
        let report = applyDocument(rig)
        XCTAssertFalse(report.lockedOut)
        XCTAssertFalse(rec.seenHolders.isEmpty, "the apply wrote preamps")
        XCTAssertTrue(rec.seenHolders.allSatisfy { $0 == LinkHub.localSessionID })
        XCTAssertTrue(rec.seenProbes.allSatisfy { $0 == .locked })
        XCTAssertNil(holder(rig))
    }

    func testConfigurationImportReleasesWhenTheDeviceRefusesWrites() {
        let rig = makeRig()
        rig.device.responder = { req in
            req.direction == .set ? LinkCmdResponse(tag: req.tag, status: .error) : self.ok(req)
        }
        _ = applyDocument(rig)
        XCTAssertNil(holder(rig))
    }

    func testConfigurationImportRefusedWhenLockedSendsNothing() {
        let rig = makeRig()
        XCTAssertTrue(rig.hub.acquireLock(session: rig.remote.id, timeout: 5))
        let before = executed(rig, REQ_SET_PREAMP_CH)
        let report = applyDocument(rig)
        XCTAssertTrue(report.lockedOut)
        XCTAssertEqual(executed(rig, REQ_SET_PREAMP_CH), before)
        XCTAssertEqual(holder(rig), rig.remote.id)
    }

    // MARK: Network and composite transports

    private func boundNetwork(capabilities: [String]) -> (NetworkTransport, LinkClientFake) {
        let client = LinkClientFake()
        client.capabilities = capabilities
        let t = NetworkTransport(client: client, hubID: "hub-1", hubName: "Studio",
                                 tokens: LinkTokenStore(service: "test-\(UUID().uuidString)"),
                                 clientName: "Tester")
        t.bind(serial: "AAAA")
        client.setDevices([LinkDeviceInfo(handle: 3, serial: "AAAA", name: "Den", state: .online)])
        client.setState(.ready)
        return (t, client)
    }

    func testNetworkTransportLocksTheBoundHandle() {
        let (t, client) = boundNetwork(capabilities: ["cmd", "lock"])
        XCTAssertTrue(offMain { t.acquireDeviceLock(reason: "Saving preset", timeout: 90) })
        XCTAssertEqual(client.lockAcquires.count, 1)
        XCTAssertEqual(client.lockAcquires.first?.handle, 3)
        XCTAssertEqual(client.lockAcquires.first?.reason, "Saving preset")
        XCTAssertEqual(client.lockAcquires.first?.timeoutMs, 60_000, "capped at the hub's 60 s")
        t.releaseDeviceLock()
        XCTAssertEqual(client.lockReleases, [3])
    }

    func testNetworkTransportRefusedLockFailsTheFlow() {
        let (t, client) = boundNetwork(capabilities: ["cmd", "lock"])
        client.lockResult = .failure(.rejected(code: LinkErrorCode.locked, message: nil))
        XCTAssertFalse(offMain { t.acquireDeviceLock(reason: "x", timeout: 5) })
    }

    func testNetworkTransportSkipsTheLockOnAHubWithoutIt() {
        let (t, client) = boundNetwork(capabilities: ["cmd"])
        XCTAssertTrue(offMain { t.acquireDeviceLock(reason: "x", timeout: 5) })
        t.releaseDeviceLock()
        XCTAssertTrue(client.lockAcquires.isEmpty)
        XCTAssertTrue(client.lockReleases.isEmpty)
    }

    func testCompositeTransportLocksTheActiveTransport() {
        let rig = makeRig()
        let composite = CompositeTransport(local: rig.transport,
                                           tokens: LinkTokenStore(service: "t-\(UUID())"),
                                           clientName: "T") { LinkClientFake() }
        XCTAssertTrue(composite.acquireDeviceLock(reason: "x", timeout: 5))
        XCTAssertEqual(holder(rig), LinkHub.localSessionID)
        composite.releaseDeviceLock()
        XCTAssertNil(holder(rig))
    }
}

private final class NoBoardLocator: BootloaderLocating {
    func currentBoards() -> [BootloaderBoard] { [] }
    var onChange: (([BootloaderBoard]) -> Void)?
    func start() {}
    func stop() {}
}

private struct NeverVerifier: FirmwareVerifying {
    func awaitDeviceVersion(timeout: TimeInterval) -> FirmwareVersion? { nil }
}
