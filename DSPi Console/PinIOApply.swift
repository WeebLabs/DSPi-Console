import Foundation

// MARK: - Applying many pin settings at once
//
// Firmware 1.1.7 lets a function hold its pins only while it is in use
// (pin_availability_query_spec.md 4.6).  A pin SET on a function that is off
// is a store that cannot conflict; switching a function on, or moving one that
// runs, is checked against every other active claim.  A sequence of plain SETs
// in the old order (types, then pins, then enables) is refused part-way, so the
// document apply, Settings Revert and Reset Pins all go through this routine:
//
//   1. release   switch off what is off in the target or about to move
//   2. store     write the pins of everything now off
//   3. move      move the functions that stay on, repeating while any move lands,
//                and break a swap through a temporary pin
//   4. start     switch things on again, checking every answer
//
// It works from the device's answers, so it needs no copy of the pin rules.
// Input blocks (S/PDIF, I2S, ADAT) hold their pins while on, selected or not,
// so the input source itself never needs a pin; it only steps aside when the
// target switches its block off.

/// A hardware IO configuration.  As a target, nil means "leave it as it is";
/// as the current state, nil means "this board does not have it".
struct PinIOConfig: Equatable {
    var slotTypes: [UInt8]?
    /// By `OUTPUT.PIN` index: the slots, then PDM.
    var outputPins: [UInt8]?
    var pdmEnabled: Bool?
    /// Index 0 the master or unified pair, 1 the slave pair.
    var bckPins: [UInt8]?
    var clockPinMode: UInt8?
    var clockMode: UInt8?
    var mckEnabled: Bool?
    var mckPin: UInt8?
    var mckMultiplier: Int?
    var spdifPins: [UInt8]?
    /// The S/PDIF input block: a switch and a count.  While on, inputs
    /// 0..<count hold their pins whether or not one is selected.
    var spdifEnabled: Bool?
    var spdifCount: Int?
    /// The I2S input block switch.  While on it holds the clock pair and the
    /// data pins of the counted pairs, selected or not.
    var i2sEnabled: Bool?
    var i2sChannels: Int?
    var i2sRxPins: [UInt8]?
    var i2sRate: UInt32?
    var inputSource: Int?
    var adatPin: UInt8?
    var adatEnabled: Bool?
    var adatInPin: UInt8?
    var adatInClockMode: UInt8?
    var adatInEnabled: Bool?
}

/// One SET the routine can issue.
enum PinIOOp: Equatable {
    case slotType(Int, UInt8)
    case outputPin(Int, UInt8)
    case pdmEnable(Bool)
    case bckPin(role: Int, UInt8)
    case clockPinMode(UInt8)
    case clockMode(UInt8)
    case mckEnable(Bool)
    case mckPin(UInt8)
    case mckMultiplier(Int)
    case spdifPin(Int, UInt8)
    case spdifEnable(Bool)
    case spdifCount(Int)
    case i2sEnable(Bool)
    case i2sChannels(Int)
    case i2sRxPin(Int, UInt8)
    case i2sRate(UInt32)
    case inputSource(Int)
    case adatPin(UInt8)
    case adatEnable(Bool)
    case adatInPin(UInt8)
    case adatInClockMode(UInt8)
    case adatInEnable(Bool)
}

/// What the routine needs from a device.  Statuses are `PIN_CONFIG_*` bytes,
/// 0xFF when there was no answer.
protocol PinIODevice: AnyObject {
    func perform(_ op: PinIOOp) -> UInt8
    /// After an accepted SET the device applies on its main loop (an output
    /// type, the input source, the I2S clock mode): wait (bounded) until it
    /// reads back.  The firmware compares later SETs with the live value, so
    /// the routine must not go on while the switch is still queued.
    func waitForApply(_ op: PinIOOp) -> Bool
    /// Wait (bounded) until PDM has stopped after a disable, including its fade-out.
    func waitForPdmStop() -> Bool
    /// The fresh free mask of an output pin index, for choosing a temporary pin.
    func freeMask(outputIndex: Int) -> UInt64?
    func freeMask(spdifInput: Int) -> UInt64?
    func freeMask(i2sPair: Int) -> UInt64?
    /// Every GPIO with any claim, active or stored.
    func claimedPins() -> Set<UInt8>?
    /// Who holds `pins`, for the report of a refused `op`.
    func conflictText(_ op: PinIOOp, pins: [UInt8]) -> String?
}

