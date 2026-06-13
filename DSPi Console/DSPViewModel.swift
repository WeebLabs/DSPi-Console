import SwiftUI
import Combine

// MARK: - GPIO Pin Conflict Resolution
//
// Top-level enum + view-model method so any tab that needs to filter
// pin pickers shares one source of truth.  Without this, each tab that
// owns a pin assignment maintains its own conflict list and a pin set
// in one tab would silently appear "available" in another.
enum PinConsumer: Equatable {
    case output(Int)    // slot or PDM index — indexes vm.outputPins[]
    case i2sBck         // also covers LRCLK (BCK + 1)
    case mck
    case spdifRx
    case dacMute
}

// MARK: - DAC Hardware Mute Config
//
// 16-byte wire-format struct mirroring firmware `DacHwMuteConfig` in
// `dac_hardware_mute_spec.md` §4.1.  Stored in the firmware's directory
// sector (board-level config — not per preset).  A single shared GPIO
// drives the DAC's MUTE input; pipeline reset is global so there's no
// per-slot granularity (installations with multiple DACs wire their
// MUTE pins together to one RP2 GPIO).
//
// Byte layout:
//   0:    enabled
//   1:    active_low
//   2:    pin (0xFF = none)
//   3:    reserved0 (alignment for hold_ms)
//   4-5:  hold_ms  (little-endian)
//   6-7:  release_ms (little-endian)
//   8-15: reserved
struct DacHwMuteConfig: Equatable {
    var enabled: Bool = false
    var activeLow: Bool = true
    var pin: UInt8 = DAC_HW_MUTE_PIN_NONE
    var holdMs: UInt16 = 0
    var releaseMs: UInt16 = 0

    /// Serialize to the 16-byte wire layout.  Reserved bytes are zero-filled.
    func toData() -> Data {
        var d = Data(count: 16)
        d[0] = enabled ? 1 : 0
        d[1] = activeLow ? 1 : 0
        d[2] = pin
        d[3] = 0  // reserved0 alignment
        d[4] = UInt8(holdMs & 0xFF)
        d[5] = UInt8((holdMs >> 8) & 0xFF)
        d[6] = UInt8(releaseMs & 0xFF)
        d[7] = UInt8((releaseMs >> 8) & 0xFF)
        return d
    }

    /// Parse the 16-byte wire layout.  Returns nil if too short.
    static func fromData(_ data: Data) -> DacHwMuteConfig? {
        guard data.count >= 16 else { return nil }
        let base = data.startIndex
        return DacHwMuteConfig(
            enabled:   data[base + 0] != 0,
            activeLow: data[base + 1] != 0,
            pin:       data[base + 2],
            holdMs:    UInt16(data[base + 4]) | (UInt16(data[base + 5]) << 8),
            releaseMs: UInt16(data[base + 6]) | (UInt16(data[base + 7]) << 8)
        )
    }
}

// MARK: - View Model

class DSPViewModel: ObservableObject {
    @Published var preampDB: [Float] = [0.0, 0.0]
    @Published var preampLinked: Bool = true
    @Published var masterVolumeDB: Float = 0.0
    /// Vendor-channel "user volume" — same field as the UAC1 host slider
    /// (`audio_state.volume`), driven via REQ_SET_USER_VOLUME (0xDA).
    /// Used as the sidebar volume control when input source is non-USB.
    /// Range: -60.0 ... 0.0 dB.
    @Published var userVolumeDB: Float = 0.0
    @Published var bypass: Bool = false
    @Published var channelData: [Int: [FilterParams]] = [:]
    /// Crossover bands per EQ channel.  Only output channels (eqCh >= 2) carry
    /// real entries; master channels are kept empty since crossover is
    /// rejected pre-matrix-mixer per spec §1.  Always 4 bands per channel
    /// (the 16-byte WireBandParams entries mapped to wire band indices 20..23).
    @Published var xoverData: [Int: [FilterParams]] = [:]
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

    // Input source state
    @Published var inputSource: Int = 0               // 0=USB, 1=SPDIF
    @Published var inputSourceSupported: Bool = false  // false if firmware STALLs 0xE1
    @Published var spdifRxPin: UInt8 = 11             // GPIO pin for SPDIF RX

    // LG Sound Sync — per-preset enable for LG TV optical-out volume decode.
    // `lgSoundSyncSupported` is set when V8+ bulk data is parsed or when an
    // explicit fetch returns a value.  Live runtime status (present/volume/
    // muted) is observed by StatsViewModel rather than mirrored here.
    @Published var lgSoundSyncEnabled: Bool = false
    @Published var lgSoundSyncSupported: Bool = false

    // DAC hardware mute — board-level config that drives a GPIO pin into
    // the DAC's mute input before clock-stop on pipeline reset.  Per-board
    // attribute, persisted in the firmware's directory sector (not per
    // preset).  `dacHwMuteSupported` flips true when the firmware responds
    // to REQ_GET_DAC_HW_MUTE_CONFIG (V10+ wire format).
    @Published var dacHwMuteConfig: DacHwMuteConfig = DacHwMuteConfig()
    @Published var dacHwMuteSupported: Bool = false

