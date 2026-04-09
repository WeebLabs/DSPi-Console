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
    @Published var channelNames: [String] = DSPViewModel.defaultChannelNames(for: "")
    @Published var core1Mode: Int = 0  // 0=IDLE, 1=PDM, 2=EQ_WORKER
    @Published var outputPins: [UInt8] = [6, 7, 8, 9, 10]  // GPIO pins for SPDIF 1-4 + PDM

    // Volume Leveller state
    @Published var levellerEnabled: Bool = false
    @Published var levellerAmount: Float = 100.0
    @Published var levellerSpeed: Int = 0        // 0=Slow, 1=Medium, 2=Fast
    @Published var levellerMaxGainDB: Float = 24.0
    @Published var levellerLookahead: Bool = false
    @Published var levellerGateDB: Float = -70.0

    // I2S configuration state
    @Published var outputSlotTypes: [UInt8] = [0, 0, 0, 0]  // Per-slot: 0=S/PDIF, 1=I2S
    @Published var i2sBckPin: UInt8 = 14      // BCK GPIO (LRCLK = BCK + 1)
    @Published var mckEnabled: Bool = false
    @Published var mckPin: UInt8 = 13
    @Published var mckMultiplier: Int = 128   // 128 or 256
    @Published var sampleRateHz: UInt32 = 0   // live device sample rate (REQ_GET_STATUS wValue=15)

    // Preset state
    @Published var presetOccupied: UInt16 = 0
    @Published var presetNames: [String] = Array(repeating: "", count: 10)
    @Published var activePresetSlot: Int = 0      // 0-9, always valid
    @Published var presetStartupMode: Int = 0     // 0 = specified default, 1 = last active
    @Published var presetDefaultSlot: Int = 0
    @Published var presetIncludePins: Bool = false

    @Published var platformName: String = ""
    @Published var isDeviceConnected: Bool = false
    @Published var availableDevices: [DSPiDevice] = []
    @Published var selectedDevice: DSPiDevice? = nil

    /// Snapshot of state at last save/load point for unsaved changes detection
    var savedSnapshot: PresetSnapshot?

    // Platform-aware output layout (platformName is set once at connection, safe to read from poll queue)
    var numChannels: Int { platformName == "RP2040" ? 7 : 11 }
    var numOutputChannels: Int { platformName == "RP2040" ? 5 : 9 }
    var pdmOutputIndex: Int { platformName == "RP2040" ? 4 : 8 }
    var eqWorkerRange: ClosedRange<Int> { platformName == "RP2040" ? 2...3 : 2...7 }
    var numOutputSlots: Int { platformName == "RP2040" ? 2 : 4 }
    var anySlotIsI2S: Bool { outputSlotTypes.prefix(numOutputSlots).contains(1) }
    private(set) var isOverviewMode: Bool = true
    @Published var activeEqChannel: Int? = nil

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

        // Clean up legacy UserDefaults key
        UserDefaults.standard.removeObject(forKey: "outputNames")

        recomputeAllMagnitudes()

        // 1. Subscribe to USB connection changes AND Trigger Fetch
        usb.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                self?.isDeviceConnected = connected
                if !connected {
                    self?.savedSnapshot = nil
                }
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

        // Forward device list and selection from USBDevice
        usb.$availableDevices
            .receive(on: RunLoop.main)
            .assign(to: &$availableDevices)

        usb.$selectedDevice
            .receive(on: RunLoop.main)
            .assign(to: &$selectedDevice)

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
        usb.reconnect()
    }

    func updateSelection(to channel: Channel?) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if let ch = channel {
                isOverviewMode = false
                activeEqChannel = ch.rawValue
                // Show only the selected master channel
                for eqCh in 0...10 {
                    channelVisibility[eqCh] = (eqCh == ch.rawValue)
                }
            } else {
                isOverviewMode = true
                activeEqChannel = nil
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
        activeEqChannel = outputIdx + 2
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

    // MARK: - Unsaved Changes Detection

    func captureSnapshot() -> PresetSnapshot {
        PresetSnapshot(
            preampDB: preampDB,
            bypass: bypass,
            loudnessEnabled: loudnessEnabled,
            loudnessRefSPL: loudnessRefSPL,
            loudnessIntensity: loudnessIntensity,
            crossfeedEnabled: crossfeedEnabled,
            crossfeedPreset: crossfeedPreset,
            crossfeedFreq: crossfeedFreq,
            crossfeedFeed: crossfeedFeed,
            crossfeedITD: crossfeedITD,
            levellerEnabled: levellerEnabled,
            levellerAmount: levellerAmount,
            levellerSpeed: levellerSpeed,
            levellerMaxGainDB: levellerMaxGainDB,
            levellerLookahead: levellerLookahead,
            levellerGateDB: levellerGateDB,
            channelDelays: channelDelays,
            matrixRouting: matrixRouting,
            matrixGain: matrixGain,
            matrixInvert: matrixInvert,
            outputEnabled: outputEnabled,
            outputMuted: outputMuted,
            outputGainDB: outputGainDB,
            outputDelayMS: outputDelayMS,
            channelFilters: channelData.mapValues { $0.map { SnapshotFilterParams(from: $0) } },
            channelNames: channelNames,
            outputPins: presetIncludePins ? outputPins : nil,
            outputSlotTypes: presetIncludePins ? outputSlotTypes : nil,
            i2sBckPin: presetIncludePins ? i2sBckPin : nil,
            mckEnabled: presetIncludePins ? mckEnabled : nil,
            mckPin: presetIncludePins ? mckPin : nil,
            mckMultiplier: presetIncludePins ? mckMultiplier : nil
        )
    }

    func updateSavedSnapshot() {
        savedSnapshot = captureSnapshot()
    }

    var hasUnsavedChanges: Bool {
        guard let saved = savedSnapshot else { return false }
        return captureSnapshot() != saved
    }

    func computeDiff() -> PresetDiff {
        guard let saved = savedSnapshot else { return PresetDiff(changes: []) }
        return PresetSnapshot.diff(from: saved, to: captureSnapshot(), channelNames: channelNames)
    }

    func switchToDevice(_ device: DSPiDevice) {
        guard device != selectedDevice else { return }

        if isDeviceConnected && hasUnsavedChanges {
            let diff = computeDiff()
            let action = PresetAlerts.showUnsavedChangesAlert(diff: diff)
            switch action {
            case .save:
                DispatchQueue.global(qos: .userInitiated).async {
                    if self.presetNames[self.activePresetSlot].isEmpty {
                        self.setPresetName(slot: self.activePresetSlot, name: "Preset \(self.activePresetSlot + 1)")
                    }
                    let saveStatus = self.savePreset(slot: self.activePresetSlot)
                    guard saveStatus == PRESET_OK else {
                        DispatchQueue.main.async {
                            let alert = NSAlert()
                            alert.messageText = "Save Failed"
                            alert.informativeText = "Failed to save preset (error \(saveStatus)). Device switch aborted."
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            alert.runModal()
                        }
                        return
                    }
                    self.savedSnapshot = nil
                    self.usb.selectDevice(device)
                }
            case .discard:
                savedSnapshot = nil
                usb.selectDevice(device)
            case .cancel:
                return
            }
        } else {
            savedSnapshot = nil
            usb.selectDevice(device)
        }
    }

    // MARK: - Channel Clipboard

    struct ChannelClipboard {
        let filters: [FilterParams]
        let outputGainDB: Float?
        let outputDelayMS: Float?
        let outputMuted: Bool?
        let sourceName: String
    }

    var channelClipboard: ChannelClipboard? = nil

    func copyChannelParams(eqChannel: Int, name: String) {
        let filters = channelData[eqChannel] ?? []
        if eqChannel >= 2 {
            let outIdx = eqChannel - 2
            channelClipboard = ChannelClipboard(
                filters: filters,
                outputGainDB: outputGainDB[outIdx],
                outputDelayMS: outputDelayMS[outIdx],
                outputMuted: outputMuted[outIdx],
                sourceName: name
            )
        } else {
            channelClipboard = ChannelClipboard(
                filters: filters,
                outputGainDB: nil, outputDelayMS: nil, outputMuted: nil,
                sourceName: name
            )
        }
    }

    func pasteChannelParams(eqChannel: Int) {
        guard let cb = channelClipboard else { return }
        for (i, filter) in cb.filters.prefix(10).enumerated() {
            setFilter(ch: eqChannel, band: i, p: filter)
        }
        for i in cb.filters.count..<10 {
            setFilter(ch: eqChannel, band: i, p: FilterParams())
        }
        if eqChannel >= 2 {
            let outIdx = eqChannel - 2
            if let gain = cb.outputGainDB { setOutputGain(output: outIdx, db: gain) }
            if let delay = cb.outputDelayMS { setOutputDelay(output: outIdx, ms: delay) }
            if let muted = cb.outputMuted { setOutputMute(output: outIdx, muted: muted) }
        }
    }

    static func defaultChannelNames(for platform: String) -> [String] {
        return defaultChannelNames(for: platform, slotTypes: [0, 0, 0, 0])
    }

    static func defaultChannelNames(for platform: String, slotTypes: [UInt8]) -> [String] {
        func slotName(_ slot: Int) -> String {
            slot < slotTypes.count && slotTypes[slot] == 1 ? "I2S" : "SPDIF"
        }
        if platform == "RP2040" {
            return ["USB L", "USB R", "\(slotName(0)) 1 L", "\(slotName(0)) 1 R",
                    "\(slotName(1)) 2 L", "\(slotName(1)) 2 R", "PDM", "", "", "", ""]
        } else {
            return ["USB L", "USB R", "\(slotName(0)) 1 L", "\(slotName(0)) 1 R",
                    "\(slotName(1)) 2 L", "\(slotName(1)) 2 R", "\(slotName(2)) 3 L", "\(slotName(2)) 3 R",
                    "\(slotName(3)) 4 L", "\(slotName(3)) 4 R", "PDM"]
        }
    }
}
