import Foundation
import Combine

// MARK: - Wire structures
//
// The device-side spectrum analyser, as described by
// Documentation/Features/spectrum_analyser_spec.md in the firmware repository.
// Every structure here is a byte-for-byte reading of a packed little-endian
// struct, so the parsers check the length they were given rather than trusting
// the caller: firmware without the analyser STALLs these requests, and a STALL
// arrives as a nil or a short read.

/// The staged configuration (REQ_RTA_SET_CONFIG / GET_CONFIG, 12 bytes).
///
/// A change of tap, channel mask or FFT size restarts the frame in flight and
/// clears the averaging; a change of averaging or peak decay alone takes effect
/// at the next publish.  Byte 5 and the last two bytes are reserved and go out
/// as zero.
struct RtaConfig: Equatable {
    var tap: UInt8 = RTA_TAP_OUTPUT
    var channelMask: UInt16 = 1
    var fftOrder: UInt8 = 10
    var avgMs: UInt16 = 300
    var peakDecayDBs: UInt8 = 12
    var flags: UInt8 = 0

    /// Points in the transform: 256, 512 or 1024.
    var points: Int { 1 << Int(fftOrder) }

    func toData() -> Data {
        var d = Data(count: RTA_CONFIG_SIZE)
        d[0] = RTA_CFG_VERSION
        d[1] = tap
        d[2] = UInt8(channelMask & 0xFF)
        d[3] = UInt8(channelMask >> 8)
        d[4] = fftOrder
        d[6] = UInt8(avgMs & 0xFF)
        d[7] = UInt8(avgMs >> 8)
        d[8] = peakDecayDBs
        d[9] = flags
        return d
    }

    static func fromData(_ d: Data) -> RtaConfig? {
        guard d.count >= RTA_CONFIG_SIZE, d[d.startIndex] == RTA_CFG_VERSION else { return nil }
        let b = [UInt8](d)
        return RtaConfig(
            tap: b[1],
            channelMask: UInt16(b[2]) | (UInt16(b[3]) << 8),
            fftOrder: b[4],
            avgMs: UInt16(b[6]) | (UInt16(b[7]) << 8),
            peakDecayDBs: b[8],
            flags: b[9])
    }
}

/// What this device's analyser can do (REQ_RTA_GET_CAPS wValue 0, 16 bytes).
/// A successful read is the feature probe: the analyser is transient and absent
/// from the bulk parameter blob, so there is no wire-format version to gate on.
struct RtaCaps: Equatable {
    var version: UInt8 = 0
    var inputChannels: UInt8 = 0
    var outputChannels: UInt8 = 0
    var fftOrderMin: UInt8 = UInt8(RTA_ORDER_MIN)
    var fftOrderMax: UInt8 = UInt8(RTA_ORDER_MAX)
    var fftOrderDefault: UInt8 = 10
    var bassBands: UInt8 = 0
    var maxBands: UInt8 = UInt8(RTA_MAX_BANDS)
    var levelZero: UInt8 = RTA_LEVEL_ZERO_DBFS
    /// Measured, not theoretical: 78 dB for the RP2040 Q15 kernel, 120 for the
    /// RP2350 float kernel.  Worth showing, because it is the floor a reading
    /// can be trusted down to.
    var dynamicRangeDB: UInt8 = 0
    var idleTimeoutMs: UInt16 = 0
    var maxBinFrame: UInt16 = 0
    /// Bass detection has a separate usable range from the FFT arithmetic.
    var bassDynamicRangeDB: UInt16 = 0
    var bandFrameSize: Int { 8 + 2 * Int(maxBands) }

    static func fromData(_ d: Data) -> RtaCaps? {
        guard d.count >= RTA_CAPS_SIZE else { return nil }
        let b = [UInt8](d)
        // Band indices and strides changed in V3. Never send V3 config to
        // an older/newer protocol or interpret its frames with this layout.
        guard b[0] == RTA_CFG_VERSION,
              Int(b[3]) >= RTA_ORDER_MIN, Int(b[4]) <= RTA_ORDER_MAX, b[3] <= b[5], b[5] <= b[4],
              b[7] > 0, Int(b[7]) <= RTA_MAX_BANDS, b[6] <= b[7] else { return nil }
        return RtaCaps(
            version: b[0],
            inputChannels: b[1],
            outputChannels: b[2],
            fftOrderMin: b[3],
            fftOrderMax: b[4],
            fftOrderDefault: b[5],
            bassBands: b[6],
            maxBands: b[7],
            levelZero: b[8],
            dynamicRangeDB: b[9],
            idleTimeoutMs: UInt16(b[10]) | (UInt16(b[11]) << 8),
            maxBinFrame: UInt16(b[12]) | (UInt16(b[13]) << 8),
            bassDynamicRangeDB: UInt16(b[14]) | (UInt16(b[15]) << 8))
    }
}