    // Preset state
    @Published var presetOccupied: UInt16 = 0
    @Published var presetNames: [String] = Array(repeating: "", count: 10)
    @Published var activePresetSlot: Int = 0      // 0-9, always valid
    @Published var presetStartupMode: Int = 0     // 0 = specified default, 1 = last active
    @Published var presetDefaultSlot: Int = 0
    @Published var presetOutputConfigMode: Int = OUTPUT_CONFIG_MODE_WITH_PRESET
    @Published var presetMasterVolumeMode: Int = MASTER_VOLUME_MODE_INDEPENDENT

    @Published var platformName: String = ""

    // Firmware version tuple parsed from REQ_GET_PLATFORM (data[1] = major,
    // data[2] high nibble = minor, data[2] low nibble = patch).  nil before
    // the first successful fetchPlatform().
    @Published var firmwareVersion: (major: Int, minor: Int, patch: Int)? = nil

    /// Notch filter type was added in firmware 1.1.4.  Older firmware won't
    /// recognize the type byte and would reject or misbehave on REQ_SET_EQ_PARAM.
    /// Defaults to `false` when the version is unknown (pre-connection) so the
    /// UI is conservative — the option becomes available the moment we confirm
    /// a supporting firmware.
    var firmwareSupportsNotch: Bool {
        guard let v = firmwareVersion else { return false }
        return (v.major, v.minor, v.patch) >= (1, 1, 4)
    }

    /// AllPass filter shipped in firmware 1.1.4.  Older firmware won't
    /// recognize the type byte and would reject or misbehave on REQ_SET_EQ_PARAM.
    /// Defaults to `false` when the version is unknown (pre-connection) so the
    /// UI is conservative — the option becomes available the moment we confirm
    /// a supporting firmware.
    var firmwareSupportsAllPass: Bool {
        guard let v = firmwareVersion else { return false }
        return (v.major, v.minor, v.patch) >= (1, 1, 4)
    }

    /// Per-band bypass shipped in firmware 1.1.4.  Older firmware STALLs the
    /// new opcodes; the bypass byte at offset 3 of EqParamPacket is also the
    /// legacy `reserved` byte, so sending bypass=1 is safe but ignored.
    var firmwareSupportsBandBypass: Bool {
        guard let v = firmwareVersion else { return false }
        return (v.major, v.minor, v.patch) >= (1, 1, 4)
    }

    /// Crossover stage (V11 wire format) shipped alongside crossover_filters_spec.
    /// Tracked via the bulk-transfer format version: firmware that returns a
    /// V11 payload accepts crossover writes at band indices 20..23.  Defaults
    /// to false until we've parsed a bulk reply, so the UI tab can hide itself
    /// on pre-V11 firmware.
    @Published var firmwareSupportsCrossover: Bool = false

    /// Wire band index for the i-th crossover band (0..3 → 20..23).  Single
    /// source of truth so view-model and view code agree about addressing.
    /// Crossover moved to base 20 (XOVER_BAND_BASE) to open a reserved gap at
    /// bands 10..19 for future PEQ-count growth - see firmware config.h.
    static func crossoverWireBand(_ localBand: Int) -> Int { 20 + localBand }
    static let crossoverBandsPerChannel = 4
    static let firstCrossoverWireBand = 20
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

