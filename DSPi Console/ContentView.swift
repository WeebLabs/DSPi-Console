import SwiftUI
import Combine

// MARK: - Constants
let REQ_SET_EQ_PARAM: UInt8 = 0x42
let REQ_GET_EQ_PARAM: UInt8 = 0x43
let REQ_SET_PREAMP: UInt8   = 0x44
let REQ_GET_PREAMP: UInt8   = 0x45
let REQ_SET_BYPASS: UInt8   = 0x46
let REQ_GET_BYPASS: UInt8   = 0x47
let REQ_SET_DELAY: UInt8    = 0x48
let REQ_GET_DELAY: UInt8    = 0x49
let REQ_GET_STATUS: UInt8   = 0x50
let REQ_SAVE_PARAMS: UInt8  = 0x51
let REQ_LOAD_PARAMS: UInt8  = 0x52
let REQ_FACTORY_RESET: UInt8 = 0x53

// Flash result codes
let FLASH_OK: UInt8           = 0
let FLASH_ERR_WRITE: UInt8    = 1
let FLASH_ERR_NO_DATA: UInt8  = 2
let FLASH_ERR_CRC: UInt8      = 3

// Data Structure from Firmware
struct SystemStatus {
    var peaks: [Float] = [0,0,0,0,0] // 0.0 to 1.0
    var cpu0: Int = 0
    var cpu1: Int = 0
}

enum Channel: Int, CaseIterable {
    case masterLeft = 0
    case masterRight = 1
    case outLeft = 2
    case outRight = 3
    case sub = 4
    
    var name: String {
        switch self {
        case .masterLeft: return "Master L"
        case .masterRight: return "Master R"
        case .outLeft: return "Out L"
        case .outRight: return "Out R"
        case .sub: return "Sub"
        }
    }
    
    var shortName: String {
        switch self {
        case .masterLeft: return "ML"
        case .masterRight: return "MR"
        case .outLeft: return "OL"
        case .outRight: return "OR"
        case .sub: return "SUB"
        }
    }
    
    var descriptor: String {
        switch self {
        case .masterLeft, .masterRight: return "USB"
        case .outLeft, .outRight: return "SPDIF"
        case .sub: return "PDM (Pin 10)"
        }
    }
    
    var bandCount: Int {
        switch self {
        case .masterLeft, .masterRight: return 10 // Matches firmware 10
        default: return 2
        }
    }
    
    var isOutput: Bool {
        switch self {
        case .outLeft, .outRight, .sub: return true
        default: return false
        }
    }
    
    var color: Color {
        switch self {
        case .masterLeft: return Color(red: 0.29, green: 0.56, blue: 0.89)
        case .masterRight: return Color(red: 0.96, green: 0.45, blue: 0.45)
        case .outLeft: return Color(red: 0.27, green: 0.76, blue: 0.64)
        case .outRight: return Color(red: 0.94, green: 0.77, blue: 0.35)
        case .sub: return Color(red: 0.73, green: 0.53, blue: 0.95)
        }
    }
}

// MARK: - View Model
class DSPViewModel: ObservableObject {
    @Published var preampDB: Float = 0.0
    @Published var bypass: Bool = false
    @Published var channelData: [Int: [FilterParams]] = [:]
    @Published var channelVisibility: [Int: Bool] = [:]
    @Published var channelDelays: [Int: Float] = [:]
    @Published var isDeviceConnected: Bool = false

    // Live Data
    @Published var status = SystemStatus()

    let usb: USBDevice
    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: Timer?

