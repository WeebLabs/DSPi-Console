import SwiftUI
import Combine

// MARK: - Buffer Stats Data Models

struct SpdifBufferStats {
    var consumerFree: UInt8 = 0
    var consumerPrepared: UInt8 = 0
    var consumerPlaying: UInt8 = 0
    var consumerFillPct: UInt8 = 0
    var consumerMinFillPct: UInt8 = 0
    var consumerMaxFillPct: UInt8 = 0
    /// Sample-granular fill in 0.01% of the same scale; may exceed 100% on the
    /// firmware's scale. Zero on firmware that predates it.
    var fillCentiPct: UInt16 = 0

    /// Fill in percent to frame resolution. consumerFillPct moves in 6.25% steps,
    /// so a slot hovering near a 48-frame boundary flickers a whole step.
    var preciseFillPct: Double {
        if fillCentiPct == 0 && consumerFillPct != 0 { return Double(consumerFillPct) }
        return Double(fillCentiPct) / 100
    }

    /// The firmware reports every percentage against a fixed 768-frame scale
    /// (16 buckets of 48 frames), kept for wire compatibility. Since the output
    /// latency setting the rings hold 512 frames, so this re-expresses each
    /// percentage against the ring itself: 100% is a full ring.
    func rescaledToRing() -> SpdifBufferStats {
        let factor = Double(SLOT_FILL_SCALE_FRAMES) / Double(OUTPUT_RING_FRAMES)
        func pct(_ v: UInt8) -> UInt8 { UInt8(min(100, (Double(v) * factor).rounded())) }
        var out = self
        out.consumerFillPct = pct(consumerFillPct)
        out.consumerMinFillPct = pct(consumerMinFillPct)
        out.consumerMaxFillPct = pct(consumerMaxFillPct)
        out.fillCentiPct = UInt16(min(10_000, (Double(fillCentiPct) * factor).rounded()))
        return out
    }
}

/// The scale REQ_GET_BUFFER_STATS percentages are measured against, in frames.
let SLOT_FILL_SCALE_FRAMES = 768
/// Output slot ring size on firmware with the output latency setting.
let OUTPUT_RING_FRAMES = 512
/// Frames ahead of each reader the firmware keeps stamped with silence; a ring
/// filled past `OUTPUT_RING_FRAMES - OUTPUT_RING_ERASE_AHEAD` cannot take a write.
let OUTPUT_RING_ERASE_AHEAD = 64

struct PdmBufferStats {
    var dmaFillPct: UInt8 = 0
    var dmaMinFillPct: UInt8 = 0
    var dmaMaxFillPct: UInt8 = 0
    var ringFillPct: UInt8 = 0
    var ringMinFillPct: UInt8 = 0
    var ringMaxFillPct: UInt8 = 0
}

struct BufferStatsPacket {
    var numSpdif: UInt8 = 0
    var flags: UInt8 = 0
    var sequence: UInt16 = 0
    var spdif: [SpdifBufferStats] = Array(repeating: SpdifBufferStats(), count: 4)
    var pdm: PdmBufferStats = PdmBufferStats()

    var pdmActive: Bool { flags & 0x01 != 0 }
    var audioStreaming: Bool { flags & 0x02 != 0 }
}

// MARK: - SPDIF RX Status Data Model

struct SpdifRxStatus {
    var state: UInt8 = 0          // 0=INACTIVE, 1=ACQUIRING, 2=LOCKED, 3=RELOCKING
    var inputSource: UInt8 = 0
    var lockCount: UInt8 = 0
    var lossCount: UInt8 = 0
    var sampleRate: UInt32 = 0
    var parityErrors: UInt32 = 0
    var fifoFillPct: UInt16 = 0
    // Debug fields (bytes 14-15 of status packet)
    var libState: UInt8 = 0       // Library internal state: 0=NO_SIGNAL, 1=WAITING_STABLE, 2=STABLE
    var callbackCounts: UInt8 = 0 // High nibble = on_stable count, low nibble = on_lost_stable count

    var isLocked: Bool { state == 2 }

    var stateString: String {
        switch state {
        case 0: return "Inactive"
        case 1: return "Acquiring"
        case 2: return "Locked"
        case 3: return "Relocking"
        default: return "Unknown (\(state))"
        }
    }

    var stateColor: Color {
        switch state {
        case 0: return .gray
        case 1: return .yellow
        case 2: return .green
        case 3: return .orange
        default: return .gray
        }
    }

    var sourceString: String {
        switch Int(inputSource) {
        case INPUT_SOURCE_SPDIF:  return "S/PDIF 1"
        case INPUT_SOURCE_SPDIF2: return "S/PDIF 2"
        case INPUT_SOURCE_SPDIF3: return "S/PDIF 3"
        case INPUT_SOURCE_SPDIF4: return "S/PDIF 4"
        case INPUT_SOURCE_I2S:    return "I2S"
        default: return "USB"
        }
    }

    var sampleRateString: String {
        guard isLocked, sampleRate > 0 else { return "-" }
        return String(format: "%.1f kHz", Double(sampleRate) / 1000.0)
    }

    var libStateString: String {
        switch libState {
        case 0: return "No Signal"
        case 1: return "Waiting Stable"
        case 2: return "Stable"
        default: return "Unknown (\(libState))"
        }
    }

    var onStableCount: UInt8 { (callbackCounts >> 4) & 0x0F }
    var onLostStableCount: UInt8 { callbackCounts & 0x0F }
}

struct SpdifRxChannelStatus {
    var raw: [UInt8] = Array(repeating: 0, count: 24)

    var isConsumer: Bool { raw[0] & 0x01 == 0 }
    var isPCM: Bool { raw[0] & 0x02 == 0 }
    var copyPermitted: Bool { raw[0] & 0x04 != 0 }
    var categoryCode: UInt8 { raw[1] }
    var sourceNumber: UInt8 { raw[2] & 0x0F }
    var channelNumber: UInt8 { (raw[2] >> 4) & 0x0F }

    var categoryString: String {
        switch categoryCode {
        case 0x00: return "General"
        case 0x01: return "CD Player"
        case 0x02: return "DAT"
        case 0x03: return "DCC"
        case 0x04: return "MiniDisc"
        case 0x06: return "Synthesizer"
        case 0x08: return "Broadcast Receiver"
        case 0x09: return "Musical Instrument"
        case 0x0A: return "A/D Converter"
        case 0x0C: return "Mixer"
        case 0x0D: return "Rate Converter"
        case 0x0E: return "Sampler"
        case 0x0F: return "Digital Signal Processor"
        default: return "0x\(String(format: "%02X", categoryCode))"
        }
    }

    var wordLengthString: String {
        switch raw[4] & 0x0F {
        case 0x00: return "Not indicated"
        case 0x02: return "16-bit"
        case 0x04: return "20-bit"
        case 0x08: return "17-bit"
        case 0x0A: return "22-bit"
        case 0x0B: return "24-bit"
        default: return "-"
        }
    }
}

// MARK: - LG Sound Sync Status

/// 16-byte runtime status returned by REQ_GET_LG_SOUND_SYNC_STATUS.
/// Only the first 4 bytes are meaningful today; the remaining 12 are
/// reserved by the firmware for future fields.
struct LgSoundSyncStatus {
    var enabled: Bool = false
    var present: Bool = false
    /// 0..100 from the LG channel-status decode; 0xFF means "never decoded
    /// since boot" (held while `present` is false).
    var volume: UInt8 = 0xFF
    var muted: Bool = false