/// One channel's third-octave picture (REQ_RTA_GET_BANDS, 82 bytes).
///
/// `avg` and `peak` always carry `RTA_MAX_BANDS` slots; only the first
/// `nBands` are meaningful at the current sample rate. The first `bassBands`
/// are continuous filter-bank readings; FFT population rules apply only above
/// them. Raw FFT bins remain a separate product.
struct RtaBandFrame: Equatable {
    var channel: UInt8 = 0
    var seq: UInt8 = 0
    var nBands: UInt8 = 0
    /// Milliseconds since this channel's last frame; 0xFFFF = never.
    var ageMs: UInt16 = 0xFFFF
    var avg: [UInt8] = Array(repeating: 0, count: RTA_MAX_BANDS)
    var peak: [UInt8] = Array(repeating: 0, count: RTA_MAX_BANDS)

    /// True once the channel has produced at least one frame.
    var hasData: Bool { ageMs != 0xFFFF }

    static func fromData(_ d: Data, at offset: Int = 0,
                         maxBands: Int = RTA_MAX_BANDS) -> RtaBandFrame? {
        guard maxBands > 0, maxBands <= RTA_MAX_BANDS,
              offset >= 0, offset <= d.count else { return nil }
        let size = 8 + 2 * maxBands
        guard d.count - offset >= size else { return nil }
        let b = [UInt8](d[(d.startIndex + offset)..<(d.startIndex + offset + size)])
        guard b[0] == RTA_CFG_VERSION, Int(b[3]) <= maxBands else { return nil }
        return RtaBandFrame(
            channel: b[1],
            seq: b[2],
            nBands: b[3],
            ageMs: UInt16(b[4]) | (UInt16(b[5]) << 8),
            avg: Array(b[8..<(8 + maxBands)]),
            peak: Array(b[(8 + maxBands)..<(8 + 2 * maxBands)]))
    }
}

/// The most recent frame's raw magnitude bins (REQ_RTA_GET_BINS).
///
/// Only the latest frame is kept, tagged with the channel it came from, so a
/// multichannel selection makes this rotate.  The sequence number appears in
/// the header and again as the frame's last byte; a host that reads the frame
/// while the engine is publishing sees the two disagree and re-reads.
struct RtaBinFrame: Equatable {
    var channel: UInt8 = 0
    var seq: UInt8 = 0
    var fftOrder: UInt8 = 0
    var sampleRateHz: UInt32 = 0
    /// One level byte per bin, bin k centred at
    /// k * sampleRateHz / (2 * bins.count).
    var bins: [UInt8] = []

    /// Hz of bin `k`.
    func frequency(ofBin k: Int) -> Double {
        guard !bins.isEmpty else { return 0 }
        return Double(k) * Double(sampleRateHz) / Double(2 * bins.count)
    }

    /// Parses a whole frame, however many chunks it was read in.  Returns nil
    /// for a short read, a header that does not describe the bytes that
    /// followed, or a sequence tail that disagrees with the header - the last
    /// of which means the engine republished mid-read and the caller should
    /// simply read it again.
    static func fromData(_ d: Data) -> RtaBinFrame? {
        guard d.count >= RTA_BIN_HEADER_SIZE else { return nil }
        let b = [UInt8](d)
        guard b[0] == RTA_CFG_VERSION else { return nil }
        let seq = b[2]
        // 0xFF is the in-progress marker the engine writes before it fills the
        // frame, never a published sequence number.
        guard seq != 0xFF else { return nil }
        let nBins = Int(UInt16(b[8]) | (UInt16(b[9]) << 8))
        let tail = RTA_BIN_HEADER_SIZE + nBins
        guard nBins > 0, b.count > tail, b[tail] == seq else { return nil }
        return RtaBinFrame(
            channel: b[1],
            seq: seq,
            fftOrder: b[3],
            sampleRateHz: UInt32(b[4]) | (UInt32(b[5]) << 8) | (UInt32(b[6]) << 16) | (UInt32(b[7]) << 24),
            bins: Array(b[RTA_BIN_HEADER_SIZE..<tail]))
    }
}