    /// Returns the name of the feature currently claiming `pin`, or nil
    /// if free.  `excluding` lets the caller skip its own claim — e.g.
    /// the DAC-mute picker passes `.dacMute` so its own pin isn't
    /// reported as a conflict against itself.
    ///
    /// Single source of truth: HardwareSettingsTab AND GlobalSettingsTab
    /// both call this so a pin assigned in one tab can't quietly appear
    /// as "available" in the other.
    func pinInUseBy(_ pin: UInt8, excluding consumer: PinConsumer? = nil) -> String? {
        // SPDIF / I2S output slot pins.
        for slot in 0..<numOutputSlots {
            if consumer != .output(slot) && outputPins[slot] == pin {
                return "Output \(slot + 1)"
            }
        }
        // PDM (Subwoofer) — its outputPins index is numOutputSlots.
        let pdmIdx = numOutputSlots
        if pdmIdx < outputPins.count,
           consumer != .output(pdmIdx),
           outputPins[pdmIdx] == pin {
            return "Subwoofer"
        }
        if consumer != .i2sBck {
            if pin == i2sBckPin { return "I2S BCK" }
            if pin == i2sBckPin &+ 1 { return "I2S LRCLK" }
        }
        if consumer != .mck && pin == mckPin { return "I2S MCK" }
        if consumer != .spdifRx && inputSourceSupported && pin == spdifRxPin { return "S/PDIF RX" }
        if consumer != .dacMute,
           dacHwMuteConfig.enabled,
           dacHwMuteConfig.pin != DAC_HW_MUTE_PIN_NONE,
           pin == dacHwMuteConfig.pin {
            return "DAC Mute"
        }
        return nil
    }

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
            // Crossover bands default to FLAT (= bypassed) per spec §7.
            xoverData[eqCh] = Array(repeating:
                FilterParams(type: .flat, freq: 1000, q: 0.707, gain: 0), count: 4)
            channelVisibility[eqCh] = outputEnabled[outputIdx]
        }

        // Clean up legacy UserDefaults key
        UserDefaults.standard.removeObject(forKey: "outputNames")

        recomputeAllMagnitudes()

        // Mirror non-host change notifications back into UI.  Host-
        // originated edits (PARAM_SRC_HOST_SET == 1, our own EP0
        // REQ_SET_* writes) already update local state synchronously at
        // the setter call site (e.g. setChannelName, setUserVolume), so
        // we ignore source==HOST to avoid clobbering an in-flight edit
        // with its own stale notification echo.  Every other source is
        // the real payload we care about — in particular
        // PARAM_SRC_UAC1 (7), the OS volume slider writing user_volume
        // over UAC1, plus BULK / PRESET / FACTORY / GPIO / INTERNAL.
        AppState.shared.interruptMonitor.onParamChanged = { [weak self] offset, size, source, payload in
            guard source != 1 /* PARAM_SRC_HOST_SET */ else { return }
            self?.applyNotifiedParamChange(offset: offset, size: size, payload: payload)
        }

        // 1. Subscribe to USB connection changes AND Trigger Fetch
        usb.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                self?.isDeviceConnected = connected
                if !connected {
                    self?.savedSnapshot = nil
                    self?.presetOccupied = 0
                    self?.presetNames = Array(repeating: "", count: 10)
                    self?.activePresetSlot = 0
                    AppState.shared.interruptMonitor.stop()
                }
                if connected {
                    AppState.shared.interruptMonitor.start()
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
                let isMaster = (ch == .masterLeft || ch == .masterRight)
                // When Link L/R is on and the user selects a master channel,
                // show both master curves on the graph (in addition to keeping
                // the right pane focused on the clicked channel).
                let showBothMasters = isMaster && preampLinked
                for eqCh in 0...10 {
                    if showBothMasters && (eqCh == Channel.masterLeft.rawValue || eqCh == Channel.masterRight.rawValue) {
                        channelVisibility[eqCh] = true
                    } else {
                        channelVisibility[eqCh] = (eqCh == ch.rawValue)
                    }
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

    /// Re-runs the current sidebar selection's graph-visibility logic.  Called
    /// after `preampLinked` changes so the graph immediately reflects whether
    /// both master curves should be drawn together.  No-op outside master
    /// selection (e.g. on output channel pages or overview) — those modes
    /// aren't affected by Link L/R.
    func refreshLinkedVisibility() {
        guard let raw = activeEqChannel,
              let ch = Channel(rawValue: raw),
              ch == .masterLeft || ch == .masterRight else {
            return
        }
        updateSelection(to: ch)
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
        let peqFilters = channelData[eqChannel] ?? []
        let xoverFilters = (eqChannel >= 2) ? (xoverData[eqChannel] ?? []) : []
        let allFilters = peqFilters + xoverFilters
        let isBypassed = bypass && (eqChannel <= 1)
        var results = [Double]()
        results.reserveCapacity(201)
        let logMin = log10(Float(10.0)), logMax = log10(Float(20000.0))
        for i in 0...200 {
            let freq = pow(10, logMin + Float(i) / 200.0 * (logMax - logMin))
            results.append(Double(isBypassed ? 0 : DSPMath.responseAt(freq: freq, filters: allFilters)))
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
            masterVolumeDB: masterVolumeDB,
            masterVolumeMode: presetMasterVolumeMode,
            outputConfigMode: presetOutputConfigMode,
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
            crossoverFilters: xoverData.mapValues { $0.map { SnapshotFilterParams(from: $0) } },
            channelNames: channelNames,
            // Output configuration is captured unconditionally; PresetSnapshot.diff
            // gates the comparison on outputConfigMode so it only contributes to
            // preset dirtiness in WITH_PRESET mode (the master-volume pattern).
            outputPins: outputPins,
            outputSlotTypes: outputSlotTypes,
            i2sBckPin: i2sBckPin,
            mckEnabled: mckEnabled,
            mckPin: mckPin,
            mckMultiplier: mckMultiplier,
            spdifRxPin: spdifRxPin,
            inputSource: inputSourceSupported ? inputSource : nil,
            lgSoundSyncEnabled: lgSoundSyncSupported ? lgSoundSyncEnabled : nil
        )
    }

    func updateSavedSnapshot() {
        savedSnapshot = captureSnapshot()
    }

    var hasUnsavedChanges: Bool {
        // Route through computeDiff so the gating matches the alert text exactly:
        // master volume only counts when both snapshots have it (i.e. when the
        // current/baseline modes were WITH_PRESET).  Plain Equatable on
        // PresetSnapshot would say nil != Float and falsely report dirty after
        // a master-volume-mode flip even though no preset-persistent state
        // actually changed.
        guard savedSnapshot != nil else { return false }
        return !computeDiff().changes.isEmpty
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