    var volumeString: String {
        volume == 0xFF ? "-" : "\(volume) / 100"
    }

    var presentString: String {
        present ? "Yes" : "No"
    }

    var presentColor: Color {
        present ? .green : .gray
    }
}

// MARK: - Output Ring Health

/// The output rings' counters and watermarks.  Underrun episodes and refused
/// blocks are cumulative; the lowest fill and the two gaps are watermarks that
/// "Reset Watermarks" clears.
struct RingHealth: Equatable {
    var targetFrames: UInt16
    var targetUs: UInt16
    /// Frames a stream input delivers per call; the fill swings by about this.
    var batchFrames: UInt16
    /// One per dry episode while a producer owed audio, not one per recovery.
    var underrunEpisodes: UInt32
    /// Blocks refused by ring admission.
    var refusedBlocks: UInt32
    /// Lowest fill seen just before a write, in frames; nil before the first write.
    var lowestPrewriteFill: UInt32?
    /// Longest wait between input deliveries, which bounds the usable margin.
    var worstInputGapUs: UInt32
    /// Longest gap between audio-carrying USB packets; a host stall shows here.
    var worstUsbPacketGapUs: UInt32
    /// Background steps that overran their main-loop budget.
    var overBudgetSteps: UInt32
}

/// Microseconds below 10 ms, milliseconds above.
func formatGapUs(_ us: UInt32) -> String {
    us < 10_000 ? "\(us) µs" : String(format: "%.1f ms", Double(us) / 1000)
}

// MARK: - Stats View Model
class StatsViewModel: ObservableObject {
    @Published var pdmRingOverruns: UInt32 = 0
    @Published var pdmRingUnderruns: UInt32 = 0
    @Published var pdmDmaOverruns: UInt32 = 0
    @Published var pdmDmaUnderruns: UInt32 = 0
    @Published var spdifOverruns: UInt32 = 0
    @Published var spdifUnderruns: UInt32 = 0
    @Published var usbRingOverruns: UInt32 = 0
    @Published var isConnected: Bool = false

    // Output ring health (REQ_GET_STATUS 26 to 31), from the firmware that added
    // the output latency setting.  Older firmware answers those indices with 0
    // rather than a STALL, so the latency status read is the feature gate, and
    // it also supplies the fill target the lowest fill is judged against.
    @Published var ringHealth: RingHealth? = nil

    // System monitoring values
    @Published var systemClockHz: UInt32 = 0
    @Published var coreVoltageMillivolts: UInt32 = 0
    @Published var sampleRateHz: UInt32 = 0
    @Published var systemTempCentiC: Int32 = 0

    // Device identification (fetched once on connect)
    @Published var serialNumber: String = "-"
    @Published var platformName: String = "-"
    @Published var firmwareVersion: String = "-"
    @Published var outputCount: Int = 0

    // Buffer fill level statistics
    @Published var bufferStats: BufferStatsPacket = BufferStatsPacket()

    /// The recent history of `bufferStats`, traced under each buffer fill row.
    /// Not published: the traces subscribe to it directly, so a sample moves
    /// layers without re-evaluating any SwiftUI view.
    let bufferHistory = BufferFillHistory()

    // SPDIF DMA starvation counters
    @Published var starvationTotal: UInt32 = 0
    @Published var starvationPerInstance: [UInt32] = [0, 0, 0, 0]
    @Published var starvationDelta: UInt32 = 0
    @Published var starvationLastEventTime: Date? = nil
    @Published var starvationPreviousEventTime: Date? = nil

    // Reconnection counter
    @Published var reconnectCount: Int = 0

    // SPDIF RX input status
    @Published var spdifRxStatus: SpdifRxStatus = SpdifRxStatus()
    @Published var spdifRxChannelStatus: SpdifRxChannelStatus = SpdifRxChannelStatus()
    @Published var spdifRxPin: UInt8 = 11
    /// GPIO of the currently-active S/PDIF input (tracks inputs 2/3 too).
    @Published var spdifActiveRxPin: UInt8 = 11
    @Published var inputSourceSupported: Bool = false

    // LG Sound Sync runtime status (V8+ firmware).  Polled on the same
    // 2-second cadence as fetchStats; stays at default until a successful
    // REQ_GET_LG_SOUND_SYNC_STATUS response sets `lgSoundSyncSupported`.
    @Published var lgSoundSyncStatus: LgSoundSyncStatus = LgSoundSyncStatus()
    @Published var lgSoundSyncSupported: Bool = false

    // ADAT bulk output diagnostics (RP2350 only).  Polled on the same
    // 2-second cadence; `adatSupported` stays false on RP2040 (zeros) and on
    // firmware that STALLs REQ_GET_ADAT_STATUS.  See adat_output_spec.md.
    @Published var adatStatus: AdatStatus = AdatStatus()
    @Published var adatSupported: Bool = false

    // I2S clock-slave lock diagnostics (firmware V18+).  Polled on the same
    // cadence; `i2sClockModeSupported` stays false on firmware that STALLs
    // REQ_GET_I2S_SLAVE_STATUS.  The section is shown only while the device is
    // in the slave role.  See i2s_slave_input_spec.md.
    @Published var i2sSlaveStatus: I2sSlaveStatus = I2sSlaveStatus()
    @Published var i2sClockModeSupported: Bool = false

    private var previousStarvationTotal: UInt32? = nil
    /// Whether buffer fill is shown against the 512-frame ring.  Set with the
    /// ring health read, the feature gate for that ring size; fetch queue only.
    private var fillOnRingScale = false
    private var hasConnectedOnce = false
    private var pollTimer: Timer?
    private var bufferPollTimer: Timer?
    private weak var transport: (any DeviceTransport)?
    private var cancellables = Set<AnyCancellable>()

    /// Every device read runs here.  The timers fire on main, but a GET
    /// blocks until the device (or, through DSPi Link, a hub across the
    /// network) answers, and the UI must never wait on that.  One serial
    /// queue keeps the reads in order; a tick that lands while the previous
    /// read of its kind is still out is skipped rather than queued.
    private let fetchQueue = DispatchQueue(label: "com.foxdac.stats.fetch", qos: .utility)
    private var statsFetchInFlight = false
    private var bufferFetchInFlight = false

    init(transport: any DeviceTransport) {
        self.transport = transport

        // Subscribe to connection state
        transport.isConnectedPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self = self else { return }
                self.isConnected = connected
                if connected {
                    if self.hasConnectedOnce {
                        self.reconnectCount += 1
                    }
                    self.hasConnectedOnce = true
                    self.fetchDeviceInfo()
                }
            }
            .store(in: &cancellables)

