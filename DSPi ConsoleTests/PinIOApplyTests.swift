import XCTest
@testable import DSPi_Console

/// A device that follows the 1.1.7 pin rules closely enough to show order
/// bugs: a function holds its pins only while in use, a store never conflicts,
/// a start or a move of a running function does.  Input blocks hold their pins
/// while on, selected or not, and the source switch needs no pin.  RP2350 shape: four slots
/// plus PDM at OUTPUT.PIN index 4.
private final class FakePinDevice: PinIODevice {
    var c: PinIOConfig
    /// PDM keeps driving its pin until `waitForPdmStop` (its fade-out).
    var pdmRunning: Bool
    /// Ops answered INVALID_PIN whatever the state.
    var refuse: [PinIOOp] = []
    /// Pins reported as claimed by something outside this model.
    var foreignClaims: Set<UInt8> = []
    private(set) var log: [PinIOOp] = []
    /// Output type, input source and clock mode switches are only queued, as
    /// on the device: they land when the caller waits for them.
    private var pending: [PinIOOp] = []
    /// False: a queued switch never lands (a wedged main loop).
    var appliesQueued = true

    static let valid: Set<UInt8> = Set((0...22).map(UInt8.init) + [26, 27, 28, 29])

    init(_ c: PinIOConfig) {
        self.c = c
        pdmRunning = c.pdmEnabled == true
    }

    private var anyI2S: Bool { c.slotTypes!.contains(1) }
    private var pair: Int { (c.clockPinMode == I2S_CLOCK_PIN_MODE_SPLIT && c.clockMode == I2S_CLOCK_MODE_SLAVE) ? 1 : 0 }
    private var clocksRun: Bool { anyI2S || c.i2sEnabled == true }
    private func spdifHeld(_ i: Int) -> Bool { c.spdifEnabled == true && i < c.spdifCount! }
    private var spdifSourceIndex: Int? {
        switch c.inputSource! {
        case INPUT_SOURCE_SPDIF: return 0
        case INPUT_SOURCE_SPDIF2...INPUT_SOURCE_SPDIF4: return c.inputSource! - INPUT_SOURCE_SPDIF2 + 1
        default: return nil
        }
    }

    /// Active claims as (owner, pin).
    func active() -> [(String, UInt8)] {
        var out: [(String, UInt8)] = []
        for (i, p) in c.outputPins!.enumerated() where i < 4 { out.append(("out\(i)", p)) }
        if c.pdmEnabled == true || pdmRunning { out.append(("out4", c.outputPins![4])) }
        if clocksRun { let b = c.bckPins![pair]; out += [("bck\(pair)", b), ("bck\(pair)", b + 1)] }
        if c.mckEnabled == true { out.append(("mck", c.mckPin!)) }
        for (i, p) in c.spdifPins!.enumerated() where spdifHeld(i) { out.append(("spdif\(i)", p)) }
        if c.i2sEnabled == true {
            for p in 0..<(c.i2sChannels! / 2) { out.append(("i2s\(p)", c.i2sRxPins![p])) }
        }
        if c.adatEnabled == true { out.append(("adat", c.adatPin!)) }
        if c.adatInEnabled == true { out.append(("adatIn", c.adatInPin!)) }
        return out
    }

    private func held(_ pin: UInt8, by owner: String? = nil, except me: String) -> Bool {
        foreignClaims.contains(pin) || active().contains { $0.1 == pin && $0.0 != me && (owner == nil || $0.0 == owner) }
    }

    /// A claim-mode check of `pins` for `me`.
    private func claim(_ pins: [UInt8], _ me: String) -> UInt8 {
        guard pins.allSatisfy(Self.valid.contains) else { return PIN_CONFIG_INVALID_PIN }
        return pins.contains { held($0, except: me) } ? PIN_CONFIG_PIN_IN_USE : PIN_CONFIG_SUCCESS
    }

    private func store(_ pins: [UInt8]) -> UInt8 {
        pins.allSatisfy(Self.valid.contains) ? PIN_CONFIG_SUCCESS : PIN_CONFIG_INVALID_PIN
    }

