import Foundation
import Combine

// MARK: - Pin map store
//
// The device's answer to "which GPIOs may each function use", cached per
// connection.  `SYS.PIN_STATE` and `SYS.PIN_CLAIMS` are read whenever the pin
// generation may have moved; the per-function availability GETs (about 23 on
// RP2350) only while a pin view is on screen, so a front-panel source toggle
// does not cost a sweep over DSPi Link when nobody is looking.

/// One availability query, by function and address.
enum PinAvailKey: Hashable {
    /// Output pin by `OUTPUT.PIN` index; PDM sits at `pdmPinIndex`.
    case output(Int)
    /// 0 master or unified pair, 1 slave pair.
    case bck(Int)
    case mck
    case spdifRx(Int)
    case i2sRx(Int)
    case dacMute
    case adatTx
    case adatRx
    case uart
    case i2c

    var command: VendorCommand {
        switch self {
        case .output: return VC.OUTPUT.PIN_AVAIL
        case .bck: return VC.CLOCK.I2S_BCK_PIN_AVAIL
        case .mck: return VC.CLOCK.MCK_PIN_AVAIL
        case .spdifRx: return VC.INPUT.SPDIF_RX_PIN_AVAIL
        case .i2sRx: return VC.INPUT.I2S_RX_PIN_AVAIL
        case .dacMute: return VC.OUTPUT.DAC_MUTE_PIN_AVAIL
        case .adatTx: return VC.OUTPUT.ADAT_TX_PIN_AVAIL
        case .adatRx: return VC.INPUT.ADAT_RX_PIN_AVAIL
        case .uart: return VC.XPORT.UART_PIN_AVAIL
        case .i2c: return VC.XPORT.I2C_PIN_AVAIL
        }
    }

    var address: UInt16 {
        switch self {
        case .output(let i), .bck(let i), .spdifRx(let i), .i2sRx(let i): return UInt16(i)
        default: return 0
        }
    }
}

struct CsAvailKey: Hashable {
    var slot: Int
    var type: Int
}

/// What the board shape says to sweep.  Captured on main when a refresh is
/// requested, so the store never reads published view-model state off main.
struct PinMapShape: Equatable {
    var pinOutputs = 0          // slots plus PDM
    var spdifInputs = 0
    var i2sPairs = 0
    var csTypes: [Int] = []     // binding types the caps table offers

    var keys: [PinAvailKey] {
        (0..<pinOutputs).map { .output($0) } + [.bck(0), .bck(1), .mck]
            + (0..<spdifInputs).map { .spdifRx($0) } + (0..<i2sPairs).map { .i2sRx($0) }
            + [.dacMute, .adatTx, .adatRx, .uart, .i2c]
    }
}

/// One consistent picture of the device's pin map.
struct PinMapSnapshot: Equatable {
    enum Support: Equatable {
        case unknown
        case supported
        /// The firmware predates the queries: pin changes need a firmware update.
        case absent
        /// The DSPi Link hub refused the reads (an older hub policy).
        case denied
        /// The device refused the read for another reason.
        case failed
    }
    var support: Support = .unknown
    var state: PinStateReply?
    var claims: [PinClaim] = []
    var avail: [PinAvailKey: PinAvailability] = [:]
    var cs: [CsAvailKey: PinAvailability] = [:]
    /// Pin generation the availability entries were read at; nil when never swept.
    var sweptGeneration: UInt32?

    var pinGeneration: UInt32? { state?.generation }

    func claims(on pin: UInt8) -> [PinClaim] { claims.filter { $0.gpio == pin } }
}

final class PinMap: ObservableObject {
    @Published private(set) var snapshot = PinMapSnapshot()

    private let transport: any DeviceTransport
    private let queue = DispatchQueue(label: "com.weeblabs.dspi.pinMap", qos: .userInitiated)

    // Main thread only.
    private var watchers = 0
    private var csWatchers: [Int: Int] = [:]
    private var shape = PinMapShape()
    private var running = false
    private var again = false
    private var forceNext = false
    private var retryScheduled = false
    private var busyRetries = 0
    private var transientRetries = 0

    /// How many times a sweep reruns when the generation moves under it.
    private static let maxReruns = 3
    private static let busyRetryLimit = 20
    private static let transientRetryLimit = 5

    init(transport: any DeviceTransport) {
        self.transport = transport
    }

    var isWatched: Bool { watchers > 0 || !csWatchers.isEmpty }