/// Engine telemetry (REQ_RTA_GET_STATUS, 24 bytes).  Reading it deliberately
/// does not count as a data read, so polling status neither starts the analyser
/// nor keeps it alive.
struct RtaStatus: Equatable {
    var state: UInt8 = RTA_STATE_IDLE
    var tap: UInt8 = RTA_TAP_OUTPUT
    /// The channel being captured or transformed; RTA_CH_NONE while idle.
    var channel: UInt8 = RTA_CH_NONE
    var liveCount: UInt8 = 0
    /// Selected AND actually live: disabled outputs and inactive input rows are
    /// dropped from the rotation, so they never slow the channels that remain.
    var liveMask: UInt16 = 0
    var framesPerSecond: UInt16 = 0
    /// Main-loop microseconds per second spent transforming.  The existing CPU
    /// figure measures only the packet callback and cannot see this work.
    var busyUsPerSecond: UInt16 = 0
    var lastFrameUs: UInt16 = 0
    var idleMs: UInt16 = 0xFFFF
    var sampleRateHz: UInt32 = 0
    /// V3 reports zero for a supported bass layout; FFT gaps above 200 Hz
    /// can still be empty. 0xFF means an unsupported layout.
    var firstBand: UInt8 = 0
    /// Summed bass tap time on both cores, already included in audio CPU load.
    /// 65535 is saturation, so it represents a lower bound rather than 6.6%.
    var bassBusyUsPerSecond: UInt16 = 0
    var bassLoadDescription: String {
        let prefix = bassBusyUsPerSecond == .max ? "≥" : ""
        return String(format: "bass %@%.2f%%", prefix, Double(bassBusyUsPerSecond) / 10000.0)
    }

    var isRunning: Bool { state != RTA_STATE_IDLE }

    /// The lowest band with a reading, as a band index the display can compare
    /// against.  A device reporting "no band resolves" greys out the lot.
    var firstResolvedBand: Int {
        firstBand == 0xFF ? RTA_MAX_BANDS : Int(firstBand)
    }

    static func fromData(_ d: Data) -> RtaStatus? {
        guard d.count >= RTA_STATUS_SIZE else { return nil }
        let b = [UInt8](d)
        guard b[0] == RTA_CFG_VERSION else { return nil }
        return RtaStatus(
            state: b[1],
            tap: b[2],
            channel: b[3],
            liveCount: b[5],
            liveMask: UInt16(b[6]) | (UInt16(b[7]) << 8),
            framesPerSecond: UInt16(b[8]) | (UInt16(b[9]) << 8),
            busyUsPerSecond: UInt16(b[10]) | (UInt16(b[11]) << 8),
            lastFrameUs: UInt16(b[12]) | (UInt16(b[13]) << 8),
            idleMs: UInt16(b[14]) | (UInt16(b[15]) << 8),
            sampleRateHz: UInt32(b[16]) | (UInt32(b[17]) << 8) | (UInt32(b[18]) << 16) | (UInt32(b[19]) << 24),
            firstBand: b[20],
            bassBusyUsPerSecond: UInt16(b[22]) | (UInt16(b[23]) << 8))
    }
}

// MARK: - Subscriptions

/// What one on-screen analyser wants to see.  Views hand one of these to the
/// engine while they are visible and take it back when they go away; the engine
/// turns the set of them into a single device configuration, because there is
/// only one FFT engine on the device.
struct RtaRequest: Equatable {
    var tap: UInt8
    /// Bit i = channel i at that tap (input row, or matrix output index).
    var mask: UInt16
    /// Whether this view also needs the raw bins.  A bin frame belongs to
    /// whichever channel was transformed last, so a view that wants bins is
    /// asking for a narrow selection as well.
    var wantsBins: Bool = false
}

/// Everything the engine republishes after a poll, in one value so a tick costs
/// SwiftUI a single invalidation rather than one per field.
struct RtaSnapshot: Equatable {
    /// Latest band frame per channel, keyed by channel index at the active tap.
    var frames: [UInt8: RtaBandFrame] = [:]
    var bins: RtaBinFrame? = nil
    var status: RtaStatus = RtaStatus()
    /// The tap the frames in this snapshot were taken at.  A view at the other
    /// tap must not draw them as its own.
    var tap: UInt8 = RTA_TAP_OUTPUT
}