    init(usb: USBDevice = AppState.shared.usb) {
        self.usb = usb

        // Initialize Default Data
        for ch in Channel.allCases {
            var bands: [FilterParams] = []
            for _ in 0..<ch.bandCount {
                bands.append(FilterParams())
            }
            channelData[ch.rawValue] = bands
            channelVisibility[ch.rawValue] = true
            channelDelays[ch.rawValue] = 0.0
        }
        
        // 1. Subscribe to USB connection changes AND Trigger Fetch
        usb.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                self?.isDeviceConnected = connected
                if connected {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self?.fetchAll()
                    }
                }
            }
            .store(in: &cancellables)
        
        // 2. Start Polling Timer (Every 60ms)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            guard let self = self, self.isDeviceConnected else { return }
            self.fetchStatus()
        }
        
        // Initial Connect attempt
        usb.connect()
    }
    
    func updateSelection(to channel: Channel?) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if let ch = channel {
                for c in Channel.allCases {
                    channelVisibility[c.rawValue] = (c == ch)
                }
            } else {
                for c in Channel.allCases {
                    channelVisibility[c.rawValue] = true
                }
            }
        }
    }
}

// MARK: - Custom Views
struct HorizontalMeterBar: View {
    var level: Float // 0.0 to 1.0
    var color: Color
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.3))
                RoundedRectangle(cornerRadius: 2).fill(color)
                    // Animation ensures smooth tweening between data points
                    .frame(width: CGFloat(max(0, min(1, level))) * geo.size.width)
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
        .frame(height: 8)
    }
}

struct CpuMeter: View {
    var core: Int
    var load: Int
    var body: some View {
        HStack(spacing: 4) {
            Text("C\(core):").font(.caption2).foregroundColor(.secondary)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.3))
                RoundedRectangle(cornerRadius: 2).fill(load > 90 ? Color.red : Color.blue)
                    .frame(width: CGFloat(load) * 0.4) // Max 40px width
            }
            .frame(width: 40, height: 6)
            Text("\(load)%").font(.caption2).monospacedDigit()
        }
    }
}

struct ChannelRow: View {
    let channel: Channel
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 0) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(width: 3).padding(.vertical, 4)
            } else {
                Rectangle().fill(Color.clear).frame(width: 3).padding(.vertical, 4)
            }
            
            Text(channel.name)
                .font(.body)
                .foregroundColor(isSelected ? .primary : .primary.opacity(0.9))
                .padding(.leading, 8)
                .frame(width: 80, alignment: .leading)
            
            Spacer()
            
            Text(channel.descriptor)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(channel.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(channel.color.opacity(0.15)))
                .overlay(Capsule().stroke(channel.color.opacity(0.4), lineWidth: 1))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 8)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .background(isSelected ? Color.primary.opacity(0.05) : Color.clear)
    }
}

struct GraphLegend: View {
    @ObservedObject var vm: DSPViewModel
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Channel.allCases, id: \.self) { ch in
                let isVisible = vm.channelVisibility[ch.rawValue] ?? true
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.1)) {
                        vm.channelVisibility[ch.rawValue] = !isVisible
                    }
                }) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isVisible ? ch.color : Color.gray.opacity(0.5))
                            .frame(width: 6, height: 6)
                        
                        Text(ch.shortName)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(isVisible ? .primary : .secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(isVisible ? ch.color.opacity(0.15) : Color.gray.opacity(0.1))
                    )
                    .overlay(
                        Capsule().stroke(
                            isVisible ? ch.color.opacity(0.5) : Color.clear,
                            lineWidth: 1
                        )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - DASHBOARD OVERVIEW (STEREO PAIRS)
struct DashboardOverview: View {
    @ObservedObject var vm: DSPViewModel
    
    var body: some View {
        VStack(spacing: 18) {
            StereoDashboardCard(
                title: "STEREO INPUT (USB)",
                left: .masterLeft,
                right: .masterRight,
                showDelay: false, // Delay Hidden for Inputs
                vm: vm
            )
            
            HStack(alignment: .top, spacing: 18) {
                StereoDashboardCard(
                    title: "STEREO OUTPUT (SPDIF)",
                    left: .outLeft,
                    right: .outRight,
                    showDelay: true, // Delay Visible for Outputs
                    vm: vm
                )

                MonoDashboardCard(
                    channel: .sub,
                    vm: vm
                )
                .frame(width: 220)
            }

        }
        .padding(.horizontal)
        .padding(.top, 4)
    }
}

// Unified Card for Stereo Pairs (L/R side by side)
struct StereoDashboardCard: View {
    let title: String
    let left: Channel
    let right: Channel
    let showDelay: Bool
    @ObservedObject var vm: DSPViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack {
                    Circle().fill(left.color).frame(width: 6, height: 6)
                    Text(left.name).font(.system(size: 11, weight: .bold)).foregroundColor(left.color)
                    Spacer()
                    if showDelay {
                        Text("Delay: \(vm.channelDelays[left.rawValue] ?? 0.0, specifier: "%.0f")ms")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(left.color.opacity(0.1))
                
                Divider()
                
                HStack {
                    Circle().fill(right.color).frame(width: 6, height: 6)
                    Text(right.name).font(.system(size: 11, weight: .bold)).foregroundColor(right.color)
                    Spacer()
                    if showDelay {
                        Text("Delay: \(vm.channelDelays[right.rawValue] ?? 0.0, specifier: "%.0f")ms")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(right.color.opacity(0.1))
            }
            .frame(height: 32)
            
            Divider().overlay(Color.gray.opacity(0.2))
            
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(0..<left.bandCount, id: \.self) { band in
                        if let params = vm.channelData[left.rawValue]?[band] {
                            DashboardRow(band: band + 1, params: params, color: left.color)
                                .background(band % 2 == 0 ? Color.white.opacity(0.03) : Color.clear)
                        }
                    }
                }

                Divider()

                VStack(spacing: 0) {
                    ForEach(0..<right.bandCount, id: \.self) { band in
                        if let params = vm.channelData[right.rawValue]?[band] {
                            DashboardRow(band: band + 1, params: params, color: right.color)
                                .background(band % 2 == 0 ? Color.white.opacity(0.03) : Color.clear)
                        }
                    }
                }
            }
            .frame(height: CGFloat(left.bandCount) * 24)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2), lineWidth: 1))
    }
}