    func perform(_ op: PinIOOp) -> UInt8 {
        log.append(op)
        if refuse.contains(op) { return PIN_CONFIG_INVALID_PIN }
        // The firmware compares a queued kind with the LIVE value: a SET equal
        // to it answers OK and changes nothing, leaving any queued switch.
        switch op {
        case .slotType(let slot, let t) where t == c.slotTypes![slot]: return 0
        case .inputSource(let src) where src == c.inputSource: return 0
        default: break
        }
        let s = verdict(op)
        guard s == PIN_CONFIG_SUCCESS else { return s }
        if PinIOApply.isDeferred(op) { pending.append(op) } else { commit(op) }
        return s
    }

    func waitForApply(_ op: PinIOOp) -> Bool {
        guard appliesQueued else { return false }
        if let i = pending.firstIndex(of: op) { commit(pending.remove(at: i)) }
        return true
    }

    private func verdict(_ op: PinIOOp) -> UInt8 {
        switch op {
        case .outputPin(4, let p):
            if pdmRunning { return PIN_CONFIG_OUTPUT_ACTIVE }
            return store([p])
        case .outputPin(let i, let p): return claim([p], "out\(i)")
        case .pdmEnable(let on): return on ? claim([c.outputPins![4]], "out4") : PIN_CONFIG_SUCCESS
        case .bckPin(let r, let p):
            if anyI2S && r == pair { return PIN_CONFIG_OUTPUT_ACTIVE }
            return clocksRun && r == pair ? claim([p, p + 1], "bck\(r)") : store([p, p + 1])
        case .slotType(_, let t):
            guard t == 1, !clocksRun else { return PIN_CONFIG_SUCCESS }
            let b = c.bckPins![pair]
            return claim([b, b + 1], "bck\(pair)")
        case .inputSource(let s):
            // No pin check; a source whose block is off is VC_ERR_STATE.
            switch s {
            case INPUT_SOURCE_I2S: return c.i2sEnabled == true ? 0 : PIN_CONFIG_OUTPUT_ACTIVE
            case INPUT_SOURCE_ADAT: return c.adatInEnabled == true ? 0 : PIN_CONFIG_OUTPUT_ACTIVE
            case INPUT_SOURCE_SPDIF: return spdifHeld(0) ? 0 : PIN_CONFIG_OUTPUT_ACTIVE
            case INPUT_SOURCE_SPDIF2...INPUT_SOURCE_SPDIF4:
                return spdifHeld(s - INPUT_SOURCE_SPDIF2 + 1) ? 0 : PIN_CONFIG_OUTPUT_ACTIVE
            default: return 0
            }
        case .mckEnable(let on): return on ? claim([c.mckPin!], "mck") : 0
        case .mckPin(let p): return c.mckEnabled == true ? PIN_CONFIG_OUTPUT_ACTIVE : store([p])
        case .spdifPin(let i, let p): return spdifHeld(i) ? claim([p], "spdif\(i)") : store([p])
        case .spdifEnable(let on):
            if !on { return spdifSourceIndex != nil ? PIN_CONFIG_OUTPUT_ACTIVE : 0 }
            return claimSpdif(0..<c.spdifCount!)
        case .spdifCount(let n):
            guard (1...4).contains(n) else { return PIN_CONFIG_INVALID_PARAM }
            if let src = spdifSourceIndex, src >= n { return PIN_CONFIG_OUTPUT_ACTIVE }
            return c.spdifEnabled == true && n > c.spdifCount! ? claimSpdif(c.spdifCount!..<n) : 0
        case .i2sEnable(let on):
            if !on { return c.inputSource == INPUT_SOURCE_I2S ? PIN_CONFIG_OUTPUT_ACTIVE : 0 }
            for p in 0..<(c.i2sChannels! / 2) where claim([c.i2sRxPins![p]], "i2s\(p)") != 0 { return PIN_CONFIG_PIN_IN_USE }
            return clocksRun ? PIN_CONFIG_SUCCESS : claim([c.bckPins![pair], c.bckPins![pair] + 1], "bck\(pair)")
        case .i2sRxPin(let p, let g):
            let inUse = c.i2sEnabled == true && p < c.i2sChannels! / 2
            return inUse ? claim([g], "i2s\(p)") : store([g])
        case .i2sChannels(let n):
            guard c.i2sEnabled == true, n > c.i2sChannels! else { return 0 }
            for p in (c.i2sChannels! / 2)..<(n / 2) where claim([c.i2sRxPins![p]], "i2s\(p)") != 0 { return PIN_CONFIG_PIN_IN_USE }
            return 0
        case .adatPin(let p): return c.adatEnabled == true ? claim([p], "adat") : store([p])
        case .adatEnable(let on): return on ? claim([c.adatPin!], "adat") : 0
        case .adatInPin(let p): return c.adatInEnabled == true ? claim([p], "adatIn") : store([p])
        case .adatInEnable(let on):
            if !on { return c.inputSource == INPUT_SOURCE_ADAT ? PIN_CONFIG_OUTPUT_ACTIVE : 0 }
            return claim([c.adatInPin!], "adatIn")
        case .clockPinMode, .clockMode, .mckMultiplier, .i2sRate, .adatInClockMode: return 0
        }
    }