/// The three settings the device owns rather than the app: transform size,
/// averaging and peak-hold decay.  They are never persisted on the device (the
/// analyser is transient), so the Console keeps them in its own preferences and
/// pushes them whenever it starts watching.
struct RtaOptions: Equatable {
    var fftOrder: UInt8 = 10
    /// Power-domain averaging; bass retains its minimum detector smoothing at 0.
    var avgMs: UInt16 = 300
    /// Peak-hold decay in dB per second; 0 turns the peak hold off.
    var peakDecayDBs: UInt8 = 12
}

// MARK: - Engine

/// The Console's half of the spectrum analyser: it owns the device
/// configuration, polls the band and bin frames, and republishes them.
///
/// Deliberately a separate observable rather than more `@Published` properties
/// on `DSPViewModel`: this republishes at the poll rate, and everything that
/// observes the view model would otherwise redraw with it.
///
/// Polling is driven from `DSPViewModel`'s existing 60 ms timer rather than a
/// timer of its own, so all vendor traffic stays on one queue in one order.
/// Nothing is polled unless a view is actually watching, and dropping the last
/// view stops the analyser on the device, which is the only way it costs
/// nothing when nobody is looking.
final class RtaEngine: ObservableObject {

    // MARK: Published state

    /// True once REQ_RTA_GET_CAPS has answered.  Firmware without the analyser
    /// STALLs it, which is the whole feature gate.
    @Published private(set) var supported: Bool = false
    @Published private(set) var caps = RtaCaps()
    /// Nominal third-octave centre frequencies, straight from the caps table,
    /// so the axis labels come from the same source as the band edges.
    @Published private(set) var bandCentresHz: [Double] = []
    @Published private(set) var snapshot = RtaSnapshot()
    /// Set when the device has repeatedly refused the configuration we are
    /// asking for.  The views show the reason rather than an empty graph.
    @Published private(set) var configRejected: Bool = false

    /// The device-side options the app is asking for, mirrored for the UI.
    /// Written only on the main thread; the poll queue reads its own copy from
    /// under the lock, which is what `setOptions` keeps in step.
    @Published private(set) var options = RtaOptions()

    // MARK: Private state

    private weak var usb: USBDevice?
    /// Guards `requests` and the polling bookkeeping, which are touched from
    /// the main thread (subscribe/release) and the poll queue (tick).
    private let lock = NSLock()
    private var requests: [UUID: (seq: UInt64, request: RtaRequest)] = [:]
    private var requestSeq: UInt64 = 0
    /// What we believe the device has applied; nil means "push again".
    private var appliedConfig: RtaConfig? = nil
    /// The last configuration we actually sent, so that asking for something
    /// different resets the give-up counter instead of inheriting it.
    private var lastAttempted: RtaConfig? = nil
    private var pushAttempts = 0
    /// The poll queue's copy of `options`, kept in step by `setOptions`.
    private var pollOptions = RtaOptions()
    /// How long the device takes to publish one frame, as last measured from
    /// the status.  The bin cadence follows it, so a 1024-point transform is
    /// not read four times per frame the way a 256-point one is read once.
    private var pollFrameInterval: TimeInterval = 1024.0 / 48000.0
    private var lastBinRead: Date = .distantPast
    private var lastStatusRead: Date = .distantPast

    init(usb: USBDevice) {
        self.usb = usb
    }

    // MARK: Subscription

    /// Start watching.  The returned token identifies this subscription; hand
    /// it back to `release` when the view goes away.
    @discardableResult
    func subscribe(_ request: RtaRequest) -> UUID {
        let id = UUID()
        update(id, to: request)
        return id
    }

    /// Change what an existing subscription wants without giving up its place:
    /// selecting another channel keeps the view primary, so the picture does
    /// not jump to whatever else happens to be on screen.
    func update(_ id: UUID, to request: RtaRequest) {
        lock.lock()
        let existing = requests[id]
        // A request that has not actually changed keeps its sequence number,
        // so a view that re-publishes the same thing does not steal the tap.
        if existing?.request == request { lock.unlock(); return }
        requestSeq += 1
        requests[id] = (requestSeq, request)
        lock.unlock()
    }

