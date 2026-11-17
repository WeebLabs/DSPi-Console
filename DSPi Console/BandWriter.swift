import Foundation

/// Sends FILTER.BAND and FILTER.BAND_BYPASS writes so that the device ends up
/// with the latest value of every band, however fast they arrive.
///
/// Firmware 1.1.7 has one pending band slot for the whole device.  A write is
/// accepted as "queued" and the main loop applies it a millisecond or two
/// later; a band write that arrives while the slot is full is refused with
/// VC_ERR_BUSY and changes nothing (1.1.6 instead let the last write win).  The
/// app sends bands in bursts (a drag on a linked pair, Clear All, paste, AutoEQ,
/// preset documents), so a plain fire-and-forget send would lose all but the
/// first write of each burst (client update guide section 4, migration guide
/// 13.2.7).
///
/// So writes are coalesced per band (only the newest value matters) and sent
/// one at a time, each waiting for the device's verdict.  On busy the newest
/// value for that band is resent after a short pause, for at most `busyBudget`;
/// a band still refused then stays pending and is tried again after
/// `busyBackoff` (a flash write can hold the slot for tens of milliseconds).
final class BandWriter {
    private enum Pending: Equatable {
        /// A whole 16-byte FILTER.BAND record.
        case record(Data)
        /// Only the bypass flag changed (FILTER.BAND_BYPASS).
        case bypass(Bool)
    }

    private let transport: any DeviceTransport
    private let queue = DispatchQueue(label: "com.weeblabs.dspi.bandwriter")
    private let lock = NSLock()
    /// Newest pending write per band address `(channel << 8) | band`, with the
    /// order the bands first became pending.
    private var pending: [UInt16: Pending] = [:]
    private var order: [UInt16] = []
    private var draining = false
    private var pendingGeneration: UInt64

    /// The firmware applies a band in 1-2 ms; its own UART/I2C retry gives up
    /// after about 50 ms, and so do we.
    var retryDelay: TimeInterval = 0.0015
    var busyBudget: TimeInterval = 0.05
    var busyBackoff: TimeInterval = 0.2

    init(transport: any DeviceTransport) {
        self.transport = transport
        self.pendingGeneration = transport.generation
    }

    /// Queue a whole band record.  Replaces anything pending for that band.
    func write(address: UInt16, record: Data) {
        enqueue(address, .record(record))
    }

    /// Queue a bypass change.  Folded into a whole record already pending for
    /// that band, so the record cannot overtake it with a stale flag.
    func writeBypass(address: UInt16, bypass: Bool) {
        lock.lock()
        if case .record(var r) = pending[address], r.count >= 2 {
            r[r.startIndex + 1] = bypass ? 1 : 0
            pending[address] = .record(r)
            lock.unlock()
            startDraining()
            return
        }
        lock.unlock()
        enqueue(address, .bypass(bypass))
    }

    /// True when no write is waiting or in flight, for tests and diagnostics.
    var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending.isEmpty && !draining
    }

    private func enqueue(_ address: UInt16, _ write: Pending) {
        lock.lock()
        // A new device must not receive the old one's pending bands.
        if transport.generation != pendingGeneration {
            pending.removeAll(); order.removeAll()
            pendingGeneration = transport.generation
        }
        if pending[address] == nil { order.append(address) }
        pending[address] = write
        lock.unlock()
        startDraining()
    }

    private func startDraining() {
        lock.lock()
        guard !draining else { lock.unlock(); return }
        draining = true
        lock.unlock()
        queue.async { self.drain() }
    }

    /// Runs on `queue`.
    private func drain() {
        while let (address, write) = takeNext() {
            let started = Date()
            var current = write
            while true {
                let status = send(address, current)
                guard status == .vcBusy else {
                    if status != .ok {
                        DeviceRefusal.notice.post(VendorRefusal(command: command(for: current),
                                                                value: address, status: status))
                    }
                    break
                }
                // Resend the newest value for this band, which may have
                // changed while we waited.
                Thread.sleep(forTimeInterval: retryDelay)
                if let newer = takeIfPending(address) { current = newer }
                if Date().timeIntervalSince(started) > busyBudget {
                    print("[BANDWRITER] band 0x\(String(address, radix: 16)) still busy after \(Int(busyBudget * 1000)) ms; retrying shortly")
                    keepPending(address, current)
                    finishDraining(retryAfter: busyBackoff)
                    return
                }
            }
        }
        finishDraining(retryAfter: nil)
    }

    private func takeNext() -> (UInt16, Pending)? {
        lock.lock(); defer { lock.unlock() }
        guard transport.generation == pendingGeneration else {
            pending.removeAll(); order.removeAll()
            return nil
        }
        while let address = order.first {
            order.removeFirst()
            if let write = pending.removeValue(forKey: address) { return (address, write) }
        }
        return nil
    }

    private func takeIfPending(_ address: UInt16) -> Pending? {
        lock.lock(); defer { lock.unlock() }
        guard let write = pending.removeValue(forKey: address) else { return nil }
        order.removeAll { $0 == address }
        return write
    }

    /// Give a band that stayed busy back to the queue, unless a newer value
    /// for it has arrived meanwhile.
    private func keepPending(_ address: UInt16, _ write: Pending) {
        lock.lock()
        if pending[address] == nil {
            pending[address] = write
            order.insert(address, at: 0)
        }
        lock.unlock()
    }

    /// A write that arrived after the last take found us still draining, so
    /// it is ours to send; after a busy give-up, wait first.
    private func finishDraining(retryAfter delay: TimeInterval?) {
        lock.lock()
        draining = false
        let more = !pending.isEmpty
        lock.unlock()
        guard more else { return }
        if let delay {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.startDraining() }
        } else {
            startDraining()
        }
    }

    private func command(for write: Pending) -> VendorCommand {
        if case .bypass = write { return VC.FILTER.BAND_BYPASS }
        return VC.FILTER.BAND
    }

    private func send(_ address: UInt16, _ write: Pending) -> LinkStatus {
        switch write {
        case .record(let r): return transport.setAndWait(VC.FILTER.BAND, value: address, data: r)
        case .bypass(let b): return transport.setAndWait(VC.FILTER.BAND_BYPASS, value: address, data: Data([b ? 1 : 0]))
        }
    }
}