final class PinIOApply {
    private let device: PinIODevice
    private var cur: PinIOConfig
    private let orig: PinIOConfig
    private let tgt: PinIOConfig
    /// Interactive paths (the Hardware tab picker, Reset Pins) undo a PDM pin
    /// move whose re-enable is refused, so one pick cannot leave the
    /// subwoofer off on a pin it cannot start on.
    private let restoreRefusedPdm: Bool
    private(set) var problems: [String] = []
    private(set) var notes: [String] = []
    /// Abort when this returns false (a device switch mid-apply).
    var stillCurrent: () -> Bool = { true }

    init(device: PinIODevice, current: PinIOConfig, target: PinIOConfig, restoreRefusedPdm: Bool = false) {
        self.device = device
        self.cur = current
        self.orig = current
        var t = target
        var kept: String?
        // A target that leaves the source alone keeps the block of the source
        // that is playing, as the firmware's own restores do, rather than
        // knocking the device back to USB.
        if t.inputSource == nil, let src = current.inputSource {
            switch src {
            case INPUT_SOURCE_I2S where t.i2sEnabled == false:
                t.i2sEnabled = true; kept = "The I2S input"
            case INPUT_SOURCE_ADAT where t.adatInEnabled == false:
                t.adatInEnabled = true; kept = "The ADAT input"
            case INPUT_SOURCE_SPDIF, INPUT_SOURCE_SPDIF2, INPUT_SOURCE_SPDIF3, INPUT_SOURCE_SPDIF4:
                let i = src == INPUT_SOURCE_SPDIF ? 0 : src - INPUT_SOURCE_SPDIF2 + 1
                if t.spdifEnabled == false { t.spdifEnabled = true; kept = "The S/PDIF input" }
                if let n = t.spdifCount, n <= i { t.spdifCount = i + 1; kept = "S/PDIF input \(i + 1)" }
            default: break
            }
        }
        self.tgt = t
        self.restoreRefusedPdm = restoreRefusedPdm
        if let kept { notes.append("\(kept) stayed on because it is the input source") }
    }

    // MARK: Naming

    private func name(_ op: PinIOOp) -> String {
        switch op {
        case .slotType(let s, _): return "Output \(s + 1) type"
        case .outputPin(let i, _):
            return i == (cur.outputPins?.count ?? 0) - 1 ? "Subwoofer GPIO" : "Output \(i + 1) GPIO"
        case .pdmEnable: return "Subwoofer output"
        case .bckPin(let r, _): return r == 0 ? "I2S BCK pin" : "I2S slave BCK pin"
        case .clockPinMode: return "I2S clock pin mode"
        case .clockMode: return "I2S clock mode"
        case .mckEnable: return "MCK enable"
        case .mckPin: return "MCK pin"
        case .mckMultiplier: return "MCK multiplier"
        case .spdifPin(let i, _): return i == 0 ? "S/PDIF RX pin" : "S/PDIF \(i + 1) RX pin"
        case .spdifEnable: return "S/PDIF input"
        case .spdifCount: return "S/PDIF input count"
        case .i2sEnable: return "I2S input"
        case .i2sChannels: return "I2S input channels"
        case .i2sRxPin(let p, _): return "I2S serial data \(p + 1) pin"
        case .i2sRate: return "I2S input rate"
        case .inputSource: return "Input source"
        case .adatPin: return "ADAT output pin"
        case .adatEnable: return "ADAT output enable"
        case .adatInPin: return "ADAT input pin"
        case .adatInClockMode: return "ADAT input clock mode"
        case .adatInEnable: return "ADAT input enable"
        }
    }

    private static func describe(_ status: UInt8) -> String {
        switch status {
        case PIN_CONFIG_INVALID_PIN:    return "invalid pin"
        case PIN_CONFIG_PIN_IN_USE:     return "pin already in use"
        case PIN_CONFIG_INVALID_OUTPUT: return "not available on this device"
        case PIN_CONFIG_OUTPUT_ACTIVE:  return "busy, switch it off first"
        case PIN_CONFIG_INVALID_PARAM:  return "invalid value"
        case 0xFF:                      return "no answer from the device"
        default:                        return String(format: "status 0x%02X", status)
        }
    }

    // MARK: State