    func release(_ id: UUID) {
        lock.lock()
        requests.removeValue(forKey: id)
        let empty = requests.isEmpty
        if empty {
            appliedConfig = nil
            lastAttempted = nil
            pushAttempts = 0
        }
        lock.unlock()
        guard empty else { return }
        // Nobody is watching.  The device would auto-off five seconds from now
        // anyway; stopping it explicitly hands the CPU back at once.
        let usb = self.usb
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = usb?.getControlRequest(request: REQ_RTA_CONTROL, value: RTA_CTL_STOP, index: 2, length: 1)
            DispatchQueue.main.async { self?.snapshot = RtaSnapshot() }
        }
    }

    /// Clear the running average and the peak hold on the device without
    /// disturbing the frame in flight.
    func resetAveraging() {
        let usb = self.usb
        DispatchQueue.global(qos: .utility).async {
            _ = usb?.getControlRequest(request: REQ_RTA_CONTROL, value: RTA_CTL_RESET_AVG, index: 2, length: 1)
        }
    }

    /// Adopt new device-side options and re-push them on the next tick.  Main
    /// thread only; the poll queue picks up its copy from under the lock.
    func setOptions(_ new: RtaOptions) {
        guard new != options else { return }
        options = new
        lock.lock()
        pollOptions = new
        appliedConfig = nil
        lastAttempted = nil
        pushAttempts = 0
        lock.unlock()
        if configRejected { configRejected = false }
    }

    /// Re-push the configuration on the next tick without changing it, after a
    /// device switch or anything else that could have reset the engine.
    func configurationChanged() {
        lock.lock()
        appliedConfig = nil
        lastAttempted = nil
        pushAttempts = 0
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.configRejected else { return }
            self.configRejected = false
        }
    }

    // MARK: Capability probe

    /// Reads the caps header and the band-centre table.  Called once per
    /// connect from the tier-2 fetches; a STALL leaves `supported` false and
    /// every analyser view shows its unsupported notice.
    ///
    /// Blocking; call off the main thread.
    func fetchCaps() {
        guard let usb else { return }
        let generation = usb.generation
        guard let d = usb.getControlRequest(request: REQ_RTA_GET_CAPS, value: 0, index: 2,
                                            length: UInt16(RTA_CAPS_SIZE)),
              let caps = RtaCaps.fromData(d) else {
            DispatchQueue.main.async { [weak self] in
                self?.supported = false
                self?.bandCentresHz = []
            }
            return
        }

        // Band centres arrive 32 values to a chunk, starting at wValue 1; the
        // table ends when a chunk comes back short or is refused.
        var centres: [Double] = []
        var chunk: UInt16 = 1
        while centres.count < Int(caps.maxBands), chunk < 16 {
            guard usb.generation == generation,
                  let c = usb.getControlRequest(request: REQ_RTA_GET_CAPS, value: chunk, index: 2,
                                                length: UInt16(RTA_CENTRES_PER_CHUNK * 2)),
                  c.count >= 2 else { break }
            let b = [UInt8](c)
            for i in stride(from: 0, to: b.count - 1, by: 2) {
                centres.append(Double(UInt16(b[i]) | (UInt16(b[i + 1]) << 8)))
            }
            if c.count < RTA_CENTRES_PER_CHUNK * 2 { break }
            chunk += 1
        }

        let complete = centres.count >= Int(caps.maxBands)
        DispatchQueue.main.async { [weak self] in
            guard let self, usb.generation == generation else { return }
            self.caps = caps
            self.bandCentresHz = Array(centres.prefix(Int(caps.maxBands)))
            self.supported = complete
            // Fold this device's limits into the options: a size outside the
            // range this device reports would be STALLed on every push.
            var o = self.options
            if o.fftOrder < caps.fftOrderMin || o.fftOrder > caps.fftOrderMax {
                o.fftOrder = caps.fftOrderDefault
            }
            self.setOptions(o)
        }
        // A fresh device knows nothing of the previous one's configuration.
        configurationChanged()
    }

    /// Forget everything about the device that just went away.
    func deviceDisconnected() {
        lock.lock()
        appliedConfig = nil
        lastAttempted = nil
        pushAttempts = 0
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.supported = false
            self?.snapshot = RtaSnapshot()
            self?.configRejected = false
        }
    }

    // MARK: Polling

    /// True when at least one view is watching, so the caller can skip the
    /// whole poll without taking the lock twice.
    var isWatching: Bool {
        lock.lock(); defer { lock.unlock() }
        return !requests.isEmpty
    }

    /// One poll.  Called from the view model's poll timer on its poll queue,
    /// which is the same queue every other vendor read runs on.  Each product
    /// has its own cadence in elapsed time, so a slower timer or a larger
    /// transform changes how often things are read but not what is read.
    func tick() {
        guard supported, let usb else { return }

        lock.lock()
        guard !requests.isEmpty else { lock.unlock(); return }
        let primary = requests.values.max(by: { $0.seq < $1.seq })!.request
        let mask: UInt16
        if primary.wantsBins {
            mask = primary.mask
        } else {
            mask = requests.values
                .filter { $0.request.tap == primary.tap }
                .reduce(UInt16(0)) { $0 | $1.request.mask }
        }
        let wantsBins = requests.values.contains { $0.request.wantsBins }
        var want = RtaConfig(
            tap: primary.tap,
            channelMask: mask,
            fftOrder: pollOptions.fftOrder,
            avgMs: pollOptions.avgMs,
            peakDecayDBs: pollOptions.peakDecayDBs,
            flags: 0)
        // An empty mask is a STALL on the device, and there is nothing to draw
        // either; hold the previous configuration and skip the poll.
        guard want.channelMask != 0 else { lock.unlock(); return }
        // Give up after three rejected pushes of the *same* configuration, so
        // firmware that refuses one setting does not turn into a write on every
        // tick - but asking for something different starts the count again,
        // otherwise a rejected size would silently freeze the channel
        // selection too.
        var needsPush = false
        if appliedConfig != want {
            if lastAttempted != want {
                lastAttempted = want
                pushAttempts = 0
            }
            if pushAttempts < 3 {
                pushAttempts += 1
                appliedConfig = want
                needsPush = true
            }
        }
        let now = Date()
        // Read the bins no faster than the device publishes them, which is a
        // frame time apart: at 1024 points that is 21 ms, at 256 points 5 ms,
        // and the poll timer is slower than both.
        let readBins = wantsBins
            && now.timeIntervalSince(lastBinRead) >= max(pollFrameInterval, RTA_MIN_BIN_INTERVAL)
        let readStatus = now.timeIntervalSince(lastStatusRead) >= RTA_STATUS_INTERVAL
        if readBins { lastBinRead = now }
        if readStatus { lastStatusRead = now }
        let bandSlots = Int(caps.maxBands)
        let bandFrameSize = caps.bandFrameSize
        let binFrameLength = caps.maxBinFrame > 0 ? Int(caps.maxBinFrame) : RTA_BIN_FRAME_MAX
        lock.unlock()

        if needsPush {
            usb.sendControlRequest(request: REQ_RTA_SET_CONFIG, value: 0, index: 2, data: want.toData())
        }

        // Band frames.  GET_BANDS_ALL answers for every live channel in one
        // transfer and each frame names its own channel, so a multichannel view
        // costs one read rather than one per channel.
        var frames: [UInt8: RtaBandFrame] = [:]
        if want.channelMask.nonzeroBitCount > 1 {
            let maxFrames = 16
            if let d = usb.getControlRequest(request: REQ_RTA_GET_BANDS_ALL, value: 0, index: 2,
                                             length: UInt16(bandFrameSize * maxFrames)) {
                var off = 0
                while off + bandFrameSize <= d.count {
                    if let f = RtaBandFrame.fromData(d, at: off, maxBands: bandSlots) { frames[f.channel] = f }
                    off += bandFrameSize
                }
            }
        } else {
            let ch = want.channelMask.trailingZeroBitCount   // exactly one bit set here
            if let d = usb.getControlRequest(request: REQ_RTA_GET_BANDS, value: UInt16(ch), index: 2,
                                             length: UInt16(bandFrameSize)),
               let f = RtaBandFrame.fromData(d, maxBands: bandSlots) {
                frames[f.channel] = f
            }
        }

        var bins: RtaBinFrame? = nil
        if readBins {
            bins = Self.readBinFrame(usb: usb, length: binFrameLength)
        }

        var status: RtaStatus? = nil
        var applied: RtaConfig? = nil
        if readStatus {
            if let d = usb.getControlRequest(request: REQ_RTA_GET_STATUS, value: 0, index: 2,
                                             length: UInt16(RTA_STATUS_SIZE)) {
                status = RtaStatus.fromData(d)
            }
            if let d = usb.getControlRequest(request: REQ_RTA_GET_CONFIG, value: 0, index: 2,
                                             length: UInt16(RTA_CONFIG_SIZE)) {
                applied = RtaConfig.fromData(d)
            }
        }

        if let s = status {
            lock.lock()
            pollFrameInterval = Self.frameInterval(status: s, order: want.fftOrder)
            lock.unlock()
        }

        // The device clamps `avgMs` and `peakDecayDBs` rather than refusing
        // them, so compare only the fields it either takes or STALLs on.
        var rejected: Bool? = nil
        if let a = applied {
            let agrees = a.tap == want.tap && a.channelMask == want.channelMask
                && a.fftOrder == want.fftOrder
            lock.lock()
            if agrees {
                pushAttempts = 0
                want.avgMs = a.avgMs
                want.peakDecayDBs = a.peakDecayDBs
                appliedConfig = want
                rejected = false
            } else if pushAttempts >= 3 {
                rejected = true
            } else {
                // Not applied yet (the device applies a staged config from its
                // main loop) or genuinely refused; try again next tick.
                appliedConfig = nil
            }
            lock.unlock()
        }

        let tap = want.tap
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var s = self.snapshot
            // A tap change invalidates every frame we were holding: the frames
            // are indexed by channel, and channel 0 means a different thing on
            // the other side of the matrix.
            if s.tap != tap { s.frames = [:]; s.bins = nil }
            s.tap = tap
            for (ch, f) in frames { s.frames[ch] = f }
            if let bins { s.bins = bins }
            if let status { s.status = status }
            if s != self.snapshot { self.snapshot = s }
            if let rejected, rejected != self.configRejected { self.configRejected = rejected }
        }
    }

    // MARK: Reads that need more than one transfer

    /// Reads the published bin frame and validates it.
    ///
    /// `wValue` is a byte offset into the frame, so a transport that cannot
    /// carry the whole thing reads it in chunks; USB manages it in one, and a
    /// short answer here is picked up from where it stopped.  The frame is
    /// published without a lock and carries its sequence number in the header
    /// and again as its last byte, so a disagreement means the engine
    /// republished mid-read: read it again rather than draw half of each.
    private static func readBinFrame(usb: USBDevice, length: Int) -> RtaBinFrame? {
        for _ in 0..<2 {
            var frame = Data()
            while frame.count < length {
                guard let chunk = usb.getControlRequest(request: REQ_RTA_GET_BINS,
                                                        value: UInt16(frame.count), index: 2,
                                                        length: UInt16(length - frame.count)),
                      !chunk.isEmpty else { break }
                frame.append(chunk)
                // A complete frame is shorter than the ceiling at every size
                // below the largest, so stop once the header's own length is in.
                if let n = binFrameLength(of: frame), frame.count >= n { break }
            }
            if let f = RtaBinFrame.fromData(frame) { return f }
        }
        return nil
    }

    /// Total frame length from a header that has arrived, or nil while it has
    /// not: 16 header bytes, one byte per bin, and the repeated sequence byte.
    private static func binFrameLength(of d: Data) -> Int? {
        guard d.count >= RTA_BIN_HEADER_SIZE else { return nil }
        let b = [UInt8](d.prefix(RTA_BIN_HEADER_SIZE))
        let nBins = Int(UInt16(b[8]) | (UInt16(b[9]) << 8))
        return nBins > 0 ? RTA_BIN_HEADER_SIZE + nBins + 1 : nil
    }

    /// How long one channel waits between frames, from the device's own frame
    /// rate where it has one and from the configured size otherwise.
    private static func frameInterval(status: RtaStatus, order: UInt8) -> TimeInterval {
        if status.framesPerSecond > 0 {
            return Double(max(Int(status.liveCount), 1)) / Double(status.framesPerSecond)
        }
        let rate = status.sampleRateHz > 0 ? Double(status.sampleRateHz) : 48000
        return Double(1 << Int(order)) / rate * Double(max(Int(status.liveCount), 1))
    }

    // MARK: Level conversion

    /// dBFS of one wire level byte.  The zero point comes from the caps so it
    /// is never hard-coded at the point of use.
    func levelDB(_ v: UInt8) -> Double {
        let zero = caps.levelZero != 0 ? Double(caps.levelZero) : Double(RTA_LEVEL_ZERO_DBFS)
        return (Double(v) - zero) * RTA_LEVEL_STEP_DB
    }

    /// The lowest level the wire can express, which is also what an empty band
    /// and a silent channel both read.
    var floorDB: Double { levelDB(0) }
}