// Single Card for Mono (Sub)
struct MonoDashboardCard: View {
    let channel: Channel
    @ObservedObject var vm: DSPViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(channel.color).frame(width: 6, height: 6)
                Text(channel.name).font(.system(size: 11, weight: .bold)).foregroundColor(channel.color)
                Spacer()
                // Updated Specifier to %.0f (No Decimals)
                Text("Delay: \(vm.channelDelays[channel.rawValue] ?? 0.0, specifier: "%.0f")ms")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(channel.color.opacity(0.1))
            .frame(height: 32)
            
            Divider().overlay(channel.color.opacity(0.2))
            
            VStack(spacing: 0) {
                ForEach(0..<channel.bandCount, id: \.self) { band in
                    if let params = vm.channelData[channel.rawValue]?[band] {
                        DashboardRow(band: band + 1, params: params, color: channel.color)
                            .background(band % 2 == 0 ? Color.white.opacity(0.03) : Color.clear)
                    }
                }
            }
            .frame(height: CGFloat(channel.bandCount) * 24)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(channel.color.opacity(0.3), lineWidth: 1))
    }
}

// Compact Read-Only Row
struct DashboardRow: View {
    let band: Int
    let params: FilterParams
    let color: Color
    
    var isActive: Bool { params.type != .flat }
    
    var typeCode: String {
        switch params.type {
        case .flat: return "OFF"
        case .peaking: return "PK"
        case .lowShelf: return "LS"
        case .highShelf: return "HS"
        case .lowPass: return "LP"
        case .highPass: return "HP"
        }
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Text("\(band)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: 14, alignment: .leading)
            
            Text(typeCode)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isActive ? color : .secondary.opacity(0.4))
                .frame(width: 28, alignment: .leading)
            
            Spacer()
            
            if isActive {
                HStack(spacing: 2) {
                    Text("\(params.freq, specifier: "%.0f")")
                        .foregroundColor(.primary)
                    Text("Hz").foregroundColor(.secondary).font(.system(size: 8))
                    
                    Spacer().frame(width: 4)
                    
                    if params.type == .peaking || params.type == .lowShelf || params.type == .highShelf {
                        Text("\(params.gain, specifier: "%+.1f")")
                            .foregroundColor(.primary)
                        Text("dB").foregroundColor(.secondary).font(.system(size: 8))
                    }
                    
                    if params.type == .peaking {
                        Spacer().frame(width: 4)
                        Text("\(params.q, specifier: "%.1f")")
                            .foregroundColor(.secondary)
                        Text("Q").foregroundColor(.secondary).font(.system(size: 8))
                    }
                }
                .font(.system(size: 10, design: .monospaced))
            } else {
                Text("—")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.2))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
    }
}