    /// Issue `op`; on success record it in `cur`.  Reports a refusal unless `quiet`.
    @discardableResult
    private func send(_ op: PinIOOp, quiet: Bool = false) -> Bool {
        let status = device.perform(op)
        guard status == PIN_CONFIG_SUCCESS else {
            if !quiet {
                var text = "\(name(op)) rejected by the device (\(Self.describe(status)))"
                if status == PIN_CONFIG_PIN_IN_USE, let who = device.conflictText(op, pins: pinsNeeded(op)) {
                    text += ": \(who)"
                }
                problems.append(text)
            }
            return false
        }
        if Self.isDeferred(op), !device.waitForApply(op) {
            problems.append("\(name(op)) did not take effect on the device in time")
            return false
        }
        apply(op)
        return true
    }

    /// SETs the device only queues; see `PinIODevice.waitForApply`.
    static func isDeferred(_ op: PinIOOp) -> Bool {
        switch op {
        case .slotType, .inputSource, .clockMode: return true
        default: return false
        }
    }

    /// The pins `op` would take, from the routine's own view of the device.
    private func pinsNeeded(_ op: PinIOOp) -> [UInt8] {
        let pair = activeClockPair
        let clock = cur.bckPins.map { [$0[pair], $0[pair] &+ 1] } ?? []
        switch op {
        case .outputPin(_, let p), .spdifPin(_, let p), .i2sRxPin(_, let p), .mckPin(let p),
             .adatPin(let p), .adatInPin(let p):
            return [p]
        case .bckPin(_, let p): return [p, p &+ 1]
        case .pdmEnable: return cur.outputPins.map { [$0[pdmIndex]] } ?? []
        case .mckEnable: return cur.mckPin.map { [$0] } ?? []
        case .spdifEnable: return spdifPins(0..<(cur.spdifCount ?? 1))
        case .spdifCount(let n):
            let have = cur.spdifCount ?? 1
            return cur.spdifEnabled == true && n > have ? spdifPins(have..<n) : []
        case .i2sEnable:
            let data = cur.i2sRxPins.map { Array($0.prefix((cur.i2sChannels ?? 2) / 2)) } ?? []
            return (anyI2SSlot ? [] : clock) + data
        case .adatEnable: return cur.adatPin.map { [$0] } ?? []
        case .adatInEnable: return cur.adatInPin.map { [$0] } ?? []
        case .slotType, .clockMode, .clockPinMode: return clock
        case .i2sChannels(let n):
            return cur.i2sRxPins.map { Array($0.prefix(n / 2)) } ?? []
        default: return []
        }
    }

    private func spdifPins(_ range: Range<Int>) -> [UInt8] {
        guard let pins = cur.spdifPins else { return [] }
        return range.filter { $0 < pins.count }.map { pins[$0] }
    }

    private func apply(_ op: PinIOOp) {
        switch op {
        case .slotType(let s, let t): cur.slotTypes?[s] = t
        case .outputPin(let i, let p): cur.outputPins?[i] = p
        case .pdmEnable(let e): cur.pdmEnabled = e
        case .bckPin(let r, let p): cur.bckPins?[r] = p
        case .clockPinMode(let m): cur.clockPinMode = m
        case .clockMode(let m): cur.clockMode = m
        case .mckEnable(let e): cur.mckEnabled = e
        case .mckPin(let p): cur.mckPin = p
        case .mckMultiplier(let m): cur.mckMultiplier = m
        case .spdifPin(let i, let p): cur.spdifPins?[i] = p
        case .spdifEnable(let e): cur.spdifEnabled = e
        case .spdifCount(let n): cur.spdifCount = n
        case .i2sEnable(let e): cur.i2sEnabled = e
        case .i2sChannels(let c): cur.i2sChannels = c
        case .i2sRxPin(let i, let p): cur.i2sRxPins?[i] = p
        case .i2sRate(let r): cur.i2sRate = r
        case .inputSource(let s): cur.inputSource = s
        case .adatPin(let p): cur.adatPin = p
        case .adatEnable(let e): cur.adatEnabled = e
        case .adatInPin(let p): cur.adatInPin = p
        case .adatInClockMode(let m): cur.adatInClockMode = m
        case .adatInEnable(let e): cur.adatInEnabled = e
        }
    }

    /// A target value that differs from the current one.
    private func change<T: Equatable>(_ t: T?, _ c: T?) -> T? {
        guard let t, let c, t != c else { return nil }
        return t
    }