    /// Inputs in `range` claimed as one unit: all or nothing.
    private func claimSpdif(_ range: Range<Int>) -> UInt8 {
        for i in range {
            let s = claim([c.spdifPins![i]], "spdif\(i)")
            if s != 0 { return s }
        }
        return 0
    }

    private func commit(_ op: PinIOOp) {
        switch op {
        case .slotType(let s, let t): c.slotTypes![s] = t
        case .outputPin(let i, let p): c.outputPins![i] = p
        case .pdmEnable(let e): c.pdmEnabled = e; if e { pdmRunning = true }
        case .bckPin(let r, let p): c.bckPins![r] = p
        case .clockPinMode(let m): c.clockPinMode = m
        case .clockMode(let m): c.clockMode = m
        case .mckEnable(let e): c.mckEnabled = e
        case .mckPin(let p): c.mckPin = p
        case .mckMultiplier(let m): c.mckMultiplier = m
        case .spdifPin(let i, let p): c.spdifPins![i] = p
        case .spdifEnable(let e): c.spdifEnabled = e
        case .spdifCount(let n): c.spdifCount = n
        case .i2sEnable(let e): c.i2sEnabled = e
        case .i2sChannels(let n): c.i2sChannels = n
        case .i2sRxPin(let i, let p): c.i2sRxPins![i] = p
        case .i2sRate(let r): c.i2sRate = r
        case .inputSource(let s): c.inputSource = s
        case .adatPin(let p): c.adatPin = p
        case .adatEnable(let e): c.adatEnabled = e
        case .adatInPin(let p): c.adatInPin = p
        case .adatInClockMode(let m): c.adatInClockMode = m
        case .adatInEnable(let e): c.adatInEnabled = e
        }
    }

    func waitForPdmStop() -> Bool {
        if c.pdmEnabled != true { pdmRunning = false }
        return !pdmRunning
    }

    private func freeMask(_ me: String) -> UInt64 {
        Self.valid.filter { !held($0, except: me) }.reduce(0) { $0 | (1 << UInt64($1)) }
    }
    func freeMask(outputIndex: Int) -> UInt64? { freeMask("out\(outputIndex)") }
    func freeMask(spdifInput: Int) -> UInt64? { freeMask("spdif\(spdifInput)") }
    func freeMask(i2sPair: Int) -> UInt64? { freeMask("i2s\(i2sPair)") }

    /// Active claims plus every stored pin of a function that is off.
    func claimedPins() -> Set<UInt8>? {
        var s = Set(active().map(\.1)).union(foreignClaims)
        s.formUnion(c.outputPins!)
        s.formUnion(c.bckPins!.flatMap { [$0, $0 + 1] })
        s.insert(c.mckPin!)
        s.formUnion(c.spdifPins!)
        s.formUnion(c.i2sRxPins!)
        s.insert(c.adatPin!)
        if c.adatInPin! != ADAT_INPUT_PIN_UNSET { s.insert(c.adatInPin!) }
        return s
    }

