import XCTest
@testable import DSPi_Console

/// Per-command sweep of the 1.1.7 paged vendor protocol against a live board.
///
/// Opt-in, because it writes to nearly every setting the board has:
///
///     TEST_RUNNER_DSPI_COMMAND_SWEEP=1 xcodebuild test \
///         -only-testing:"DSPi ConsoleTests/LiveCommandSweepTests" ...
///
/// Four passes, all through the app's own transport (`AppState.shared.transport`):
///
/// 1. **GET sweep.** Every GET in the registry, at the first and last address of
///    its kind.  A command the board says it implements (SYS.PAGE_COMMANDS)
///    must answer with exactly the registry's length; one it does not must be
///    refused.
/// 2. **Identity SET sweep.** Every settable command whose GET and SET share a
///    fixed layout gets its current value written straight back.  The write must
///    be accepted and the value must read back unchanged.  This proves the ID,
///    address and length of each SET on the wire.
/// 3. **App setters.** The view model's own setters change one value each,
///    and the result is read back raw and decoded here from the registry's
///    description, not by the app.  A layout or address mistake in the app's
///    encoder therefore shows up as a mismatch.  Indexed commands use a
///    non-zero address and check that a neighbour did not change.
/// 4. **Action SETs.** The SET-only commands that are harmless on a bench
///    board (clip clear, stats reset, RTA start/stop, IR learn arm/cancel ...).
///
/// Nothing that writes flash, reboots, resets or plays sound is sent.  Every
/// value is restored as soon as it has been checked, and at the end the whole
/// STORE.ALL_PARAMS image must equal the one taken at the start.  A report is
/// printed and written to `DSPI_SWEEP_REPORT` (default: the temp directory).
final class LiveCommandSweepTests: XCTestCase {

    // MARK: - Plumbing

    /// The Link test swaps in a network transport and a view model on it.
    private var transportOverride: DeviceTransport?
    private var vmOverride: DSPViewModel?
    private var transport: DeviceTransport { transportOverride ?? AppState.shared.transport }
    private var vm: DSPViewModel { vmOverride ?? AppState.shared.viewModel }

    private var report: [String] = []
    private var getOK = Set<UInt16>()
    private var setOK = Set<UInt16>()
    private var appSetOK = Set<UInt16>()
    private var actionOK = Set<UInt16>()
    private var notBuilt = Set<UInt16>()

    private func log(_ line: String) { report.append(line) }

    private func hex(_ d: Data?) -> String {
        guard let d else { return "nil" }
        return d.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func name(_ c: VendorCommand) -> String { c.description }

    private func fixedLength(_ c: VendorCommand) -> Int? {
        if case .fixed(let n) = VendorCommandRegistry.info(for: c)?.getLength { return n }
        return nil
    }

    /// GET with the length the registry gives; variable replies ask for plenty.
    private func read(_ c: VendorCommand, _ addr: UInt16 = 0) -> Result<Data, LinkStatus> {
        let info = VendorCommandRegistry.info(for: c)
        let length: Int
        switch info?.getLength {
        case .fixed(let n): length = n
        default: length = info?.flags.contains(.bulk) == true ? 8192 : 1024
        }
        return transport.get(c, value: addr, length: UInt16(length))
    }

    private func readData(_ c: VendorCommand, _ addr: UInt16 = 0) -> Data? {
        if case .success(let d) = read(c, addr) { return d }
        return nil
    }

    /// Re-read until `want` comes back or the time runs out.  Deferred commands
    /// are applied by the main loop a moment after the ACK, and band writes
    /// leave through the band writer's coalescing slot.
    private func readUntil(_ c: VendorCommand, _ addr: UInt16, equals want: Data,
                           timeout: TimeInterval = 1.5) -> Data? {
        HardwareTest.settle()
        let deadline = Date().addingTimeInterval(timeout)
        var last = readData(c, addr)
        while last != want, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            last = readData(c, addr)
        }
        return last
    }

