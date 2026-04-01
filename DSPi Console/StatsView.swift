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
}

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

// MARK: - Stats View Model
class StatsViewModel: ObservableObject {
    @Published var pdmRingOverruns: UInt32 = 0
    @Published var pdmRingUnderruns: UInt32 = 0
    @Published var pdmDmaOverruns: UInt32 = 0
    @Published var pdmDmaUnderruns: UInt32 = 0
    @Published var spdifOverruns: UInt32 = 0
    @Published var spdifUnderruns: UInt32 = 0
    @Published var isConnected: Bool = false

    // System monitoring values
    @Published var systemClockHz: UInt32 = 0
    @Published var coreVoltageMillivolts: UInt32 = 0
    @Published var sampleRateHz: UInt32 = 0
    @Published var systemTempCentiC: Int32 = 0

    // Device identification (fetched once on connect)
    @Published var serialNumber: String = "—"
    @Published var platformName: String = "—"
    @Published var firmwareVersion: String = "—"
    @Published var outputCount: Int = 0

    // Buffer fill level statistics
    @Published var bufferStats: BufferStatsPacket = BufferStatsPacket()

    // SPDIF DMA starvation counters
    @Published var starvationTotal: UInt32 = 0
    @Published var starvationPerInstance: [UInt32] = [0, 0, 0, 0]
    @Published var starvationDelta: UInt32 = 0
    @Published var starvationLastEventTime: Date? = nil
    @Published var starvationPreviousEventTime: Date? = nil

    // Reconnection counter
    @Published var reconnectCount: Int = 0

    private var previousStarvationTotal: UInt32? = nil
    private var hasConnectedOnce = false
    private var pollTimer: Timer?
    private weak var usb: USBDevice?
    private var cancellables = Set<AnyCancellable>()

    init(usb: USBDevice) {
        self.usb = usb

        // Subscribe to connection state
        usb.$isConnected
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

        // Initial fetch
        fetchStats()
        if usb.isConnected {
            fetchDeviceInfo()
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    func fetchStats() {
        guard let usb = usb, isConnected else { return }

        // wValue=3: pdm_ring_overruns
        if let data = usb.getControlRequest(request: REQ_GET_STATUS, value: 3, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.pdmRingOverruns = value }
        }

        // wValue=4: pdm_ring_underruns
        if let data = usb.getControlRequest(request: REQ_GET_STATUS, value: 4, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.pdmRingUnderruns = value }
        }

        // wValue=5: pdm_dma_overruns
        if let data = usb.getControlRequest(request: REQ_GET_STATUS, value: 5, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.pdmDmaOverruns = value }
        }

