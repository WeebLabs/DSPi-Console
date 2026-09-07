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
/// A change of tap, channel mask, FFT size or bass mode restarts the frame in
/// flight and clears the averaging; a change of averaging or peak decay alone
/// takes effect at the next publish.
struct RtaConfig: Equatable {
    var tap: UInt8 = RTA_TAP_OUTPUT
    var channelMask: UInt16 = 1
    var fftOrder: UInt8 = 10
    var lfMode: UInt8 = RTA_LF_1024
    var avgMs: UInt16 = 300
    var peakDecayDBs: UInt8 = 12
    var flags: UInt8 = 0

    /// Points in the fast transform: 256, 512 or 1024.
    var points: Int { 1 << Int(fftOrder) }

    func toData() -> Data {
        var d = Data(count: RTA_CONFIG_SIZE)
        d[0] = RTA_CFG_VERSION
        d[1] = tap
        d[2] = UInt8(channelMask & 0xFF)
        d[3] = UInt8(channelMask >> 8)
        d[4] = fftOrder
        d[5] = lfMode
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
            lfMode: b[5],
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
    var fftOrderMin: UInt8 = 8
    var fftOrderMax: UInt8 = 10
    var fftOrderDefault: UInt8 = 10
    /// Bit m set means RTA_LF_ mode m is supported.
    var lfModes: UInt8 = 0
    var maxBands: UInt8 = UInt8(RTA_MAX_BANDS)
    var levelZero: UInt8 = RTA_LEVEL_ZERO_DBFS
    /// Measured, not theoretical: 78 dB for the RP2040 Q15 kernel, 120 for the
    /// RP2350 float kernel.  Worth showing, because it is the floor a reading
    /// can be trusted down to.
    var dynamicRangeDB: UInt8 = 0
    var idleTimeoutMs: UInt16 = 0
    var maxBinFrame: UInt16 = 0

    func supportsLf(_ mode: UInt8) -> Bool { lfModes & (1 << mode) != 0 }

    static func fromData(_ d: Data) -> RtaCaps? {
        guard d.count >= RTA_CAPS_SIZE else { return nil }
        let b = [UInt8](d)
        // Version 0 would mean a device answering with a zeroed buffer rather
        // than a real caps block; treat that as no analyser.
        guard b[0] != 0 else { return nil }
        return RtaCaps(
            version: b[0],
            inputChannels: b[1],
            outputChannels: b[2],
            fftOrderMin: b[3],
            fftOrderMax: b[4],
            fftOrderDefault: b[5],
            lfModes: b[6],
            maxBands: b[7],
            levelZero: b[8],
            dynamicRangeDB: b[9],
            idleTimeoutMs: UInt16(b[10]) | (UInt16(b[11]) << 8),
            maxBinFrame: UInt16(b[12]) | (UInt16(b[13]) << 8))
    }
}

/// One channel's third-octave picture (REQ_RTA_GET_BANDS, 80 bytes).
///
/// `avg` and `peak` always carry `RTA_MAX_BANDS` slots; only the first
/// `nBands` are meaningful at the current sample rate.  A band that contains no
/// FFT bin at the current size reads the floor and is never faked from a
/// neighbour, which is what `RtaStatus.fastFirstBand` lets a display grey out.
struct RtaBandFrame: Equatable {
    var channel: UInt8 = 0
    var seq: UInt8 = 0
    var nBands: UInt8 = 0
    /// Milliseconds since this channel's last fast-stream frame; 0xFFFF = never.
    var ageMs: UInt16 = 0xFFFF
    /// Same for the bass stream; 0xFFFF when it has never run or is off.
    var lfAgeMs: UInt16 = 0xFFFF
    var avg: [UInt8] = Array(repeating: 0, count: RTA_MAX_BANDS)
    var peak: [UInt8] = Array(repeating: 0, count: RTA_MAX_BANDS)

    /// True once the channel has produced at least one frame.
    var hasData: Bool { ageMs != 0xFFFF }