        // Poll every 2 seconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fetchStats()
        }

        // Poll buffer fill stats at 60ms for smooth meter updates
        bufferPollTimer = Timer.scheduledTimer(withTimeInterval: 0.060, repeats: true) { [weak self] _ in
            self?.fetchBufferStats()
        }

        // Initial fetch
        fetchStats()
        if transport.isConnected {
            fetchDeviceInfo()
        }
    }

    deinit {
        pollTimer?.invalidate()
        bufferPollTimer?.invalidate()
    }

    // MARK: Scheduling (main thread)

    /// Read the 2 s counters and status blocks off the main thread.
    func fetchStats() {
        guard isConnected, !statsFetchInFlight else { return }
        statsFetchInFlight = true
        fetchQueue.async { [weak self] in
            self?.readStats()
            DispatchQueue.main.async { self?.statsFetchInFlight = false }
        }
    }

    /// Read the buffer fill packet off the main thread.
    func fetchBufferStats() {
        guard isConnected, !bufferFetchInFlight else { return }
        bufferFetchInFlight = true
        fetchQueue.async { [weak self] in
            self?.readBufferStats()
            DispatchQueue.main.async { self?.bufferFetchInFlight = false }
        }
    }

    /// Read the identity block (serial, platform, input source) off the main thread.
    func fetchDeviceInfo() {
        fetchQueue.async { [weak self] in self?.readDeviceInfo() }
    }

    func resetBufferWatermarks() {
        guard isConnected else { return }
        fetchQueue.async { [weak self] in
            guard let transport = self?.transport else { return }
            _ = transport.getControlRequest(request: REQ_RESET_BUFFER_STATS, value: 1, index: 0, length: 1)
        }
    }

    // MARK: Reads (fetch queue)

    private func readStats() {
        guard let transport = transport, isConnected else { return }

        // wValue=3: pdm_ring_overruns
        if let data = transport.getControlRequest(request: REQ_GET_STATUS, value: 3, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.pdmRingOverruns = value }
        }

        // wValue=4: pdm_ring_underruns
        if let data = transport.getControlRequest(request: REQ_GET_STATUS, value: 4, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.pdmRingUnderruns = value }
        }

        // wValue=5: pdm_dma_overruns
        if let data = transport.getControlRequest(request: REQ_GET_STATUS, value: 5, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.pdmDmaOverruns = value }
        }

        // wValue=6: pdm_dma_underruns
        if let data = transport.getControlRequest(request: REQ_GET_STATUS, value: 6, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.pdmDmaUnderruns = value }
        }

        // wValue=7: spdif_overruns
        if let data = transport.getControlRequest(request: REQ_GET_STATUS, value: 7, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.spdifOverruns = value }
        }

        // wValue=8: spdif_underruns
        if let data = transport.getControlRequest(request: REQ_GET_STATUS, value: 8, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.spdifUnderruns = value }
        }

        // wValue=22: USB audio ring overruns
        if let data = transport.getControlRequest(request: REQ_GET_STATUS, value: 22, index: 2, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.usbRingOverruns = value }
        }

        // wValue=13: system clock frequency (Hz)
        if let data = transport.getControlRequest(request: REQ_GET_STATUS, value: 13, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.systemClockHz = value }
        }

        // wValue=14: core voltage (millivolts)
        if let data = transport.getControlRequest(request: REQ_GET_STATUS, value: 14, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.coreVoltageMillivolts = value }
        }

        // wValue=15: sample rate (Hz)
        if let data = transport.getControlRequest(request: REQ_GET_STATUS, value: 15, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.sampleRateHz = value }
        }

        // wValue=16: system temperature (centi-degrees C)
        if let data = transport.getControlRequest(request: REQ_GET_STATUS, value: 16, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: Int32.self) }
            DispatchQueue.main.async { self.systemTempCentiC = value }
        }

        fetchRingHealth()
        fetchStarvationStats()
        fetchSpdifRxStatus()
        fetchLgSoundSyncStatus()
        fetchAdatStatus()
        fetchI2SSlaveStatus()
    }

    private func fetchRingHealth() {
        guard let transport = transport, isConnected else { return }
        guard let d = transport.getControlRequest(request: REQ_OUTPUT_LATENCY, value: OUTPUT_LATENCY_GET_STATUS,
                                                  index: 2, length: UInt16(OUTPUT_LATENCY_STATUS_SIZE)),
              let latency = OutputLatencyStatus.fromData(d) else {
            fillOnRingScale = false
            DispatchQueue.main.async { self.ringHealth = nil }
            return
        }
        fillOnRingScale = true
        func read(_ index: UInt16) -> UInt32? {
            guard let data = transport.getControlRequest(request: REQ_GET_STATUS, value: index, index: 0, length: 4),
                  data.count >= 4 else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        let health = RingHealth(
            targetFrames: latency.targetFrames,
            targetUs: latency.effectiveUs,
            batchFrames: latency.batchFrames,
            underrunEpisodes: read(26) ?? 0,
            refusedBlocks: read(27) ?? 0,
            lowestPrewriteFill: read(28).flatMap { $0 == UInt32.max ? nil : $0 },
            worstInputGapUs: read(29) ?? 0,
            worstUsbPacketGapUs: read(30) ?? 0,
            overBudgetSteps: read(31) ?? 0
        )
        DispatchQueue.main.async { self.ringHealth = health }
    }

    /// Poll REQ_GET_I2S_SLAVE_STATUS (0x8A) for the I2S clock-slave lock
    /// diagnostics.  A STALL (nil) leaves `i2sClockModeSupported` false so the
    /// section stays hidden on firmware that predates the feature.
    private func fetchI2SSlaveStatus() {
        guard let transport = transport, isConnected else { return }
        guard let data = transport.getControlRequest(request: REQ_GET_I2S_SLAVE_STATUS, value: 0, index: 2, length: 16),
              let status = I2sSlaveStatus.fromData(data) else {
            DispatchQueue.main.async { self.i2sClockModeSupported = false }
            return
        }
        DispatchQueue.main.async {
            self.i2sClockModeSupported = true
            self.i2sSlaveStatus = status
        }
    }

    /// Poll REQ_GET_ADAT_STATUS (0xCE) for the ADAT diagnostics section.  A
    /// STALL (nil) or a non-RP2350 platform leaves `adatSupported` false so the
    /// section stays hidden.  RP2040 returns all-zero, also treated as absent.
    private func fetchAdatStatus() {
        guard let transport = transport, isConnected else { return }
        guard let data = transport.getControlRequest(request: REQ_GET_ADAT_STATUS, value: 0, index: 2, length: 8),
              let status = AdatStatus.fromData(data) else {
            DispatchQueue.main.async { self.adatSupported = false }
            return
        }
        DispatchQueue.main.async {
            self.adatSupported = (self.platformName == "RP2350")
            self.adatStatus = status
        }
    }

    /// REQ_GET_LG_SOUND_SYNC_STATUS (0xE8): returns the 16-byte
    /// LgSoundSyncStatus struct.  STALLs on V7 / older firmware - we
    /// detect that via the nil response and leave `lgSoundSyncSupported`
    /// false, which hides the section in the UI.
    private func fetchLgSoundSyncStatus() {
        guard let transport = transport, isConnected else { return }
        guard let data = transport.getControlRequest(request: REQ_GET_LG_SOUND_SYNC_STATUS, value: 0, index: 0, length: 16),
              data.count >= 4 else { return }

        var status = LgSoundSyncStatus()
        status.enabled = data[0] != 0
        status.present = data[1] != 0
        status.volume  = data[2]
        status.muted   = data[3] != 0

        DispatchQueue.main.async {
            self.lgSoundSyncStatus = status
            self.lgSoundSyncSupported = true
        }
    }

    private func readBufferStats() {
        guard let transport = transport, isConnected else { return }
        guard let data = transport.getControlRequest(request: REQ_GET_BUFFER_STATS, value: 0, index: 0, length: 44),
              data.count >= 44 else { return }

        var packet = BufferStatsPacket()
        packet.numSpdif = data[0]
        packet.flags = data[1]
        packet.sequence = data.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) }

        for i in 0..<min(Int(packet.numSpdif), 4) {
            let base = 4 + i * 8
            let stats = SpdifBufferStats(
                consumerFree: data[base],
                consumerPrepared: data[base + 1],
                consumerPlaying: data[base + 2],
                consumerFillPct: data[base + 3],
                consumerMinFillPct: data[base + 4],
                consumerMaxFillPct: data[base + 5],
                fillCentiPct: UInt16(data[base + 6]) | (UInt16(data[base + 7]) << 8)
            )
            packet.spdif[i] = fillOnRingScale ? stats.rescaledToRing() : stats
        }

        let pdmBase = 36
        packet.pdm = PdmBufferStats(
            dmaFillPct: data[pdmBase],
            dmaMinFillPct: data[pdmBase + 1],
            dmaMaxFillPct: data[pdmBase + 2],
            ringFillPct: data[pdmBase + 3],
            ringMinFillPct: data[pdmBase + 4],
            ringMaxFillPct: data[pdmBase + 5]
        )

        DispatchQueue.main.async {
            self.bufferStats = packet
            self.bufferHistory.append(packet)
        }
    }

    private func fetchStarvationStats() {
        guard let transport = transport, isConnected else { return }

        // wValue=17: total SPDIF DMA starvations (wIndex=2 per spec)
        guard let data = transport.getControlRequest(request: REQ_GET_STATUS, value: 17, index: 2, length: 4) else { return }
        let total = data.withUnsafeBytes { $0.load(as: UInt32.self) }

        var delta: UInt32 = 0
        if let prev = previousStarvationTotal {
            delta = total &- prev  // wrap-safe subtraction
        }
        previousStarvationTotal = total

        // If new starvation events, read per-instance counters
        var perInstance: [UInt32] = [0, 0, 0, 0]
        var eventTime: Date? = starvationLastEventTime
        var prevEventTime: Date? = starvationPreviousEventTime
        if delta > 0 {
            prevEventTime = starvationLastEventTime
            for i in 0..<4 {
                if let d = transport.getControlRequest(request: REQ_GET_STATUS, value: UInt16(18 + i), index: 2, length: 4) {
                    perInstance[i] = d.withUnsafeBytes { $0.load(as: UInt32.self) }
                }
            }
            eventTime = Date()
        } else if total > 0 {
            // No new events but have historical - still read per-instance for display
            for i in 0..<4 {
                if let d = transport.getControlRequest(request: REQ_GET_STATUS, value: UInt16(18 + i), index: 2, length: 4) {
                    perInstance[i] = d.withUnsafeBytes { $0.load(as: UInt32.self) }
                }
            }
        }

        DispatchQueue.main.async {
            self.starvationTotal = total
            self.starvationPerInstance = perInstance
            self.starvationDelta = delta
            if let t = eventTime { self.starvationLastEventTime = t }
            if let p = prevEventTime { self.starvationPreviousEventTime = p }
        }
    }

    private func fetchSpdifRxStatus() {
        guard let transport = transport, isConnected, inputSourceSupported else { return }

        guard let data = transport.getControlRequest(request: REQ_GET_SPDIF_RX_STATUS, value: 0, index: 2, length: 16),
              data.count >= 16 else { return }

        var status = SpdifRxStatus()
        status.state = data[0]
        status.inputSource = data[1]
        status.lockCount = data[2]
        status.lossCount = data[3]
        status.sampleRate = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        status.parityErrors = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
        status.fifoFillPct = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt16.self) }
        status.libState = data[14]
        status.callbackCounts = data[15]

        // Fetch IEC 60958 channel status when locked
        var chStatus = SpdifRxChannelStatus()
        if status.state == 2 {
            if let chData = transport.getControlRequest(request: REQ_GET_SPDIF_RX_CH_STATUS, value: 0, index: 2, length: 24),
               chData.count >= 24 {
                chStatus.raw = Array(chData.prefix(24))
            }
        }

        // Resolve the GPIO of whichever S/PDIF input is active (inputs 2/3/4 have
        // their own pins) so the RX Pin row stays accurate.  The optional sources
        // are contiguous from INPUT_SOURCE_SPDIF2, matching the firmware helpers.
        let src = Int(status.inputSource)
        let extIndex = src - INPUT_SOURCE_SPDIF2 + 1
        let srcIndex = (1..<SPDIF_RX_NUM_INPUTS).contains(extIndex) ? extIndex : 0
        var activePin = self.spdifRxPin
        if let pd = transport.getControlRequest(request: REQ_GET_SPDIF_RX_PIN, value: UInt16(srcIndex), index: 2, length: 1),
           pd.count >= 1, pd[0] != 0 {
            activePin = pd[0]
        }

        DispatchQueue.main.async {
            self.spdifRxStatus = status
            self.spdifRxChannelStatus = chStatus
            self.spdifActiveRxPin = activePin
        }
    }

    private func readDeviceInfo() {
        guard let transport = transport else { return }

        // REQ_GET_SERIAL (0x7E): 16-byte ASCII hex serial
        if let data = transport.getControlRequest(request: REQ_GET_SERIAL, value: 0, index: 2, length: 16) {
            let serial = String(data: data, encoding: .ascii)?
                .trimmingCharacters(in: .controlCharacters.union(.whitespaces)) ?? "-"
            DispatchQueue.main.async { self.serialNumber = serial.isEmpty ? "-" : serial }
        }

        // REQ_GET_PLATFORM (0x7F): decoded, short replies included, by
        // FirmwareVersion.fromPlatformReply, the same as fetchPlatform().
        if let data = transport.getControlRequest(request: REQ_GET_PLATFORM, value: 0, index: 2, length: 7),
           let reply = FirmwareVersion.fromPlatformReply([UInt8](data)) {
            let outputs = Int(data[data.startIndex + 3])

            let platformStr: String
            switch reply.platform {
            case 1:  platformStr = "RP2350"
            case 2:  platformStr = "STM32H723"
            default: platformStr = "RP2040"
            }
            let versionStr = "v" + reply.version.description

            DispatchQueue.main.async {
                self.platformName = platformStr
                self.firmwareVersion = versionStr
                self.outputCount = outputs
            }
        }

        // Probe input source feature support
        if let data = transport.getControlRequest(request: REQ_GET_INPUT_SOURCE, value: 0, index: 2, length: 1),
           data.count >= 1 {
            if let pinData = transport.getControlRequest(request: REQ_GET_SPDIF_RX_PIN, value: 0, index: 2, length: 1),
               pinData.count >= 1 {
                DispatchQueue.main.async { self.spdifRxPin = pinData[0] }
            }
            DispatchQueue.main.async { self.inputSourceSupported = true }
        } else {
            DispatchQueue.main.async { self.inputSourceSupported = false }
        }
    }
}

