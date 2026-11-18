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

    private var transport: DeviceTransport { AppState.shared.transport }
    private var vm: DSPViewModel { AppState.shared.viewModel }

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

    private func implemented(_ c: VendorCommand, set: Bool) -> Bool {
        transport.implements(c, set: set) != false
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

    private func addresses(for info: VendorCommandInfo) -> [UInt16] {
        // Only optional inputs 1-3 have an enable; input 0 is always on.
        if info.command == VC.INPUT.SPDIF_RX_ENABLE { return [1, 3] }
        if info.command == VC.CS.AUX_STATE || info.command == VC.CS.AUX_LEVEL { return auxSlot.map { [$0] } ?? [] }
        let lastCh = UInt16(shape.channels - 1), lastIn = UInt16(shape.inputs - 1)
        let lastOut = UInt16(shape.outputs - 1)
        switch info.address {
        case .none: return [0]
        case .page: return [UInt16(VC.SYS.PROTOCOL_INFO.page), UInt16(VC.CS.CAPS.page)]
        case .pageCommand: return [VC.SYS.PROTOCOL_INFO.id, VC.CS.CAPS.id]
        case .channel: return [0, lastCh]
        case .input: return [0, lastIn]
        case .output, .outputAll: return [0, lastOut]
        case .inputOutput: return [0, (lastIn << 8) | lastOut]
        // Band 9 is the last PEQ band of every channel; band 20 the first
        // crossover band, which only output channels have.
        case .channelBand: return [0, (lastCh << 8) | 9, (lastCh << 8) | 20]
        default: return [0]
        }
    }

    // MARK: - The test

    func testEveryCommand() throws {
        guard ProcessInfo.processInfo.environment["DSPI_COMMAND_SWEEP"] == "1" else {
            throw XCTSkip("Opt-in: run with TEST_RUNNER_DSPI_COMMAND_SWEEP=1 (writes to the board).")
        }
        _ = try HardwareTest.requireDevice()

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
        let act: (DSPViewModel, Int) -> Void
    }

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
        if c.blocking { offMain { c.act(self.vm, pick) } } else { c.act(vm, pick) }
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

        for c in cases { run(c) }
        log("  \(appSetOK.count) commands verified through the app's setters (\(cases.count) cases)")
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

        let text = report.joined(separator: "\n")
        print("\n----- DSPi command sweep -----\n\(text)\n------------------------------")
        let path = ProcessInfo.processInfo.environment["DSPI_SWEEP_REPORT"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("dspi-command-sweep.txt")
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        print("Sweep report written to \(path)")
    }
}