    static func fromData(_ d: Data, at offset: Int = 0) -> RtaBandFrame? {
        guard d.count >= offset + RTA_BAND_FRAME_SIZE else { return nil }
        let b = [UInt8](d[(d.startIndex + offset)..<(d.startIndex + offset + RTA_BAND_FRAME_SIZE)])
        guard b[0] == RTA_CFG_VERSION else { return nil }
        return RtaBandFrame(
            channel: b[1],
            seq: b[2],
            nBands: b[3],
            ageMs: UInt16(b[4]) | (UInt16(b[5]) << 8),
            lfAgeMs: UInt16(b[6]) | (UInt16(b[7]) << 8),
            avg: Array(b[8..<(8 + RTA_MAX_BANDS)]),
            peak: Array(b[(8 + RTA_MAX_BANDS)..<(8 + 2 * RTA_MAX_BANDS)]))
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
    /// Fast-stream bins, one level byte each, bin k centred at
    /// k * sampleRateHz / (2 * bins.count).
    var bins: [UInt8] = []
    /// Bass-stream bins when the high-resolution bass stream is running, bin k
    /// centred at k * lfRateHz / (2 * lfBins.count).  Empty when it is off.
    var lfBins: [UInt8] = []
    var lfRateHz: UInt16 = 0

    /// Hz of fast bin `k`.
    func frequency(ofBin k: Int) -> Double {
        guard !bins.isEmpty else { return 0 }
        return Double(k) * Double(sampleRateHz) / Double(2 * bins.count)
    }

    /// Hz of bass-stream bin `k`.
    func lfFrequency(ofBin k: Int) -> Double {
        guard !lfBins.isEmpty else { return 0 }
        return Double(k) * Double(lfRateHz) / Double(2 * lfBins.count)
    }

    /// Parses a whole frame read in one transfer.  Returns nil for a short
    /// read, a header that does not describe the bytes that followed, or a
    /// sequence tail that disagrees with the header - the last of which means
    /// the engine republished mid-read and the caller should simply try again.
    static func fromData(_ d: Data) -> RtaBinFrame? {
        guard d.count >= RTA_BIN_HEADER_SIZE else { return nil }
        let b = [UInt8](d)
        guard b[0] == RTA_CFG_VERSION else { return nil }
        let seq = b[2]
        // 0xFF is the in-progress marker the engine writes before it fills the
        // frame, never a published sequence number.
        guard seq != 0xFF else { return nil }
        let nBins   = Int(UInt16(b[8])  | (UInt16(b[9])  << 8))
        let nLfBins = Int(UInt16(b[10]) | (UInt16(b[11]) << 8))
        let lfRate  = UInt16(b[12]) | (UInt16(b[13]) << 8)
        let lfArea  = Int(UInt16(b[14]) | (UInt16(b[15]) << 8))
        let tail = RTA_BIN_HEADER_SIZE + nBins + lfArea
        guard nBins > 0, nLfBins <= lfArea, b.count > tail, b[tail] == seq else { return nil }
        return RtaBinFrame(
            channel: b[1],
            seq: seq,
            fftOrder: b[3],
            sampleRateHz: UInt32(b[4]) | (UInt32(b[5]) << 8) | (UInt32(b[6]) << 16) | (UInt32(b[7]) << 24),
            bins: Array(b[RTA_BIN_HEADER_SIZE..<(RTA_BIN_HEADER_SIZE + nBins)]),
            lfBins: Array(b[(RTA_BIN_HEADER_SIZE + nBins)..<(RTA_BIN_HEADER_SIZE + nBins + nLfBins)]),
            lfRateHz: lfRate)
    }
}

/// Engine telemetry (REQ_RTA_GET_STATUS, 24 bytes).  Reading it deliberately
/// does not count as a data read, so polling status neither starts the analyser
/// nor keeps it alive.
struct RtaStatus: Equatable {
    var state: UInt8 = RTA_STATE_IDLE
    var tap: UInt8 = RTA_TAP_OUTPUT
    var fastChannel: UInt8 = RTA_CH_NONE
    var lfChannel: UInt8 = RTA_CH_NONE
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
    /// The lowest band the fast stream resolves; everything below it reads the
    /// floor unless the bass stream is filling it in.
    var fastFirstBand: UInt8 = 0
    /// Same for the bass stream, or 0xFF when the bass stream is off.
    var lfFirstBand: UInt8 = 0xFF

    var isRunning: Bool { state != RTA_STATE_IDLE }

    /// The lowest band anything resolves, taking the bass stream into account.
    var firstResolvedBand: Int {
        lfFirstBand == 0xFF ? Int(fastFirstBand) : min(Int(fastFirstBand), Int(lfFirstBand))
    }