    func conflictText(_ op: PinIOOp, pins: [UInt8]) -> String? { "held" }
}

final class PinIOApplyTests: XCTestCase {

    /// A quiet RP2350: four S/PDIF slots on 6-9, PDM off on 10, clocks idle.
    private func base() -> PinIOConfig {
        PinIOConfig(slotTypes: [0, 0, 0, 0], outputPins: [6, 7, 8, 9, 10], pdmEnabled: false,
                    bckPins: [14, 26], clockPinMode: I2S_CLOCK_PIN_MODE_UNIFIED, clockMode: I2S_CLOCK_MODE_MASTER,
                    mckEnabled: false, mckPin: 13, mckMultiplier: 0,
                    spdifPins: [5, 20, 21, 22], spdifEnabled: true, spdifCount: 1, i2sEnabled: false,
                    i2sChannels: 2, i2sRxPins: [1, 2, 3, 4], i2sRate: 48000, inputSource: INPUT_SOURCE_USB,
                    adatPin: 12, adatEnabled: false, adatInPin: ADAT_INPUT_PIN_UNSET, adatInClockMode: 0, adatInEnabled: false)
    }

    @discardableResult
    private func apply(_ dev: FakePinDevice, _ target: PinIOConfig, restorePdm: Bool = false) -> PinIOApply {
        let r = PinIOApply(device: dev, current: dev.c, target: target, restoreRefusedPdm: restorePdm)
        r.run()
        return r
    }

    /// The old order set the slot type first, which start-checks the OLD
    /// clock pair; here the pair is stored before the slot goes to I2S.
    func testClockPinsBeforeSlotType() {
        var cur = base()
        cur.spdifCount = 2
        cur.spdifPins = [5, 14, 21, 22]           // S/PDIF 2 holds GPIO 14
        let dev = FakePinDevice(cur)
        var tgt = cur
        tgt.slotTypes = [1, 0, 0, 0]
        tgt.bckPins = [16, 26]
        let r = apply(dev, tgt)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(dev.c.bckPins, [16, 26])
        XCTAssertEqual(dev.c.slotTypes, [1, 0, 0, 0])
        XCTAssertLessThan(dev.log.firstIndex(of: .bckPin(role: 0, 16))!, dev.log.firstIndex(of: .slotType(0, 1))!)
    }

    /// Moving the clock pair the I2S outputs run on parks them on S/PDIF.
    func testClockPinChangeWhileSlotsStayI2S() {
        var cur = base()
        cur.slotTypes = [1, 1, 0, 0]
        let dev = FakePinDevice(cur)
        var tgt = cur
        tgt.bckPins = [16, 26]
        let r = apply(dev, tgt)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(dev.c.bckPins, [16, 26])
        XCTAssertEqual(dev.c.slotTypes, [1, 1, 0, 0])
    }

    /// The I2S block switches on once its data pins are in place, then the
    /// source follows.
    func testSourceAfterRxPins() {
        let cur = base()
        let dev = FakePinDevice(cur)
        var tgt = cur
        tgt.spdifPins = [19, 20, 21, 22]           // S/PDIF 1 leaves GPIO 5
        tgt.i2sRxPins = [5, 2, 3, 4]               // I2S data takes it
        tgt.i2sEnabled = true
        tgt.inputSource = INPUT_SOURCE_I2S
        let r = apply(dev, tgt)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(dev.c.i2sEnabled, true)
        XCTAssertEqual(dev.c.inputSource, INPUT_SOURCE_I2S)
        XCTAssertLessThan(dev.log.firstIndex(of: .i2sEnable(true))!, dev.log.firstIndex(of: .inputSource(INPUT_SOURCE_I2S))!)
        XCTAssertEqual(dev.c.i2sRxPins?[0], 5)
        XCTAssertEqual(dev.c.spdifPins?[0], 19)
    }