// MARK: - Graph Animation Support
struct AnimatableVector: VectorArithmetic {
    var values: [Double]
    
    static var zero = AnimatableVector(values: [])
    
    var magnitudeSquared: Double {
        values.reduce(0.0) { $0 + $1 * $1 }
    }
    
    static func - (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        let count = max(lhs.values.count, rhs.values.count)
        var result = [Double](repeating: 0.0, count: count)
        for i in 0..<count {
            let l = i < lhs.values.count ? lhs.values[i] : 0.0
            let r = i < rhs.values.count ? rhs.values[i] : 0.0
            result[i] = l - r
        }
        return AnimatableVector(values: result)
    }
    
    static func + (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        let count = max(lhs.values.count, rhs.values.count)
        var result = [Double](repeating: 0.0, count: count)
        for i in 0..<count {
            let l = i < lhs.values.count ? lhs.values[i] : 0.0
            let r = i < rhs.values.count ? rhs.values[i] : 0.0
            result[i] = l + r
        }
        return AnimatableVector(values: result)
    }
    
    mutating func scale(by rhs: Double) {
        for i in 0..<values.count {
            values[i] *= rhs
        }
    }
}

struct BodeLineShape: Shape {
    var magnitudes: [Double] // 201 points
    
    var animatableData: AnimatableVector {
        get { AnimatableVector(values: magnitudes) }
        set { magnitudes = newValue.values }
    }
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !magnitudes.isEmpty else { return path }
        
        let width = rect.width
        let height = rect.height
        let dbRange: Float = 20.0
        
        func yPos(_ db: Float) -> CGFloat {
            let normalized = (db + dbRange) / (2.0 * dbRange)
            return height - (CGFloat(normalized) * height)
        }
        
        let count = magnitudes.count
        for i in 0..<count {
            let pct = CGFloat(i) / CGFloat(count - 1)
            let x = pct * width
            let y = yPos(Float(magnitudes[i]))
            
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        
        return path
    }
}

// MARK: - Graph View
struct BodePlotView: View {
    @ObservedObject var vm: DSPViewModel
    
    let minFreq: Float = 20.0
    let maxFreq: Float = 20000.0
    let dbRange: Float = 20.0
    
    // Grid Helper
    func xPos(_ freq: Float, width: CGFloat) -> CGFloat {
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let logVal = log10(freq)
        return CGFloat((logVal - logMin) / (logMax - logMin)) * width
    }
    
    func yPos(_ db: Float, height: CGFloat) -> CGFloat {
        let normalized = (db + dbRange) / (2.0 * dbRange)
        return height - (CGFloat(normalized) * height)
    }
    
    // Calculation Helper for Animation
    func calculateMagnitudes(for channel: Channel) -> [Double] {
        let filters = vm.channelData[channel.rawValue] ?? []
        var results: [Double] = []
        results.reserveCapacity(201)
        
        for i in 0...200 {
            let pct = Float(i) / 200.0
            let logMin = log10(minFreq)
            let logMax = log10(maxFreq)
            let freq = pow(10, logMin + pct * (logMax - logMin))
            
            var mag: Float = 0
            if (channel == .masterLeft || channel == .masterRight) && vm.bypass {
                mag = 0
            } else {
                mag = DSPMath.responseAt(freq: freq, filters: filters)
            }
            results.append(Double(mag))
        }
        return results
    }
    