    /// Runs `work` off the main thread (the CS setters block) while the main
    /// run loop keeps turning for the transport's callbacks.
    private func offMain(_ work: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { work(); done.signal() }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// A network transport cannot know the board's command set, so a Link
    /// run asks the local USB connection to the same board.
    private func implemented(_ c: VendorCommand, set: Bool) -> Bool {
        (transportOverride == nil ? transport : AppState.shared.usb).implements(c, set: set) != false
    }

    // Payload builders, written from the registry descriptions.
    private func f32(_ v: Float) -> Data { withUnsafeBytes(of: v.bitPattern.littleEndian) { Data($0) } }
    private func u8(_ v: UInt8) -> Data { Data([v]) }
    private func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func name32(_ s: String) -> Data {
        var d = Data(s.utf8.prefix(31)); d.append(Data(count: 32 - d.count)); return d
    }

    // MARK: - Board shape

    private struct Shape { var channels = 1, inputs = 1, outputs = 1 }
    private var shape = Shape()

    /// The first Control Surfaces slot holding an aux output, or nil.
    private var auxSlot: UInt16?

    private var boardPages: [UInt16] = []

    /// Address counts found by walking a one-index kind until VC_ERR_ADDRESS.
    private var walked: [UInt16: Int] = [:]

    /// Every valid address of the command.  Kinds whose size the board shape
    /// gives are enumerated; the rest are walked once (see `walk`).
    private func addresses(for info: VendorCommandInfo) -> [UInt16] {
        if info.command == VC.CS.AUX_STATE || info.command == VC.CS.AUX_LEVEL { return auxSlot.map { [$0] } ?? [] }
        let firstOutCh = shape.channels - shape.outputs
        func range(_ n: Int) -> [UInt16] { (0..<n).map(UInt16.init) }
        switch info.address {
        case .none, .offset: return [0]
        // The pages the board lists (page, revision pairs), not the registry's:
        // a page with no command in this build is not listed and is refused.
        case .page: return boardPages
        case .pageCommand:
            return VendorCommandRegistry.all.filter { implemented($0.command, set: $0.hasSet && !$0.hasGet) }.map { $0.command.id }
        case .channel: return range(shape.channels)
        case .input: return range(shape.inputs)
        case .output, .outputAll: return range(shape.outputs)
        case .preset: return range(10)
        case .csSlot: return range(CS_MAX_BINDINGS)
        // Every binding type in the first and last slot; the slot does not
        // change which types a build has.
        case .csSlotType:
            return [0, CS_MAX_BINDINGS - 1].flatMap { slot in
                (CS_TYPE_BUTTON...CS_TYPE_AUX_PWM).map { UInt16($0 << 8 | slot) }
            }
        case .csSub: return range(CS_MAX_IR_COMMANDS)
        case .csGroup, .csMacro: return range(CS_MAX_MACROS)
        case .csPage: return range(CS_MAX_DISPLAY_PAGES)
        case .inputOutput:
            return (0..<shape.inputs).flatMap { i in (0..<shape.outputs).map { UInt16(i << 8 | $0) } }
        case .csMacroStep:
            return (0..<CS_MAX_MACROS).flatMap { m in (0..<CS_MAX_MACRO_STEPS).map { UInt16($0 << 8 | m) } }
        case .channelBand:
            // PEQ bands 0-9 on every channel; crossover bands 20-23 on outputs.
            return (0..<shape.channels).flatMap { ch -> [UInt16] in
                let bands = Array(0..<10) + (ch >= firstOutCh ? Array(20..<24) : [])
                return bands.map { UInt16(ch << 8 | $0) }
            }
        default:
            return range(walked[info.command.id] ?? 1)
        }
    }

    /// For one-index kinds the board shape does not size (output slots, pin
    /// outputs, sources, I2S pairs, roles, nouns, chunk indexes), read upward
    /// until the board refuses.  The refusal must be VC_ERR_ADDRESS: anything
    /// else means the address was not the problem.
    private func walk(_ info: VendorCommandInfo) {
        var n = 0
        while n < 256 {
            switch read(info.command, UInt16(n)) {
            case .success: n += 1; continue
            case .failure(let s):
                if s != .vcAddress {
                    XCTFail("\(name(info.command)) @\(n): first refusal is \(s), expected vcAddress")
                }
            }
            break
        }
        walked[info.command.id] = n
        log("  \(name(info.command)): \(n) addresses")
    }

    // MARK: - The test

    func testEveryCommand() throws {
        guard ProcessInfo.processInfo.environment["DSPI_COMMAND_SWEEP"] == "1" else {
            throw XCTSkip("Opt-in: run with TEST_RUNNER_DSPI_COMMAND_SWEEP=1 (writes to the board).")
        }
        _ = try HardwareTest.requireDevice()
        runSweep()
    }

    /// The four passes and the final image check, through `transport`.
    private func runSweep() {
        // The pin map and the setters' guards come from the app's first full
        // read, which lands a few seconds after the link is up.
        let ready = Date().addingTimeInterval(15)
        while !vm.deviceNameSupported, Date() < ready {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        guard let bulkBefore = readData(VC.STORE.ALL_PARAMS), bulkBefore.count >= 5 else {
            return XCTFail("STORE.ALL_PARAMS did not answer")
        }
        shape = Shape(channels: Int(bulkBefore[2]), inputs: Int(bulkBefore[4]), outputs: Int(bulkBefore[3]))
        let csDirtyBefore = readData(VC.CS.STATUS).map { $0.count > 3 && $0[3] != 0 }
        auxSlot = (0..<UInt16(CS_MAX_BINDINGS)).first { slot in
            guard let b = readData(VC.CS.BINDING, slot), let t = b.first else { return false }
            return Int(t) == CS_TYPE_AUX_OUT || Int(t) == CS_TYPE_AUX_PWM
        }
        log("Board: \(shape.channels) channels, \(shape.inputs) inputs, \(shape.outputs) outputs, aux slot \(auxSlot.map(String.init) ?? "none")")
        if auxSlot == nil {
            // Without an aux output the board must refuse the aux commands
            // with VC_ERR_STATE: that still proves the command and address.
            for c in [VC.CS.AUX_STATE, VC.CS.AUX_LEVEL] {
                if case .failure(let s) = read(c, 0) {
                    XCTAssertEqual(s, .vcState, "\(name(c)) on a slot that is not an aux output")
                } else {
                    XCTFail("\(name(c)) answered on a slot that is not an aux output")
                }
            }
            log("  CS.AUX_STATE, CS.AUX_LEVEL: no aux output configured; both refused with vcState as expected, not written")
        }

        getSweep()
        identitySweep()
        appSetterPass()
        actionPass()

        // Identity and preview writes mark the Control Surfaces config dirty.
        // When it was clean before, the stored copy equals the live one, so a
        // revert only clears the flag.
        if csDirtyBefore == false, readData(VC.CS.STATUS).map({ $0[3] != 0 }) == true {
            let status = transport.setAndWait(VC.CS.REVERT)
            XCTAssertEqual(status, .ok, "CS.REVERT to clear the dirty flag")
            HardwareTest.settle()
        }

        // The whole parameter image must be back where it started.
        if let bulkAfter = readUntil(VC.STORE.ALL_PARAMS, 0, equals: bulkBefore, timeout: 2) {
            let diffs = zip(bulkBefore.indices, zip(bulkBefore, bulkAfter)).filter { $0.1.0 != $0.1.1 }.map { $0.0 }
            XCTAssertEqual(bulkAfter.count, bulkBefore.count, "ALL_PARAMS length changed")
            XCTAssertTrue(diffs.isEmpty, "ALL_PARAMS differs at offsets \(diffs.prefix(40))")
            log("Final ALL_PARAMS: \(diffs.isEmpty ? "identical to the start" : "DIFFERS at \(diffs.prefix(40))")")
        } else {
            XCTFail("ALL_PARAMS did not answer at the end")
        }

        // Bring the UI back in line with the board.
        vm.fetchAll()
        writeReport()
    }

    // MARK: - Pass 1: GET

    private func getSweep() {
        log("\n== GET sweep")
        if let list = readData(VC.SYS.PAGE_LIST) {
            boardPages = stride(from: 0, to: list.count - 1, by: 2).map { UInt16(list[$0]) }
            log("  board lists pages \(boardPages.map { String(format: "0x%02X", $0) })")
        }
        let walkKinds: Set<VendorAddressKind> = [.slot, .pinOutput, .source, .spdifRx, .i2sPair, .role, .csNoun, .index]
        for info in VendorCommandRegistry.all where info.hasGet && walkKinds.contains(info.address)
            && implemented(info.command, set: false) {
            walk(info)
        }
        // A SET-only command of a walked kind uses its GET sibling's count.
        walked[VC.OUTPUT.TYPE.id] = walked[VC.OUTPUT.TYPE.id] ?? walked[VC.OUTPUT.PIN.id]
        for info in VendorCommandRegistry.all where info.hasGet {
            let c = info.command
            guard implemented(c, set: false) else {
                notBuilt.insert(c.id)
                // The board must really refuse what it says it lacks.
                let raw = transport.getControlResult(request: c.number, value: 0, index: c.usbIndex, length: 64)
                if case .success(let d) = raw {
                    XCTFail("\(name(c)) is not listed in PAGE_COMMANDS but answered \(d.count) bytes")
                }
                log("  \(name(c)): not in this build (build \(info.build ?? "-"))")
                continue
            }
            var allOK = true
            for addr in addresses(for: info) {
                switch read(c, addr) {
                case .success(let d):
                    if let n = fixedLength(c) {
                        if d.count != n {
                            allOK = false
                            XCTFail("\(name(c)) @\(String(format: "0x%04X", addr)) answered \(d.count) bytes, registry says \(n)")
                        }
                    } else if d.isEmpty {
                        allOK = false
                        XCTFail("\(name(c)) @\(String(format: "0x%04X", addr)) answered nothing")
                    }
                case .failure(let s):
                    allOK = false
                    XCTFail("\(name(c)) @\(String(format: "0x%04X", addr)) refused: \(s)")
                    log("  \(name(c)) @\(String(format: "0x%04X", addr)): REFUSED \(s)")
                }
            }
            if allOK { getOK.insert(c.id) }
        }
        log("  \(getOK.count) GETs answered correctly, \(notBuilt.count) not in this build")
    }

    // MARK: - Pass 2: identity SET

    /// Never written, even with their own value: flash writes and the bulk
    /// image are out of scope for a bench sweep.
    private func identityEligible(_ info: VendorCommandInfo) -> Bool {
        guard info.hasGet, info.hasSet, let n = fixedLength(info.command) else { return false }
        if info.flags.contains(.flash) || info.flags.contains(.bulk) { return false }
        return n >= info.setMin && n <= info.setMax
    }

    private func identitySweep() {
        log("\n== Identity SET sweep")
        var skipped: [String] = []
        for info in VendorCommandRegistry.all where info.hasSet {
            let c = info.command
            guard identityEligible(info) else { skipped.append(name(c)); continue }
            guard implemented(c, set: true) else { continue }
            var allOK = true
            for addr in addresses(for: info) {
                guard let before = readData(c, addr) else {
                    allOK = false
                    XCTFail("\(name(c)) @\(String(format: "0x%04X", addr)): no value to write back")
                    continue
                }
                let status = transport.setAndWait(c, value: addr, data: before)
                if status != .ok {
                    allOK = false
                    XCTFail("\(name(c)) @\(String(format: "0x%04X", addr)): writing its own value back was refused (\(status)), value \(hex(before))")
                    log("  \(name(c)) @\(String(format: "0x%04X", addr)): REFUSED \(status) for \(hex(before))")
                    continue
                }
                let after = readUntil(c, addr, equals: before)
                if after != before {
                    allOK = false
                    XCTFail("\(name(c)) @\(String(format: "0x%04X", addr)): read back \(hex(after)) after writing \(hex(before))")
                    log("  \(name(c)) @\(String(format: "0x%04X", addr)): CHANGED \(hex(before)) -> \(hex(after))")
                }
            }
            if allOK { setOK.insert(c.id) }
        }
        log("  \(setOK.count) SETs accepted their own value; not written: \(skipped.joined(separator: ", "))")
    }

    // MARK: - Pass 3: app setters

    private struct AppCase {
        let label: String
        let command: VendorCommand
        var address: UInt16 = 0
        /// An address that must not change while `address` is written.
        var neighbour: UInt16? = nil
        /// Expected raw values; the first that differs from the board's
        /// current value is used, so the write is a real change.
        let candidates: [Data]
        var blocking = false
        /// Other settings the write can disturb, put back after the main one
        /// in this order (the tube's type must come last).
        var restoreAfter: [(VendorCommand, UInt16)] = []
        let act: (DSPViewModel, Int) -> Void
        /// For setters that answer a PIN_CONFIG_* style status: the status of
        /// the last act.  A documented refusal is recorded, not failed.
        var status: ((DSPViewModel, Int) -> UInt8)? = nil
    }

    /// Setters whose refusal is a documented answer rather than a fault,
    /// with the reason, so the report can list them for review.
    private var refusedAsDocumented: [String] = []

    private func run(_ c: AppCase) {
        let cmd = c.command
        guard implemented(cmd, set: true) else { log("  \(c.label): not in this build"); return }
        guard let before = readData(cmd, c.address) else {
            return XCTFail("\(c.label): \(name(cmd)) could not be read")
        }
        let neighbourBefore = c.neighbour.flatMap { readData(cmd, $0) }
        guard let pick = c.candidates.firstIndex(where: { $0 != before }) else {
            return XCTFail("\(c.label): every candidate equals the current value")
        }
        let want = c.candidates[pick]
        let after = c.restoreAfter.map { readData($0.0, $0.1) }
        if let statusOf = c.status {
            var status: UInt8 = 0xFF
            if c.blocking { offMain { status = statusOf(self.vm, pick) } } else { status = statusOf(vm, pick) }
            if status != PIN_CONFIG_SUCCESS {
                // Nothing changed, so nothing to restore; the status is the
                // board's own reason, mapped back by the app.
                let unchanged = readData(cmd, c.address) == before
                if status == 0xFF || !unchanged {
                    XCTFail("\(c.label): status \(status), value \(unchanged ? "unchanged" : "CHANGED")")
                } else {
                    refusedAsDocumented.append("\(c.label): status \(status)")
                    log("  \(c.label): refused with status \(status), value unchanged")
                }
                return
            }
        } else if c.blocking { offMain { c.act(self.vm, pick) } } else { c.act(vm, pick) }
        let got = readUntil(cmd, c.address, equals: want)
        var ok = got == want
        if !ok {
            XCTFail("\(c.label): \(name(cmd)) reads \(hex(got)), expected \(hex(want))")
            log("  \(c.label): MISMATCH want \(hex(want)) got \(hex(got))")
        }
        if let n = c.neighbour {
            let after = readData(cmd, n)
            if after != neighbourBefore {
                ok = false
                XCTFail("\(c.label): neighbour @\(String(format: "0x%04X", n)) changed \(hex(neighbourBefore)) -> \(hex(after))")
            }
        }
        // Put it back with the raw SET the identity pass already proved.
        let status = transport.setAndWait(cmd, value: c.address, data: before)
        let restored = readUntil(cmd, c.address, equals: before)
        if status != .ok || restored != before {
            XCTFail("\(c.label): restore failed (\(status)), reads \(hex(restored)), was \(hex(before))")
        }
        for (i, extra) in c.restoreAfter.enumerated() {
            guard let value = after[i] else { continue }
            _ = transport.setAndWait(extra.0, value: extra.1, data: value)
        }
        for (i, extra) in c.restoreAfter.enumerated() {
            guard let value = after[i] else { continue }
            let back = readUntil(extra.0, extra.1, equals: value)
            if back != value { XCTFail("\(c.label): \(name(extra.0))@\(extra.1) not restored: \(hex(back)), was \(hex(value))") }
        }
        if ok { appSetOK.insert(cmd.id) }
    }

    private func appSetterPass() {
        log("\n== App setters")
        let firstOut = vm.chOut1
        let outCh = firstOut + 1                // an output channel, for crossover bands
        let lastIn = max(shape.inputs - 1, 1)
        let o: UInt16 = UInt16(min(2, shape.outputs - 1))
        func band(_ type: Int, _ bypass: UInt8, _ freq: Float, _ q: Float, _ gain: Float) -> Data {
            var d = Data([UInt8(type), bypass, 0, 0]); d += f32(freq); d += f32(q); d += f32(gain); return d
        }
        func route(_ en: UInt8, _ inv: UInt8, _ gain: Float) -> Data { Data([en, inv, 0, 0]) + f32(gain) }
        let bandParams: [(FilterType, Float, Float, Float)] = [(.peaking, 1234, 1.5, 3.5), (.peaking, 2500, 0.75, -4.25)]
        let xoParams: [(FilterType, Float)] = [(.lowPass, 800), (.lowPass, 1600)]

        var cases: [AppCase] = [
            // ROUTE
            AppCase(label: "setMasterVolume", command: VC.ROUTE.MASTER_VOLUME, candidates: [f32(-20), f32(-31.5)],
                    act: { vm, i in vm.setMasterVolume([-20, -31.5][i]) }),
            AppCase(label: "setUserVolume", command: VC.ROUTE.USER_VOLUME, candidates: [f32(-12.5), f32(-7.25)],
                    act: { vm, i in vm.setUserVolume([-12.5, -7.25][i]) }),
            AppCase(label: "setPreampChannel", command: VC.ROUTE.PREAMP, address: UInt16(lastIn), neighbour: 0,
                    candidates: [f32(-3.5), f32(2)], act: { vm, i in vm.setPreampChannel(channel: lastIn, db: [-3.5, 2][i]) }),
            AppCase(label: "setDelay", command: VC.ROUTE.CHANNEL_DELAY, address: UInt16(outCh), neighbour: 0,
                    candidates: [f32(3), f32(7)], act: { vm, i in vm.setDelay(ch: outCh, ms: [3, 7][i]) }),
            AppCase(label: "setOutputGain", command: VC.ROUTE.OUTPUT_GAIN, address: o, neighbour: 0,
                    candidates: [f32(-6.5), f32(-2)], act: { vm, i in vm.setOutputGain(output: Int(o), db: [-6.5, -2][i]) }),
            AppCase(label: "setOutputMute", command: VC.ROUTE.OUTPUT_MUTE, address: o, neighbour: 0,
                    candidates: [u8(1), u8(0)], act: { vm, i in vm.setOutputMute(output: Int(o), muted: i == 0) }),
            AppCase(label: "setOutputDelay", command: VC.ROUTE.OUTPUT_DELAY, address: o, neighbour: 0,
                    candidates: [f32(4), f32(9)], act: { vm, i in vm.setOutputDelay(output: Int(o), ms: [4, 9][i]) }),
            AppCase(label: "setMatrixRoute", command: VC.ROUTE.MATRIX_ROUTE, address: (1 << 8) | o, neighbour: (o << 8) | 1,
                    candidates: [route(1, 1, -4.5), route(1, 0, -9)],
                    act: { vm, i in vm.setMatrixRoute(input: 1, output: Int(o), enabled: true, gain: [-4.5, -9][i], invert: i == 0) }),
            // FILTER
            AppCase(label: "setFilter", command: VC.FILTER.BAND, address: UInt16(outCh << 8 | 2), neighbour: UInt16(outCh << 8 | 1),
                    candidates: bandParams.map { band($0.0.rawValue, 0, $0.1, $0.2, $0.3) },
                    act: { vm, i in let b = bandParams[i]
                        vm.setFilter(ch: outCh, band: 2, p: FilterParams(type: b.0, freq: b.1, q: b.2, gain: b.3)) }),
            AppCase(label: "setCrossoverBand", command: VC.FILTER.BAND, address: UInt16(outCh << 8 | 21), neighbour: UInt16(outCh << 8 | 20),
                    candidates: xoParams.map { band($0.0.rawValue, 0, $0.1, 0.707, 0) },
                    act: { vm, i in let b = xoParams[i]
                        vm.setCrossoverBand(ch: outCh, localBand: 1, p: FilterParams(type: b.0, freq: b.1, q: 0.707, gain: 0)) }),
            AppCase(label: "setChannelName", command: VC.ROUTE.CHANNEL_NAME, address: UInt16(outCh), neighbour: 0,
                    candidates: [name32("Sweep Ch A"), name32("Sweep Ch B")],
                    act: { vm, i in vm.setChannelName(channel: outCh, name: ["Sweep Ch A", "Sweep Ch B"][i]) }),
            AppCase(label: "setBypass", command: VC.FILTER.EQ_BYPASS, candidates: [u8(1), u8(0)],
                    act: { vm, i in vm.setBypass(i == 0) }),
            // DYN
            AppCase(label: "setLimiterThreshold", command: VC.DYN.LIMITER_THRESHOLD, address: o, neighbour: 0,
                    candidates: [f32(-6), f32(-9)], act: { vm, i in vm.setLimiterThreshold(output: Int(o), [-6, -9][i]) }),
            AppCase(label: "setLimiterRelease", command: VC.DYN.LIMITER_RELEASE, address: o, neighbour: 0,
                    candidates: [f32(100), f32(250)], act: { vm, i in vm.setLimiterRelease(output: Int(o), [100, 250][i]) }),
            AppCase(label: "setLeveller", command: VC.DYN.LEVELLER_ENABLE, candidates: [u8(1), u8(0)],
                    act: { vm, i in vm.setLeveller(i == 0) }),
            AppCase(label: "setLevellerAmount", command: VC.DYN.LEVELLER_AMOUNT, candidates: [f32(30), f32(60)],
                    act: { vm, i in vm.setLevellerAmount([30, 60][i]) }),
            AppCase(label: "setLevellerSpeed", command: VC.DYN.LEVELLER_SPEED, candidates: [u8(0), u8(1)],
                    act: { vm, i in vm.setLevellerSpeed(i) }),
            AppCase(label: "setLevellerMaxGain", command: VC.DYN.LEVELLER_MAX_GAIN, candidates: [f32(6), f32(12)],
                    act: { vm, i in vm.setLevellerMaxGain([6, 12][i]) }),
            AppCase(label: "setLevellerLookahead", command: VC.DYN.LEVELLER_LOOKAHEAD, candidates: [u8(1), u8(0)],
                    act: { vm, i in vm.setLevellerLookahead(i == 0) }),
            AppCase(label: "setLevellerGate", command: VC.DYN.LEVELLER_GATE, candidates: [f32(-60), f32(-50)],
                    act: { vm, i in vm.setLevellerGate([-60, -50][i]) }),
            AppCase(label: "setLevellerMasks", command: VC.DYN.LEVELLER_MASKS, candidates: [Data([0x03, 0x01]), Data([0x01, 0x03])],
                    act: { vm, i in vm.setLevellerMasks(detector: [0x03, 0x01][i], apply: [0x01, 0x03][i]) }),
            AppCase(label: "setLoudness", command: VC.DYN.LOUDNESS_ENABLE, candidates: [u8(1), u8(0)],
                    act: { vm, i in vm.setLoudness(i == 0) }),
            AppCase(label: "setLoudnessRef", command: VC.DYN.LOUDNESS_REF, candidates: [f32(75), f32(85)],
                    act: { vm, i in vm.setLoudnessRef([75, 85][i]) }),
            AppCase(label: "setLoudnessIntensity", command: VC.DYN.LOUDNESS_INTENSITY, candidates: [f32(50), f32(80)],
                    act: { vm, i in vm.setLoudnessIntensity([50, 80][i]) }),
            AppCase(label: "setLoudnessMask", command: VC.DYN.LOUDNESS_MASK, candidates: [u16(0x0005), u16(0x0003)],
                    act: { vm, i in vm.setLoudnessMask([0x0005, 0x0003][i]) }),
            // FX: crossfeed
            AppCase(label: "setCrossfeed", command: VC.FX.CROSSFEED_ENABLE, candidates: [u8(1), u8(0)],
                    act: { vm, i in vm.setCrossfeed(i == 0) }),
            AppCase(label: "setCrossfeedPreset", command: VC.FX.CROSSFEED_PRESET, candidates: [u8(0), u8(1)],
                    act: { vm, i in vm.setCrossfeedPreset(i) }),
            AppCase(label: "setCrossfeedFreq", command: VC.FX.CROSSFEED_FREQ, candidates: [f32(700), f32(900)],
                    act: { vm, i in vm.setCrossfeedFreq([700, 900][i]) }),
            AppCase(label: "setCrossfeedFeed", command: VC.FX.CROSSFEED_FEED, candidates: [f32(6), f32(9)],
                    act: { vm, i in vm.setCrossfeedFeed([6, 9][i]) }),
            AppCase(label: "setCrossfeedITD", command: VC.FX.CROSSFEED_ITD, candidates: [u8(1), u8(0)],
                    act: { vm, i in vm.setCrossfeedITD(i == 0) }),
            AppCase(label: "setCrossfeedMask", command: VC.FX.CROSSFEED_OUTPUTS, candidates: [u8(0x01), u8(0x03)],
                    act: { vm, i in vm.setCrossfeedMask([0x01, 0x03][i]) }),
            // FX: subharmonic synth
            AppCase(label: "setSubharm", command: VC.FX.SUBHARM_ENABLE, candidates: [u8(1), u8(0)],
                    act: { vm, i in vm.setSubharm(i == 0) }),
            AppCase(label: "setSubharmLow", command: VC.FX.SUBHARM_LOW, candidates: [f32(-6), f32(-12)],
                    act: { vm, i in vm.setSubharmLow([-6, -12][i]) }),
            AppCase(label: "setSubharmHigh", command: VC.FX.SUBHARM_HIGH, candidates: [f32(-6), f32(-12)],
                    act: { vm, i in vm.setSubharmHigh([-6, -12][i]) }),
            AppCase(label: "setSubharmTop", command: VC.FX.SUBHARM_TOP, candidates: [f32(-6), f32(-12)],
                    act: { vm, i in vm.setSubharmTop([-6, -12][i]) }),
            AppCase(label: "setSubharmBoost", command: VC.FX.SUBHARM_BOOST, candidates: [f32(3), f32(6)],
                    act: { vm, i in vm.setSubharmBoost([3, 6][i]) }),
            AppCase(label: "setSubharmMask", command: VC.FX.SUBHARM_MASK, candidates: [u16(0x0010), u16(0x0003)],
                    act: { vm, i in vm.setSubharmMask([0x0010, 0x0003][i]) }),
            AppCase(label: "setSubharmSelectMode", command: VC.FX.SUBHARM_SELECT, candidates: [u8(0), u8(1)],
                    act: { vm, i in vm.setSubharmSelectMode(i) }),
            AppCase(label: "setSubharmSelectDepth", command: VC.FX.SUBHARM_DEPTH, candidates: [f32(50), f32(70)],
                    act: { vm, i in vm.setSubharmSelectDepth([50, 70][i]) }),
            AppCase(label: "setSubharmSelectHold", command: VC.FX.SUBHARM_HOLD, candidates: [f32(100), f32(200)],
                    act: { vm, i in vm.setSubharmSelectHold([100, 200][i]) }),
            AppCase(label: "setSubharmCeiling", command: VC.FX.SUBHARM_CEILING, candidates: [f32(-12), f32(-6)],
                    act: { vm, i in vm.setSubharmCeiling([-12, -6][i]) }),
            AppCase(label: "setSubharmLinkPairs", command: VC.FX.SUBHARM_LINK, candidates: [u8(1), u8(0)],
                    act: { vm, i in vm.setSubharmLinkPairs(i == 0) }),
            AppCase(label: "setSubharmSolo", command: VC.FX.SUBHARM_SOLO, candidates: [u8(1), u8(0)],
                    act: { vm, i in vm.setSubharmSolo(i == 0) }),
            // FX: psychoacoustic bass
            AppCase(label: "setPsybass", command: VC.FX.PSYBASS_ENABLE, candidates: [u8(1), u8(0)],
                    act: { vm, i in vm.setPsybass(i == 0) }),
            AppCase(label: "setPsybassCutoff", command: VC.FX.PSYBASS_CUTOFF, candidates: [f32(100), f32(120)],
                    act: { vm, i in vm.setPsybassCutoff([100, 120][i]) }),
            AppCase(label: "setPsybassHarmonics", command: VC.FX.PSYBASS_HARMONICS, candidates: [f32(-12), f32(-6)],
                    act: { vm, i in vm.setPsybassHarmonics([-12, -6][i]) }),
            AppCase(label: "setPsybassDrive", command: VC.FX.PSYBASS_DRIVE, candidates: [f32(3), f32(6)],
                    act: { vm, i in vm.setPsybassDrive([3, 6][i]) }),
            AppCase(label: "setPsybassCharacter", command: VC.FX.PSYBASS_CHARACTER, candidates: [f32(30), f32(60)],
                    act: { vm, i in vm.setPsybassCharacter([30, 60][i]) }),
            AppCase(label: "setPsybassOriginal", command: VC.FX.PSYBASS_ORIGINAL, candidates: [f32(-6), f32(-3)],
                    act: { vm, i in vm.setPsybassOriginal([-6, -3][i]) }),
            AppCase(label: "setPsybassMask", command: VC.FX.PSYBASS_MASK, candidates: [u16(0x0010), u16(0x0003)],
                    act: { vm, i in vm.setPsybassMask([0x0010, 0x0003][i]) }),
            // FX: tube (all float32 on the wire)
            AppCase(label: "setTube", command: VC.FX.TUBE_ENABLE, candidates: [f32(1), f32(0)],
                    act: { vm, i in vm.setTube(i == 0) }),
            AppCase(label: "setTubeMask", command: VC.FX.TUBE_OUTPUT_MASK, candidates: [f32(5), f32(3)],
                    act: { vm, i in vm.setTubeMask([5, 3][i]) }),
            AppCase(label: "setTubeRectifier", command: VC.FX.TUBE_RECTIFIER, candidates: [f32(0), f32(1)],
                    act: { vm, i in vm.setTubeRectifier(i) }),
            AppCase(label: "setTubeXfmr", command: VC.FX.TUBE_XFMR_ENABLE, candidates: [f32(1), f32(0)],
                    act: { vm, i in vm.setTubeXfmr(i == 0) }),
            AppCase(label: "setTubeMix", command: VC.FX.TUBE_MIX, candidates: [f32(50), f32(80)],
                    act: { vm, i in vm.setTubeMix([50, 80][i]) }),
            AppCase(label: "setTubeTrim", command: VC.FX.TUBE_TRIM, candidates: [f32(-3), f32(-1)],
                    act: { vm, i in vm.setTubeTrim([-3, -1][i]) }),
            // INPUT / CLOCK
            AppCase(label: "setLgSoundSyncEnabled", command: VC.INPUT.LG_SOUND_SYNC_ENABLE, candidates: [u8(1), u8(0)],
                    act: { vm, i in vm.setLgSoundSyncEnabled(i == 0) }),
            AppCase(label: "setInputRate", command: VC.INPUT.I2S_RX_RATE, candidates: [u32(48000), u32(44100)],
                    act: { vm, i in vm.setInputRate([48000, 44100][i]) }),
            AppCase(label: "setMckMultiplier", command: VC.CLOCK.MCK_MULTIPLIER, candidates: [u8(1), u8(0)],
                    act: { vm, i in _ = vm.setMckMultiplier([256, 128][i]) }),
            // CS: names and macro step addressing ((step << 8) | macro)
            AppCase(label: "setCsName", command: VC.CS.SLOT_NAME, address: 2, neighbour: 0,
                    candidates: [name32("Sweep A"), name32("Sweep B")], blocking: true,
                    act: { vm, i in _ = vm.setCsName(slot: 2, name: ["Sweep A", "Sweep B"][i]) }),
        ]
        // The tube's knob edits on a stock type switch it to Custom, so only
        // the type-independent parameters are above; upmixer on RP2350 only.
        cases += [
            AppCase(label: "setUpmixStrength", command: VC.FX.UPMIX_STRENGTH, candidates: [f32(50), f32(80)],
                    act: { vm, i in vm.setUpmixStrength([50, 80][i]) }),
            AppCase(label: "setUpmixCenterWidth", command: VC.FX.UPMIX_CENTER_WIDTH, candidates: [f32(40), f32(60)],
                    act: { vm, i in vm.setUpmixCenterWidth([40, 60][i]) }),
            AppCase(label: "setUpmixAttack", command: VC.FX.UPMIX_ATTACK, candidates: [f32(20), f32(50)],
                    act: { vm, i in vm.setUpmixAttack([20, 50][i]) }),
            AppCase(label: "setUpmixRelease", command: VC.FX.UPMIX_RELEASE, candidates: [f32(200), f32(400)],
                    act: { vm, i in vm.setUpmixRelease([200, 400][i]) }),
            AppCase(label: "setUpmixSurroundDelay", command: VC.FX.UPMIX_SUR_DELAY, candidates: [f32(10), f32(15)],
                    act: { vm, i in vm.setUpmixSurroundDelay([10, 15][i]) }),
            AppCase(label: "setUpmixSurroundMode", command: VC.FX.UPMIX_SURROUND_MODE, candidates: [f32(0), f32(1)],
                    act: { vm, i in vm.setUpmixSurroundMode(i) }),
            AppCase(label: "setUpmixCenterMode", command: VC.FX.UPMIX_CENTER_MODE, candidates: [f32(0), f32(1)],
                    act: { vm, i in vm.setUpmixCenterMode(i) }),
        ]

        // Macro step 2 of macro 3: a valid step (master volume SET) that two
        // pre-delays tell apart.  An empty step with only a delay is refused.
        // Nothing fires it, and the original record is written back after.
        let stepAddr: UInt16 = (2 << 8) | 3
        if implemented(VC.CS.MACRO_STEP, set: true) {
            let variants = [UInt16(7), UInt16(9)].map {
                CsMacroStep(noun: UInt8(CS_NOUN_MASTER_VOLUME), action: UInt8(CS_ACT_SET), value: -20, preDelay: $0)
            }
            cases.append(AppCase(label: "setCsMacroStep", command: VC.CS.MACRO_STEP, address: stepAddr,
                                 neighbour: (3 << 8) | 2, candidates: variants.map { $0.toData() }, blocking: true,
                                 act: { vm, i in _ = vm.setCsMacroStep(macro: 3, step: 2, value: variants[i]) }))
        }

        cases += moreCases(outCh: outCh, o: o)
        for c in cases { run(c) }
        auxPass()
        adatInputEnablePass()
        irLearnPass()
        macroFirePass()
        log("  \(appSetOK.count) commands verified through the app's setters (\(cases.count) cases)")
    }

    // MARK: - Pass 3b: the setters the first version left to identity writes

    /// GPIOs no function claims, by the device's own claim list, stored
    /// claims included, so a pin move never lands on something in use or on
    /// a pin a switched-off function will want back.
    private func freePins() -> [UInt8] {
        guard let state = readData(VC.SYS.PIN_STATE).flatMap(PinStateReply.decode),
              let claims = transport.getData(VC.SYS.PIN_CLAIMS, length: PinClaimsReply.requestSize)
                .flatMap(PinClaimsReply.decode) else { return [] }
        let taken = Set(claims.claims.map(\.gpio))
        return state.gpios.filter { !taken.contains($0) }
    }

    private func edited(_ base: Data, at offset: Int, _ bytes: Data) -> Data {
        var d = base; d.replaceSubrange(offset..<offset + bytes.count, with: bytes); return d
    }

    private func moreCases(outCh: Int, o: UInt16) -> [AppCase] {
        var cases: [AppCase] = []
        let gpios = freePins()
        let pairs = gpios.filter { gpios.contains($0 + 1) }
        log("  free GPIOs: \(gpios)")
        func pinCase(_ label: String, _ cmd: VendorCommand, _ addr: UInt16 = 0, neighbour: UInt16? = nil,
                     pins: [UInt8], _ set: @escaping (DSPViewModel, UInt8) -> UInt8) {
            let use = Array(pins.prefix(2))
            guard !use.isEmpty else { log("  \(label): no free GPIO to move to"); return }
            cases.append(AppCase(label: label, command: cmd, address: addr, neighbour: neighbour,
                                 candidates: use.map { Data([$0]) }, blocking: true,
                                 act: { _, _ in }, status: { vm, i in set(vm, use[i]) }))
        }
        pinCase("setOutputPin", VC.OUTPUT.PIN, 1, neighbour: 0, pins: gpios) { vm, p in vm.setOutputPin(output: 1, pin: p) }
        pinCase("setSpdifRxPin(0)", VC.INPUT.SPDIF_RX_PIN, 0, pins: gpios) { vm, p in vm.setSpdifRxPin(index: 0, p) }
        pinCase("setSpdifRxPin(2)", VC.INPUT.SPDIF_RX_PIN, 2, neighbour: 1, pins: gpios) { vm, p in vm.setSpdifRxPin(index: 2, p) }
        pinCase("setI2SRxPin(1)", VC.INPUT.I2S_RX_PIN, 1, neighbour: 0, pins: gpios) { vm, p in vm.setI2SRxPin(pair: 1, p) }
        pinCase("setAdatPin", VC.OUTPUT.ADAT_TX_PIN, pins: gpios) { vm, p in vm.setAdatPin(p) }
        pinCase("setAdatInputPin", VC.INPUT.ADAT_RX_PIN, pins: gpios) { vm, p in vm.setAdatInputPin(p) }
        // MCK must sit on a clock-output pin.
        pinCase("setMckPin", VC.CLOCK.MCK_PIN, pins: gpios.filter { [13, 15, 21, 23, 24, 25].contains($0) }) { vm, p in vm.setMckPin(p) }
        pinCase("setI2SBckPin(slave)", VC.CLOCK.I2S_BCK_PIN, UInt16(I2S_BCK_ROLE_SLAVE), neighbour: 0, pins: pairs) { vm, p in
            vm.setI2SBckPin(p, role: I2S_BCK_ROLE_SLAVE)
        }

        func statusCase(_ label: String, _ cmd: VendorCommand, _ addr: UInt16 = 0, neighbour: UInt16? = nil,
                        values: [UInt8], _ set: @escaping (DSPViewModel, UInt8) -> UInt8) {
            cases.append(AppCase(label: label, command: cmd, address: addr, neighbour: neighbour,
                                 candidates: values.map { Data([$0]) }, blocking: true,
                                 act: { _, _ in }, status: { vm, i in set(vm, values[i]) }))
        }
        statusCase("setAdatEnable", VC.OUTPUT.ADAT_TX_ENABLE, values: [1, 0]) { vm, v in vm.setAdatEnable(v == 1) }
        statusCase("setAdatInputEnable", VC.INPUT.ADAT_RX_ENABLE, values: [1, 0]) { vm, v in vm.setAdatInputEnable(v == 1) }
        statusCase("setAdatInputClockMode", VC.INPUT.ADAT_RX_CLOCK_MODE, values: [1, 0]) { vm, v in vm.setAdatInputClockMode(v) }
        statusCase("setMckEnable", VC.CLOCK.MCK_ENABLE, values: [1, 0]) { vm, v in vm.setMckEnable(v == 1) }
        // The count is a store while the block is off, so toggle it there and
        // leave the block's own switch to the I2S-style toggle below.
        statusCase("setSpdifRxCount", VC.INPUT.SPDIF_RX_COUNT, values: [2, 1]) { vm, v in vm.setSpdifRxCount(Int(v)) }
        statusCase("setI2SInputEnable", VC.INPUT.I2S_RX_ENABLE, values: [1, 0]) { vm, v in vm.setI2SInputEnable(v == 1) }
        statusCase("setI2SInputChannels", VC.INPUT.I2S_RX_CHANNELS, values: [4, 2]) { vm, v in vm.setI2SInputChannels(Int(v)) }
        statusCase("setI2SClockPinMode", VC.CLOCK.I2S_CLOCK_PIN_MODE, values: [1, 0]) { vm, v in vm.setI2SClockPinMode(v) }
        statusCase("setOutputSlotType(3)", VC.OUTPUT.TYPE, 3, neighbour: 0, values: [1, 0]) { vm, v in vm.setOutputSlotType(slot: 3, type: v) }

        let tubeKnobs: [(VendorCommand, UInt16)] = [(VC.FX.TUBE_BIAS, 0), (VC.FX.TUBE_ASYM, 0),
                                                    (VC.FX.TUBE_HARDNESS, 0), (VC.FX.TUBE_SAG, 0)]
        let tubeTail: [(VendorCommand, UInt16)] = tubeKnobs + [(VC.FX.TUBE_TYPE, UInt16(0))]
        func others(_ c: VendorCommand) -> [(VendorCommand, UInt16)] { tubeTail.filter { $0.0 != c } }

        cases += [
            AppCase(label: "setI2SClockMode", command: VC.CLOCK.I2S_CLOCK_MODE, candidates: [u8(1), u8(0)],
                    act: { vm, i in vm.setI2SClockMode([1, 0][i]) }),
            AppCase(label: "setInputSource", command: VC.INPUT.SOURCE, candidates: [u8(1), u8(0)],
                    act: { vm, i in vm.setInputSource([1, 0][i]) }),
            AppCase(label: "setOutputEnable", command: VC.ROUTE.OUTPUT_ENABLE, address: o, candidates: [u8(0), u8(1)],
                    act: { vm, i in vm.setOutputEnable(output: Int(o), enabled: i == 1) }),
            AppCase(label: "setLimiterEnabled", command: VC.DYN.LIMITER_ENABLE, address: o, candidates: [f32(1), f32(0)],
                    act: { vm, i in vm.setLimiterEnabled(output: Int(o), i == 0) }),
            // Joining a group copies the group's settings onto the output.
            AppCase(label: "setLimiterLinkGroup", command: VC.DYN.LIMITER_LINK_GROUP, address: o, candidates: [f32(4), f32(3)],
                    restoreAfter: [(VC.DYN.LIMITER_ENABLE, o), (VC.DYN.LIMITER_THRESHOLD, o), (VC.DYN.LIMITER_RELEASE, o)],
                    act: { vm, i in vm.setLimiterLinkGroup(output: Int(o), [4, 3][i]) }),
            AppCase(label: "setBandBypass", command: VC.FILTER.BAND_BYPASS, address: UInt16(outCh << 8 | 3),
                    neighbour: UInt16(outCh << 8 | 2), candidates: [u8(1), u8(0)],
                    act: { vm, i in vm.setBandBypass(ch: outCh, band: 3, bypass: i == 0) }),
            AppCase(label: "setCrossoverBandBypass", command: VC.FILTER.BAND_BYPASS, address: UInt16(outCh << 8 | 22),
                    neighbour: UInt16(outCh << 8 | 21), candidates: [u8(1), u8(0)],
                    act: { vm, i in vm.setCrossoverBandBypass(ch: outCh, localBand: 2, bypass: i == 0) }),
            // A stock type rewrites bias, asymmetry, hardness and sag, and
            // writing any of those four makes the type custom, so those come
            // back too and the type is restored last.
            AppCase(label: "setTubeType", command: VC.FX.TUBE_TYPE, candidates: [f32(1), f32(2)],
                    restoreAfter: tubeTail, act: { vm, i in vm.setTubeType(i + 1) }),
            AppCase(label: "setTubeDrive", command: VC.FX.TUBE_DRIVE, candidates: [f32(6), f32(9)],
                    act: { vm, i in vm.setTubeDrive([6, 9][i]) }),
            AppCase(label: "setTubeBias", command: VC.FX.TUBE_BIAS, candidates: [f32(20), f32(40)],
                    restoreAfter: others(VC.FX.TUBE_BIAS), act: { vm, i in vm.setTubeBias([20, 40][i]) }),
            AppCase(label: "setTubeAsym", command: VC.FX.TUBE_ASYM, candidates: [f32(1), f32(2)],
                    restoreAfter: others(VC.FX.TUBE_ASYM), act: { vm, i in vm.setTubeAsym([1, 2][i]) }),
            AppCase(label: "setTubeHardness", command: VC.FX.TUBE_HARDNESS, candidates: [f32(30), f32(50)],
                    restoreAfter: others(VC.FX.TUBE_HARDNESS), act: { vm, i in vm.setTubeHardness([30, 50][i]) }),
            AppCase(label: "setTubeSag", command: VC.FX.TUBE_SAG, candidates: [f32(10), f32(20)],
                    restoreAfter: others(VC.FX.TUBE_SAG), act: { vm, i in vm.setTubeSag([10, 20][i]) }),
            AppCase(label: "setTubeXfmrDamping", command: VC.FX.TUBE_XFMR_DAMPING, candidates: [f32(2), f32(8)],
                    act: { vm, i in vm.setTubeXfmrDamping([2, 8][i]) }),
            AppCase(label: "setTubeXfmrRes", command: VC.FX.TUBE_XFMR_RES, candidates: [f32(40), f32(60)],
                    act: { vm, i in vm.setTubeXfmrRes([40, 60][i]) }),
            AppCase(label: "setUpmixEnabled", command: VC.FX.UPMIX_ENABLE, candidates: [f32(1), f32(0)],
                    act: { vm, i in vm.setUpmixEnabled(i == 0) }),
            AppCase(label: "setUpmixThreshold", command: VC.FX.UPMIX_THRESHOLD, candidates: [f32(30), f32(50)],
                    act: { vm, i in vm.setUpmixThreshold([30, 50][i]) }),
            AppCase(label: "setUpmixDetectorHpf", command: VC.FX.UPMIX_DET_HPF, candidates: [f32(100), f32(150)],
                    act: { vm, i in vm.setUpmixDetectorHpf([100, 150][i]) }),
            AppCase(label: "setUpmixSurroundHpf", command: VC.FX.UPMIX_SUR_HPF, candidates: [f32(100), f32(150)],
                    act: { vm, i in vm.setUpmixSurroundHpf([100, 150][i]) }),
            AppCase(label: "setUpmixSurroundLpf", command: VC.FX.UPMIX_SUR_LPF, candidates: [f32(7000), f32(9000)],
                    act: { vm, i in vm.setUpmixSurroundLpf([7000, 9000][i]) }),
            AppCase(label: "setUpmixDecorr", command: VC.FX.UPMIX_DECORR, candidates: [f32(30), f32(60)],
                    act: { vm, i in vm.setUpmixDecorr([30, 60][i]) }),
            AppCase(label: "setUpmixPresence", command: VC.FX.UPMIX_PRESENCE, candidates: [f32(1), f32(2)],
                    act: { vm, i in vm.setUpmixPresence([1, 2][i]) }),
        ]

        // Struct-valued writes: the expected bytes are the board's own record
        // with one field edited here by offset, and the app decodes, edits
        // and re-encodes the record itself.
        if let raw = readData(VC.MEAS.SIGGEN_CONFIG), let cfg = SiggenConfig.fromData(raw) {
            let levels: [Float] = [-33, -36]
            cases.append(AppCase(label: "siggenSetConfig", command: VC.MEAS.SIGGEN_CONFIG,
                                 candidates: levels.map { edited(raw, at: 8, f32($0)) },
                                 act: { vm, i in var c = cfg; c.levelDB = levels[i]; vm.siggenSetConfig(c) }))
        }
        if let raw = readData(VC.MEAS.RTA_CONFIG), let cfg = RtaConfig.fromData(raw) {
            let avgs: [UInt16] = [200, 400]
            cases.append(AppCase(label: "RtaConfig.toData", command: VC.MEAS.RTA_CONFIG,
                                 candidates: avgs.map { edited(raw, at: 6, u16($0)) },
                                 act: { _, i in var c = cfg; c.avgMs = avgs[i]
                                     self.transport.send(VC.MEAS.RTA_CONFIG, data: c.toData()) }))
        }
        if let raw = readData(VC.CS.DISPLAY_CONFIG), raw.first == 0, let cfg = CsDisplayCfg.fromData(raw, offset: 0) {
            let dwells: [UInt16] = [40, 50]
            cases.append(AppCase(label: "setCsDisplayCfg", command: VC.CS.DISPLAY_CONFIG,
                                 candidates: dwells.map { edited(raw, at: 2, u16($0)) }, blocking: true,
                                 act: { vm, i in var c = cfg; c.dwell = dwells[i]; _ = vm.setCsDisplayCfg(c) }))
        }
        func emptySlot(_ c: VendorCommand, _ n: Int) -> UInt16? {
            (0..<UInt16(n)).reversed().first { i in readData(c, i).map { $0.allSatisfy { $0 == 0 } } ?? false }
        }
        if let g = emptySlot(VC.CS.GROUP, CS_MAX_MACROS) {
            let masks: [UInt32] = [0x03, 0x05]
            cases.append(AppCase(label: "setCsGroup", command: VC.CS.GROUP, address: g,
                                 candidates: masks.map { Data([CS_TARGET_OUTPUT_CH, 0, 0, 0]) + u32($0) + name32("Sweep G") },
                                 blocking: true,
                                 act: { vm, i in _ = vm.setCsGroup(Int(g), group: CsGroup(targetKind: CS_TARGET_OUTPUT_CH,
                                                                                         memberMask: masks[i], name: "Sweep G")) }))
        }
        if let p = emptySlot(VC.CS.DISPLAY_PAGE, CS_MAX_DISPLAY_PAGES) {
            let flags: [UInt8] = [CS_DPAGE_ACTIVE, CS_DPAGE_ACTIVE | CS_DPAGE_LARGE]
            cases.append(AppCase(label: "setCsDisplayPage", command: VC.CS.DISPLAY_PAGE, address: p,
                                 candidates: flags.map { Data([UInt8(CS_NOUN_MASTER_VOLUME), 0, 0, $0]) }, blocking: true,
                                 act: { vm, i in _ = vm.setCsDisplayPage(Int(p), page: CsDisplayPage(
                                     noun: UInt8(CS_NOUN_MASTER_VOLUME), target: 0, index: 0, flags: flags[i])) }))
        }
        if let sub = emptySlot(VC.CS.IR_CMD, CS_MAX_IR_COMMANDS) {
            let codes: [UInt32] = [0x00FF_12ED, 0x00FF_34CB]
            func record(_ code: UInt32) -> Data {
                Data([UInt8(CS_NOUN_MASTER_VOLUME), UInt8(CS_ACT_SET), 0, 0, 0, CS_IR_PROTO_NEC])
                    + withUnsafeBytes(of: Int16(-20).littleEndian) { Data($0) } + Data([0, 0, 0, 0]) + u32(code)
            }
            cases.append(AppCase(label: "setCsIrCommand", command: VC.CS.IR_CMD, address: sub,
                                 candidates: codes.map(record), blocking: true,
                                 act: { vm, i in _ = vm.setCsIrCommand(sub: Int(sub), command: IrCommand(
                                     noun: UInt8(CS_NOUN_MASTER_VOLUME), action: UInt8(CS_ACT_SET), proto: CS_IR_PROTO_NEC,
                                     value: -20, code: codes[i])) }))
        }
        // A button only reads its GPIO, so a free pin is safe to bind.
        if let b = emptySlot(VC.CS.BINDING, CS_MAX_BINDINGS), let pin = gpios.last {
            let nouns: [UInt8] = [UInt8(CS_NOUN_EQ_BYPASS), UInt8(CS_NOUN_LOUDNESS)]
            func record(_ noun: UInt8) -> Data {
                var d = Data(count: 24)
                d[0] = UInt8(CS_TYPE_BUTTON); d[1] = noun; d[2] = UInt8(CS_ACT_TOGGLE); d[4] = pin; d[5] = CS_GPIO_UNUSED
                return d
            }
            cases.append(AppCase(label: "setCsBinding", command: VC.CS.BINDING, address: b,
                                 candidates: nouns.map(record), blocking: true,
                                 act: { vm, i in _ = vm.setCsBinding(slot: Int(b), binding: CsBinding(
                                     type: UInt8(CS_TYPE_BUTTON), noun: nouns[i], action: UInt8(CS_ACT_TOGGLE),
                                     gpio0: pin, gpio1: CS_GPIO_UNUSED)) }))
        }
        return cases
    }

    /// IR learn needs a live receiver: bind one on a free GPIO (it only
    /// listens), arm through the app, read the armed state, cancel, unbind.
    private func irLearnPass() {
        guard implemented(VC.CS.IR_LEARN_ARM, set: true),
              let slot = (0..<UInt16(CS_MAX_BINDINGS)).reversed().first(where: { i in
                  readData(VC.CS.BINDING, i).map { $0.allSatisfy { $0 == 0 } } ?? false }),
              let pin = freePins().first, let empty = readData(VC.CS.BINDING, slot) else {
            log("  IR learn: no free slot or GPIO"); return
        }
        let vm = self.vm
        var status: UInt8 = 0xFF
        offMain { status = vm.setCsBinding(slot: Int(slot), binding: CsBinding(type: UInt8(CS_TYPE_IR), gpio0: pin, gpio1: CS_GPIO_UNUSED)) }
        guard status == PIN_CONFIG_SUCCESS else { XCTFail("IR receiver on GPIO \(pin): status \(status)"); return }
        var arm = CsIrLearnArmResult.locked
        offMain { arm = vm.csIrLearnArm() }
        var learn: CsIrLearnResult?
        offMain { learn = vm.csIrLearnRead() }
        if arm == .armed, learn?.state == CS_IR_LEARN_STATE_ARMED {
            actionOK.insert(VC.CS.IR_LEARN_ARM.id); getOK.insert(VC.CS.IR_LEARN_STATUS.id)
            log("  IR learn: armed on a receiver at GPIO \(pin), status read ARMED, cancelled")
        } else {
            XCTFail("IR learn with a receiver: arm \(arm), state \(String(describing: learn?.state))")
        }
        offMain { vm.csIrLearnCancel() }
        let idle = readData(VC.CS.IR_LEARN_STATUS).map { $0.first != CS_IR_LEARN_STATE_ARMED } ?? false
        if idle { actionOK.insert(VC.CS.IR_LEARN_CANCEL.id) } else { XCTFail("IR learn still armed after cancel") }
        restore(VC.CS.BINDING, slot, empty, "IR receiver binding")
    }

    /// Fire a one-step macro that toggles EQ bypass, check the bypass moved,
    /// then put the bypass and the macro back.
    private func macroFirePass() {
        guard implemented(VC.CS.MACRO_FIRE, set: true),
              let index = (0..<UInt16(CS_MAX_MACROS)).reversed().first(where: { i in
                  readData(VC.CS.MACRO, i).flatMap(CsMacro.fromData).map { !$0.isConfigured } ?? false }),
              let before = readData(VC.CS.MACRO, index), let bypass0 = readData(VC.FILTER.EQ_BYPASS) else {
            log("  macro fire: no empty macro"); return
        }
        let vm = self.vm
        var macro = CsMacro()
        macro.name = "Sweep"
        macro.stepCount = 1
        macro.steps[0] = CsMacroStep(noun: UInt8(CS_NOUN_EQ_BYPASS), action: UInt8(CS_ACT_TOGGLE))
        var status: UInt8 = 0xFF
        offMain { status = vm.setCsMacro(Int(index), macro: macro) }
        guard status == PIN_CONFIG_SUCCESS else { XCTFail("setCsMacro: status \(status)"); return }
        // setCsMacro writes the steps, then CS.MACRO_HEADER with name and count.
        if readData(VC.CS.MACRO, index).map({ $0[32] == 1 && str($0.prefix(32)) == "Sweep" }) == true {
            appSetOK.insert(VC.CS.MACRO_HEADER.id); appSetOK.insert(VC.CS.MACRO_STEP.id)
        } else { XCTFail("setCsMacro: header not stored") }
        offMain { status = vm.csMacroFire(index) }
        let flipped = u8(bypass0.first == 0 ? 1 : 0)
        if status == PIN_CONFIG_SUCCESS, readUntil(VC.FILTER.EQ_BYPASS, 0, equals: flipped) == flipped {
            actionOK.insert(VC.CS.MACRO_FIRE.id)
            log("  macro fire: macro \(index) toggled EQ bypass \(hex(bypass0)) -> \(hex(flipped))")
        } else {
            XCTFail("csMacroFire: status \(status), EQ bypass \(hex(readData(VC.FILTER.EQ_BYPASS)))")
        }
        restore(VC.FILTER.EQ_BYPASS, 0, bypass0, "EQ bypass")
        if let m = CsMacro.fromData(before) { offMain { _ = vm.setCsMacro(Int(index), macro: m) } }
        if readUntil(VC.CS.MACRO, index, equals: before) != before { XCTFail("macro \(index) not cleared again") }
    }

    /// ADAT input enable is refused while the input has no pin, so give it a
    /// free one first, then undo both.
    private func adatInputEnablePass() {
        guard implemented(VC.INPUT.ADAT_RX_ENABLE, set: true), readData(VC.INPUT.ADAT_RX_ENABLE) == u8(0),
              let pin0 = readData(VC.INPUT.ADAT_RX_PIN), let pin = freePins().first else { return }
        var status: UInt8 = 0xFF
        offMain { status = self.vm.setAdatInputPin(pin) }
        guard status == PIN_CONFIG_SUCCESS else { XCTFail("ADAT input pin \(pin): status \(status)"); return }
        offMain { status = self.vm.setAdatInputEnable(true) }
        if status == PIN_CONFIG_SUCCESS, readUntil(VC.INPUT.ADAT_RX_ENABLE, 0, equals: u8(1)) == u8(1) {
            appSetOK.insert(VC.INPUT.ADAT_RX_ENABLE.id)
            log("  setAdatInputEnable: enabled on GPIO \(pin), then disabled")
        } else {
            XCTFail("setAdatInputEnable with GPIO \(pin): status \(status), reads \(hex(readData(VC.INPUT.ADAT_RX_ENABLE)))")
        }
        offMain { _ = self.vm.setAdatInputEnable(false) }
        _ = readUntil(VC.INPUT.ADAT_RX_ENABLE, 0, equals: u8(0))
        restore(VC.INPUT.ADAT_RX_PIN, 0, pin0, "ADAT input pin")
    }

    /// Aux outputs need a slot that holds one, and this board has none: bind
    /// a dimmable aux output on a free GPIO, drive it briefly through the
    /// app, then clear the slot again.
    private func auxPass() {
        guard implemented(VC.CS.AUX_STATE, set: true), auxSlot == nil,
              let slot = (0..<UInt16(CS_MAX_BINDINGS)).reversed().first(where: { i in
                  readData(VC.CS.BINDING, i).map { $0.allSatisfy { $0 == 0 } } ?? false }),
              let pin = freePins().first, let empty = readData(VC.CS.BINDING, slot) else {
            log("  aux: no free slot or GPIO"); return
        }
        var status: UInt8 = 0xFF
        offMain { status = self.vm.setCsBinding(slot: Int(slot), binding: CsBinding(
            type: UInt8(CS_TYPE_AUX_PWM), gpio0: pin, gpio1: CS_GPIO_UNUSED)) }
        guard status == PIN_CONFIG_SUCCESS else {
            XCTFail("aux: binding an aux output on GPIO \(pin) was refused (\(status))"); return
        }
        vm.setCsAuxState(Int(slot), on: true)
        if readUntil(VC.CS.AUX_STATE, slot, equals: u8(1)) == u8(1) { appSetOK.insert(VC.CS.AUX_STATE.id) }
        else { XCTFail("setCsAuxState: AUX_STATE did not read 1") }
        vm.setCsAuxLevel(Int(slot), percent: 50)
        let half = u16(50 * 256)
        if readUntil(VC.CS.AUX_LEVEL, slot, equals: half) == half { appSetOK.insert(VC.CS.AUX_LEVEL.id) }
        else { XCTFail("setCsAuxLevel: AUX_LEVEL reads \(hex(readData(VC.CS.AUX_LEVEL, slot))), expected \(hex(half))") }
        vm.setCsAuxState(Int(slot), on: false)
        _ = readUntil(VC.CS.AUX_STATE, slot, equals: u8(0))
        restore(VC.CS.BINDING, slot, empty, "aux binding")
        log("  aux: slot \(slot) on GPIO \(pin) switched on, set to 50 %, switched off and cleared")
    }

    // MARK: - Pass 4: action SETs

    private func actionPass() {
        log("\n== Action SETs")
        func act(_ c: VendorCommand, _ data: Data = Data(), check: (() -> Bool)? = nil, _ what: String = "") {
            guard implemented(c, set: true) else { log("  \(name(c)): not in this build"); return }
            let status = transport.setAndWait(c, data: data)
            HardwareTest.settle()
            if status != .ok {
                XCTFail("\(name(c)) refused: \(status)")
                log("  \(name(c)): REFUSED \(status)")
                return
            }
            if let check, !check() {
                XCTFail("\(name(c)) accepted but \(what) did not follow")
                log("  \(name(c)): accepted, but \(what) did not follow")
                return
            }
            actionOK.insert(c.id)
        }
        act(VC.SYS.STATS_RESET, u8(0x01))
        act(VC.MEAS.CLIP_CLEAR, check: { self.readData(VC.MEAS.CLIP_FLAGS) == Data(count: 4) }, "the clip flags clearing")
        act(VC.MEAS.RTA_START)
        act(VC.MEAS.RTA_RESET)
        act(VC.MEAS.RTA_STOP)
        act(VC.MEAS.SIGGEN_STOP)
        act(VC.MEAS.SIGGEN_STOP_NOW)
        act(VC.CS.MACRO_CANCEL)
        act(VC.CS.IR_LEARN_CANCEL)
        log("  \(actionOK.count) action SETs accepted")
    }

    // MARK: - Flash pass

    private var flashOK = Set<UInt16>()

    /// Raw blocking SET that skips the app's local length check: the registry
    /// gives STORE.ALL_PARAMS no SET length, but the firmware takes exactly
    /// the whole 6136-byte image (client guide, SET_ALL_PARAMS).
    private func rawSet(_ c: VendorCommand, value: UInt16 = 0, data: Data) -> LinkStatus {
        let done = DispatchSemaphore(value: 0)
        var result = LinkStatus.timeout
        transport.sendControlResult(request: c.number, value: value, index: c.usbIndex, data: data) { s in
            result = s; done.signal()
        }
        let deadline = Date().addingTimeInterval(10)
        while done.wait(timeout: .now()) == .timedOut, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return result
    }

    /// Writes `before` back and checks it stuck.
    private func restore(_ c: VendorCommand, _ addr: UInt16 = 0, _ before: Data, _ label: String) {
        let status = transport.setAndWait(c, value: addr, data: before)
        let back = readUntil(c, addr, equals: before, timeout: 3)
        if status != .ok || back != before {
            XCTFail("\(label): restore failed (\(status)), reads \(hex(back)), was \(hex(before))")
            log("  \(label): RESTORE FAILED, reads \(hex(back)), was \(hex(before))")
        }
    }

    /// A flash write through an app call, then a raw readback.
    private func flashCheck(_ label: String, _ c: VendorCommand, _ addr: UInt16 = 0, want: Data,
                            blocking: Bool = false, _ act: @escaping () -> Void) -> Bool {
        if blocking { offMain(act) } else { act() }
        let got = readUntil(c, addr, equals: want, timeout: 3)
        if got != want {
            XCTFail("\(label): \(name(c)) reads \(hex(got)), expected \(hex(want))")
            log("  \(label): MISMATCH want \(hex(want)) got \(hex(got))")
            return false
        }
        flashOK.insert(c.id)
        return true
    }

    /// Every live Control Surfaces record the app can write back.
    private func csRecords() -> [(VendorCommand, UInt16, Data?)] {
        var keys: [(VendorCommand, UInt16)] = [(VC.CS.DISPLAY_CONFIG, 0)]
        for i in 0..<UInt16(CS_MAX_MACROS) { keys += [(VC.CS.GROUP, i), (VC.CS.MACRO, i)] }
        for i in 0..<UInt16(CS_MAX_BINDINGS) { keys += [(VC.CS.BINDING, i), (VC.CS.SLOT_NAME, i)] }
        for i in 0..<UInt16(CS_MAX_IR_COMMANDS) { keys.append((VC.CS.IR_CMD, i)) }
        for i in 0..<UInt16(CS_MAX_DISPLAY_PAGES) { keys.append((VC.CS.DISPLAY_PAGE, i)) }
        return keys.map { ($0.0, $0.1, readData($0.0, $0.1)) }
    }

    private func csDirty() -> Bool? { readData(VC.CS.STATUS).map { $0.count > 3 && $0[3] != 0 } }

    /// Revert and save while Control Surfaces holds unsaved live edits: take
    /// the live records, revert (the stored config comes back, dirty clears),
    /// save (rewrites what is already stored), then put every live record
    /// back through the app's own setters so the edits survive.
    private func csRevertSaveKeepingLiveEdits() {
        let vm = self.vm
        let live = csRecords()
        var status: UInt8 = 0xFF
        offMain { status = vm.csRevert() }
        let stored = csRecords()
        let differing = zip(live, stored).filter { $0.0.2 != $0.1.2 }.map { $0.0 }
        if status == PIN_CONFIG_SUCCESS, csDirty() == false {
            flashOK.insert(VC.CS.REVERT.id)
            log("  CS.REVERT: dirty cleared, \(differing.count) live records differed from the stored ones")
        } else {
            XCTFail("csRevert: status \(status), dirty \(String(describing: csDirty()))")
        }
        offMain { status = vm.csSave() }
        if status == PIN_CONFIG_SUCCESS, csDirty() == false, csRecords().map({ $0.2 }) == stored.map({ $0.2 }) {
            flashOK.insert(VC.CS.SAVE.id)
        } else {
            XCTFail("csSave of the stored config: status \(status)")
        }
        // Groups and macros first: bindings may refer to them.
        let order: [VendorCommand] = [VC.CS.GROUP, VC.CS.MACRO, VC.CS.DISPLAY_CONFIG, VC.CS.DISPLAY_PAGE,
                                      VC.CS.BINDING, VC.CS.SLOT_NAME, VC.CS.IR_CMD]
        for cmd in order {
            for rec in differing where rec.0 == cmd {
                guard let d = rec.2 else { continue }
                let i = Int(rec.1)
                offMain {
                    switch cmd {
                    case VC.CS.GROUP: if let g = CsGroup.fromData(d) { _ = vm.setCsGroup(i, group: g) }
                    case VC.CS.MACRO: if let m = CsMacro.fromData(d) { _ = vm.setCsMacro(i, macro: m) }
                    case VC.CS.DISPLAY_CONFIG: if let c = CsDisplayCfg.fromData(d, offset: 0) { _ = vm.setCsDisplayCfg(c) }
                    case VC.CS.DISPLAY_PAGE: if let pg = CsDisplayPage.fromData(d) { _ = vm.setCsDisplayPage(i, page: pg) }
                    case VC.CS.BINDING: if let b = CsBinding.fromData(d) { _ = vm.setCsBinding(slot: i, binding: b) }
                    case VC.CS.SLOT_NAME: _ = vm.setCsName(slot: i, name: String(decoding: d.prefix { $0 != 0 }, as: UTF8.self))
                    case VC.CS.IR_CMD: if let c = IrCommand.fromData(d) { _ = vm.setCsIrCommand(sub: i, command: c) }
                    default: break
                    }
                }
            }
        }
        var back: [String] = []
        for rec in differing {
            let now = readUntil(rec.0, rec.1, equals: rec.2 ?? Data(), timeout: 2)
            if now == rec.2 { appSetOK.insert(rec.0.id) }
            else { back.append("\(name(rec.0))@\(rec.1): \(hex(now)) want \(hex(rec.2))") }
        }
        // Safety net: whatever the app failed to put back is written raw, so
        // the live edits survive even when the test has found a bug.
        for rec in differing {
            guard let d = rec.2, readData(rec.0, rec.1) != d else { continue }
            if rec.0 == VC.CS.MACRO, let m = CsMacro.fromData(d) {
                for (step, value) in m.steps.enumerated() {
                    _ = transport.setAndWait(VC.CS.MACRO_STEP, value: UInt16(step << 8) | rec.1, data: value.toData())
                }
                _ = transport.setAndWait(VC.CS.MACRO_HEADER, value: rec.1, data: m.headerData())
            } else {
                _ = transport.setAndWait(rec.0, value: rec.1, data: d)
            }
        }
        XCTAssertTrue(back.isEmpty, "live CS records not restored by the app: \(back)")
        if !differing.isEmpty { XCTAssertEqual(csDirty(), true, "the restored live edits read as unsaved again") }
        log("  CS live edits restored through the app: \(differing.count - back.count) of \(differing.count)"
            + (back.isEmpty ? "" : "; NOT restored: \(back)"))
    }

    private func directory() -> Data? { readData(VC.STORE.DIRECTORY) }
    private func occupied(_ dir: Data?) -> UInt16 {
        guard let d = dir, d.count >= 2 else { return 0 }
        return UInt16(d[0]) | (UInt16(d[1]) << 8)
    }

    /// Waits for a deferred preset save or delete to show in the directory.
    private func waitForSlot(_ slot: Int, occupied want: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if (occupied(directory()) & (1 << slot) != 0) == want { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return false
    }

    /// The commands the plain sweep never sends: flash writes, presets,
    /// factory reset, the generator and the CS save/revert/learn/fire actions.
    /// Opt-in on its own (TEST_RUNNER_DSPI_FLASH_SWEEP=1).  Each change is
    /// undone, the live image is put back with STORE.ALL_PARAMS, and the
    /// directory, names and image must all match the start.  It persists two
    /// things that were already live: the IO config (OUTPUT_CONFIG_SAVE) and,
    /// when Control Surfaces had no unsaved changes, the CS config (CS.SAVE).
    func testFlashCommands() throws {
        guard ProcessInfo.processInfo.environment["DSPI_FLASH_SWEEP"] == "1" else {
            throw XCTSkip("Opt-in: run with TEST_RUNNER_DSPI_FLASH_SWEEP=1 (writes flash on the board).")
        }
        _ = try HardwareTest.requireDevice()
        let vm = self.vm
        // The app's first full read lands a few seconds after the link is up;
        // until then the view model does not know the board takes a name, and
        // setDeviceName does nothing.
        let ready = Date().addingTimeInterval(10)
        while !vm.deviceNameSupported, Date() < ready {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        guard let bulk0 = readData(VC.STORE.ALL_PARAMS), Int(bulk0.count) == Int(BULK_PARAMS_SIZE),
              let dir0 = directory(), let active0 = readData(VC.STORE.PRESET_ACTIVE)?.first else {
            return XCTFail("could not snapshot the board")
        }
        shape = Shape(channels: Int(bulk0[2]), inputs: Int(bulk0[4]), outputs: Int(bulk0[3]))
        let name0 = readData(VC.SYS.DEVICE_NAME), source0 = readData(VC.INPUT.SOURCE_NAME, 1)
        let startup0 = readData(VC.STORE.STARTUP), ocm0 = readData(VC.STORE.OUTPUT_CONFIG_MODE)
        let mvm0 = readData(VC.ROUTE.MASTER_VOLUME_MODE), latency0 = readData(VC.OUTPUT.LATENCY)
        let mv0 = readData(VC.ROUTE.MASTER_VOLUME), mvSaved0 = readData(VC.ROUTE.MASTER_VOLUME_SAVED)
        let siggen0 = readData(VC.MEAS.SIGGEN_CONFIG)
        // Settings outside the bulk image that a factory reset or preset load
        // could touch; all must read the same at the end.
        var watched: [(VendorCommand, UInt16)] = [(VC.CS.DISPLAY_CONFIG, 0), (VC.MEAS.RTA_CONFIG, 0),
            (VC.OUTPUT.DAC_MUTE_CONFIG, 0), (VC.XPORT.UART_CONFIG, 0), (VC.XPORT.I2C_CONFIG, 0)]
        for i in 0..<UInt16(CS_MAX_BINDINGS) { watched += [(VC.CS.BINDING, i), (VC.CS.SLOT_NAME, i)] }
        for i in 0..<UInt16(CS_MAX_IR_COMMANDS) { watched.append((VC.CS.IR_CMD, i)) }
        for i in 0..<UInt16(CS_MAX_MACROS) { watched += [(VC.CS.MACRO, i), (VC.CS.GROUP, i)] }
        for i in 0..<UInt16(16) { watched.append((VC.CS.DISPLAY_PAGE, i)) }
        for i in 0..<UInt16(shape.channels) { watched.append((VC.ROUTE.CHANNEL_NAME, i)) }
        for i in 0..<UInt16(10) { watched.append((VC.STORE.PRESET_NAME, i)) }
        for i in 0..<UInt16(7) { watched.append((VC.INPUT.SOURCE_NAME, i)) }
        let watched0 = watched.map { readData($0.0, $0.1) }
        // Keep a copy outside the board in case the run dies half way.
        let backup = (NSTemporaryDirectory() as NSString).appendingPathComponent("dspi-flash-sweep-backup.bin")
        try? bulk0.write(to: URL(fileURLWithPath: backup))
        log("Flash pass: active preset \(active0), directory \(hex(dir0)); image backed up to \(backup)")

        // --- Names and directory settings, each changed then put back ---
        log("\n== Flash settings")
        if let name0, flashCheck("setDeviceName", VC.SYS.DEVICE_NAME, want: name32("Sweep Bench"), { vm.setDeviceName("Sweep Bench") }) {
            restore(VC.SYS.DEVICE_NAME, 0, name0, "DEVICE_NAME")
        }
        if let source0, flashCheck("setInputSourceName", VC.INPUT.SOURCE_NAME, 1, want: name32("Sweep Source"),
                                   { vm.setInputSourceName(source: 1, name: "Sweep Source") }) {
            restore(VC.INPUT.SOURCE_NAME, 1, source0, "SOURCE_NAME")
        }
        if let s = startup0, s.count == 2 {
            let mode = s[0] == 0 ? 1 : 0
            if flashCheck("setPresetStartup", VC.STORE.STARTUP, want: Data([UInt8(mode), s[1]]),
                          { vm.setPresetStartup(mode: mode, defaultSlot: Int(s[1])) }) {
                restore(VC.STORE.STARTUP, 0, s, "STARTUP")
            }
        }
        if let m = ocm0?.first {
            let other = m == 1 ? 0 : 1
            if flashCheck("setOutputConfigMode", VC.STORE.OUTPUT_CONFIG_MODE, want: u8(UInt8(other)),
                          { vm.setOutputConfigMode(other) }) {
                restore(VC.STORE.OUTPUT_CONFIG_MODE, 0, Data([m]), "OUTPUT_CONFIG_MODE")
            }
        }
        if let m = mvm0?.first {
            let other = m == 1 ? 0 : 1
            if flashCheck("setMasterVolumeMode", VC.ROUTE.MASTER_VOLUME_MODE, want: u8(UInt8(other)),
                          { vm.setMasterVolumeMode(other) }) {
                restore(VC.ROUTE.MASTER_VOLUME_MODE, 0, Data([m]), "MASTER_VOLUME_MODE")
            }
        }
        if let l = latency0?.first,
           let st = readData(VC.OUTPUT.LATENCY_STATUS).flatMap(OutputLatencyStatus.fromData),
           let table = readData(VC.OUTPUT.LATENCY_OPTIONS).map(OutputLatencyOption.tableFromData),
           let other = table.prefix(Int(st.optionCount)).first(where: { $0.available && $0.id != l }) {
            if flashCheck("setOutputLatency", VC.OUTPUT.LATENCY, want: u8(other.id), blocking: true,
                          { vm.setOutputLatency(other.id) }) {
                offMain { vm.setOutputLatency(l) }
                XCTAssertEqual(readUntil(VC.OUTPUT.LATENCY, 0, equals: Data([l]), timeout: 4), Data([l]), "LATENCY restore")
            }
        } else {
            log("  setOutputLatency: no second option to switch to")
        }
        // DAC mute and the control interfaces drive GPIOs, so they get their
        // own value back, decoded and re-encoded by the app.
        if let raw = readData(VC.OUTPUT.DAC_MUTE_CONFIG), let cfg = DacHwMuteConfig.fromData(raw) {
            _ = flashCheck("setDacHwMuteConfig (own value)", VC.OUTPUT.DAC_MUTE_CONFIG, want: raw, blocking: true,
                           { vm.setDacHwMuteConfig(cfg) })
        }
        if let raw = readData(VC.XPORT.UART_CONFIG), raw.first == 0, var cfg = UartCtrlConfig.fromData(raw) {
            // Off, so a new baud rate drives nothing.
            let baud: UInt32 = cfg.baud == 57600 ? 38400 : 57600
            cfg.baud = baud
            let c = cfg
            var st: UInt8 = 0xFF
            if flashCheck("setUartCtrlConfig (baud)", VC.XPORT.UART_CONFIG, want: edited(raw, at: 4, u32(baud)), blocking: true,
                          { st = vm.setUartCtrlConfig(c) }) {
                restore(VC.XPORT.UART_CONFIG, 0, raw, "UART_CONFIG")
            }
            _ = st
        }
        // A disabled config is zeroed by the firmware, so the timing fields
        // only stick while enabled.  Enabled with no pin drives nothing.
        if let raw = readData(VC.OUTPUT.DAC_MUTE_CONFIG), raw.first == 0 {
            let cfg = DacHwMuteConfig(enabled: true, activeLow: true, pin: DAC_HW_MUTE_PIN_NONE, holdMs: 150, releaseMs: 50)
            let want = Data([1, 1, DAC_HW_MUTE_PIN_NONE, 0]) + u16(150) + u16(50) + Data(count: 8)
            if flashCheck("setDacHwMuteConfig (enabled, no pin)", VC.OUTPUT.DAC_MUTE_CONFIG, want: want, blocking: true,
                          { vm.setDacHwMuteConfig(cfg) }) {
                // Enabled, the test pulse is accepted (it has no pin to drive).
                var pulse: UInt8 = 0xFF
                offMain { pulse = vm.testDacHwMute() }
                if pulse == PIN_CONFIG_SUCCESS { flashOK.insert(VC.OUTPUT.DAC_MUTE_TEST.id); log("  OUTPUT.DAC_MUTE_TEST: accepted while enabled") }
                else { XCTFail("testDacHwMute while enabled: status \(pulse)") }
                Thread.sleep(forTimeInterval: 1.2)
                restore(VC.OUTPUT.DAC_MUTE_CONFIG, 0, raw, "DAC_MUTE_CONFIG")
            }
        }
        if let raw = readData(VC.XPORT.UART_CONFIG), let cfg = UartCtrlConfig.fromData(raw) {
            _ = flashCheck("setUartCtrlConfig (own value)", VC.XPORT.UART_CONFIG, want: raw, blocking: true,
                           { _ = vm.setUartCtrlConfig(cfg) })
        }
        if let raw = readData(VC.XPORT.I2C_CONFIG), let cfg = I2cCtrlConfig.fromData(raw) {
            _ = flashCheck("setI2cCtrlConfig (own value)", VC.XPORT.I2C_CONFIG, want: raw, blocking: true,
                           { _ = vm.setI2cCtrlConfig(cfg) })
        }
        // Master volume save: save a different live value, then put both back.
        if let mv0, let mvSaved0 {
            let probe: Float = mvSaved0 == f32(-27) ? -33 : -27
            vm.setMasterVolume(probe)
            _ = readUntil(VC.ROUTE.MASTER_VOLUME, 0, equals: f32(probe))
            var ok = false
            offMain { ok = vm.saveMasterVolume() }
            XCTAssertTrue(ok, "saveMasterVolume")
            if ok, readUntil(VC.ROUTE.MASTER_VOLUME_SAVED, 0, equals: f32(probe), timeout: 3) == f32(probe) {
                flashOK.insert(VC.ROUTE.MASTER_VOLUME_SAVE.id)
            } else {
                XCTFail("MASTER_VOLUME_SAVED did not follow the save")
            }
            _ = transport.setAndWait(VC.ROUTE.MASTER_VOLUME, data: mvSaved0)
            _ = readUntil(VC.ROUTE.MASTER_VOLUME, 0, equals: mvSaved0)
            _ = transport.setAndWait(VC.ROUTE.MASTER_VOLUME_SAVE)
            XCTAssertEqual(readUntil(VC.ROUTE.MASTER_VOLUME_SAVED, 0, equals: mvSaved0, timeout: 3), mvSaved0, "saved master volume restore")
            restore(VC.ROUTE.MASTER_VOLUME, 0, mv0, "MASTER_VOLUME")
        }

        // --- Control Surfaces: revert, save, IR learn, macro fire ---
        log("\n== Control Surfaces actions")
        let csClean = readData(VC.CS.STATUS).map { $0.count > 3 && $0[3] == 0 } ?? false
        if csClean, let slotName = readData(VC.CS.SLOT_NAME, 3) {
            _ = transport.setAndWait(VC.CS.SLOT_NAME, value: 3, data: name32("Sweep Preview"))
            _ = readUntil(VC.CS.SLOT_NAME, 3, equals: name32("Sweep Preview"))
            var status: UInt8 = 0xFF
            offMain { status = vm.csRevert() }
            let back = readUntil(VC.CS.SLOT_NAME, 3, equals: slotName, timeout: 3)
            let clean = readData(VC.CS.STATUS).map { $0[3] == 0 } ?? false
            if status == PIN_CONFIG_SUCCESS, back == slotName, clean { flashOK.insert(VC.CS.REVERT.id) }
            else { XCTFail("csRevert: status \(status), name \(hex(back)), clean \(clean)") }
            offMain { status = vm.csSave() }
            if status == PIN_CONFIG_SUCCESS, readData(VC.CS.STATUS).map({ $0[3] == 0 }) == true {
                flashOK.insert(VC.CS.SAVE.id)
            } else {
                XCTFail("csSave of an unchanged config: status \(status)")
            }
        } else {
            csRevertSaveKeepingLiveEdits()
        }
        var arm = CsIrLearnArmResult.locked
        offMain { arm = vm.csIrLearnArm() }
        switch arm {
        case .armed:
            flashOK.insert(VC.CS.IR_LEARN_ARM.id)
            XCTAssertEqual(transport.setAndWait(VC.CS.IR_LEARN_CANCEL), .ok, "IR learn cancel")
        case .noReceiver:
            // The documented refusal without a live receiver: command and
            // address reached the firmware.
            flashOK.insert(VC.CS.IR_LEARN_ARM.id)
            log("  CS.IR_LEARN_ARM: no IR receiver configured, refused as documented")
        case .locked:
            XCTFail("csIrLearnArm: device lock held")
        }
        if let empty = (0..<UInt16(CS_MAX_MACROS)).first(where: { i in
            readData(VC.CS.MACRO, i).flatMap(CsMacro.fromData).map { !$0.isConfigured } ?? false
        }) {
            var status: UInt8 = 0xFF
            offMain { status = vm.csMacroFire(empty) }
            if status == PIN_CONFIG_SUCCESS { flashOK.insert(VC.CS.MACRO_FIRE.id) }
            else { XCTFail("csMacroFire on empty macro \(empty): status \(status)") }
        } else {
            log("  CS.MACRO_FIRE: every macro is configured, none fired")
        }

        // --- DAC mute test and the signal generator ---
        log("\n== Output actions")
        var dacStatus: UInt8 = 0xFF
        offMain { dacStatus = vm.testDacHwMute() }
        if dacStatus == PIN_CONFIG_SUCCESS || dacStatus == 3 {
            flashOK.insert(VC.OUTPUT.DAC_MUTE_TEST.id)
            if dacStatus == 3 { log("  OUTPUT.DAC_MUTE_TEST: no DAC mute pin configured, refused as documented") }
        } else {
            XCTFail("testDacHwMute: status \(dacStatus)")
        }
        if let siggen0, var cfg = SiggenConfig.fromData(siggen0) {
            // Inaudible: one output at -120 dBFS.
            cfg.levelDB = -120
            cfg.channelMask = 0x0001
            cfg.invertMask = 0
            offMain { vm.siggenStart(with: cfg) }
            HardwareTest.settle()
            let running = readData(VC.MEAS.SIGGEN_STATUS).flatMap(SiggenStatus.fromData)?.isRunning ?? false
            var stopped = false
            offMain { stopped = vm.siggenControl(SIGGEN_CTL_STOP_NOW) }
            if running && stopped { flashOK.insert(VC.MEAS.SIGGEN_START.id) }
            else { XCTFail("siggenStart: running \(running), stopped \(stopped)") }
            restore(VC.MEAS.SIGGEN_CONFIG, 0, siggen0, "SIGGEN_CONFIG")
        }

        // --- Presets and factory reset, on an empty scratch slot ---
        log("\n== Presets")
        // An empty slot can still hold a name, and a delete clears it, so
        // prefer an unnamed one and put the name back otherwise.
        let empties = (0..<10).filter { occupied(dir0) & (1 << $0) == 0 }
        let unnamed = empties.first { readData(VC.STORE.PRESET_NAME, UInt16($0)).map { $0.first == 0 } ?? false }
        if let scratch = unnamed ?? empties.first {
            let scratchName0 = readData(VC.STORE.PRESET_NAME, UInt16(scratch))
            var status: UInt8 = 0xFF
            offMain { status = vm.savePreset(slot: scratch) }
            let saved = status == PRESET_OK && waitForSlot(scratch, occupied: true)
            XCTAssertTrue(saved, "savePreset(\(scratch)): status \(status)")
            if saved {
                flashOK.insert(VC.STORE.PRESET_SAVE.id)
                XCTAssertEqual(readData(VC.STORE.PRESET_ACTIVE)?.first, UInt8(scratch), "a save makes the slot active")
                if flashCheck("setPresetName", VC.STORE.PRESET_NAME, UInt16(scratch), want: name32("Sweep Scratch"),
                              { vm.setPresetName(slot: scratch, name: "Sweep Scratch") }) {}
                offMain { status = vm.factoryReset() }
                let reset = readData(VC.STORE.ALL_PARAMS)
                if status == FLASH_OK {
                    flashOK.insert(VC.STORE.FACTORY_RESET.id)
                    log("  factory reset changed \(zip(bulk0, reset ?? Data()).filter { $0 != $1 }.count) bytes of the image")
                } else {
                    XCTFail("factoryReset: status \(status)")
                }
                offMain { status = vm.loadPreset(slot: scratch) }
                if status == PRESET_OK, let loaded = readData(VC.STORE.ALL_PARAMS) {
                    flashOK.insert(VC.STORE.PRESET_LOAD.id)
                    let diffs = zip(bulk0, loaded).filter { $0 != $1 }.count
                    log("  loading the scratch preset left \(diffs) bytes different from the start (the IO block when it is kept apart from presets)")
                } else {
                    XCTFail("loadPreset(\(scratch)): status \(status)")
                }
                offMain { status = vm.deletePreset(slot: scratch) }
                if status == PRESET_OK, waitForSlot(scratch, occupied: false) { flashOK.insert(VC.STORE.PRESET_DELETE.id) }
                else { XCTFail("deletePreset(\(scratch)): status \(status)") }
                if let scratchName0, readData(VC.STORE.PRESET_NAME, UInt16(scratch)) != scratchName0 {
                    restore(VC.STORE.PRESET_NAME, UInt16(scratch), scratchName0, "PRESET_NAME of the scratch slot")
                }
            }
            // Back to the original slot, then the exact live image.
            if occupied(dir0) & (1 << Int(active0)) != 0 {
                offMain { status = vm.loadPreset(slot: Int(active0)) }
                XCTAssertEqual(status, PRESET_OK, "reload the original preset \(active0)")
            }
        } else {
            log("  no empty preset slot; preset save/load/delete and factory reset not sent")
        }
        let put = rawSet(VC.STORE.ALL_PARAMS, data: bulk0)
        XCTAssertEqual(put, .ok, "STORE.ALL_PARAMS SET of the starting image")
        if put == .ok { flashOK.insert(VC.STORE.ALL_PARAMS.id) }
        // The live IO block now equals the starting one, so saving it stores
        // what was live when the run began.
        if case .success = vm.saveOutputConfigResult() { flashOK.insert(VC.STORE.OUTPUT_CONFIG_SAVE.id) }
        else { XCTFail("saveOutputConfigResult failed") }

        // --- Everything must be back ---
        let bulkEnd = readUntil(VC.STORE.ALL_PARAMS, 0, equals: bulk0, timeout: 3)
        let diffs = zip(bulk0.indices, zip(bulk0, bulkEnd ?? Data())).filter { $0.1.0 != $0.1.1 }.map { $0.0 }
        XCTAssertTrue(bulkEnd?.count == bulk0.count && diffs.isEmpty, "ALL_PARAMS differs at \(diffs.prefix(40))")
        XCTAssertEqual(directory(), dir0, "STORE.DIRECTORY")
        XCTAssertEqual(readData(VC.STORE.PRESET_ACTIVE)?.first, active0, "active preset")
        XCTAssertEqual(readData(VC.SYS.DEVICE_NAME), name0, "device name")
        XCTAssertEqual(readData(VC.INPUT.SOURCE_NAME, 1), source0, "source name 1")
        var changed: [String] = []
        for (i, w) in watched.enumerated() {
            let now = readData(w.0, w.1)
            if now != watched0[i] { changed.append("\(name(w.0))@\(w.1): \(hex(watched0[i])) -> \(hex(now))") }
        }
        XCTAssertTrue(changed.isEmpty, "settings outside the image changed: \(changed)")
        log("Settings outside the image: \(changed.isEmpty ? "all \(watched.count) unchanged" : "CHANGED \(changed)")")
        log("\nFinal: image \(diffs.isEmpty ? "identical" : "DIFFERS at \(diffs.prefix(40))"), directory \(directory() == dir0 ? "identical" : "DIFFERS"), active \(readData(VC.STORE.PRESET_ACTIVE)?.first.map(String.init) ?? "?")")
        log("Flash pass reached: \(flashOK.map { name(VendorCommand($0)) }.sorted().joined(separator: ", "))")

        vm.fetchAll()
        let text = report.joined(separator: "\n")
        print("\n----- DSPi flash sweep -----\n\(text)\n----------------------------")
        let path = ProcessInfo.processInfo.environment["DSPI_SWEEP_REPORT"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("dspi-flash-sweep.txt")
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Audio behaviour

    /// Peak of one channel from MEAS.LEVELS, in dBFS, as the max over a
    /// short window (the meter is a decaying peak).
    private func peakDB(channel: Int, channels: Int, window: TimeInterval = 0.4) -> Double {
        var best: UInt16 = 0
        let end = Date().addingTimeInterval(window)
        repeat {
            if let d = readData(VC.MEAS.LEVELS), d.count >= channels * 2 {
                best = max(best, u16le(d, channel * 2) ?? 0)
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
        } while Date() < end
        return best == 0 ? -200 : 20 * log10(Double(best) / 32767)
    }

    /// Settings must change what the board actually outputs, read on its
    /// own output meter: the generator plays a quiet 1 kHz sine into one
    /// enabled output, then output gain, mute, an EQ peak and the limiter are
    /// changed through the app.  Plays sound at -50 dBFS for a few seconds.
    func testAudioFollowsSettings() throws {
        guard ProcessInfo.processInfo.environment["DSPI_AUDIO_SWEEP"] == "1" else {
            throw XCTSkip("Opt-in: run with TEST_RUNNER_DSPI_AUDIO_SWEEP=1 (plays a quiet test tone).")
        }
        _ = try HardwareTest.requireDevice()
        let vm = self.vm
        let ready = Date().addingTimeInterval(10)
        while !vm.deviceNameSupported, Date() < ready {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let bulk0 = readData(VC.STORE.ALL_PARAMS), let siggen0 = readData(VC.MEAS.SIGGEN_CONFIG),
              var cfg = SiggenConfig.fromData(siggen0) else { return XCTFail("snapshot failed") }
        let channels = vm.numChannels, firstOut = vm.chOut1
        guard let o = (0..<vm.numOutputChannels).first(where: { readData(VC.ROUTE.OUTPUT_ENABLE, UInt16($0)) == u8(1) }) else {
            return XCTFail("no enabled output")
        }
        let ch = firstOut + o
        var descs: [(UInt8, String)] = []
        for t in 0..<(readData(VC.MEAS.SIGGEN_CAPS).map { Int($0[1]) } ?? 0) {
            if let d = readData(VC.MEAS.SIGGEN_TYPE_DESC, UInt16(t)) {
                descs.append((d[0], String(decoding: d[1..<9].prefix { $0 != 0 }, as: UTF8.self)))
            }
        }
        guard let sine = descs.first(where: { $0.1.lowercased().contains("sine") }) else {
            return XCTFail("no sine type in \(descs)")
        }
        log("== Audio: output \(o) (meter channel \(ch)), generator types \(descs.map { $0.1 })")

        let gain0 = readData(VC.ROUTE.OUTPUT_GAIN, UInt16(o)), mute0 = readData(VC.ROUTE.OUTPUT_MUTE, UInt16(o))
        let band0 = readData(VC.FILTER.BAND, UInt16(ch << 8 | 9))
        let lim: [(VendorCommand, UInt16)] = [(VC.DYN.LIMITER_ENABLE, UInt16(o)), (VC.DYN.LIMITER_THRESHOLD, UInt16(o)), (VC.DYN.LIMITER_RELEASE, UInt16(o))]
        let lim0 = lim.map { readData($0.0, $0.1) }
        defer {
            offMain { _ = vm.siggenControl(SIGGEN_CTL_STOP_NOW) }
            _ = transport.setAndWait(VC.MEAS.SIGGEN_CONFIG, data: siggen0)
            for (k, v) in zip(lim, lim0) { if let v { _ = transport.setAndWait(k.0, value: k.1, data: v) } }
            if let gain0 { _ = transport.setAndWait(VC.ROUTE.OUTPUT_GAIN, value: UInt16(o), data: gain0) }
            if let mute0 { _ = transport.setAndWait(VC.ROUTE.OUTPUT_MUTE, value: UInt16(o), data: mute0) }
            if let band0 { _ = transport.setAndWait(VC.FILTER.BAND, value: UInt16(ch << 8 | 9), data: band0) }
            let end = readUntil(VC.STORE.ALL_PARAMS, 0, equals: bulk0, timeout: 3)
            XCTAssertEqual(end, bulk0, "ALL_PARAMS back to the start")
            vm.fetchAll()
            print("\n----- DSPi audio check -----\n\(report.joined(separator: "\n"))\n----------------------------")
        }

        // Start from 0 dB output gain, unmuted, band 9 flat, limiter off.
        vm.setOutputGain(output: o, db: 0)
        vm.setOutputMute(output: o, muted: false)
        vm.setLimiterEnabled(output: o, false)
        vm.setFilter(ch: ch, band: 9, p: FilterParams(type: .flat, freq: 1000, q: 0.707, gain: 0))
        HardwareTest.settle()
        cfg.signalType = sine.0
        cfg.channelMask = UInt16(1 << o)
        cfg.invertMask = 0
        cfg.flags = 0
        cfg.levelDB = -50
        cfg.durationMS = 0
        cfg.repeatCount = 0
        cfg.p1 = 1000
        let c = cfg
        offMain { vm.siggenStart(with: c) }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
        let base = peakDB(channel: ch, channels: channels)
        log("  generator at -50 dBFS: output meter \(String(format: "%.1f", base)) dBFS")
        // The tone passes the master and user volumes on its way out.
        let master = Double(f32le(readData(VC.ROUTE.MASTER_VOLUME)) ?? 0), user = Double(f32le(readData(VC.ROUTE.USER_VOLUME)) ?? 0)
        let expected = -50 + master + user
        log("  expected \(String(format: "%.1f", expected)) dBFS (-50 with master \(master) dB and user \(user) dB)")
        plausible("generator reaches the output meter through the volumes", abs(base - expected) < 3, "\(base) dBFS, expected \(expected)")

        vm.setOutputGain(output: o, db: -10)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.6))
        let lower = peakDB(channel: ch, channels: channels)
        log("  output gain -10 dB: \(String(format: "%.1f", lower)) dBFS (change \(String(format: "%.1f", lower - base)) dB)")
        plausible("output gain -10 dB lowers the output by 10 dB", abs((lower - base) + 10) < 1.5, "change \(lower - base) dB")
        vm.setOutputGain(output: o, db: 0)

        vm.setOutputMute(output: o, muted: true)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.8))
        let muted = peakDB(channel: ch, channels: channels)
        log("  output muted: \(String(format: "%.1f", muted)) dBFS")
        plausible("mute silences the output", muted < base - 30, "\(muted) dBFS")
        vm.setOutputMute(output: o, muted: false)

        vm.setFilter(ch: ch, band: 9, p: FilterParams(type: .peaking, freq: 1000, q: 1, gain: 6))
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.8))
        let boosted = peakDB(channel: ch, channels: channels)
        log("  EQ peak +6 dB at 1 kHz: \(String(format: "%.1f", boosted)) dBFS (change \(String(format: "%.1f", boosted - base)) dB)")
        plausible("a +6 dB EQ peak at the tone raises the output by 6 dB", abs((boosted - base) - 6) < 1.5, "change \(boosted - base) dB")
        vm.setFilter(ch: ch, band: 9, p: FilterParams(type: .flat, freq: 1000, q: 0.707, gain: 0))

        // The threshold cannot go below -30 dB, so for this step the output
        // must cross -30 dBFS: raise the generator for under a second.
        vm.setLimiterThreshold(output: o, -30)
        let pushed = -30 + 10 - (master + user)            // pre-limiter output -20 dBFS
        var loud = c
        loud.levelDB = Float(min(-20, pushed - 10))
        let gainForLimit = Float(pushed) - loud.levelDB
        offMain { vm.siggenSetConfig(loud) }
        vm.setOutputGain(output: o, db: gainForLimit)
        vm.setLimiterEnabled(output: o, true)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.8))
        let limited = peakDB(channel: ch, channels: channels)
        let reduction = readData(VC.DYN.LIMITER_METERS).flatMap { u16le($0, o * 2) }.map { Double($0) / 100 } ?? 0
        log("  generator \(loud.levelDB) dBFS with +\(gainForLimit) dB gain into a -30 dB limiter: \(String(format: "%.1f", limited)) dBFS, gain reduction \(String(format: "%.1f", reduction)) dB")
        plausible("the limiter holds the output at its threshold", limited < -28 && limited > -33, "\(limited) dBFS")
        plausible("the limiter meter shows the reduction", reduction > 3, "\(reduction) dB")
        offMain { _ = vm.siggenControl(SIGGEN_CTL_STOP_NOW) }
        vm.setLimiterEnabled(output: o, false)
        vm.setOutputGain(output: o, db: 0)
    }