    /// Two running outputs swapping pins go through an unclaimed temp pin.
    func testOutputSwapRoutesThroughUnclaimedPin() {
        let cur = base()
        let dev = FakePinDevice(cur)
        var tgt = cur
        tgt.outputPins = [7, 6, 8, 9, 10]
        let r = apply(dev, tgt)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(dev.c.outputPins, [7, 6, 8, 9, 10])
        XCTAssertEqual(r.notes.count, 1)
        // The temp pin had no claim of any kind, stored ones included.
        let temps = dev.log.compactMap { op -> UInt8? in
            if case .outputPin(_, let p) = op, ![6, 7].contains(p) { return p }
            return nil
        }
        XCTAssertEqual(temps.count, 1)
        XCTAssertFalse(FakePinDevice(cur).claimedPins()!.contains(temps[0]))
    }

    /// An input in the swap takes the temp pin, since it drives nothing.
    func testSwapWithInputMovesTheInput() {
        let cur = base()
        let dev = FakePinDevice(cur)
        var tgt = cur
        tgt.outputPins = [5, 7, 8, 9, 10]
        tgt.spdifPins = [6, 20, 21, 22]
        let r = apply(dev, tgt)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(dev.c.outputPins?[0], 5)
        XCTAssertEqual(dev.c.spdifPins?[0], 6)
        // Only the input visited a pin outside the two being swapped.
        let detours = dev.log.filter { op in
            switch op {
            case .spdifPin(0, let p), .outputPin(0, let p): return ![5, 6].contains(p)
            default: return false
            }
        }
        XCTAssertEqual(detours.count, 1, "one visit to the temp pin")
        XCTAssertTrue(detours.allSatisfy { if case .spdifPin = $0 { return true } else { return false } })
    }

    /// No unclaimed pin for an output-only swap: nothing moves, the user is told.
    func testSwapWithNoEligiblePinStops() {
        let cur = base()
        let dev = FakePinDevice(cur)
        dev.foreignClaims = FakePinDevice.valid.subtracting([6, 7])
        var tgt = cur
        tgt.outputPins = [7, 6, 8, 9, 10]
        let r = apply(dev, tgt)
        XCTAssertEqual(dev.c.outputPins, [6, 7, 8, 9, 10])
        XCTAssertFalse(r.problems.isEmpty)
        XCTAssertTrue(r.notes.contains { $0.contains("by hand") })
    }

    /// The second move of a swap is refused: the first goes back.
    func testSwapRollsBackWhenTheSecondMoveFails() {
        let cur = base()
        let dev = FakePinDevice(cur)
        dev.refuse = [.outputPin(1, 6)]
        var tgt = cur
        tgt.outputPins = [7, 6, 8, 9, 10]
        let r = apply(dev, tgt)
        XCTAssertEqual(dev.c.outputPins, [6, 7, 8, 9, 10])
        XCTAssertFalse(r.problems.isEmpty)
    }

    /// PDM moves only once stopped; a refused re-enable on the interactive
    /// path puts the old pin back and runs PDM there again.
    func testPdmRefusedReenableRestoresOnInteractivePath() {
        var cur = base()
        cur.pdmEnabled = true
        cur.adatEnabled = true
        cur.adatPin = 11
        let dev = FakePinDevice(cur)
        var tgt = PinIOConfig()
        tgt.outputPins = [6, 7, 8, 9, 11]
        let r = apply(dev, tgt, restorePdm: true)
        XCTAssertEqual(dev.c.outputPins?[4], 10)
        XCTAssertEqual(dev.c.pdmEnabled, true)
        XCTAssertFalse(r.problems.isEmpty, "the refused enable is still reported")
    }

    func testPdmRefusedReenableIsReportedInDocumentApply() {
        var cur = base()
        cur.pdmEnabled = true
        cur.adatEnabled = true
        cur.adatPin = 11
        let dev = FakePinDevice(cur)
        var tgt = PinIOConfig()
        tgt.outputPins = [6, 7, 8, 9, 11]
        let r = apply(dev, tgt)
        XCTAssertEqual(dev.c.outputPins?[4], 11)
        XCTAssertEqual(dev.c.pdmEnabled, false)
        XCTAssertTrue(r.problems.contains { $0.contains("Subwoofer output") })
    }

