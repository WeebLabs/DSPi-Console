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
    case i2sRx(Int)     // I2S input data pin, per stereo pair (0..3)
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
    /// Per-input preamp (dB).  Always `MAX_MATRIX_INPUTS` (8) wide: indices 0/1
    /// are the stereo USB L/R bus (also the master chain), 2-7 are the extra
    /// USB channels in RP2350 8-channel input mode.  Indices 2-7 stay 0 on
    /// stereo-only firmware.
    @Published var preampDB: [Float] = Array(repeating: 0.0, count: MAX_MATRIX_INPUTS)
    @Published var preampLinked: Bool = true
    @Published var masterVolumeDB: Float = 0.0
    /// Vendor-channel "user volume" — same field as the UAC1 host slider
    /// (`audio_state.volume`), driven via REQ_SET_USER_VOLUME (0xDA).
    /// Used as the sidebar volume control when input source is non-USB.
    /// Range: -60.0 ... 0.0 dB.
    @Published var userVolumeDB: Float = 0.0
    @Published var bypass: Bool = false
    @Published var channelData: [Int: [FilterParams]] = [:]
    /// Crossover bands per EQ channel.  Only output channels (eqCh >= chOut1) carry
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

    // Matrix mixer state (up to 8 inputs x 9 outputs).  Backing arrays are
    // always MAX_MATRIX_INPUTS rows so crosspoint bindings for inputs 2-7 are
    // always valid; the UI renders only `numMatrixInputs` of them.  Rows 2-7
    // stay all-false / 0 dB on stereo-only firmware.
    @Published var matrixRouting = Array(repeating: Array(repeating: false, count: 9), count: MAX_MATRIX_INPUTS)
    @Published var matrixGain = Array(repeating: Array(repeating: Float(0.0), count: 9), count: MAX_MATRIX_INPUTS)
    @Published var matrixInvert = Array(repeating: Array(repeating: false, count: 9), count: MAX_MATRIX_INPUTS)
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
    @Published var inputSource: Int = 0               // 0=USB, 1=SPDIF, 2=I2S
    @Published var inputSourceSupported: Bool = false  // false if firmware STALLs 0xE1
    @Published var spdifRxPin: UInt8 = 11             // GPIO pin for SPDIF RX

    // I2S input state (firmware wire format V12+).  `i2sInputSupported` is
    // false on older firmware that STALLs REQ_GET_I2S_RX_PIN (0xF2) or returns
    // a pre-V12 bulk payload.  See i2s_multi_input.md.
    @Published var i2sInputSupported: Bool = false
    /// Active I2S input channel count: 2 / 4 / 6 / 8 (1..4 stereo pairs).
    /// Multichannel (>2) is RP2350-only; RP2040 is stereo (always 2).
    @Published var i2sInputChannels: Int = 2
    /// Per-stereo-pair I2S RX data GPIO (pair 0..3).  Pair p carries input
    /// channels 2p, 2p+1.  Pairs 1..3 are RP2350-only.
    @Published var i2sRxPins: [UInt8] = I2S_RX_PIN_DEFAULTS
    @Published var i2sInputRateHz: UInt32 = 48000               // selected I2S input rate

    /// Max I2S stereo pairs / channels for this platform (RP2350 = 4 pairs / 8 ch,
    /// RP2040 = 1 pair / 2 ch).  Used to gate the multichannel I2S UI.
    var i2sMaxPairs: Int { platformName == "RP2040" ? 1 : I2S_RX_MAX_PAIRS_RP2350 }
    var i2sMaxInputChannels: Int { i2sMaxPairs * 2 }
    /// True when the device can do multichannel (>2) I2S input.
    var supportsMultichannelI2S: Bool { i2sInputSupported && platformName == "RP2350" }
    /// Number of currently-active I2S stereo pairs (count / 2).
    var i2sActivePairs: Int { max(1, i2sInputChannels / 2) }

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

    /// Device MAX input channels, read from the bulk header (byte 4): 2 for
    /// RP2040, 8 for RP2350.  This is the capability flag and also defines the
    /// channel-index base for outputs (CH_OUT_1 = num_input_channels).  Defaults
    /// to the stereo base until the first bulk fetch.
    @Published var numInputChannels: Int = BASE_MATRIX_INPUTS

    /// Live ACTIVE input count (2/4/6/8), driven by the host's USB audio format.
    /// Read from the status packet and the NOTIFY_EVT_INPUT_FORMAT push; used to
    /// lay out exactly that many input strips (sidebar + matrix).  Always >= 2.
    @Published var activeInputChannels: Int = BASE_MATRIX_INPUTS

    /// True when the device supports multichannel (>2) USB input: an RP2350 on
    /// V16 firmware reporting 8 inputs.  Gates all multichannel UI (spec §4).
    var supports8chInput: Bool {
        platformName == "RP2350"
            && firmwareWireFormatVersion == WIRE_FORMAT_VERSION
            && numInputChannels == MAX_MATRIX_INPUTS
    }

    /// First output's unified channel index (CH_OUT_1 = device max inputs).
    /// 8 on RP2350, 2 on RP2040.  Output EQ channel = output index + chOut1.
    var chOut1: Int { platformName == "RP2040" ? BASE_MATRIX_INPUTS : MAX_MATRIX_INPUTS }

    /// Unified EQ/channel index for a matrix output index (0-8).
    func eqChannel(forOutput output: Int) -> Int { output + chOut1 }

    /// Number of input strips to render: the live active count (>= 2).
    var numMatrixInputs: Int { max(BASE_MATRIX_INPUTS, min(activeInputChannels, chOut1)) }

    // Firmware version tuple parsed from REQ_GET_PLATFORM (data[1] = major,
    // data[2] high nibble = minor, data[2] low nibble = patch).  nil before
    // the first successful fetchPlatform().
    @Published var firmwareVersion: (major: Int, minor: Int, patch: Int)? = nil

    /// Bulk wire-format version (WIRE_FORMAT_VERSION), captured from byte 0 of
    /// the last REQ_GET_BULK_PARAMS reply.  This - not the firmware release
    /// version, which lagged behind - is the reliable signal for filter-type
    /// capabilities: the crossover-type renumber and first-order all-pass
    /// shipped in V13, the first-order shelves in V14.  0 before the first
    /// successful bulk fetch.
    @Published var firmwareWireFormatVersion: Int = 0

    /// First-order all-pass (FilterType.allPass1) shipped in wire format V13,
    /// which also renumbered the crossover types to 32..63.  Hidden from the
    /// PEQ picker until we've confirmed a V13+ firmware so we never send the
    /// new type byte (or the renumbered crossover values) to firmware that
    /// would misinterpret it.
    var firmwareSupportsFirstOrderAllPass: Bool { firmwareWireFormatVersion >= 13 }

    /// First-order low/high shelves (FilterType.lowShelf1 / .highShelf1)
    /// shipped in wire format V14.  Hidden from the PEQ picker until confirmed.
    var firmwareSupportsFirstOrderShelves: Bool { firmwareWireFormatVersion >= 14 }

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

    // Platform-aware layout (platformName is set once at connection, safe to read from poll queue).
    // V16 unified channel model: inputs 0..chOut1-1, outputs chOut1..numChannels-1.
    var numChannels: Int { chOut1 + numOutputChannels }   // 7 (RP2040) / 17 (RP2350)
    var numOutputChannels: Int { platformName == "RP2040" ? 5 : 9 }
    var pdmOutputIndex: Int { numOutputChannels - 1 }     // matrix output index (4 / 8)
    // EQ-worker outputs that share Core 1 with the PDM sub (matrix output indices).
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
        // I2S RX data pins.  Mirrors the firmware's two-tier rule:
        //   - Assigning an I2S RX pin itself keeps ALL configured pair pins
        //     mutually distinct (firmware i2s_rx_pair_pin_taken), so a pair can't
        //     land on another pair's pin even if that pair is currently inactive.
        //   - Every OTHER consumer (outputs, MCK, BCK, S/PDIF RX, DAC mute) only
        //     sees the *active* pairs as reserved (firmware is_pin_in_use), so
        //     inactive placeholder pins never lock GPIOs out of other functions
        //     while in a lower channel mode.
        if i2sInputSupported {
            let assigningI2SRx: Bool
            if case .some(.i2sRx) = consumer { assigningI2SRx = true } else { assigningI2SRx = false }
            let pairsReserved = assigningI2SRx ? i2sMaxPairs : i2sActivePairs
            for pair in 0..<min(pairsReserved, i2sRxPins.count) where consumer != .i2sRx(pair) && i2sRxPins[pair] == pin {
                return i2sMaxPairs > 1 ? "I2S RX \(pair + 1)" : "I2S RX"
            }
        }
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

        // Initialize Default Data (V16 unified model: inputs 0..chOut1-1 are
        // first-class EQ channels; outputs chOut1..numChannels-1 add crossover).
        // platformName is empty at init, so chOut1 defaults to the RP2350 base
        // (8); fetchAllParams repopulates once the device platform is known.
        for ch in 0..<chOut1 {
            channelData[ch] = Array(repeating: FilterParams(), count: 10)
            channelVisibility[ch] = true
        }
        for outputIdx in 0..<9 {
            let eqCh = eqChannel(forOutput: outputIdx)
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

        // The host switched USB input format — update the live active input
        // count so the sidebar / matrix relayout to the new channel count.
        AppState.shared.interruptMonitor.onInputFormatChanged = { [weak self] channels in
            guard let self = self else { return }
            let clamped = max(BASE_MATRIX_INPUTS, min(channels, self.chOut1))
            if self.activeInputChannels != clamped {
                self.activeInputChannels = clamped
                if self.isOverviewMode { self.updateSelection(to: nil) }
            }
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

    /// Select an input channel for editing (unified EQ channel index 0..chOut1-1),
    /// or pass nil for the overview.  Drives graph curve visibility.
    func updateSelection(to inputChannel: Int?) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if let ch = inputChannel {
                isOverviewMode = false
                activeEqChannel = ch
                // Link L/R: selecting a stereo input (0/1) with link on shows
                // both curves together (and the right pane stays on the click).
                let showBothMasters = ch < BASE_MATRIX_INPUTS && preampLinked
                for eqCh in 0..<numChannels {
                    if showBothMasters && eqCh < BASE_MATRIX_INPUTS {
                        channelVisibility[eqCh] = true
                    } else {
                        channelVisibility[eqCh] = (eqCh == ch)
                    }
                }
            } else {
                isOverviewMode = true
                activeEqChannel = nil
                // Overview: show active input channels + all enabled outputs.
                for eqCh in 0..<numChannels { channelVisibility[eqCh] = false }
                for i in 0..<min(activeInputChannels, chOut1) { channelVisibility[i] = true }
                for outputIdx in 0..<numOutputChannels {
                    channelVisibility[eqChannel(forOutput: outputIdx)] = outputEnabled[outputIdx]
                }
            }
        }
    }

    /// Re-runs the current selection's graph-visibility logic.  Called after
    /// `preampLinked` changes so the graph reflects whether both stereo input
    /// curves should be drawn together.  No-op outside a stereo-input selection.
    func refreshLinkedVisibility() {
        guard let ch = activeEqChannel, ch < BASE_MATRIX_INPUTS else { return }
        updateSelection(to: ch)
    }

    func updateSelectionToOutput(_ outputIdx: Int) {
        isOverviewMode = false
        let eqCh = eqChannel(forOutput: outputIdx)
        activeEqChannel = eqCh
        withAnimation(.easeInOut(duration: 0.2)) {
            for c in 0..<numChannels {
                channelVisibility[c] = (c == eqCh)
            }
        }
    }

    // MARK: - Magnitude / Phase Cache
    @Published var cachedMagnitudes: [Int: [Double]] = [:]
    @Published var cachedPhases: [Int: [Double]] = [:]
    @Published var cachedPhasesUnwrapped: [Int: [Double]] = [:]

    func recomputeMagnitudes(for eqChannel: Int) {
        let peqFilters = channelData[eqChannel] ?? []
        // Crossover is an output-only feature (channels >= chOut1).
        let xoverFilters = (eqChannel >= chOut1) ? (xoverData[eqChannel] ?? []) : []
        let allFilters = peqFilters + xoverFilters
        let isBypassed = bypass && (eqChannel < BASE_MATRIX_INPUTS)
        var results = [Double]()
        var phases = [Double]()
        results.reserveCapacity(201)
        phases.reserveCapacity(201)
        let logMin = log10(Float(10.0)), logMax = log10(Float(20000.0))
        for i in 0...200 {
            let freq = pow(10, logMin + Float(i) / 200.0 * (logMax - logMin))
            results.append(Double(isBypassed ? 0 : DSPMath.responseAt(freq: freq, filters: allFilters)))
            phases.append(Double(isBypassed ? 0 : DSPMath.phaseAt(freq: freq, filters: allFilters)))
        }
        cachedMagnitudes[eqChannel] = results
        cachedPhases[eqChannel] = phases
        cachedPhasesUnwrapped[eqChannel] = DSPMath.unwrapPhase(phases)
    }

    func recomputeAllMagnitudes() {
        for eqCh in 0..<numChannels { recomputeMagnitudes(for: eqCh) }
    }

    // MARK: - Unsaved Changes Detection

    func captureSnapshot() -> PresetSnapshot {
        PresetSnapshot(
            preampDB: preampDB,
            masterVolumeDB: masterVolumeDB,
            masterVolumeMode: presetMasterVolumeMode,
            outputConfigMode: presetOutputConfigMode,
            platformName: platformName,
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
            i2sRxPins: i2sInputSupported ? Array(i2sRxPins.prefix(i2sMaxPairs)) : nil,
            i2sInputChannels: i2sInputSupported ? i2sInputChannels : nil,
            i2sInputRate: i2sInputSupported ? i2sInputRateHz : nil,
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
        if eqChannel >= chOut1 {
            let outIdx = eqChannel - chOut1
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
        if eqChannel >= chOut1 {
            let outIdx = eqChannel - chOut1
            if let gain = cb.outputGainDB { setOutputGain(output: outIdx, db: gain) }
            if let delay = cb.outputDelayMS { setOutputDelay(output: outIdx, ms: delay) }
            if let muted = cb.outputMuted { setOutputMute(output: outIdx, muted: muted) }
        }
    }

    static func defaultChannelNames(for platform: String) -> [String] {
        return defaultChannelNames(for: platform, slotTypes: [0, 0, 0, 0])
    }

    /// Default channel names for the V16 unified model: inputs first, then
    /// outputs.  Matches firmware get_default_channel_name(): inputs are
    /// "USB L"/"USB R" then "USB 3".."USB 8"; outputs are "<type> N L/R" with
    /// the PDM sub last.  Returns one entry per channel for the platform.
    static func defaultChannelNames(for platform: String, slotTypes: [UInt8]) -> [String] {
        func slotName(_ slot: Int) -> String {
            slot < slotTypes.count && slotTypes[slot] == 1 ? "I2S" : "SPDIF"
        }
        let inputCount = platform == "RP2040" ? BASE_MATRIX_INPUTS : MAX_MATRIX_INPUTS
        let outputCount = platform == "RP2040" ? 5 : 9
        var names: [String] = []
        // Inputs 0..inputCount-1
        for ch in 0..<inputCount {
            switch ch {
            case 0:  names.append("USB L")
            case 1:  names.append("USB R")
            default: names.append("USB \(ch + 1)")
            }
        }
        // Outputs: stereo S/PDIF (or I2S) pairs, PDM sub last.
        for out in 0..<outputCount {
            if out == outputCount - 1 {
                names.append("PDM")
            } else {
                let slot = out / 2
                let side = out % 2 == 0 ? "L" : "R"
                names.append("\(slotName(slot)) \(slot + 1) \(side)")
            }
        }
        return names
    }
}