    private func element<T: Equatable>(_ t: [T]?, _ c: [T]?, _ i: Int) -> T? {
        guard let t, let c, i < t.count, i < c.count, t[i] != c[i] else { return nil }
        return t[i]
    }

    private var anyI2SSlot: Bool { cur.slotTypes?.contains(1) ?? false }
    private var i2sBlockOn: Bool { cur.i2sEnabled == true }

    /// The clock pair the running clocks use (firmware `outputs_clock_pair`).
    private var activeClockPair: Int {
        (cur.clockPinMode == I2S_CLOCK_PIN_MODE_SPLIT && cur.clockMode == I2S_CLOCK_MODE_SLAVE) ? 1 : 0
    }

    private func bckInUse(_ role: Int) -> Bool { (anyI2SSlot || i2sBlockOn) && role == activeClockPair }
    private func i2sPairInUse(_ p: Int) -> Bool { i2sBlockOn && p < (cur.i2sChannels ?? 2) / 2 }
    private func spdifInUse(_ i: Int) -> Bool { cur.spdifEnabled == true && i < (cur.spdifCount ?? 1) }
    private var pdmIndex: Int { (cur.outputPins?.count ?? 1) - 1 }

    // MARK: Run

    func run() {
        release()
        guard stillCurrent() else { return }
        store()
        guard stillCurrent() else { return }
        move()
        guard stillCurrent() else { return }
        start()
    }

    /// Slots switched to S/PDIF only so their clock pair could move.
    private var parkedSlots: [Int] = []
    /// Where PDM ran before it was stopped to move its pin.
    private var pdmPinBefore: UInt8?

    /// Whether `source` can be selected with the input blocks in `c`.  The
    /// device refuses a source whose block is off (VC_ERR_STATE), and refuses to
    /// switch off or cut the block of the active or pending source.
    private func sourceUsable(_ source: Int, in c: PinIOConfig) -> Bool {
        switch source {
        case INPUT_SOURCE_USB: return true
        case INPUT_SOURCE_ADAT: return c.adatInEnabled == true
        case INPUT_SOURCE_I2S: return c.i2sEnabled == true
        case INPUT_SOURCE_SPDIF: return c.spdifEnabled ?? true
        case INPUT_SOURCE_SPDIF2, INPUT_SOURCE_SPDIF3, INPUT_SOURCE_SPDIF4:
            let i = source - INPUT_SOURCE_SPDIF2 + 1
            return c.spdifEnabled == true && i < (c.spdifCount ?? 1)
        default: return true
        }
    }

    /// The source the device should end on.
    private var finalSource: Int? { tgt.inputSource ?? orig.inputSource }

    private func release() {
        // The source steps aside first when its input block is about to be
        // switched off or cut below it.  A block that stays on holds its pins
        // whether selected or not, so nothing else needs it to move.
        if let src = cur.inputSource {
            var after = cur
            if tgt.adatInEnabled == false { after.adatInEnabled = false }
            if tgt.i2sEnabled == false { after.i2sEnabled = false }
            if tgt.spdifEnabled == false { after.spdifEnabled = false }
            if let n = tgt.spdifCount, let c = after.spdifCount, n < c { after.spdifCount = n }
            if !sourceUsable(src, in: after) {
                let interim = finalSource.flatMap { sourceUsable($0, in: after) ? $0 : nil } ?? INPUT_SOURCE_USB
                send(.inputSource(interim))
            }
        }
        // Input blocks and counts that end off or smaller.
        if let n = change(tgt.spdifCount, cur.spdifCount), n < cur.spdifCount! { send(.spdifCount(n)) }
        if cur.spdifEnabled == true, tgt.spdifEnabled == false { send(.spdifEnable(false)) }
        if cur.i2sEnabled == true, tgt.i2sEnabled == false { send(.i2sEnable(false)) }
        if let n = change(tgt.i2sChannels, cur.i2sChannels), n < cur.i2sChannels! {
            send(.i2sChannels(n))
        }
        // Slots that end as S/PDIF.
        if let types = cur.slotTypes {
            for s in types.indices where types[s] == 1 && element(tgt.slotTypes, cur.slotTypes, s) == 0 {
                send(.slotType(s, 0))
            }
        }
        // The pair the I2S outputs run on cannot move under them
        // (VC_ERR_STATE), so they are parked on S/PDIF until start.
        let pair = activeClockPair
        if anyI2SSlot, element(tgt.bckPins, cur.bckPins, pair) != nil, let types = cur.slotTypes {
            for s in types.indices where types[s] == 1 {
                if send(.slotType(s, 0), quiet: true) { parkedSlots.append(s) }
                else { problems.append("Output \(s + 1) type could not be switched to S/PDIF to move the clock pins") }
            }
        }
        // Enables that end off.  MCK and PDM also stop to move their pin;
        // the others move while running.
        if cur.mckEnabled == true, tgt.mckEnabled == false || change(tgt.mckPin, cur.mckPin) != nil {
            send(.mckEnable(false))
        }
        if cur.adatEnabled == true, tgt.adatEnabled == false { send(.adatEnable(false)) }
        if cur.adatInEnabled == true, tgt.adatInEnabled == false { send(.adatInEnable(false)) }
        if cur.pdmEnabled == true, cur.outputPins != nil {
            let moving = element(tgt.outputPins, cur.outputPins, pdmIndex) != nil
            if tgt.pdmEnabled == false || moving {
                if send(.pdmEnable(false)) {
                    if moving { pdmPinBefore = cur.outputPins?[pdmIndex] }
                    if !device.waitForPdmStop() { notes.append("The subwoofer output was slow to stop") }
                }
            }
        }
    }