    /// A PDM pin move that is allowed lands with PDM running again.
    func testPdmMoveCyclesOffAndOn() {
        var cur = base()
        cur.pdmEnabled = true
        let dev = FakePinDevice(cur)
        var tgt = PinIOConfig()
        tgt.outputPins = [6, 7, 8, 9, 11]
        let r = apply(dev, tgt, restorePdm: true)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(dev.c.outputPins?[4], 11)
        XCTAssertEqual(dev.c.pdmEnabled, true)
    }

    /// Cutting the count below the input that is the source: the source steps
    /// aside first.
    func testSourceStepsAsideBeforeItsInputIsCut() {
        var cur = base()
        cur.spdifCount = 2
        cur.inputSource = INPUT_SOURCE_SPDIF2
        let dev = FakePinDevice(cur)
        var tgt = cur
        tgt.spdifCount = 1
        tgt.inputSource = INPUT_SOURCE_SPDIF
        let r = apply(dev, tgt)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(dev.c.inputSource, INPUT_SOURCE_SPDIF)
        XCTAssertEqual(dev.c.spdifCount, 1)
    }

    /// Switching a whole block off under the source: it steps aside to the
    /// target source first, here I2S, whose block the target turns on - so
    /// it goes via USB and ends on I2S.
    func testSourceLeavesABlockThatGoesOff() {
        var cur = base()
        cur.inputSource = INPUT_SOURCE_SPDIF
        let dev = FakePinDevice(cur)
        var tgt = cur
        tgt.spdifEnabled = false
        tgt.i2sEnabled = true
        tgt.inputSource = INPUT_SOURCE_I2S
        let r = apply(dev, tgt)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(dev.c.spdifEnabled, false)
        XCTAssertEqual(dev.c.inputSource, INPUT_SOURCE_I2S)
        XCTAssertEqual(dev.log.first, .inputSource(INPUT_SOURCE_USB))
    }

    /// A source switch into a block that is already on needs no pin at all,
    /// even while another function sits on a pin the block does not use.
    func testSourceSwitchIntoAnOnBlockNeedsNoPins() {
        var cur = base()
        cur.i2sEnabled = true
        cur.spdifCount = 3
        let dev = FakePinDevice(cur)
        var tgt = cur
        tgt.inputSource = INPUT_SOURCE_SPDIF3
        let r = apply(dev, tgt)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(dev.log, [.inputSource(INPUT_SOURCE_SPDIF3)])
    }

    /// The I2S block claims its clock pair even with no I2S output: a held
    /// BCK pin refuses the switch and the source stays where it was.
    func testI2SBlockOnRefusedOnHeldClockPin() {
        var cur = base()
        cur.outputPins = [6, 15, 8, 9, 10]          // Output 2 sits on LRCLK
        let dev = FakePinDevice(cur)
        var tgt = cur
        tgt.i2sEnabled = true
        tgt.inputSource = INPUT_SOURCE_I2S
        let r = apply(dev, tgt)
        XCTAssertEqual(dev.c.i2sEnabled, false)
        XCTAssertEqual(dev.c.inputSource, INPUT_SOURCE_USB)
        XCTAssertTrue(r.problems.contains { $0.hasPrefix("I2S input rejected") })
        XCTAssertTrue(r.notes.contains { $0.contains("stayed on USB") })
    }

    /// A count raise claims every new input as one unit: one held pin and the
    /// count stays where it was.
    func testSpdifCountRaiseIsAllOrNothing() {
        var cur = base()
        cur.spdifPins = [5, 20, 7, 22]             // input 3 on Output 2's pin
        let dev = FakePinDevice(cur)
        var tgt = cur
        tgt.spdifCount = 4
        let r = apply(dev, tgt)
        XCTAssertEqual(dev.c.spdifCount, 1)
        XCTAssertTrue(r.problems.contains { $0.hasPrefix("S/PDIF input count rejected") })
    }