    // MARK: - DSPi Link

    /// The same sweep from a networked client: a second hub server on the
    /// app's own hub (throwaway pairing store, test keychain namespace), an
    /// admin client paired over localhost, a NetworkTransport bound to the
    /// board and a view model on top of it.
    func testEveryCommandOverLink() throws {
        guard ProcessInfo.processInfo.environment["DSPI_COMMAND_SWEEP"] == "1" else {
            throw XCTSkip("Opt-in: run with TEST_RUNNER_DSPI_COMMAND_SWEEP=1 (writes to the board).")
        }
        _ = try HardwareTest.requireDevice()
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-link-\(UUID().uuidString).json")
        let auth = LinkAuthStore(storeURL: storeURL)
        let server = LinkServer(hub: AppState.shared.linkHub, auth: auth, policy: LinkPolicy.bundled ?? LinkPolicy.empty)
        try server.start(port: 0)
        let port = try XCTUnwrap(server.boundPort)
        let url = URL(string: "ws://127.0.0.1:\(port)/dspi/v1")!
        let tokens = LinkTokenStore(service: "com.weeblabs.dspi-console.link.sweep-test")
        let hubID = "sweep-hub"
        defer {
            transportOverride = nil
            vmOverride = nil
            server.stop()
            tokens.removeToken(forHub: hubID)
            try? FileManager.default.removeItem(at: storeURL)
        }
        func spin(until done: () -> Bool, _ timeout: TimeInterval) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while !done(), Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            return done()
        }