    private func store() {
        if cur.pdmEnabled != true, let p = element(tgt.outputPins, cur.outputPins, pdmIndex) {
            send(.outputPin(pdmIndex, p))
        }
        for role in 0..<2 where !bckInUse(role) {
            if let p = element(tgt.bckPins, cur.bckPins, role) { send(.bckPin(role: role, p)) }
        }
        if cur.mckEnabled != true, let p = change(tgt.mckPin, cur.mckPin) { send(.mckPin(p)) }
        if let pins = cur.spdifPins {
            for i in pins.indices where !spdifInUse(i) {
                if let p = element(tgt.spdifPins, cur.spdifPins, i) { send(.spdifPin(i, p)) }
            }
        }
        if let pins = cur.i2sRxPins {
            for p in pins.indices where !i2sPairInUse(p) {
                if let g = element(tgt.i2sRxPins, cur.i2sRxPins, p) { send(.i2sRxPin(p, g)) }
            }
        }
        if cur.adatEnabled != true, let p = change(tgt.adatPin, cur.adatPin) { send(.adatPin(p)) }
        if cur.adatInEnabled != true, let p = change(tgt.adatInPin, cur.adatInPin), p != ADAT_INPUT_PIN_UNSET {
            send(.adatInPin(p))
        }
    }

    /// A pending move of a function that stays in use.
    private enum Mover: Equatable {
        case output(Int), spdif(Int), i2sRx(Int), bck(Int), adatTx, adatRx

        var isInput: Bool {
            switch self { case .spdif, .i2sRx, .adatRx: return true; default: return false }
        }
    }

    private func pin(of m: Mover, in c: PinIOConfig) -> UInt8? {
        switch m {
        case .output(let i): return c.outputPins.flatMap { i < $0.count ? $0[i] : nil }
        case .spdif(let i): return c.spdifPins.flatMap { i < $0.count ? $0[i] : nil }
        case .i2sRx(let p): return c.i2sRxPins.flatMap { p < $0.count ? $0[p] : nil }
        case .bck(let r): return c.bckPins.flatMap { r < $0.count ? $0[r] : nil }
        case .adatTx: return c.adatPin
        case .adatRx: return c.adatInPin
        }
    }

    private func op(_ m: Mover, _ p: UInt8) -> PinIOOp {
        switch m {
        case .output(let i): return .outputPin(i, p)
        case .spdif(let i): return .spdifPin(i, p)
        case .i2sRx(let pair): return .i2sRxPin(pair, p)
        case .bck(let r): return .bckPin(role: r, p)
        case .adatTx: return .adatPin(p)
        case .adatRx: return .adatInPin(p)
        }
    }

