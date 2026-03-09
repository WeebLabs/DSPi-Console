import SwiftUI
import Combine

// MARK: - View Model

class DSPViewModel: ObservableObject {
    @Published var preampDB: Float = 0.0
    @Published var bypass: Bool = false
    @Published var channelData: [Int: [FilterParams]] = [:]
    @Published var channelVisibility: [Int: Bool] = [:]
    @Published var channelDelays: [Int: Float] = [:]
    @Published var loudnessEnabled: Bool = false
    @Published var loudnessRefSPL: Float = 83.0
    @Published var loudnessIntensity: Float = 100.0
    @Published var crossfeedEnabled: Bool = false
    @Published var crossfeedPreset: Int = 0
    @Published var crossfeedFreq: Float = 700.0
    @Published var crossfeedFeed: Float = 4.5
    @Published var crossfeedITD: Bool = true

    // Matrix mixer state (2 inputs x 9 outputs)
    @Published var matrixRouting = Array(repeating: Array(repeating: false, count: 9), count: 2)
    @Published var matrixGain = Array(repeating: Array(repeating: Float(0.0), count: 9), count: 2)
    @Published var matrixInvert = Array(repeating: Array(repeating: false, count: 9), count: 2)
    @Published var outputEnabled = Array(repeating: false, count: 9)
    @Published var outputGainDB = Array(repeating: Float(0.0), count: 9)
    @Published var outputMuted = Array(repeating: false, count: 9)
    @Published var outputDelayMS = Array(repeating: Float(0.0), count: 9)
    @Published var outputNames: [String] = MatrixOutput.all.map { $0.name } {
        didSet { UserDefaults.standard.set(outputNames, forKey: "outputNames") }
    }
    @Published var core1Mode: Int = 0  // 0=IDLE, 1=PDM, 2=EQ_WORKER
    @Published var outputPins: [UInt8] = [6, 7, 8, 9, 10]  // GPIO pins for SPDIF 1-4 + PDM

    // Preset state
    @Published var presetOccupied: UInt16 = 0
    @Published var presetNames: [String] = Array(repeating: "", count: 10)
    @Published var activePresetSlot: Int = 0      // 0-9, always valid
    @Published var presetStartupMode: Int = 0     // 0 = specified default, 1 = last active
    @Published var presetDefaultSlot: Int = 0
    @Published var presetIncludePins: Bool = false

    @Published var platformName: String = ""
    @Published var isDeviceConnected: Bool = false

    // Platform-aware output layout (platformName is set once at connection, safe to read from poll queue)
    var numChannels: Int { platformName == "RP2040" ? 7 : 11 }
    var numOutputChannels: Int { platformName == "RP2040" ? 5 : 9 }
    var pdmOutputIndex: Int { platformName == "RP2040" ? 4 : 8 }
    var eqWorkerRange: ClosedRange<Int> { platformName == "RP2040" ? 2...3 : 2...7 }
    private(set) var isOverviewMode: Bool = true

    // Live Data
    let meters = DSPMeterModel()

    /// Returns true if the matrix output is disabled or muted.
    func isOutputInactive(_ outputIndex: Int) -> Bool {
        !outputEnabled[outputIndex] || outputMuted[outputIndex]
    }

    func isPresetOccupied(_ slot: Int) -> Bool { presetOccupied & (1 << slot) != 0 }

    let usb: USBDevice
    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "com.foxdac.poll", qos: .userInteractive)

    init(usb: USBDevice = AppState.shared.usb) {
        self.usb = usb

        // Initialize Default Data
        // Master channels 0, 1
        for ch in [Channel.masterLeft, Channel.masterRight] {
            channelData[ch.rawValue] = Array(repeating: FilterParams(), count: 10)
            channelVisibility[ch.rawValue] = true
        }
        // Output EQ channels 2-10 (output index + 2)
        for outputIdx in 0..<9 {
            let eqCh = outputIdx + 2
            channelData[eqCh] = Array(repeating: FilterParams(), count: 10)
            channelVisibility[eqCh] = outputEnabled[outputIdx]
        }

        // Load saved output names
        if let saved = UserDefaults.standard.stringArray(forKey: "outputNames"), saved.count == 9 {
            outputNames = saved
        }

        recomputeAllMagnitudes()

        // 1. Subscribe to USB connection changes AND Trigger Fetch
        usb.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                self?.isDeviceConnected = connected
                if connected {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self?.updateSelection(to: nil)
                    }
                    self?.pollQueue.asyncAfter(deadline: .now() + 0.1) {
                        self?.fetchAll()
                    }
                }
            }
            .store(in: &cancellables)

        // 2. Start Polling Timer (Every 60ms) on background queue
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: 0.06)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isDeviceConnected else { return }
            self.fetchStatus()
        }
        timer.resume()
        pollTimer = timer

        // Initial Connect attempt
        usb.connect()
    }

    func updateSelection(to channel: Channel?) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if let ch = channel {
                isOverviewMode = false
                // Show only the selected master channel
                for eqCh in 0...10 {
                    channelVisibility[eqCh] = (eqCh == ch.rawValue)
                }
            } else {
                isOverviewMode = true
                // Overview: show master L/R + all enabled output channels
                channelVisibility[Channel.masterLeft.rawValue] = true
                channelVisibility[Channel.masterRight.rawValue] = true
                for outputIdx in 0..<9 {
                    channelVisibility[outputIdx + 2] = outputEnabled[outputIdx]
                }
            }
        }
    }

    func updateSelectionToOutput(_ outputIdx: Int) {
        isOverviewMode = false
        withAnimation(.easeInOut(duration: 0.2)) {
            for eqCh in 0...10 {
                channelVisibility[eqCh] = (eqCh == outputIdx + 2)
            }
        }
    }

    // MARK: - Magnitude Cache
    @Published var cachedMagnitudes: [Int: [Double]] = [:]

    func recomputeMagnitudes(for eqChannel: Int) {
        let filters = channelData[eqChannel] ?? []
        let isBypassed = bypass && (eqChannel <= 1)
        var results = [Double]()
        results.reserveCapacity(201)
        let logMin = log10(Float(10.0)), logMax = log10(Float(20000.0))
        for i in 0...200 {
            let freq = pow(10, logMin + Float(i) / 200.0 * (logMax - logMin))
            results.append(Double(isBypassed ? 0 : DSPMath.responseAt(freq: freq, filters: filters)))
        }
        cachedMagnitudes[eqChannel] = results
    }

    func recomputeAllMagnitudes() {
        for eqCh in 0...10 { recomputeMagnitudes(for: eqCh) }
    }
}