    // MARK: Watching (main thread)

    /// A pin view appeared: sweep now if the cached answers are stale.
    func watch(shape: PinMapShape) {
        watchers += 1
        self.shape = shape
        requestRefresh()
    }

    func unwatch() { watchers = max(0, watchers - 1) }

    /// A Control Surfaces slot editor appeared: fetch every type for it.
    func watchCS(slot: Int, shape: PinMapShape) {
        csWatchers[slot, default: 0] += 1
        self.shape = shape
        requestRefresh()
    }

    func unwatchCS(slot: Int) {
        guard let n = csWatchers[slot] else { return }
        if n <= 1 { csWatchers[slot] = nil } else { csWatchers[slot] = n - 1 }
    }

    /// Update the board shape without changing watchers (after a connect).
    func updateShape(_ shape: PinMapShape) { self.shape = shape }

    /// Tests only: install a snapshot as if the device had sent it.
    func injectForTesting(_ snapshot: PinMapSnapshot) { self.snapshot = snapshot }

    /// Drop everything; a new connection starts with no answers.
    func reset() {
        snapshot = PinMapSnapshot()
        busyRetries = 0
        transientRetries = 0
    }

    // MARK: Refresh

    /// Re-read what may have changed.  `force` re-reads even when the pin
    /// generation looks unchanged: a board that rebooted behind a hub restarts
    /// the counter at 0, so an equal number proves nothing after a RESYNC or
    /// BULK_INVALIDATED.  Coalesced; safe to call from any thread.
    func requestRefresh(force: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.requestRefresh(force: force) }
            return
        }
        if force { forceNext = true }
        guard !running else { again = true; return }
        running = true
        let job = Job(force: forceNext, sweep: watchers > 0, csSlots: Array(csWatchers.keys),
                      shape: shape, previous: snapshot, connection: transport.generation)
        forceNext = false
        queue.async { [weak self] in
            guard let self else { return }
            let outcome = self.run(job)
            DispatchQueue.main.async { self.finish(job, outcome) }
        }
    }

    private struct Job {
        var force: Bool
        var sweep: Bool
        var csSlots: [Int]
        var shape: PinMapShape
        var previous: PinMapSnapshot
        var connection: UInt64
    }

    private enum Outcome {
        case updated(PinMapSnapshot, busy: Bool)
        /// Lock or timeout: keep the old data and try again later.
        case deferred
        /// No device: keep the old data; the next connect refreshes.
        case gone
        case unchanged
    }

    private func finish(_ job: Job, _ outcome: Outcome) {
        running = false
        if transport.generation == job.connection {
            switch outcome {
            case .updated(let snap, let busy):
                if snap != snapshot { snapshot = snap }
                if busy { scheduleRetry(busy: true) } else { busyRetries = 0 }
            case .deferred:
                // Bounded: a lock held for long would otherwise post the lock
                // notice every two seconds.  The next notification retries.
                transientRetries += 1
                if transientRetries <= Self.transientRetryLimit { scheduleRetry(busy: false) }
            case .gone, .unchanged:
                break
            }
            if case .updated = outcome { transientRetries = 0 }
        }
        if again {
            again = false
            requestRefresh()
        }
    }

    private func scheduleRetry(busy: Bool) {
        if busy {
            busyRetries += 1
            guard busyRetries <= Self.busyRetryLimit else { return }
        }
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (busy ? 0.25 : 2.0)) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.requestRefresh(force: true)
        }
    }

    /// Statuses that end a sweep early and keep the cached data.
    private static func isTransient(_ s: LinkStatus) -> Bool {
        switch s {
        case .locked, .timeout, .rateLimited, .busy: return true
        default: return false
        }
    }

    private func read(_ command: VendorCommand, value: UInt16 = 0, length: UInt16) -> Result<Data, LinkStatus> {
        transport.get(command, value: value, length: length)
    }

    /// Runs on `queue`.
    private func run(_ job: Job) -> Outcome {
        var snap = job.previous
        var rerun = 0
        while true {
            guard transport.generation == job.connection else { return .unchanged }

            // 1. Generation, GPIO set and substitutions.
            let state: PinStateReply
            switch read(VC.SYS.PIN_STATE, length: PinStateReply.size) {
            case .success(let data):
                guard let s = PinStateReply.decode(data) else { return .deferred }
                state = s
            case .failure(.vcUnknown), .failure(.vcDirection):
                snap = PinMapSnapshot()
                snap.support = .absent
                return .updated(snap, busy: false)
            case .failure(.denied):
                snap = PinMapSnapshot()
                snap.support = .denied
                return .updated(snap, busy: false)
            case .failure(.noDevice):
                return .gone
            case .failure(let s):
                if Self.isTransient(s) { return .deferred }
                // Any other refusal: the pickers say the map is unavailable
                // rather than showing a lone current pin with no reason.
                snap = PinMapSnapshot()
                snap.support = .failed
                // Often passing (a Link board whose protocol is not known
                // yet, a one-off STALL), so try once more shortly.
                return .updated(snap, busy: true)
            }

            let moved = job.force || snap.pinGeneration != state.generation
            let needSweep = job.sweep && (moved || snap.sweptGeneration != state.generation)
            let needCS = !job.csSlots.isEmpty
                && (moved || job.csSlots.contains { slot in !job.shape.csTypes.allSatisfy { snap.cs[CsAvailKey(slot: slot, type: $0)] != nil } })
            if !moved && !needSweep && !needCS && snap.support == .supported {
                return .unchanged
            }
            snap.support = .supported
            snap.state = state
            var busy = false
            var mismatch = false

            // 2. Owners.  BUSY while a Control Surfaces revert holds two sets
            // of bindings; keep the old list and retry rather than fail.
            if moved || snap.claims.isEmpty {
                switch read(VC.SYS.PIN_CLAIMS, length: PinClaimsReply.requestSize) {
                case .success(let data):
                    if let r = PinClaimsReply.decode(data) {
                        snap.claims = r.claims
                        if r.generation != state.generation { mismatch = true }
                    }
                case .failure(.vcBusy):
                    busy = true
                case .failure(.noDevice):
                    return .gone
                case .failure(let s):
                    if Self.isTransient(s) { return .deferred }
                }
            }

            // 3. Availability, only while watched.
            if needSweep {
                var avail: [PinAvailKey: PinAvailability] = [:]
                for key in job.shape.keys {
                    switch read(key.command, value: key.address, length: PinAvailability.maxReplySize) {
                    case .success(let data):
                        guard let a = PinAvailability.decode(data) else { continue }
                        if a.status == VC_ERR_BUSY_STATUS { busy = true }
                        if a.generation != state.generation { mismatch = true }
                        avail[key] = a
                    case .failure(.noDevice):
                        return .gone
                    case .failure(let s):
                        // A command or address this build lacks is simply absent.
                        if Self.isTransient(s) { return .deferred }
                    }
                }
                snap.avail = avail
                snap.sweptGeneration = state.generation
            } else if moved {
                // Stale answers must not outlive the generation they describe.
                snap.avail = [:]
                snap.sweptGeneration = nil
            }

            // 4. Control Surfaces, every offered type of each watched slot.
            if moved { snap.cs = [:] }
            if !job.csSlots.isEmpty {
                for slot in job.csSlots {
                    for type in job.shape.csTypes {
                        let key = CsAvailKey(slot: slot, type: type)
                        switch read(VC.CS.BINDING_PIN_AVAIL, value: UInt16(type << 8 | slot),
                                    length: UInt16(PinAvailability.csReplySize)) {
                        case .success(let data):
                            guard let a = PinAvailability.decodeCS(data) else { continue }
                            if a.status == UInt8(CS_STATUS_BUSY) { busy = true }
                            if a.generation != state.generation { mismatch = true }
                            snap.cs[key] = a
                        case .failure(.noDevice):
                            return .gone
                        case .failure(let s):
                            if Self.isTransient(s) { return .deferred }
                        }
                    }
                }
            }

            // The map moved mid-sweep: read it all again so one snapshot never
            // mixes two generations.
            if mismatch {
                if rerun < Self.maxReruns {
                    rerun += 1
                    snap.sweptGeneration = nil
                    continue
                }
                // Still moving: publish what we have, but marked stale, and retry.
                snap.sweptGeneration = nil
                return .updated(snap, busy: true)
            }
            return .updated(snap, busy: busy)
        }
    }
}

/// `VC_ERR_BUSY` as it appears in an availability reply's status byte.
let VC_ERR_BUSY_STATUS: UInt8 = 0x17
/// `VC_ERR_STATE`: the SET would be refused whatever pin is sent.
let VC_ERR_STATE_STATUS: UInt8 = 0x18