    /// While the block is off its count and pins are plain stores; the switch
    /// then claims them all at once.
    func testSpdifCountAndPinsStoreWhileOffThenSwitchOn() {
        var cur = base()
        cur.spdifEnabled = false
        cur.spdifPins = [5, 6, 21, 22]             // input 2 stored on Output 1's pin
        let dev = FakePinDevice(cur)
        var tgt = cur
        tgt.spdifEnabled = true
        tgt.spdifCount = 2
        tgt.spdifPins = [5, 19, 21, 22]
        let r = apply(dev, tgt)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(dev.c.spdifEnabled, true)
        XCTAssertEqual(dev.c.spdifCount, 2)
        XCTAssertEqual(dev.c.spdifPins?[1], 19)
        XCTAssertLessThan(dev.log.firstIndex(of: .spdifCount(2))!, dev.log.firstIndex(of: .spdifEnable(true))!)
    }

    /// A queued switch that never lands is reported, and the routine does not
    /// carry on as if it had.
    func testQueuedSwitchThatNeverLandsIsReported() {
        var cur = base()
        cur.slotTypes = [1, 1, 0, 0]
        let dev = FakePinDevice(cur)
        dev.appliesQueued = false
        var tgt = cur
        tgt.bckPins = [16, 26]
        let r = apply(dev, tgt)
        XCTAssertTrue(r.problems.contains { $0.contains("did not take effect") })
        XCTAssertEqual(dev.c.bckPins?[0], 14, "the pair could not move under running clocks")
    }

    /// With the I2S block on (not selected, no I2S output) the clock pair is in
    /// use, so an output swapping onto LRCLK while the pair moves onto the
    /// output's pin is broken through a temporary pin.
    func testSwapWithClockPairWhileI2SBlockOn() {
        var cur = base()
        cur.i2sEnabled = true
        cur.outputPins = [16, 7, 8, 9, 10]
        let dev = FakePinDevice(cur)
        var tgt = cur
        tgt.bckPins = [16, 26]
        tgt.outputPins = [15, 7, 8, 9, 10]
        let r = apply(dev, tgt)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(dev.c.bckPins?[0], 16)
        XCTAssertEqual(dev.c.outputPins?[0], 15)
    }

    /// A target that leaves the source alone keeps the playing input's block,
    /// as the firmware's restores do: the count is not cut below it.
    func testLiveSourceKeepsItsBlock() {
        var cur = base()
        cur.spdifCount = 2
        cur.inputSource = INPUT_SOURCE_SPDIF2
        let dev = FakePinDevice(cur)
        var tgt = cur
        tgt.spdifCount = 1
        tgt.inputSource = nil                      // Settings Revert leaves the source alone
        let r = apply(dev, tgt)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(dev.c.inputSource, INPUT_SOURCE_SPDIF2)
        XCTAssertEqual(dev.c.spdifCount, 2)
        XCTAssertTrue(r.notes.contains { $0.contains("S/PDIF input 2 stayed on") })
    }

    /// The same for an I2S source whose block the target switches off.
    func testLiveI2SSourceKeepsItsBlock() {
        var cur = base()
        cur.i2sEnabled = true
        cur.inputSource = INPUT_SOURCE_I2S
        let dev = FakePinDevice(cur)
        var tgt = cur
        tgt.i2sEnabled = false
        tgt.inputSource = nil
        let r = apply(dev, tgt)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(dev.c.i2sEnabled, true)
        XCTAssertEqual(dev.c.inputSource, INPUT_SOURCE_I2S)
    }

    /// A function that is off stores a held pin; enabling it there is refused and reported.
    func testEnableOnHeldPinIsReported() {
        let cur = base()
        let dev = FakePinDevice(cur)
        var tgt = cur
        tgt.mckEnabled = true
        tgt.mckPin = 6                              // Output 1 holds it
        let r = apply(dev, tgt)
        XCTAssertEqual(dev.c.mckPin, 6, "stored")
        XCTAssertEqual(dev.c.mckEnabled, false)
        XCTAssertTrue(r.problems.contains { $0.hasPrefix("MCK enable") })
    }
}