        // Pair once for an admin token.
        let pairer = LinkClient()
        pairer.connect(to: url, clientName: "Sweep", token: nil)
        XCTAssertTrue(spin(until: { pairer.state == .awaitingAuth(needsPairing: true) }, 5), "pairing prompt")
        var token: String?
        pairer.pair(pin: auth.beginPairing(), clientName: "Sweep", role: .admin) { token = try? $0.get() }
        XCTAssertTrue(spin(until: { token != nil }, 5), "pairing")
        pairer.disconnect()
        tokens.setToken(try XCTUnwrap(token), forHub: hubID)

        let client = LinkClient()
        let net = NetworkTransport(client: client, hubID: hubID, hubName: "Sweep hub", tokens: tokens, clientName: "Sweep")
        net.connect(to: url)
        XCTAssertTrue(spin(until: { !client.devices.isEmpty }, 10), "the hub lists the board")
        let serial = try XCTUnwrap(client.devices.first?.serial)
        net.bind(serial: serial)
        XCTAssertTrue(spin(until: { net.isConnected && net.deviceProtocol.isPaged }, 10), "bound to the paged board over Link")
        log("Over DSPi Link: hub at \(url), board \(serial), protocol \(net.deviceProtocol)")

        transportOverride = net
        vmOverride = DSPViewModel(transport: net)
        runSweep()
    }

    // MARK: - Reply decoding

    private var decodeChecks = 0

    private func expect<T: Equatable>(_ label: String, _ app: T?, _ raw: T?) {
        decodeChecks += 1
        if app != raw || raw == nil {
            XCTFail("\(label): app decoded \(String(describing: app)), raw says \(String(describing: raw))")
            log("  \(label): MISMATCH app \(String(describing: app)) raw \(String(describing: raw))")
        }
    }

    private func plausible(_ label: String, _ ok: Bool, _ detail: String) {
        decodeChecks += 1
        if !ok { XCTFail("\(label): \(detail)"); log("  \(label): IMPLAUSIBLE \(detail)") }
    }

    /// Lets the main-queue assignments of the fetch functions land.
    private func land() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }

    private func u16le(_ d: Data?, _ o: Int) -> UInt16? {
        guard let d, d.count >= o + 2 else { return nil }
        return UInt16(d[d.startIndex + o]) | (UInt16(d[d.startIndex + o + 1]) << 8)
    }
    private func u32le(_ d: Data?, _ o: Int) -> UInt32? {
        guard let d, d.count >= o + 4 else { return nil }
        return (0..<4).reduce(UInt32(0)) { $0 | (UInt32(d[d.startIndex + o + $1]) << (8 * UInt32($1))) }
    }
    private func f32le(_ d: Data?, _ o: Int = 0) -> Float? { u32le(d, o).map(Float.init(bitPattern:)) }
    private func str(_ d: Data?) -> String? { d.map { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }

    /// Every reply the app decodes: call the app's own fetch, then compare
    /// what it published with a decode of the raw reply written here from the
    /// client guide.  Replies only the Stats window decodes (its readers are
    /// private) are checked against the guide's offsets by cross-reading the
    /// same value from another command and by plausibility.  Read-only.
    func testReplyDecoding() throws {
        guard ProcessInfo.processInfo.environment["DSPI_COMMAND_SWEEP"] == "1" else {
            throw XCTSkip("Opt-in: run with TEST_RUNNER_DSPI_COMMAND_SWEEP=1.")
        }
        _ = try HardwareTest.requireDevice()
        let vm = self.vm
        let ready = Date().addingTimeInterval(10)
        while !vm.deviceNameSupported, Date() < ready {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        log("== Reply decoding")
        if let bulk = readData(VC.STORE.ALL_PARAMS), bulk.count > 4 {
            shape = Shape(channels: Int(bulk[2]), inputs: Int(bulk[4]), outputs: Int(bulk[3]))
        }
        let walkKinds: Set<VendorAddressKind> = [.slot, .pinOutput, .source, .i2sPair, .csNoun, .index]
        for info in VendorCommandRegistry.all where info.hasGet && walkKinds.contains(info.address) && implemented(info.command, set: false) {
            walk(info)
        }
        walked[VC.OUTPUT.TYPE.id] = walked[VC.OUTPUT.TYPE.id] ?? walked[VC.OUTPUT.PIN.id]
        let outputs = vm.numOutputChannels

        // SYS
        let plat = readData(VC.SYS.PLATFORM)
        vm.fetchPlatform(); land()
        expect("PLATFORM platform", vm.platformName, plat.map { $0[0] == 1 ? "RP2350" : ($0[0] == 2 ? "STM32H723" : "RP2040") })
        expect("PLATFORM minor", vm.firmwareVersion?.minor, plat.map { Int($0[4]) })
        expect("PLATFORM patch", vm.firmwareVersion?.patch, plat.map { Int($0[5]) })
        expect("PLATFORM beta", vm.firmwareVersion?.beta, plat.map { Int($0[6]) })
        expect("CORE1_MODE", { vm.fetchCore1Mode(); land(); return vm.core1Mode }(), readData(VC.SYS.CORE1_MODE).map { Int($0[0]) })
        let sys = readData(VC.SYS.SYSTEM_STATUS)
        vm.fetchSampleRate(); land()
        expect("SYSTEM_STATUS rate (u32 @4)", vm.telemetry.sampleRateHz, u32le(sys, 4))
        plausible("SYSTEM_STATUS rate", [44100, 48000, 88200, 96000].contains(u32le(sys, 4) ?? 0), "\(String(describing: u32le(sys, 4)))")
        plausible("SYSTEM_STATUS clk_sys (u32 @0)", (100_000_000...400_000_000).contains(u32le(sys, 0) ?? 0), "\(String(describing: u32le(sys, 0)))")
        plausible("SYSTEM_STATUS core mV (u16 @8)", (900...1400).contains(u16le(sys, 8) ?? 0), "\(String(describing: u16le(sys, 8)))")
        let centi = u16le(sys, 10).map { Int16(bitPattern: $0) } ?? 0
        plausible("SYSTEM_STATUS temperature (i16 @10)", (500...9500).contains(Int(centi)), "\(centi) centi-degrees")
        plausible("SYSTEM_STATUS CPU loads (@12, @13)", (sys?[12] ?? 255) <= 100 && (sys?[13] ?? 255) <= 100, hex(sys))

        // MEAS.LEVELS: peaks[channels] u16, cpu0, cpu1, clip u32, active inputs
        let levels = readData(VC.MEAS.LEVELS), input = readData(VC.INPUT.STATUS)
        expect("LEVELS length", levels?.count, vm.numChannels * 2 + 7)
        vm.fetchStatus(); land()
        let off = vm.numChannels * 2
        expect("LEVELS active inputs vs INPUT.STATUS @1", levels.map { Int($0[off + 6]) }, input.map { Int($0[1]) })
        expect("LEVELS active inputs (app)", vm.activeInputChannels, levels.map { max(BASE_MATRIX_INPUTS, Int($0[off + 6])) })
        expect("LEVELS clip flags vs MEAS.CLIP_FLAGS", u32le(levels, off + 2), u32le(readData(VC.MEAS.CLIP_FLAGS), 0))
        plausible("LEVELS peaks <= full scale", (0..<vm.numChannels).allSatisfy { (u16le(levels, $0 * 2) ?? 0) <= 32767 }, hex(levels))

        // Stats structs (decoded privately by the Stats window).
        let usb = readData(VC.SYS.USB_AUDIO_STATUS)
        plausible("USB_AUDIO_STATUS alt (u8 @12)", (usb?[12] ?? 255) < 8, hex(usb))
        plausible("USB_AUDIO_STATUS mounted (u8 @13) is a flag", (usb?[13] ?? 255) <= 1, hex(usb))
        let pipe = readData(VC.SYS.PIPELINE_STATS)
        let lowest = u32le(pipe, 8) ?? 0
        plausible("PIPELINE_STATS lowest prewrite (u32 @8)", lowest == UInt32.max || lowest < 100_000, "\(lowest)")
        let pdm1 = readData(VC.SYS.PDM_STATS), tx1 = readData(VC.SYS.SPDIF_TX_STATS)
        let buf1 = readData(VC.SYS.BUFFER_STATS)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
        let pdm2 = readData(VC.SYS.PDM_STATS), tx2 = readData(VC.SYS.SPDIF_TX_STATS)
        let buf2 = readData(VC.SYS.BUFFER_STATS)
        plausible("USB_AUDIO_STATUS packets (u32 @0) only grow", (u32le(readData(VC.SYS.USB_AUDIO_STATUS), 0) ?? 0) >= (u32le(usb, 0) ?? 0), hex(usb))
        plausible("PDM_STATS counters only grow", (0..<4).allSatisfy { (u32le(pdm2, $0 * 4) ?? 0) >= (u32le(pdm1, $0 * 4) ?? 0) }, "\(hex(pdm1)) / \(hex(pdm2))")
        plausible("SPDIF_TX_STATS counters only grow", (0..<6).allSatisfy { (u32le(tx2, $0 * 4) ?? 0) >= (u32le(tx1, $0 * 4) ?? 0) }, "\(hex(tx1)) / \(hex(tx2))")
        plausible("SPDIF_TX_STATS total >= each slot", (0..<4).allSatisfy { (u32le(tx2, 4) ?? 0) >= (u32le(tx2, 8 + $0 * 4) ?? 0) }, hex(tx2))
        plausible("BUFFER_STATS output count (u8 @0)", (buf1?[0] ?? 9) <= 4, hex(buf1))
        plausible("BUFFER_STATS sequence advances (u16 @2)", u16le(buf2, 2) != u16le(buf1, 2), "\(String(describing: u16le(buf1, 2))) then \(String(describing: u16le(buf2, 2)))")

        // DYN
        let lstat = readData(VC.DYN.LIMITER_STATUS)
        expect("LIMITER_STATUS output count (@3)", lstat.map { Int($0[3]) }, outputs)
        expect("LIMITER_STATUS lookahead and block (@1, @2)", lstat.map { [$0[1], $0[2]] }, [32, 16])
        expect("LIMITER_METERS length (u16 per output)", readData(VC.DYN.LIMITER_METERS)?.count, outputs * 2)
        expect("USER_VOLUME", { vm.fetchUserVolume(); land(); return vm.userVolumeDB }(), f32le(readData(VC.ROUTE.USER_VOLUME)))

        // FX
        vm.fetchUpmixConfig(); land()
        let up = readData(VC.FX.UPMIX_CONFIG)
        expect("UPMIX_CONFIG enable vs UPMIX_ENABLE", vm.upmixEnabled, f32le(readData(VC.FX.UPMIX_ENABLE)).map { $0 != 0 })
        expect("UPMIX_CONFIG centre mode vs UPMIX_CENTER_MODE", Float(vm.upmix.centerMode), f32le(readData(VC.FX.UPMIX_CENTER_MODE)))
        expect("UPMIX_CONFIG surround mode vs UPMIX_SURROUND_MODE", Float(vm.upmix.surroundMode), f32le(readData(VC.FX.UPMIX_SURROUND_MODE)))
        expect("UPMIX_CONFIG presence vs UPMIX_PRESENCE", vm.upmix.presenceDB, f32le(readData(VC.FX.UPMIX_PRESENCE)))
        for (label, value, cmd) in [("strength", vm.upmix.strengthPct, VC.FX.UPMIX_STRENGTH),
                                    ("width", vm.upmix.centerWidthPct, VC.FX.UPMIX_CENTER_WIDTH),
                                    ("threshold", vm.upmix.thresholdPct, VC.FX.UPMIX_THRESHOLD),
                                    ("attack", vm.upmix.attackMs, VC.FX.UPMIX_ATTACK),
                                    ("release", vm.upmix.releaseMs, VC.FX.UPMIX_RELEASE),
                                    ("detector HPF", vm.upmix.detectorHpfHz, VC.FX.UPMIX_DET_HPF),
                                    ("surround delay", vm.upmix.surroundDelayMs, VC.FX.UPMIX_SUR_DELAY),
                                    ("surround HPF", vm.upmix.surroundHpfHz, VC.FX.UPMIX_SUR_HPF),
                                    ("surround LPF", vm.upmix.surroundLpfHz, VC.FX.UPMIX_SUR_LPF),
                                    ("decorrelation", vm.upmix.decorrPct, VC.FX.UPMIX_DECORR)] {
            expect("UPMIX_CONFIG \(label) vs its own command", value, f32le(readData(cmd)))
        }
        _ = up
        expect("SUBHARM_HEADROOM", { vm.fetchSubharmHeadroom(); land(); return vm.subharm.headroomDB }(), f32le(readData(VC.FX.SUBHARM_HEADROOM)))
        expect("SUBHARM_SOLO", { vm.fetchSubharmSolo(); land(); return vm.subharm.solo }(), readData(VC.FX.SUBHARM_SOLO).map { $0[0] != 0 })
        expect("SUBHARM_METER length", readData(VC.FX.SUBHARM_METER)?.count, outputs * 2)

        // OUTPUT / ROUTE
        for o in 0..<outputs {
            vm.fetchOutputEnable(output: o)
        }
        land()
        for o in 0..<outputs {
            expect("OUTPUT_ENABLE[\(o)]", vm.outputEnabled[o], readData(VC.ROUTE.OUTPUT_ENABLE, UInt16(o)).map { $0[0] != 0 })
        }
        for i in 0..<(walked[VC.OUTPUT.PIN.id] ?? 5) { vm.fetchOutputPin(output: i) }
        for sl in 0..<(walked[VC.OUTPUT.TYPE.id] ?? 4) { vm.fetchOutputSlotType(slot: sl) }
        land()
        for i in 0..<(walked[VC.OUTPUT.PIN.id] ?? 5) {
            expect("OUTPUT.PIN[\(i)]", vm.outputPins[i], readData(VC.OUTPUT.PIN, UInt16(i))?.first)
        }
        for sl in 0..<(walked[VC.OUTPUT.TYPE.id] ?? 4) {
            expect("OUTPUT.TYPE[\(sl)]", vm.outputSlotTypes[sl], readData(VC.OUTPUT.TYPE, UInt16(sl))?.first)
        }
        vm.fetchOutputLatency(); land()
        let lat = readData(VC.OUTPUT.LATENCY_STATUS)
        expect("LATENCY_STATUS requested id (@0)", vm.outputLatencyStatus.requestedId, lat?.first)
        expect("LATENCY_STATUS requested id vs OUTPUT.LATENCY", lat?.first, readData(VC.OUTPUT.LATENCY)?.first)
        expect("LATENCY_STATUS effective us (u16 @2)", vm.outputLatencyStatus.effectiveUs, u16le(lat, 2))
        expect("LATENCY_OPTIONS count (status @9)", vm.outputLatencyOptions.count, lat.map { Int($0[9]) })
        expect("LATENCY_OPTIONS ids", vm.outputLatencyOptions.map(\.id),
               readData(VC.OUTPUT.LATENCY_OPTIONS).map { d in stride(from: 0, to: d.count, by: 8).map { d[$0] } })
        vm.fetchDacHwMuteConfig(); land()
        let dac = readData(VC.OUTPUT.DAC_MUTE_CONFIG)
        expect("DAC_MUTE_CONFIG enabled/pin/hold", [vm.dacHwMuteConfig.enabled ? 1 : 0, Int(vm.dacHwMuteConfig.pin), Int(vm.dacHwMuteConfig.holdMs)],
               dac.map { [Int($0[0]), Int($0[2]), Int(u16le($0, 4) ?? 0)] })
        vm.fetchAdatStatus(); land()
        expect("ADAT_TX_STATUS enabled vs ADAT_TX_ENABLE", vm.adatEnabled, readData(VC.OUTPUT.ADAT_TX_ENABLE).map { $0[0] != 0 })
        expect("ADAT_TX_STATUS pin vs ADAT_TX_PIN", vm.adatPin, readData(VC.OUTPUT.ADAT_TX_PIN)?.first)

        // INPUT
        vm.fetchInputSource(); vm.fetchInputSourceNames(); vm.fetchDeviceName(); vm.fetchSpdifInputConfig()
        vm.fetchI2SInputConfig(); vm.fetchI2SInputChannels(); vm.fetchInputRate(); vm.fetchLgSoundSyncEnabled()
        vm.fetchAdatInputConfig()
        land()
        expect("SOURCE", vm.inputSource, readData(VC.INPUT.SOURCE).map { Int($0[0]) })
        for i in 0..<min(vm.inputSourceNames.count, walked[VC.INPUT.SOURCE_NAME.id] ?? 0) {
            expect("SOURCE_NAME[\(i)]", vm.inputSourceNames[i], str(readData(VC.INPUT.SOURCE_NAME, UInt16(i))))
        }
        expect("DEVICE_NAME", vm.deviceName, str(readData(VC.SYS.DEVICE_NAME)))
        let spcfg = readData(VC.INPUT.SPDIF_RX_CONFIG)
        expect("SPDIF_RX_CONFIG count (@0)", vm.spdifInputCount, spcfg.map { Int($0[0]) })
        expect("SPDIF_RX_CONFIG pin 0 vs SPDIF_RX_PIN[0]", vm.spdifRxPin, readData(VC.INPUT.SPDIF_RX_PIN, 0)?.first)
        for i in 1..<vm.spdifInputCount {
            expect("SPDIF_RX_CONFIG pin \(i) vs SPDIF_RX_PIN[\(i)]", vm.spdifRxPinsExt[i - 1], readData(VC.INPUT.SPDIF_RX_PIN, UInt16(i))?.first)
        }
        expect("SPDIF_RX_CONFIG switch vs SPDIF_RX_ENABLE", vm.spdifRxEnabled, readData(VC.INPUT.SPDIF_RX_ENABLE).map { $0[0] != 0 })
        expect("SPDIF_RX_CONFIG count vs SPDIF_RX_COUNT", vm.spdifRxCount, readData(VC.INPUT.SPDIF_RX_COUNT).map { Int($0[0]) })
        expect("I2S_RX_ENABLE", vm.i2sInputEnabled, readData(VC.INPUT.I2S_RX_ENABLE).map { $0[0] != 0 })
        for pair in 0..<(walked[VC.INPUT.I2S_RX_PIN.id] ?? 1) {
            expect("I2S_RX_PIN[\(pair)]", vm.i2sRxPins[pair], readData(VC.INPUT.I2S_RX_PIN, UInt16(pair))?.first)
        }
        expect("I2S_RX_CHANNELS", vm.i2sInputChannels, readData(VC.INPUT.I2S_RX_CHANNELS).map { Int($0[0]) })
        expect("I2S_RX_RATE", vm.i2sInputRateHz, u32le(readData(VC.INPUT.I2S_RX_RATE), 0))
        expect("LG_SOUND_SYNC_ENABLE", vm.lgSoundSyncEnabled, readData(VC.INPUT.LG_SOUND_SYNC_ENABLE).map { $0[0] != 0 })
        expect("LG_SOUND_SYNC_STATUS enabled (@0) vs LG_SOUND_SYNC_ENABLE", readData(VC.INPUT.LG_SOUND_SYNC_STATUS)?.first.map { $0 != 0 },
               readData(VC.INPUT.LG_SOUND_SYNC_ENABLE).map { $0[0] != 0 })
        expect("ADAT_RX_STATUS enabled vs ADAT_RX_ENABLE", vm.adatInputEnabled, readData(VC.INPUT.ADAT_RX_ENABLE).map { $0[0] != 0 })
        expect("ADAT_RX_STATUS pin vs ADAT_RX_PIN", vm.adatInputPin, readData(VC.INPUT.ADAT_RX_PIN)?.first)
        expect("ADAT_RX_STATUS clock mode vs ADAT_RX_CLOCK_MODE", vm.adatInputClockMode, readData(VC.INPUT.ADAT_RX_CLOCK_MODE)?.first)

        // CLOCK
        vm.fetchI2SBckPin(role: 0); vm.fetchI2SBckPin(role: 1); vm.fetchMckEnable(); vm.fetchMckPin(); vm.fetchMckMultiplier()
        vm.fetchI2SClockMode(); vm.fetchI2SClockPinMode()
        land()
        expect("I2S_BCK_PIN[0]", vm.i2sBckPin, readData(VC.CLOCK.I2S_BCK_PIN, 0)?.first)
        expect("I2S_BCK_PIN[1]", vm.i2sBckPinSlave, readData(VC.CLOCK.I2S_BCK_PIN, 1)?.first)
        expect("MCK_ENABLE", vm.mckEnabled, readData(VC.CLOCK.MCK_ENABLE).map { $0[0] != 0 })
        expect("MCK_PIN", vm.mckPin, readData(VC.CLOCK.MCK_PIN)?.first)
        expect("MCK_MULTIPLIER", vm.mckMultiplier, readData(VC.CLOCK.MCK_MULTIPLIER).map { $0[0] == 1 ? 256 : 128 })
        expect("I2S_CLOCK_MODE", vm.i2sClockMode, readData(VC.CLOCK.I2S_CLOCK_MODE)?.first)
        expect("I2S_CLOCK_PIN_MODE", vm.i2sClockPinMode, readData(VC.CLOCK.I2S_CLOCK_PIN_MODE)?.first)

        // XPORT
        vm.fetchUartCtrlConfig(); vm.fetchI2cCtrlConfig(); land()
        let uart = readData(VC.XPORT.UART_CONFIG)
        expect("UART_CONFIG enabled/tx/rx/baud", [vm.uartCtrlConfig.enabled ? 1 : 0, Int(vm.uartCtrlConfig.txPin), Int(vm.uartCtrlConfig.rxPin), Int(vm.uartCtrlConfig.baud)],
               uart.map { [Int($0[0]), Int($0[1]), Int($0[2]), Int(u32le($0, 4) ?? 0)] })
        expect("I2C_CONFIG bytes", vm.i2cCtrlConfig.toData(), readData(VC.XPORT.I2C_CONFIG))

        // STORE
        vm.fetchPresetDirectory(); land()
        let dir = readData(VC.STORE.DIRECTORY), startup = readData(VC.STORE.STARTUP)
        expect("DIRECTORY occupied (u16 @0)", vm.presetOccupied, u16le(dir, 0))
        expect("DIRECTORY startup mode vs STORE.STARTUP @0", vm.presetStartupMode, startup.map { Int($0[0]) })
        expect("DIRECTORY default slot vs STORE.STARTUP @1", vm.presetDefaultSlot, startup.map { Int($0[1]) })
        expect("DIRECTORY output config mode vs OUTPUT_CONFIG_MODE", vm.presetOutputConfigMode, readData(VC.STORE.OUTPUT_CONFIG_MODE).map { Int($0[0]) })
        expect("DIRECTORY master volume mode vs MASTER_VOLUME_MODE", vm.presetMasterVolumeMode, readData(VC.ROUTE.MASTER_VOLUME_MODE).map { Int($0[0]) })
        expect("PRESET_ACTIVE", { vm.fetchPresetActive(); land(); return vm.activePresetSlot }(), readData(VC.STORE.PRESET_ACTIVE).map { Int($0[0]) })
        for slot in 0..<10 { vm.fetchPresetName(slot: slot) }
        for ch in 0..<vm.numChannels { vm.fetchChannelName(channel: ch) }
        land()
        for slot in 0..<10 { expect("PRESET_NAME[\(slot)]", vm.presetNames[slot], str(readData(VC.STORE.PRESET_NAME, UInt16(slot)))) }
        for ch in 0..<vm.numChannels { expect("CHANNEL_NAME[\(ch)]", vm.channelNames[ch] ?? "", str(readData(VC.ROUTE.CHANNEL_NAME, UInt16(ch)))) }

        // MEAS: RTA caps and centres, generator caps and status
        vm.rta.fetchCaps(); land()
        let caps = readData(VC.MEAS.RTA_CAPS)
        var centres: [Double] = []
        for chunk in 0..<(walked[VC.MEAS.RTA_BAND_CENTRES.id] ?? 2) {
            if let c = readData(VC.MEAS.RTA_BAND_CENTRES, UInt16(chunk)) {
                centres += stride(from: 0, to: c.count - 1, by: 2).map { Double(UInt16(c[$0]) | (UInt16(c[$0 + 1]) << 8)) }
            }
        }
        expect("RTA band centres (chunked from 0)", vm.rta.bandCentresHz, Array(centres.prefix(Int(vm.rta.caps.maxBands))))
        plausible("RTA band centres rise", zip(centres, centres.dropFirst()).allSatisfy { $0 < $1 }, "\(centres)")
        plausible("RTA caps max bands matches the table", Int(vm.rta.caps.maxBands) == centres.count, "\(vm.rta.caps.maxBands) vs \(centres.count), caps \(hex(caps))")
        vm.fetchSiggen(); vm.fetchSiggenStatus(); land()
        expect("SIGGEN_CAPS type count vs TYPE_DESC addresses", Int(vm.siggenCaps.typeCount), walked[VC.MEAS.SIGGEN_TYPE_DESC.id])
        expect("SIGGEN_STATUS state (@1)", vm.siggenStatus.state, readData(VC.MEAS.SIGGEN_STATUS).map { $0[1] })

        // CS
        vm.fetchControlSurfaces(); land()
        expect("CS.CAPS noun count vs NOUN_DESC addresses", Int(vm.csCaps.nounCount), walked[VC.CS.NOUN_DESC.id])
        expect("CS noun descriptors read", vm.csNounDescs.count, Int(vm.csCaps.nounCount))
        let cst = readData(VC.CS.STATUS)
        expect("CS.STATUS max bindings (@2)", vm.csStatus.maxBindings, cst.map { $0[2] })
        expect("CS.STATUS dirty (@3)", vm.csStatus.dirty, cst.map { $0[3] != 0 })
        for slot in 0..<CS_MAX_BINDINGS {
            let b = readData(VC.CS.BINDING, UInt16(slot))
            expect("CS.BINDING[\(slot)] type/gpio", [vm.csBindings[slot].type, vm.csBindings[slot].gpio0], b.map { [$0[0], $0[4]] })
            expect("CS.SLOT_NAME[\(slot)]", vm.csNames[slot], str(readData(VC.CS.SLOT_NAME, UInt16(slot))))
        }
        for sub in 0..<CS_MAX_IR_COMMANDS {
            expect("CS.IR_CMD[\(sub)] proto/code", [UInt32(vm.csIrCommands[sub].proto), vm.csIrCommands[sub].code],
                   readData(VC.CS.IR_CMD, UInt16(sub)).map { [UInt32($0[5]), u32le($0, 12) ?? 0] })
        }
        for i in 0..<CS_MAX_MACROS { vm.fetchCsGroup(i); vm.fetchCsMacro(i) }
        let maxPages = vm.fetchCsDisplayCfg()
        for i in 0..<Int(maxPages) { vm.fetchCsDisplayPage(i) }
        vm.fetchCsAuxValues()
        land()
        for i in 0..<CS_MAX_MACROS {
            expect("CS.GROUP[\(i)] kind/mask", [UInt32(vm.csGroups[i].targetKind), vm.csGroups[i].memberMask],
                   readData(VC.CS.GROUP, UInt16(i)).map { [UInt32($0[0]), u32le($0, 4) ?? 0] })
            expect("CS.MACRO[\(i)] step count (@32)", Int(vm.csMacros[i].stepCount), readData(VC.CS.MACRO, UInt16(i)).map { Int($0[32]) })
        }
        let dcaps = readData(VC.CS.DISPLAY_CAPS), dcfg = readData(VC.CS.DISPLAY_CONFIG)
        expect("DISPLAY_CAPS page slots (@0)", vm.csDisplayMaxPages, dcaps?.first)
        expect("DISPLAY_CAPS model count (@1)", vm.csDisplayModelCount, dcaps.map { $0[1] })
        expect("DISPLAY_CONFIG mode/dwell", [Int(vm.csDisplayCfg.mode), Int(vm.csDisplayCfg.dwell)], dcfg.map { [Int($0[0]), Int(u16le($0, 2) ?? 0)] })
        for i in 0..<Int(maxPages) {
            expect("DISPLAY_PAGE[\(i)]", vm.csDisplayPages[i].toData(), readData(VC.CS.DISPLAY_PAGE, UInt16(i)))
        }
        let aux = readData(VC.CS.AUX_ALL)
        expect("AUX_ALL states (16 bytes)", vm.csAuxState, aux.map { d in (0..<16).map { d[$0] != 0 } })
        expect("AUX_ALL levels (16 x u16 @16)", vm.csAuxLevel, aux.map { d in (0..<16).map { u16le(d, 16 + 2 * $0) ?? 0 } })
        expect("IR_LEARN_STATUS state (@0)", { var r: CsIrLearnResult?; offMain { r = vm.csIrLearnRead() }; return r?.state }(),
               readData(VC.CS.IR_LEARN_STATUS)?.first)

        log("  \(decodeChecks) decode checks")
        let text = report.joined(separator: "\n")
        print("\n----- DSPi reply decoding -----\n\(text)\n-------------------------------")
    }

    // MARK: - Report

    /// Every command the app's source names, so the report can say what the
    /// sweep did not reach.
    private func commandsTheAppUses() -> Set<UInt16> {
        let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("DSPi Console")
        let byName = Dictionary(uniqueKeysWithValues: VendorCommandRegistry.all.map { ($0.qualifiedName, $0.command.id) })
        let regex = try! NSRegularExpression(pattern: #"VC\.([A-Z]+)\.([A-Z0-9_]+)"#)
        var used = Set<UInt16>()
        let files = FileManager.default.enumerator(at: appDir, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "VendorCommands.swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let s = (text as NSString)
                if let id = byName["\(s.substring(with: m.range(at: 1))).\(s.substring(with: m.range(at: 2)))"] { used.insert(id) }
            }
        }
        return used
    }

    private func writeReport() {
        let used = commandsTheAppUses()
        let exercised = getOK.union(setOK).union(appSetOK).union(actionOK)
        let usedBuilt = used.subtracting(notBuilt)
        let missed = usedBuilt.subtracting(exercised).sorted()
        // A GET-and-SET command counts as fully reached only when its SET was
        // proven too; list those whose SET was not.
        let setNotProven = usedBuilt.filter { id in
            guard let info = VendorCommandRegistry.info(for: VendorCommand(id)), info.hasSet else { return false }
            return !setOK.contains(id) && !appSetOK.contains(id) && !actionOK.contains(id)
        }.sorted()
        log("\n== Coverage of the \(used.count) commands the app names (\(usedBuilt.count) in this build)")
        log("  reached: \(usedBuilt.intersection(exercised).count)")
        log("  not reached at all: \(missed.map { name(VendorCommand($0)) }.joined(separator: ", "))")
        log("  SET never sent: \(setNotProven.map { name(VendorCommand($0)) }.joined(separator: ", "))")
        log("  verified through app setters: \(appSetOK.count)")
        // Settable commands the app names whose app code path was not run
        // with a changed value here (the flash pass covers the FLASH ones).
        let identityOnly = usedBuilt.filter { id in
            guard let info = VendorCommandRegistry.info(for: VendorCommand(id)), info.hasSet else { return false }
            return !appSetOK.contains(id) && !actionOK.contains(id) && !info.flags.contains(.flash)
        }.sorted()
        log("  SETs the app names but did not change here (non-flash): \(identityOnly.map { name(VendorCommand($0)) }.joined(separator: ", "))")

        let text = report.joined(separator: "\n")
        print("\n----- DSPi command sweep -----\n\(text)\n------------------------------")
        let path = ProcessInfo.processInfo.environment["DSPI_SWEEP_REPORT"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("dspi-command-sweep.txt")
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        print("Sweep report written to \(path)")
    }
}