        // wValue=6: pdm_dma_underruns
        if let data = usb.getControlRequest(request: REQ_GET_STATUS, value: 6, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.pdmDmaUnderruns = value }
        }

        // wValue=7: spdif_overruns
        if let data = usb.getControlRequest(request: REQ_GET_STATUS, value: 7, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.spdifOverruns = value }
        }

        // wValue=8: spdif_underruns
        if let data = usb.getControlRequest(request: REQ_GET_STATUS, value: 8, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.spdifUnderruns = value }
        }

        // wValue=13: system clock frequency (Hz)
        if let data = usb.getControlRequest(request: REQ_GET_STATUS, value: 13, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.systemClockHz = value }
        }

        // wValue=14: core voltage (millivolts)
        if let data = usb.getControlRequest(request: REQ_GET_STATUS, value: 14, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.coreVoltageMillivolts = value }
        }

        // wValue=15: sample rate (Hz)
        if let data = usb.getControlRequest(request: REQ_GET_STATUS, value: 15, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            DispatchQueue.main.async { self.sampleRateHz = value }
        }

        // wValue=16: system temperature (centi-degrees C)
        if let data = usb.getControlRequest(request: REQ_GET_STATUS, value: 16, index: 0, length: 4) {
            let value = data.withUnsafeBytes { $0.load(as: Int32.self) }
            DispatchQueue.main.async { self.systemTempCentiC = value }
        }

        fetchBufferStats()
        fetchStarvationStats()
    }

    func fetchBufferStats() {
        guard let usb = usb, isConnected else { return }
        guard let data = usb.getControlRequest(request: REQ_GET_BUFFER_STATS, value: 0, index: 0, length: 44) else { return }

        var packet = BufferStatsPacket()
        packet.numSpdif = data[0]
        packet.flags = data[1]
        packet.sequence = data.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) }

        for i in 0..<min(Int(packet.numSpdif), 4) {
            let base = 4 + i * 8
            packet.spdif[i] = SpdifBufferStats(
                consumerFree: data[base],
                consumerPrepared: data[base + 1],
                consumerPlaying: data[base + 2],
                consumerFillPct: data[base + 3],
                consumerMinFillPct: data[base + 4],
                consumerMaxFillPct: data[base + 5]
            )
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

        DispatchQueue.main.async { self.bufferStats = packet }
    }

    func fetchStarvationStats() {
        guard let usb = usb, isConnected else { return }

        // wValue=17: total SPDIF DMA starvations (wIndex=2 per spec)
        guard let data = usb.getControlRequest(request: REQ_GET_STATUS, value: 17, index: 2, length: 4) else { return }
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
                if let d = usb.getControlRequest(request: REQ_GET_STATUS, value: UInt16(18 + i), index: 2, length: 4) {
                    perInstance[i] = d.withUnsafeBytes { $0.load(as: UInt32.self) }
                }
            }
            eventTime = Date()
        } else if total > 0 {
            // No new events but have historical — still read per-instance for display
            for i in 0..<4 {
                if let d = usb.getControlRequest(request: REQ_GET_STATUS, value: UInt16(18 + i), index: 2, length: 4) {
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

    func resetBufferWatermarks() {
        guard let usb = usb, isConnected else { return }
        _ = usb.getControlRequest(request: REQ_RESET_BUFFER_STATS, value: 1, index: 0, length: 1)
    }

    func fetchDeviceInfo() {
        guard let usb = usb else { return }

        // REQ_GET_SERIAL (0x7E): 16-byte ASCII hex serial
        if let data = usb.getControlRequest(request: REQ_GET_SERIAL, value: 0, index: 2, length: 16) {
            let serial = String(data: data, encoding: .ascii)?
                .trimmingCharacters(in: .controlCharacters.union(.whitespaces)) ?? "—"
            DispatchQueue.main.async { self.serialNumber = serial.isEmpty ? "—" : serial }
        }

        // REQ_GET_PLATFORM (0x7F): 4-byte platform info
        if let data = usb.getControlRequest(request: REQ_GET_PLATFORM, value: 0, index: 2, length: 4) {
            let platform = data[0]
            let major = Int(data[1])
            let minor = Int(data[2] >> 4)
            let patch = Int(data[2] & 0x0F)
            let outputs = Int(data[3])

            let platformStr = platform == 1 ? "RP2350" : "RP2040"
            let versionStr = "v\(major).\(minor).\(patch)"

            DispatchQueue.main.async {
                self.platformName = platformStr
                self.firmwareVersion = versionStr
                self.outputCount = outputs
            }
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
    @State private var now = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            if let since = since {
                Text(formatElapsed(now.timeIntervalSince(since)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 1)
        .onReceive(timer) { self.now = $0 }
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
                Text("—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}

struct StatsView: View {
    @ObservedObject var vm: StatsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Device Information Section
                Text("Device Information")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    SystemInfoRow(title: "Platform", value: vm.platformName)
                    SystemInfoRow(title: "Firmware", value: vm.firmwareVersion)
                    SystemInfoRow(title: "Serial", value: vm.serialNumber)
                    SystemInfoRow(title: "Reconnects", value: "\(vm.reconnectCount)")
                }

                Divider()

                // System Information Section
                Text("System Information")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

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

                Divider()

                // PDM Section
                Text("PDM (Subwoofer)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

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

                Divider()

                // Output Section
                Text("Audio Output")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

                StatRow(
                    title: "Buffer Pool",
                    subtitle: "USB → DMA",
                    overruns: vm.spdifOverruns,
                    underruns: vm.spdifUnderruns
                )

                Divider()

                // SPDIF DMA Starvation Section
                Text("SPDIF DMA Starvation")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

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

                    // Elapsed time since last event
                    StarvationTimerRow(label: "Time since last event",
                                       since: vm.starvationLastEventTime)

                    StarvationIntervalRow(label: "Time between last two",
                                          from: vm.starvationPreviousEventTime,
                                          to: vm.starvationLastEventTime)
                }

                Divider()

                // Buffer Fill Levels Section
                Text("Buffer Fill Levels")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)

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
                                title: "\(AppState.shared.viewModel.outputSlotTypes[i] == 1 ? "I2S" : "SPDIF") \(i + 1)",
                                fillPct: vm.bufferStats.spdif[i].consumerFillPct,
                                minPct: vm.bufferStats.spdif[i].consumerMinFillPct,
                                maxPct: vm.bufferStats.spdif[i].consumerMaxFillPct,
                                thresholds: .spdif
                            )
                        }
                    }
                }

                // PDM buffer rows (only when PDM active)
                if vm.bufferStats.pdmActive {
                    VStack(alignment: .leading, spacing: 6) {
                        BufferFillRow(
                            title: "PDM DMA",
                            fillPct: vm.bufferStats.pdm.dmaFillPct,
                            minPct: vm.bufferStats.pdm.dmaMinFillPct,
                            maxPct: vm.bufferStats.pdm.dmaMaxFillPct,
                            thresholds: .pdmDma
                        )
                        BufferFillRow(
                            title: "PDM Ring",
                            fillPct: vm.bufferStats.pdm.ringFillPct,
                            minPct: vm.bufferStats.pdm.ringMinFillPct,
                            maxPct: vm.bufferStats.pdm.ringMaxFillPct,
                            thresholds: .pdmRing
                        )
                    }
                }

                // Reset watermarks button
                HStack {
                    Spacer()
                    Button("Reset Watermarks") {
                        vm.resetBufferWatermarks()
                    }
                    .controlSize(.small)
                }

                Spacer().frame(height: 4)

                // Footer
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
            .padding()
        }
        .frame(width: 320)
    }

}

// MARK: - Buffer Fill Thresholds

enum BufferFillThresholds {
    case spdif
    case pdmDma
    case pdmRing

    func color(for pct: UInt8) -> Color {
        let v = Int(pct)
        switch self {
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
    let fillPct: UInt8
    let minPct: UInt8
    let maxPct: UInt8
    let thresholds: BufferFillThresholds

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 70, alignment: .leading)

            Text("\(fillPct)%")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(thresholds.color(for: fillPct))
                .frame(width: 50, alignment: .trailing)

            Spacer()

            Text("\(minPct)–\(maxPct)%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - System Info Row
struct SystemInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)
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