// MARK: - Stats View
// MARK: - Starvation Timer Helpers

private func formatElapsed(_ interval: TimeInterval) -> String {
    let totalSeconds = Int(interval)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
    } else {
        return String(format: "%dm %02ds", minutes, seconds)
    }
}

struct StarvationTimerRow: View {
    let label: String
    let since: Date?

    // A TimelineView, not a Timer.publish stored on the struct: the buffer poll
    // rebuilds this row every 60 ms, which restarted that timer before it could
    // ever fire and froze the elapsed time.
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            if let since = since {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(formatElapsed(max(0, context.date.timeIntervalSince(since))))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("-")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}

struct StarvationIntervalRow: View {
    let label: String
    let from: Date?
    let to: Date?

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            if let from = from, let to = to {
                Text(formatElapsed(to.timeIntervalSince(from)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("-")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}

struct StatsView: View {
    @ObservedObject var vm: StatsViewModel

    /// Trace colours in `BufferFillHistory` series order, converted once: each
    /// S/PDIF slot takes its pair's left-channel colour, and both PDM traces
    /// the sub's.
    private static let historyColors: [NSColor] =
        (0..<4).map { NSColor(ChannelPalette.output($0 * 2)) }
        + [NSColor(ChannelPalette.pdm), NSColor(ChannelPalette.pdm)]

    /// The I2S input section is shown only while the device is in the slave role.
    private var showI2sSlave: Bool { vm.i2sClockModeSupported && vm.i2sSlaveStatus.isSlave }

    /// Whether the device reports any optional input or interface section.
    private var hasInterfaceSections: Bool {
        vm.inputSourceSupported || vm.lgSoundSyncSupported || vm.adatSupported || showI2sSlave
    }

    var body: some View {
        VStack(spacing: 0) {
            // Device facts and output counters, then buffer health, then the
            // optional inputs and interfaces in a third column of their own,
            // so those sections never pile up under one of the fixed columns.
            // The scroll view only engages when a locked S/PDIF input with its
            // channel status and debug rows outgrows a short window.
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        deviceSection
                        Divider()
                        systemSection
                        Divider()
                        audioOutputSection
                        if let health = vm.ringHealth {
                            Divider()
                            ringHealthSection(health)
                        }
                        Divider()
                        pdmSection
                    }
                    .toolColumn()

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        starvationSection
                        Divider()
                        bufferFillSection
                    }
                    .toolColumn()

                    if hasInterfaceSections {
                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            if vm.inputSourceSupported {
                                spdifInputSection
                            }

                            if vm.lgSoundSyncSupported {
                                if vm.inputSourceSupported { Divider() }
                                lgSoundSyncSection
                            }

                            if vm.adatSupported {
                                if vm.inputSourceSupported || vm.lgSoundSyncSupported { Divider() }
                                adatSection
                            }

                            if showI2sSlave {
                                if vm.inputSourceSupported || vm.lgSoundSyncSupported || vm.adatSupported { Divider() }
                                i2sSlaveSection
                            }
                        }
                        .toolColumn()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 16)
            }

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.secondary)
    }