    var body: some View {
        ZStack {
            // Static Grid
            Canvas { context, size in
                let gridPath = Path { path in
                    for f in [100.0, 1000.0, 10000.0] {
                        let x = xPos(Float(f), width: size.width)
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for db in [-10.0, 0.0, 10.0] {
                        let y = yPos(Float(db), height: size.height)
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                context.stroke(gridPath, with: .color(.white.opacity(0.1)))
                
                let zeroY = yPos(0, height: size.height)
                var zeroPath = Path(); zeroPath.move(to: CGPoint(x: 0, y: zeroY)); zeroPath.addLine(to: CGPoint(x: size.width, y: zeroY))
                context.stroke(zeroPath, with: .color(.white.opacity(0.3)), lineWidth: 1)
            }
            
            // Animated Lines
            ForEach(Channel.allCases, id: \.self) { ch in
                if vm.channelVisibility[ch.rawValue] == true {
                    BodeLineShape(magnitudes: calculateMagnitudes(for: ch))
                        .stroke(ch.color, lineWidth: 2)
                        // Animate magnitude changes smoothly
                        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: calculateMagnitudes(for: ch))
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .clipped()
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

// MARK: - Main Layout
struct ContentView: View {
    @ObservedObject var vm: DSPViewModel
    @State private var selectedChannel: Channel? = nil
    
    var body: some View {
        HSplitView {
            // SIDEBAR
            List {
                Section(header: Text("INPUTS")) {
                    ForEach(Channel.allCases.filter { !$0.isOutput }, id: \.self) { ch in
                        ChannelRow(channel: ch, isSelected: selectedChannel == ch)
                            .onTapGesture {
                                if selectedChannel == ch { selectedChannel = nil }
                                else { selectedChannel = ch }
                                vm.updateSelection(to: selectedChannel)
                            }
                    }
                }
                
                Section(header: Text("OUTPUTS")) {
                    ForEach(Channel.allCases.filter { $0.isOutput }, id: \.self) { ch in
                        ChannelRow(channel: ch, isSelected: selectedChannel == ch)
                            .onTapGesture {
                                if selectedChannel == ch { selectedChannel = nil }
                                else { selectedChannel = ch }
                                vm.updateSelection(to: selectedChannel)
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    
                    // Global Controls
                    VStack(alignment: .leading, spacing: 12) {
                        Text("GLOBAL").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                        
                        VStack(spacing: 4) {
                            HStack {
                                Text("Preamp").font(.caption2).foregroundColor(.secondary)
                                Spacer()
                                Text("\(vm.preampDB, specifier: "%.1f") dB").font(.caption2).monospacedDigit()
                            }
                            Slider(value: Binding(get: { vm.preampDB }, set: { vm.setPreamp($0) }), in: -60...10)
                                .controlSize(.small)
                        }
                        
                        Toggle(isOn: Binding(get: { vm.bypass }, set: { vm.setBypass($0) })) {
                            Text("Bypass Master EQ").font(.caption).fontWeight(.medium)
                        }
                        .toggleStyle(.button)
                        .tint(.red)
                        .frame(maxWidth: .infinity)
                    }
                    .padding()
                    
                    Divider()
                    
                    // System Status (UPDATED)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("SYSTEM STATUS").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                        
                        HStack {
                            CpuMeter(core: 0, load: vm.status.cpu0)
                            Spacer()
                            CpuMeter(core: 1, load: vm.status.cpu1)
                        }
                        
                        // Vertical Stack of Horizontal Meters
                        VStack(alignment: .leading, spacing: 12) {
                            // Group 1: USB IN
                            VStack(spacing: 4) {
                                Text("USB IN").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Text("L").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                                        .frame(width: 8, alignment: .leading)
                                        HorizontalMeterBar(level: vm.status.peaks[0], color: Channel.masterLeft.color)
                                }
                                HStack {
                                    Text("R").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                                        .frame(width: 8, alignment: .leading)
                                        HorizontalMeterBar(level: vm.status.peaks[1], color: Channel.masterRight.color)
                                }
                            }
                            
                            // Group 2: SPDIF OUT
                            VStack(spacing: 4) {
                                Text("SPDIF OUT").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Text("L").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                                        .frame(width: 8, alignment: .leading)
                                        HorizontalMeterBar(level: vm.status.peaks[2], color: Channel.outLeft.color)
                                }
                                HStack {
                                    Text("R").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                                        .frame(width: 8, alignment: .leading)
                                        HorizontalMeterBar(level: vm.status.peaks[3], color: Channel.outRight.color)
                                }
                            }
                            
                            // Group 3: SUB
                            VStack(spacing: 4) {
                                Text("PDM OUT").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Text("S").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                                        .frame(width: 8, alignment: .leading)
                                        HorizontalMeterBar(level: vm.status.peaks[4], color: Channel.sub.color)
                                }
                            }
                        }
                    }
                    .padding()
                }
                .background(.ultraThinMaterial)
            }
            .frame(minWidth: 220, maxWidth: 260)

            // MAIN CONTENT
            VStack(alignment: .leading, spacing: 20) {
                // Graph
                
                VStack(alignment: .leading, spacing: 0) { // Spacing handled manually
                    // Combined header: Filters title + connection status
                    HStack {
                        Text("Filter Response").font(.headline)

                        Spacer()

                        if vm.isDeviceConnected {
                            HStack(spacing: 6) {
                                Circle().fill(.green).frame(width: 6, height: 6)
                                Text("Connected").font(.caption).foregroundColor(.secondary)
                            }
                        } else {
                            HStack(spacing: 6) {
                                Circle().fill(.red).frame(width: 6, height: 6)
                                Text(vm.usb.errorMessage ?? "Disconnected").font(.caption).foregroundColor(.red)
                            }
                        }

                        Button(action: { vm.usb.connect(); vm.fetchAll() }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 8)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                    BodePlotView(vm: vm).frame(height: 250).padding(.horizontal)
                    GraphLegend(vm: vm).padding(.horizontal).padding(.top, 8)
                }
                
                //Divider()
                
                // Right Panel Content (Dynamic)
                VStack {
                    if let channel = selectedChannel {
                        HStack {
                            Text("\(channel.name) Filters").font(.title2)
                            Spacer()
                            if channel == .masterLeft || channel == .masterRight {
                                Button("Clear All Master PEQ", role: .destructive) { vm.clearAllMaster() }
                            }
                        }
                        .padding(.horizontal)
                        
                        if channel.isOutput {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath").foregroundColor(.secondary)
                                Text("Output Delay:").font(.callout).fontWeight(.medium)
                                Slider(value: Binding(
                                    get: { vm.channelDelays[channel.rawValue] ?? 0.0 },
                                    set: { vm.setDelay(ch: channel.rawValue, ms: $0) }
                                ), in: 0...170).frame(width: 200)
                                ValueField(label: "ms", value: vm.channelDelays[channel.rawValue] ?? 0.0, width: 60) {
                                    vm.setDelay(ch: channel.rawValue, ms: $0)
                                }
                                Spacer()
                            }
                            .padding(.all, 12)
                            //.background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                            .cornerRadius(8)
                            .padding(.horizontal)
                        }
                        
                        ScrollView {
                            VStack(spacing: 12) {
                                ForEach(0..<channel.bandCount, id: \.self) { band in
                                    FilterRow(
                                        bandIndex: band,
                                        params: vm.channelData[channel.rawValue]?[band] ?? FilterParams(),
                                        onChange: { newParams in vm.setFilter(ch: channel.rawValue, band: band, p: newParams) }
                                    )
                                }
                            }
                            .padding()
                        }
                        .frame(maxHeight: .infinity)
                        //.frame(height: 400)
                    } else {
                        // --- NEW DASHBOARD VIEW ---
                        ScrollView {
                            DashboardOverview(vm: vm)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Main window background color
            .background(Color(NSColor.windowBackgroundColor.blended(withFraction: 0.2, of: .black) ?? .windowBackgroundColor))
        }
        .navigationTitle("DSPi Console")
        .frame(maxHeight:900)
        .onAppear {
            DispatchQueue.main.async {
                if let window = NSApp.keyWindow {
                    window.isMovableByWindowBackground = true
                    window.setContentSize(NSSize(width: 900, height: 770))
                    window.styleMask.remove(.resizable)
                }
            }
        }
        //.background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Subviews
struct FilterRow: View {
    let bandIndex: Int
    var params: FilterParams
    var onChange: (FilterParams) -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Text("Band \(bandIndex + 1)")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 50, alignment: .leading)
                .foregroundColor(.secondary)
            
            Picker("", selection: Binding(
                get: { params.type },
                set: { var p = params; p.type = $0; onChange(p) }
            )) {
                ForEach(FilterType.allCases) { t in Text(t.name).tag(t) }
            }
            .frame(width: 100)
            
            switch params.type {
            case .highPass:
                ValueField(label: "Hz", value: params.freq, width: 70) { var p = params; p.freq = $0; onChange(p) }
            case .lowPass:
                ValueField(label: "Hz", value: params.freq, width: 70) { var p = params; p.freq = $0; onChange(p) }
            case .highShelf:
                ValueField(label: "Hz", value: params.freq, width: 70) { var p = params; p.freq = $0; onChange(p) }
                ValueField(label: "dB", value: params.gain, width: 50) { var p = params; p.gain = $0; onChange(p) }
            case .lowShelf:
                ValueField(label: "Hz", value: params.freq, width: 70) { var p = params; p.freq = $0; onChange(p) }
                ValueField(label: "dB", value: params.gain, width: 50) { var p = params; p.gain = $0; onChange(p) }
            case .peaking:
                ValueField(label: "Hz", value: params.freq, width: 70) { var p = params; p.freq = $0; onChange(p) }
                ValueField(label: "Q", value: params.q, width: 50) { var p = params; p.q = $0; onChange(p) }
                ValueField(label: "dB", value: params.gain, width: 50) { var p = params; p.gain = $0; onChange(p) }
            case .flat:
                EmptyView()
            }
            Spacer()
        }
        .padding(8).background(Color(NSColor.controlBackgroundColor)).cornerRadius(6)
    }
}

struct ValueField: View {
    let label: String
    let value: Float
    let width: CGFloat
    let onCommit: (Float) -> Void
    @State private var text: String = ""
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            TextField(label, text: $text)
                .frame(width: width).textFieldStyle(.roundedBorder).focused($isFocused)
                .onSubmit { if let v = Float(text) { onCommit(v) } else { text = String(format: "%.1f", value) } }
                .onChange(of: isFocused) { focused in if !focused { if let v = Float(text) { onCommit(v) } else { text = String(format: "%.1f", value) } } }
            Text(label).font(.caption).foregroundColor(.secondary)
        }
        .onAppear { text = String(format: "%.1f", value) }
        .onChange(of: value) { newValue in if !isFocused { text = String(format: "%.1f", newValue) } }
    }
}

// MARK: - Preview Support

extension DSPViewModel {
    /// Creates a preview-safe view model with mock data (no USB connection)
    static var preview: DSPViewModel {
        let vm = DSPViewModel(usb: USBDevice())
        vm.isDeviceConnected = true
        vm.preampDB = -3.0
        vm.status = SystemStatus(peaks: [0.6, 0.55, 0.4, 0.35, 0.25], cpu0: 42, cpu1: 38)

        // Add some sample filter data for Master L
        vm.channelData[Channel.masterLeft.rawValue] = [
            FilterParams(type: .peaking, freq: 100, q: 0.7, gain: -5.0),
            FilterParams(type: .peaking, freq: 400, q: 1.0, gain: 3.0),
            FilterParams(type: .highShelf, freq: 8000, q: 0.7, gain: -2.0),
            FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams()
        ]

        // Add some sample filter data for Master R
        vm.channelData[Channel.masterRight.rawValue] = [
            FilterParams(type: .peaking, freq: 100, q: 0.7, gain: -5.0),
            FilterParams(type: .peaking, freq: 400, q: 1.0, gain: 3.0),
            FilterParams(type: .highShelf, freq: 8000, q: 0.7, gain: -2.0),
            FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams()
        ]

        return vm
    }
}

#Preview("Dashboard") {
    ContentView(vm: .preview)
    .frame(height: 790)
}

#Preview("Channel Selected") {
    ContentView(vm: .preview)
    .frame(width: 1000, height: 780)
}