    static func fromData(_ d: Data) -> RtaStatus? {
        guard d.count >= RTA_STATUS_SIZE else { return nil }
        let b = [UInt8](d)
        guard b[0] == RTA_CFG_VERSION else { return nil }
        return RtaStatus(
            state: b[1],
            tap: b[2],
            fastChannel: b[3],
            lfChannel: b[4],
            liveCount: b[5],
            liveMask: UInt16(b[6]) | (UInt16(b[7]) << 8),
            framesPerSecond: UInt16(b[8]) | (UInt16(b[9]) << 8),
            busyUsPerSecond: UInt16(b[10]) | (UInt16(b[11]) << 8),
            lastFrameUs: UInt16(b[12]) | (UInt16(b[13]) << 8),
            idleMs: UInt16(b[14]) | (UInt16(b[15]) << 8),
            sampleRateHz: UInt32(b[16]) | (UInt32(b[17]) << 8) | (UInt32(b[18]) << 16) | (UInt32(b[19]) << 24),
            fastFirstBand: b[20],
            lfFirstBand: b[21])
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

/// The four settings the device owns rather than the app: transform size,
/// averaging, peak-hold decay and the high-resolution bass stream.  They are
/// never persisted on the device (the analyser is transient), so the Console
/// keeps them in its own preferences and pushes them whenever it starts
/// watching.
struct RtaOptions: Equatable {
    var fftOrder: UInt8 = 10
    var lfMode: UInt8 = RTA_LF_1024
    /// Power-domain averaging time constant; 0 turns averaging off.
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
    private var tickCount: UInt64 = 0
    /// The poll queue's copy of `options`, kept in step by `setOptions`.
    private var pollOptions = RtaOptions()

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

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.caps = caps
            self.bandCentresHz = centres
            self.supported = true
            // Fold this device's limits into the options: an RP2040 caps out at
            // 512 points where an RP2350 does 1024, and a setting carried over
            // from the other platform would be STALLed on every push.
            var o = self.options
            if o.fftOrder < caps.fftOrderMin || o.fftOrder > caps.fftOrderMax {
                o.fftOrder = caps.fftOrderDefault
            }
            if !caps.supportsLf(o.lfMode) {
                o.lfMode = caps.supportsLf(RTA_LF_1024) ? RTA_LF_1024 : RTA_LF_OFF
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

    /// One poll.  Called from the view model's 60 ms timer on its poll queue,
    /// which is the same queue every other vendor read runs on.
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
            lfMode: pollOptions.lfMode,
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
        let tick = tickCount
        tickCount &+= 1
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
                                             length: UInt16(RTA_BAND_FRAME_SIZE * maxFrames)) {
                var off = 0
                while off + RTA_BAND_FRAME_SIZE <= d.count {
                    if let f = RtaBandFrame.fromData(d, at: off) { frames[f.channel] = f }
                    off += RTA_BAND_FRAME_SIZE
                }
            }
        } else {
            let ch = want.channelMask.trailingZeroBitCount   // exactly one bit set here
            if let d = usb.getControlRequest(request: REQ_RTA_GET_BANDS, value: UInt16(ch), index: 2,
                                             length: UInt16(RTA_BAND_FRAME_SIZE)),
               let f = RtaBandFrame.fromData(d) {
                frames[f.channel] = f
            }
        }

        // Raw bins are eight times the traffic of a band read for one channel,
        // and the underlying frame only turns over at the frame rate, so they
        // go at half the band cadence.
        var bins: RtaBinFrame? = nil
        if wantsBins && tick % 2 == 0 {
            let len = caps.maxBinFrame > 0 ? Int(caps.maxBinFrame) : RTA_BIN_FRAME_MAX
            if let d = usb.getControlRequest(request: REQ_RTA_GET_BINS, value: 0, index: 2,
                                             length: UInt16(len)) {
                // nil here usually means the engine republished mid-read; the
                // next tick picks up the new frame.
                bins = RtaBinFrame.fromData(d)
            }
        }

        // Status every eighth tick (about twice a second): it drives the
        // greyed-out bands, the rotation readout and the running indicator,
        // none of which needs the band cadence.
        var status: RtaStatus? = nil
        var applied: RtaConfig? = nil
        if tick % 8 == 0 {
            if let d = usb.getControlRequest(request: REQ_RTA_GET_STATUS, value: 0, index: 2,
                                             length: UInt16(RTA_STATUS_SIZE)) {
                status = RtaStatus.fromData(d)
            }
            if let d = usb.getControlRequest(request: REQ_RTA_GET_CONFIG, value: 0, index: 2,
                                             length: UInt16(RTA_CONFIG_SIZE)) {
                applied = RtaConfig.fromData(d)
            }
        }

        // The device clamps `avgMs` and `peakDecayDBs` rather than refusing
        // them, so compare only the fields it either takes or STALLs on.
        var rejected: Bool? = nil
        if let a = applied {
            let agrees = a.tap == want.tap && a.channelMask == want.channelMask
                && a.fftOrder == want.fftOrder && a.lfMode == want.lfMode
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