    private func pendingMoves() -> [Mover] {
        var all: [Mover] = []
        let slots = max(0, (cur.outputPins?.count ?? 0) - 1)
        all += (0..<slots).map { .output($0) }
        if cur.pdmEnabled == true { all.append(.output(pdmIndex)) }
        if let pins = cur.spdifPins { all += pins.indices.filter { spdifInUse($0) }.map { .spdif($0) } }
        if let pins = cur.i2sRxPins { all += pins.indices.filter { i2sPairInUse($0) }.map { .i2sRx($0) } }
        all += (0..<2).filter { bckInUse($0) }.map { .bck($0) }
        if cur.adatEnabled == true { all.append(.adatTx) }
        if cur.adatInEnabled == true { all.append(.adatRx) }
        return all.filter { m in
            guard let want = pin(of: m, in: tgt), let have = pin(of: m, in: cur) else { return false }
            return want != have && !(m == .adatRx && want == ADAT_INPUT_PIN_UNSET)
        }
    }

    /// Attempt every pending move, quietly, until a pass makes no progress.
    private func settleMoves() -> [Mover] {
        var pending = pendingMoves()
        var progress = true
        while progress && !pending.isEmpty && stillCurrent() {
            progress = false
            for m in pending {
                guard let want = pin(of: m, in: tgt) else { continue }
                if send(op(m, want), quiet: true) { progress = true }
            }
            pending = pendingMoves()
        }
        return pending
    }

    private func move() {
        var left = settleMoves()
        // What remains is either a swap (each wants a pin another holds) or a
        // real refusal.  Break swaps through a temporary pin.
        var attempts = 0
        while !left.isEmpty, attempts < left.count, stillCurrent() {
            attempts += 1
            guard let (m, temp) = swapBreak(left) else { break }
            let original = pin(of: m, in: cur)!
            guard send(op(m, temp), quiet: true) else { break }
            let before = left.count
            left = settleMoves()
            if left.count < before, !left.contains(m) {
                notes.append("\(moverName(m)) was routed through GPIO \(temp) briefly to swap pins")
            } else if pin(of: m, in: cur) == temp {
                // Nothing moved into its old pin: put it back.
                if !send(op(m, original), quiet: true) {
                    problems.append("\(moverName(m)) was left on GPIO \(temp) after a failed swap; set it by hand")
                }
                break
            }
        }
        for m in pendingMoves() {
            guard let want = pin(of: m, in: tgt) else { continue }
            let swap = blocking(m) != nil
            // One last attempt, reported, so the message carries the reason.
            if !send(op(m, want)), swap {
                notes.append("\(moverName(m)) could not swap pins automatically; move it by hand")
            }
        }
    }

    private func moverName(_ m: Mover) -> String {
        switch m {
        case .output(let i): return i == pdmIndex ? "Subwoofer" : "Output \(i + 1)"
        case .spdif(let i): return i == 0 ? "S/PDIF input" : "S/PDIF input \(i + 1)"
        case .i2sRx(let p): return "I2S serial data \(p + 1)"
        case .bck: return "I2S clock pins"
        case .adatTx: return "ADAT output"
        case .adatRx: return "ADAT input"
        }
    }

    /// Every pin a mover occupies: the clock pair is BCK and LRCLK (BCK + 1).
    private func heldPins(of m: Mover, in c: PinIOConfig) -> [UInt8] {
        guard let p = pin(of: m, in: c) else { return [] }
        if case .bck = m { return [p, p &+ 1] }
        return [p]
    }

    /// The pending mover holding a pin `m` wants, if any.  Counts the LRCLK
    /// pin, so a swap with the clock pair (now held whenever the I2S input
    /// block is on) is seen and broken through a temporary pin.
    private func blocking(_ m: Mover) -> Mover? {
        let want = heldPins(of: m, in: tgt)
        guard !want.isEmpty else { return nil }
        return pendingMoves().first { $0 != m && !Set(heldPins(of: $0, in: cur)).isDisjoint(with: want) }
    }

