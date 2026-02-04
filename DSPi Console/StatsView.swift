import SwiftUI
import Combine

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

    private var pollTimer: Timer?
    private weak var usb: USBDevice?
    private var cancellables = Set<AnyCancellable>()

    init(usb: USBDevice) {
        self.usb = usb

        // Subscribe to connection state
        usb.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                self?.isConnected = connected
            }
            .store(in: &cancellables)

        // Poll every 2 seconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fetchStats()
        }

        // Initial fetch
        fetchStats()
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
    }
}

// MARK: - Stats View
struct StatsView: View {
    @ObservedObject var vm: StatsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("System Statistics")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(vm.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(vm.isConnected ? "Connected" : "Disconnected")
                    .font(.caption)
                    .foregroundColor(.secondary)
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

            // SPDIF Section
            Text("SPDIF (Main Output)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            StatRow(
                title: "Buffer Pool",
                subtitle: "USB → DMA",
                overruns: vm.spdifOverruns,
                underruns: vm.spdifUnderruns
            )

            Spacer()

            // Footer
            Text("Updated every 2 seconds")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 320, height: 420)
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