    /// A row whose value carries a coloured state dot.
    private func stateRow(_ title: String, color: Color, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium))
            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(value)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Device

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("DEVICE INFORMATION")

            VStack(alignment: .leading, spacing: 6) {
                SystemInfoRow(title: "Platform", value: vm.platformName)
                SystemInfoRow(title: "Firmware", value: vm.firmwareVersion)
                SystemInfoRow(title: "Serial", value: vm.serialNumber)
                SystemInfoRow(title: "Reconnects", value: "\(vm.reconnectCount)")
            }
        }
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("SYSTEM INFORMATION")

            VStack(alignment: .leading, spacing: 6) {
                SystemInfoRow(
                    title: "Clock Frequency",
                    value: "\(String(format: "%.1f", Double(vm.systemClockHz) / 1_000_000.0)) MHz"
                )
                SystemInfoRow(
                    title: "Core Voltage",
                    value: "\(String(format: "%.2f", Double(vm.coreVoltageMillivolts) / 1000.0)) V"
                )
                SystemInfoRow(
                    title: "Sample Rate",
                    value: "\(String(format: "%.1f", Double(vm.sampleRateHz) / 1000.0)) kHz"
                )
                SystemInfoRow(
                    title: "Temperature",
                    value: "\(String(format: "%.1f", Double(vm.systemTempCentiC) / 100.0)) °C"
                )
            }
        }
    }

    // MARK: - Inputs and interfaces

    private var spdifInputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("S/PDIF INPUT")

            VStack(alignment: .leading, spacing: 6) {
                stateRow("State", color: vm.spdifRxStatus.stateColor, value: vm.spdifRxStatus.stateString)

                SystemInfoRow(title: "Active Source", value: vm.spdifRxStatus.sourceString)
                SystemInfoRow(title: "Sample Rate", value: vm.spdifRxStatus.sampleRateString)
                SystemInfoRow(title: "Lock Count", value: "\(vm.spdifRxStatus.lockCount)")
                SystemInfoRow(title: "Loss Count", value: "\(vm.spdifRxStatus.lossCount)")
                SystemInfoRow(title: "Parity Errors",
                              value: vm.spdifRxStatus.isLocked ? "\(vm.spdifRxStatus.parityErrors)" : "-")
                SystemInfoRow(title: "FIFO Fill",
                              value: vm.spdifRxStatus.isLocked ? "\(vm.spdifRxStatus.fifoFillPct)%" : "-")
                SystemInfoRow(title: "RX Pin", value: "GPIO \(vm.spdifActiveRxPin)")

                // IEC 60958 Channel Status (only when locked)
                if vm.spdifRxStatus.isLocked {
                    Divider()
                    sectionLabel("CHANNEL STATUS")
                    SystemInfoRow(title: "Format",
                                  value: vm.spdifRxChannelStatus.isConsumer ? "Consumer" : "Professional")
                    SystemInfoRow(title: "Audio",
                                  value: vm.spdifRxChannelStatus.isPCM ? "PCM" : "Non-PCM")
                    SystemInfoRow(title: "Category",
                                  value: vm.spdifRxChannelStatus.categoryString)
                    SystemInfoRow(title: "Word Length",
                                  value: vm.spdifRxChannelStatus.wordLengthString)
                    SystemInfoRow(title: "Copy",
                                  value: vm.spdifRxChannelStatus.copyPermitted ? "Permitted" : "Prohibited")
                }

                // Debug fields (from reserved bytes in status packet)
                if vm.spdifRxStatus.state != 0 {
                    Divider()
                    sectionLabel("DEBUG")
                    SystemInfoRow(title: "Library State",
                                  value: vm.spdifRxStatus.libStateString)
                    SystemInfoRow(title: "Stable Callbacks",
                                  value: "\(vm.spdifRxStatus.onStableCount)")
                    SystemInfoRow(title: "Lost Callbacks",
                                  value: "\(vm.spdifRxStatus.onLostStableCount)")
                }
            }
        }
    }

    private var lgSoundSyncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("LG SOUND SYNC")

            VStack(alignment: .leading, spacing: 6) {
                SystemInfoRow(title: "Enabled",
                              value: vm.lgSoundSyncStatus.enabled ? "Yes" : "No")
                stateRow("Present", color: vm.lgSoundSyncStatus.presentColor,
                         value: vm.lgSoundSyncStatus.presentString)
                SystemInfoRow(title: "TV Volume",
                              value: vm.lgSoundSyncStatus.volumeString)
                SystemInfoRow(title: "TV Mute",
                              value: vm.lgSoundSyncStatus.muted ? "On" : "Off")
            }
        }
    }

    private var adatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("ADAT BULK OUTPUT")

            VStack(alignment: .leading, spacing: 6) {
                stateRow("State", color: vm.adatStatus.stateColor, value: vm.adatStatus.stateString)
                SystemInfoRow(title: "Streaming",
                              value: vm.adatStatus.active ? "Yes" : "No")
                SystemInfoRow(title: "Rate Supported",
                              value: vm.adatStatus.rateOk ? "Yes" : "No")
                SystemInfoRow(title: "Data Pin", value: "GPIO \(vm.adatStatus.pin)")
                SystemInfoRow(title: "Resync Count", value: "\(vm.adatStatus.resyncCount)")
                // Slip count should stay 0; nonzero flags a stalled main
                // loop or DMA fault (spec §"AdatStatus").
                SystemInfoRow(title: "Slip Count", value: "\(vm.adatStatus.slipCount)")
            }
        }
    }

    private var i2sSlaveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("I2S INPUT (SLAVE CLOCK)")

            VStack(alignment: .leading, spacing: 6) {
                stateRow("State", color: vm.i2sSlaveStatus.stateColor, value: vm.i2sSlaveStatus.stateString)
                SystemInfoRow(title: "Detected Rate", value: vm.i2sSlaveStatus.detectedRateString)
                // Raw measured external rate: nonzero-but-never-locked
                // means an unsupported rate or wrong BCK ratio (spec §7).
                SystemInfoRow(title: "Measured Rate", value: vm.i2sSlaveStatus.measuredHzString)
                SystemInfoRow(title: "Lock Count", value: "\(vm.i2sSlaveStatus.lockCount)")
                SystemInfoRow(title: "Loss Count", value: "\(vm.i2sSlaveStatus.lossCount)")
            }
        }
    }

    // MARK: - Audio pipeline

    private var audioOutputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("AUDIO OUTPUT")

            StatRow(
                title: "USB Ring",
                subtitle: "ISR → Main Loop",
                overruns: vm.usbRingOverruns,
                underruns: nil
            )

            StatRow(
                title: "Buffer Pool",
                subtitle: "USB → DMA",
                overruns: vm.spdifOverruns,
                underruns: vm.spdifUnderruns
            )
        }
    }

    private func ringHealthSection(_ health: RingHealth) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("OUTPUT RING HEALTH")

            VStack(alignment: .leading, spacing: 6) {
                SystemInfoRow(title: "Fill Target",
                              value: "\(health.targetFrames) frames (\(formatLatencyMs(health.targetUs)))")
                    .help("How full the output rings are kept, set by Latency in Settings")
                SystemInfoRow(title: "Underrun Episodes", value: "\(health.underrunEpisodes)",
                              valueColor: health.underrunEpisodes > 0 ? .red : .primary)
                    .help("Times the outputs ran dry while a source owed audio. A host that pauses its stream does not count.")
                SystemInfoRow(title: "Refused Blocks", value: "\(health.refusedBlocks)",
                              valueColor: health.refusedBlocks > 0 ? .orange : .primary)
                    .help("Audio blocks dropped because the rings had no room for them")
                SystemInfoRow(title: "Lowest Fill",
                              value: health.lowestPrewriteFill.map { "\($0) frames" } ?? "-")
                    .help("The emptiest any output ring got just before new audio arrived, since the watermarks were reset. Near zero means the margin is thin.")
                SystemInfoRow(title: "Worst Input Gap", value: formatGapUs(health.worstInputGapUs))
                    .help("Longest wait between input deliveries since the watermarks were reset")
                SystemInfoRow(title: "Worst USB Gap", value: formatGapUs(health.worstUsbPacketGapUs))
                    .help("Longest gap between USB audio packets since the watermarks were reset. Long gaps are the host pausing its stream.")
                SystemInfoRow(title: "Over-Budget Steps", value: "\(health.overBudgetSteps)",
                              valueColor: health.overBudgetSteps > 0 ? .orange : .primary)
                    .help("Background tasks that ran past their time slice in the device's main loop")
            }
        }
    }

    private var pdmSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("PDM (SUBWOOFER)")

            VStack(alignment: .leading, spacing: 8) {
                StatRow(
                    title: "Ring Buffer",
                    subtitle: "Core 0 → Core 1",
                    overruns: vm.pdmRingOverruns,
                    underruns: vm.pdmRingUnderruns
                )

                StatRow(
                    title: "DMA Buffer",
                    subtitle: "Core 1 → PIO",
                    overruns: vm.pdmDmaOverruns,
                    underruns: vm.pdmDmaUnderruns
                )
            }
        }
    }

    private var starvationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("SPDIF DMA STARVATION")

            VStack(alignment: .leading, spacing: 6) {
                // Total with delta warning
                HStack {
                    Text("Total")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    if vm.starvationDelta > 0 {
                        Text("+\(vm.starvationDelta)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.15))
                            .cornerRadius(3)
                    }
                    Text("\(vm.starvationTotal)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(vm.starvationTotal > 0 ? .red : .primary)
                }
                .padding(.vertical, 2)

                // Per-instance counters (based on numSpdif)
                let instanceCount = max(Int(vm.bufferStats.numSpdif), 2)
                ForEach(0..<instanceCount, id: \.self) { i in
                    let chL = i * 2 + 1
                    let chR = chL + 1
                    HStack {
                        Text("Out \(chL)/\(chR)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(vm.starvationPerInstance[i])")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(vm.starvationPerInstance[i] > 0 ? .red : .primary)
                    }
                    .padding(.vertical, 1)
                }

                StarvationTimerRow(label: "Time since last event",
                                   since: vm.starvationLastEventTime)

                StarvationIntervalRow(label: "Time between last two",
                                      from: vm.starvationPreviousEventTime,
                                      to: vm.starvationLastEventTime)
            }
        }
    }

    private var bufferFillSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("BUFFER FILL LEVELS")
                Spacer()
                Button("Reset Watermarks") {
                    vm.resetBufferWatermarks()
                }
                .controlSize(.small)
            }

            // Status flags
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(vm.bufferStats.audioStreaming ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    Text("Audio Streaming")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    Circle()
                        .fill(vm.bufferStats.pdmActive ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    Text("PDM Active")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            // Per-output slot rows
            if vm.bufferStats.numSpdif > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<Int(vm.bufferStats.numSpdif), id: \.self) { i in
                        BufferFillRow(
                            title: "Out \(i * 2 + 1)/\(i * 2 + 2) (\(AppState.shared.viewModel.outputSlotTypes[i] == 1 ? "I2S" : "SPDIF"))",
                            fillPct: vm.bufferStats.spdif[i].preciseFillPct,
                            minPct: vm.bufferStats.spdif[i].consumerMinFillPct,
                            maxPct: vm.bufferStats.spdif[i].consumerMaxFillPct,
                            thresholds: vm.ringHealth.map {
                                BufferFillThresholds.ringTarget(targetFrames: Int($0.targetFrames), batchFrames: Int($0.batchFrames))
                            } ?? .spdif,
                            color: ChannelPalette.output(i * 2),
                            history: vm.bufferHistory,
                            series: i,
                            lineColor: Self.historyColors[i]
                        )
                    }
                }
            }

            // PDM buffer rows (only when PDM active)
            if vm.bufferStats.pdmActive {
                VStack(alignment: .leading, spacing: 6) {
                    BufferFillRow(
                        title: "PDM DMA",
                        fillPct: Double(vm.bufferStats.pdm.dmaFillPct),
                        minPct: vm.bufferStats.pdm.dmaMinFillPct,
                        maxPct: vm.bufferStats.pdm.dmaMaxFillPct,
                        thresholds: .pdmDma,
                        color: ChannelPalette.pdm,
                        history: vm.bufferHistory,
                        series: BufferFillHistory.pdmDmaSeries,
                        lineColor: Self.historyColors[BufferFillHistory.pdmDmaSeries]
                    )
                    BufferFillRow(
                        title: "PDM Ring",
                        fillPct: Double(vm.bufferStats.pdm.ringFillPct),
                        minPct: vm.bufferStats.pdm.ringMinFillPct,
                        maxPct: vm.bufferStats.pdm.ringMaxFillPct,
                        thresholds: .pdmRing,
                        color: ChannelPalette.pdm,
                        hollow: true,
                        history: vm.bufferHistory,
                        series: BufferFillHistory.pdmRingSeries,
                        lineColor: Self.historyColors[BufferFillHistory.pdmRingSeries]
                    )
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Circle()
                .fill(vm.isConnected ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            Text(vm.isConnected ? "Connected" : "Disconnected")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Text("Updated every 2 seconds")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Buffer Fill Thresholds

enum BufferFillThresholds {
    /// Fixed bands for firmware without the latency setting, whose single fill
    /// target sat at 50% of the reported scale.
    case spdif
    /// Bands around the live latency target, on the 512-frame ring scale.  A
    /// healthy ring swings from about one delivery below the target to one
    /// above it, so green spans a quarter of the target up to two deliveries
    /// over; red is an empty ring or one too full to take a write.
    case ringTarget(targetFrames: Int, batchFrames: Int)
    case pdmDma
    case pdmRing

    func color(for pct: Double) -> Color {
        let v = Int(pct.rounded(.down))
        switch self {
        case .ringTarget(let target, let batch):
            let frames = pct / 100 * Double(OUTPUT_RING_FRAMES)
            if frames < 1 || frames >= Double(OUTPUT_RING_FRAMES - OUTPUT_RING_ERASE_AHEAD) { return .red }
            if frames < Double(target) / 4 || frames > Double(target + 2 * batch) { return .yellow }
            return .green
        case .spdif:
            if v == 0 || v == 100 { return .red }
            if v < 25 || v > 75 { return .yellow }
            return .green
        case .pdmDma:
            if v > 50 { return .red }
            if v < 5 || v > 30 { return .yellow }
            return .green
        case .pdmRing:
            if v > 50 { return .red }
            if v > 20 { return .yellow }
            return .green
        }
    }
}

// MARK: - Buffer Fill Row

struct BufferFillRow: View {
    let title: String
    let fillPct: Double
    let minPct: UInt8
    let maxPct: UInt8
    let thresholds: BufferFillThresholds
    /// The row's colour, shared with its trace.  Hollow marks the PDM ring
    /// buffer, whose trace is dashed.
    var color: Color? = nil
    var hollow: Bool = false
    /// The history to trace, and which of its series.
    var history: BufferFillHistory? = nil
    var series: Int = 0
    var lineColor: NSColor = .controlAccentColor

    /// One small graph per buffer: the name, watermarks and current value sit
    /// in its top strip, and the trace scrolls over a band spanning the min and
    /// max watermarks below them.
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.07))

            if let history {
                BufferFillSparkline(
                    history: history,
                    series: series,
                    color: lineColor,
                    minPct: minPct,
                    maxPct: maxPct
                )
            }

            HStack(spacing: 6) {
                if let color {
                    Circle()
                        .strokeBorder(color, lineWidth: 1.5)
                        .background(Circle().fill(hollow ? Color.clear : color))
                        .frame(width: 7, height: 7)
                }

                Text(title)
                    .font(.system(size: 10, weight: .medium))

                Spacer()

                Text("\(minPct)–\(maxPct)%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .help("Lowest and highest fill since the watermarks were reset")

                Text("\(Int(fillPct.rounded()))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(thresholds.color(for: min(100, max(0, fillPct))))
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .padding(.top, 3)
        }
        .frame(height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .help("\(title) fill level over the last 15 seconds")
    }
}

// MARK: - System Info Row
struct SystemInfoRow: View {
    let title: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(valueColor)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Stat Row
struct StatRow: View {
    let title: String
    let subtitle: String
    let overruns: UInt32?
    let underruns: UInt32?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 12) {
                if let over = overruns {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(over)")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(over > 0 ? .orange : .primary)
                        Text("over")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }

                if let under = underruns {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(under)")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(under > 0 ? .red : .primary)
                        Text("under")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Buffer Fill History

/// The last 15 s of buffer fill samples, one ring per series.  A plain class
/// rather than published state: each trace subscribes to `appended` itself, so
/// a sample moves layers without re-evaluating any SwiftUI view.
final class BufferFillHistory {
    /// About 15 s at the 60 ms buffer poll.
    static let capacity = 256
    /// S/PDIF slots 0 to 3, then the PDM DMA and PDM ring buffers.
    static let seriesCount = 6
    static let pdmDmaSeries = 4
    static let pdmRingSeries = 5
    private static let absent: Float = -1

    private var rings = [[Float]](
        repeating: [Float](repeating: BufferFillHistory.absent, count: BufferFillHistory.capacity),
        count: BufferFillHistory.seriesCount
    )

    /// Samples appended so far.  Sample `s` lives at ring index `s % capacity`,
    /// so it keeps one number, and one x position, for as long as it is kept.
    private(set) var total = 0

    /// Sends the number of each new sample, on the main thread.
    let appended = PassthroughSubject<Int, Never>()

    func append(_ packet: BufferStatsPacket) {
        let slot = total % Self.capacity
        let spdifCount = min(Int(packet.numSpdif), 4)
        for i in 0..<4 {
            // Older firmware's ring can exceed its 768-frame scale; pin the trace to the graph top.
            rings[i][slot] = i < spdifCount ? Float(min(100, packet.spdif[i].preciseFillPct)) : Self.absent
        }
        rings[Self.pdmDmaSeries][slot] = packet.pdmActive ? Float(packet.pdm.dmaFillPct) : Self.absent
        rings[Self.pdmRingSeries][slot] = packet.pdmActive ? Float(packet.pdm.ringFillPct) : Self.absent
        total += 1
        appended.send(total - 1)
    }

    /// The fill percentage of `series` at sample `s`, or nil when the sample
    /// has aged out or that buffer was not running.
    func value(series: Int, sample s: Int) -> Float? {
        guard s >= 0, s < total, s >= total - Self.capacity else { return nil }
        let v = rings[series][s % Self.capacity]
        return v == Self.absent ? nil : v
    }
}

/// Scrolls one buffer's history on the GPU.  The trace is drawn into short
/// segment layers inside one content layer: a poll redraws only the newest
/// segment's few points and slides the content layer left, which Core
/// Animation composites without re-rasterising anything else.  Nothing is
/// drawn while the window is hidden or covered; the kept history is redrawn
/// once when it shows again.
final class BufferFillSparklineNSView: NSView {
    private let history: BufferFillHistory
    private let series: Int
    private var color: NSColor
    private let content = CALayer()
    private let guide = CAShapeLayer()
    private let band = CALayer()
    private var watermarks: (min: UInt8, max: UInt8) = (0, 0)
    private var segments: [Int: CAShapeLayer] = [:]
    private var subscription: AnyCancellable?
    private var occlusionObserver: NSObjectProtocol?
    private var step: CGFloat = 0
    private var drawnSize: CGSize = .zero
    private var drawing = false

    /// Samples per segment layer, about a second of history.
    private static let segmentLength = 16
    private static let ringDash: [NSNumber] = [3, 2]
    private static let ringDashLength: CGFloat = 5

    /// The meters' 60 ms linear glide, so the scroll is continuous between polls.
    private static let glide: CABasicAnimation = {
        let animation = CABasicAnimation()
        animation.duration = 0.06
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        return animation
    }()

    private static let noActions: [String: CAAction] = [
        "path": NSNull(), "strokeColor": NSNull(), "position": NSNull(),
        "bounds": NSNull(), "contentsScale": NSNull(),
        "onOrderIn": NSNull(), "onOrderOut": NSNull(),
    ]

    init(history: BufferFillHistory, series: Int, color: NSColor, minPct: UInt8, maxPct: UInt8) {
        self.history = history
        self.series = series
        self.color = color
        self.watermarks = (minPct, maxPct)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        band.actions = Self.noActions
        band.backgroundColor = color.withAlphaComponent(0.14).cgColor
        layer?.addSublayer(band)

        guide.fillColor = nil
        guide.lineWidth = 0.5
        guide.lineDashPattern = [2, 3]
        guide.actions = Self.noActions
        layer?.addSublayer(guide)

        content.anchorPoint = .zero
        content.actions = ["position": Self.glide, "bounds": NSNull(), "sublayers": NSNull()]
        layer?.addSublayer(content)

        subscription = history.appended.sink { [weak self] sample in
            self?.didAppend(sample)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    /// The row around the trace owns every click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setColor(_ newColor: NSColor) {
        guard newColor != color else { return }
        color = newColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.backgroundColor = color.withAlphaComponent(0.14).cgColor
        for shape in segments.values {
            shape.strokeColor = color.cgColor
        }
        CATransaction.commit()
    }

    /// Moves the watermark band.  The watermarks change rarely, so this only
    /// touches the band when they do.
    func setWatermarks(min newMin: UInt8, max newMax: UInt8) {
        guard newMin != watermarks.min || newMax != watermarks.max else { return }
        watermarks = (newMin, newMax)
        layoutBand()
    }

    private func layoutBand() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let low = yPosition(for: CGFloat(Swift.min(watermarks.min, watermarks.max)))
        let high = yPosition(for: CGFloat(Swift.max(watermarks.min, watermarks.max)))
        band.frame = CGRect(x: 0, y: low, width: bounds.width, height: Swift.max(1, high - low))
        CATransaction.commit()
    }

    // MARK: Visibility

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.updateDrawing()
            }
        }
        updateGuideStyle()
        updateDrawing()
    }

    /// Draws only while some of the window is on screen.  Samples keep landing
    /// in the history meanwhile, so showing again redraws from it.
    private func updateDrawing() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        if visible && !drawing {
            drawing = true
            rebuild()
        } else if !visible && drawing {
            drawing = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            removeSegments()
            CATransaction.commit()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGuideStyle()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGuideStyle()
        rebuild()
    }

    private func updateGuideStyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guide.contentsScale = window?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guide.strokeColor = NSColor.separatorColor.cgColor
        }
        CATransaction.commit()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        guard bounds.size != drawnSize else { return }
        drawnSize = bounds.size

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guide.frame = bounds
        // A single 50% guide: at this height more would crowd the trace.
        let path = CGMutablePath()
        let y = yPosition(for: 50)
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: bounds.width, y: y))
        guide.path = path
        content.bounds = CGRect(origin: .zero, size: bounds.size)
        CATransaction.commit()
        layoutBand()

        // The oldest kept sample sits on the left edge, the newest on the right.
        step = bounds.width / CGFloat(BufferFillHistory.capacity - 1)
        rebuild()
    }

    /// Height of the strip the row draws its name and values in.
    private static let headerHeight: CGFloat = 17

    /// Maps a percentage into the plot below the header strip.  The 2 pt inset
    /// keeps a trace at 0% or 100% from losing half its width.
    private func yPosition(for percent: CGFloat) -> CGFloat {
        let bottom: CGFloat = 2
        let top = max(bottom, bounds.height - Self.headerHeight)
        return bottom + percent / 100 * (top - bottom)
    }

    /// Where the content layer sits so that the newest sample is on the right edge.
    private func contentPosition() -> CGPoint {
        CGPoint(x: bounds.width - CGFloat(history.total - 1) * step, y: 0)
    }

    // MARK: Drawing

    private func didAppend(_ sample: Int) {
        guard drawing, step > 0 else { return }
        let segment = sample / Self.segmentLength
        redraw(segment: segment)
        // A sample on a boundary is also the end point of the segment before.
        if sample % Self.segmentLength == 0 && segment > 0 {
            redraw(segment: segment - 1)
        }
        dropAgedSegments()
        // The new point was drawn one step past the right edge; the glide
        // slides it into view over the 60 ms until the next poll.
        content.position = contentPosition()
    }

    private func rebuild() {
        guard drawing, step > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeSegments()
        let total = history.total
        if total > 0 {
            let first = max(0, total - BufferFillHistory.capacity) / Self.segmentLength
            let last = (total - 1) / Self.segmentLength
            for segment in first...last {
                redraw(segment: segment)
            }
        }
        content.position = contentPosition()
        CATransaction.commit()
    }

    private func removeSegments() {
        for shape in segments.values {
            shape.removeFromSuperlayer()
        }
        segments.removeAll()
    }

    private func dropAgedSegments() {
        let oldest = history.total - BufferFillHistory.capacity
        for segment in Array(segments.keys) where (segment + 1) * Self.segmentLength < oldest {
            segments.removeValue(forKey: segment)?.removeFromSuperlayer()
        }
    }

    /// Redraws one segment from the history.  Segment `k` spans samples
    /// `k * length` through `(k + 1) * length`, sharing its end point with the
    /// next segment so the trace joins.  A missing sample lifts the pen.
    private func redraw(segment: Int) {
        let shape = segments[segment] ?? makeSegment(segment)
        let first = segment * Self.segmentLength
        let last = min(first + Self.segmentLength, history.total - 1)
        guard last >= first else { return }
        let path = CGMutablePath()
        var penDown = false
        for s in first...last {
            guard let v = history.value(series: series, sample: s) else {
                penDown = false
                continue
            }
            let point = CGPoint(x: CGFloat(s) * step, y: yPosition(for: CGFloat(v)))
            if penDown {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                penDown = true
            }
        }
        shape.path = path
    }

    private func makeSegment(_ segment: Int) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.actions = Self.noActions
        shape.contentsScale = window?.backingScaleFactor ?? 2
        shape.fillColor = nil
        shape.strokeColor = color.cgColor
        shape.lineWidth = 1.25
        shape.lineJoin = .round
        shape.lineCap = .round
        if series == BufferFillHistory.pdmRingSeries {
            shape.lineDashPattern = Self.ringDash
            // Offsets each segment's dash so the pattern runs on unbroken
            // across boundaries (exact for level runs, close otherwise).
            shape.lineDashPhase = (CGFloat(segment * Self.segmentLength) * step)
                .truncatingRemainder(dividingBy: Self.ringDashLength)
        }
        content.addSublayer(shape)
        segments[segment] = shape
        return shape
    }
}

/// SwiftUI host for `BufferFillSparklineNSView`.  The Stats view re-evaluates
/// on every 60 ms packet; this only compares a colour and two watermarks, and
/// the samples reach
/// the trace through the history's own subscription.
struct BufferFillSparkline: NSViewRepresentable {
    let history: BufferFillHistory
    let series: Int
    let color: NSColor
    let minPct: UInt8
    let maxPct: UInt8

    func makeNSView(context: Context) -> BufferFillSparklineNSView {
        BufferFillSparklineNSView(history: history, series: series, color: color,
                                  minPct: minPct, maxPct: maxPct)
    }

    func updateNSView(_ view: BufferFillSparklineNSView, context: Context) {
        view.setColor(color)
        view.setWatermarks(min: minPct, max: maxPct)
    }
}