    /// Choose who moves to a temporary pin, and which pin.  An input in the
    /// swap goes first, since an input pin drives nothing.  An output only
    /// takes a pin no function claims at all, active or stored, and that no
    /// target of this apply wants.
    private func swapBreak(_ left: [Mover]) -> (Mover, UInt8)? {
        // Members of a swap: each is blocked by another pending mover.
        let members = left.filter { blocking($0) != nil && $0 != .bck(0) && $0 != .bck(1) }
        guard !members.isEmpty else { return nil }
        let targets = Set(pendingMoves().compactMap { pin(of: $0, in: tgt) })
            .union([tgt.mckPin, tgt.adatPin, tgt.adatInPin].compactMap { $0 })
            .union(tgt.outputPins ?? []).union(tgt.spdifPins ?? []).union(tgt.i2sRxPins ?? [])
            .union(tgt.bckPins.map { $0.flatMap { [$0, $0 &+ 1] } } ?? [])
        let ordered = members.filter(\.isInput) + members.filter { !$0.isInput }
        let claimed = device.claimedPins()
        for m in ordered {
            let mask: UInt64?
            switch m {
            case .output(let i): mask = device.freeMask(outputIndex: i)
            case .spdif(let i): mask = device.freeMask(spdifInput: i)
            case .i2sRx(let p): mask = device.freeMask(i2sPair: p)
            default: mask = nil
            }
            guard let mask else { continue }
            for p in pins(in: mask) where !targets.contains(p) {
                if !m.isInput {
                    guard let claimed, !claimed.contains(p) else { continue }
                }
                return (m, p)
            }
        }
        return nil
    }

    private func start() {
        // Clocks: pin mode, then clock mode, then the slots and the input.
        if let m = change(tgt.clockPinMode, cur.clockPinMode) { send(.clockPinMode(m)) }
        if let m = change(tgt.clockMode, cur.clockMode) { send(.clockMode(m)) }
        // Clock pins of a pair that came out of use above, now that the mode settled.
        for role in 0..<2 where !bckInUse(role) {
            if let p = element(tgt.bckPins, cur.bckPins, role) { send(.bckPin(role: role, p)) }
        }
        if let types = cur.slotTypes {
            for s in types.indices {
                let want = tgt.slotTypes.map { s < $0.count ? $0[s] : types[s] } ?? (parkedSlots.contains(s) ? 1 : types[s])
                if want == 1, cur.slotTypes![s] != 1 { send(.slotType(s, 1)) }
            }
        }
        if let n = change(tgt.i2sChannels, cur.i2sChannels), n > cur.i2sChannels! { send(.i2sChannels(n)) }
        if let r = change(tgt.i2sRate, cur.i2sRate) { send(.i2sRate(r)) }
        if let m = change(tgt.mckMultiplier, cur.mckMultiplier) { send(.mckMultiplier(m)) }

        // Enables, back to the target or to how they were.  Their pins were
        // stored above, so a refusal here means another function holds one.
        // A count raise goes before its block switch: while the block is off it
        // is a plain store, and the switch then claims every input as one unit.
        if (tgt.mckEnabled ?? orig.mckEnabled) == true, cur.mckEnabled == false { send(.mckEnable(true)) }
        if let n = change(tgt.spdifCount, cur.spdifCount), n > cur.spdifCount! { send(.spdifCount(n)) }
        if (tgt.spdifEnabled ?? orig.spdifEnabled) == true, cur.spdifEnabled == false { send(.spdifEnable(true)) }
        if (tgt.i2sEnabled ?? orig.i2sEnabled) == true, cur.i2sEnabled == false { send(.i2sEnable(true)) }
        if let m = change(tgt.adatInClockMode, cur.adatInClockMode) { send(.adatInClockMode(m)) }
        if (tgt.adatEnabled ?? orig.adatEnabled) == true, cur.adatEnabled == false { send(.adatEnable(true)) }
        if (tgt.adatInEnabled ?? orig.adatInEnabled) == true, cur.adatInEnabled == false { send(.adatInEnable(true)) }
        // The source last: its input is running again by now.  A source whose
        // input the target leaves off cannot come back; say where it stayed.
        if let src = finalSource, let now = cur.inputSource, now != src {
            if sourceUsable(src, in: cur) {
                send(.inputSource(src))
            } else {
                notes.append("The input source stayed on \(now == INPUT_SOURCE_USB ? "USB" : "source \(now)") because its input is now switched off")
            }
        }

        let pdmOn = tgt.pdmEnabled ?? orig.pdmEnabled
        if pdmOn == true, cur.pdmEnabled == false {
            if !send(.pdmEnable(true)), restoreRefusedPdm, let old = pdmPinBefore {
                // Put the pin back where PDM ran, and run it again there.
                if device.waitForPdmStop(), send(.outputPin(pdmIndex, old), quiet: true), send(.pdmEnable(true), quiet: true) {
                    notes.append("The subwoofer stayed on GPIO \(old)")
                } else {
                    problems.append("The subwoofer output could not be restarted; check its pin")
                }
            }
        }
    }
}
