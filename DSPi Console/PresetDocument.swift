import Foundation

/// A complete DSP configuration saved to (or loaded from) a `.dspipreset` file.
/// The document covers what a firmware preset slot covers (bulk_params.h), so it
/// round-trips a device rather than just its EQ.
///
/// The layout is deliberately identical to the Windows console's schema 1, so a
/// file written on either platform opens on the other.  Two consequences of that
/// shape are worth knowing before editing this file:
///
///  - **Values are stored raw, as the firmware sees them.**  Filter types, masks
///    and pin numbers are wire values, not Swift enum names: the wire values are
///    the firmware's own and stay stable across app releases, whereas a renamed
///    Swift case would silently break every existing file.
///
///  - **Channels carry two identities.**  `channelId` is the Windows console's
///    channel numbering; `eqChannel` / `inputIndex` / `outputIndex` are this
///    app's V16 unified numbering.  This app reads its own fields when they are
///    present and falls back to `channelId`, which is what a Windows-written
///    file carries.  See `PresetChannelRef`.
///
/// Fields this app adds on top of the shared schema are additive and optional:
/// a JSON reader ignores keys it doesn't know, so adding them keeps the file
/// readable on Windows.  They are marked "additive" below.
struct PresetDocument: Codable {

    /// Bumped only when the layout changes in a way an older reader would get
    /// wrong.  Readers reject a document from the future rather than guessing at
    /// blocks they can't see - the same rule the Windows reader applies.
    static let currentSchemaVersion = 1

    static let fileExtension = "dspipreset"

    var schemaVersion: Int = currentSchemaVersion
    var meta = Meta()
    var global = GlobalBlock()
    var loudness = LoudnessBlock()
    var crossfeed = CrossfeedBlock()
    var leveller = LevellerBlock()
    /// Absent when the source device had no psychoacoustic bass (pre-V23).
    var psybass: PsybassBlock?
    /// Absent when the source device had no upmixer (pre-V25 / RP2040).
    var upmix: UpmixBlock?
    var channels: [ChannelBlock] = []
    var matrix: [CrosspointBlock] = []
    /// Physical wiring.  Applied only when the user opts in on import, since
    /// GPIO assignments belong to a board rather than to a listening setup.
    var io = IoBlock()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.value(.schemaVersion, 0)
        meta = c.value(.meta, Meta())
        global = c.value(.global, GlobalBlock())
        loudness = c.value(.loudness, LoudnessBlock())
        crossfeed = c.value(.crossfeed, CrossfeedBlock())
        leveller = c.value(.leveller, LevellerBlock())
        psybass = c.value(.psybass, nil)
        upmix = c.value(.upmix, nil)
        channels = c.value(.channels, [])
        matrix = c.value(.matrix, [])
        io = c.value(.io, IoBlock())
    }

    // MARK: - Meta

    /// Provenance.  Informational only - nothing here gates an import, but a
    /// mismatch is worth telling the user about.
    struct Meta: Codable {
        var name: String?
        /// ISO-8601 UTC timestamp.  Held as a string rather than a `Date` so the
        /// encoding does not depend on a coding strategy: the Windows writer
        /// emits a `DateTimeOffset` with fractional seconds, which the strict
        /// ISO-8601 date decoders reject.
        var savedUtc: String = ""
        var appVersion: String?
        var platform: String?            // "RP2040" / "RP2350"
        var firmwareVersion: String?
        var wireFormatVersion: Int = 0
        var inputChannelCount: Int = 0
        var outputChannelCount: Int = 0
        /// additive: the source device's master-volume and output-config modes,
        /// so an import can explain why it left one of them alone.
        var masterVolumeMode: Int?
        var outputConfigMode: Int?

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.value(.name, nil)
            savedUtc = c.value(.savedUtc, "")
            appVersion = c.value(.appVersion, nil)
            platform = c.value(.platform, nil)
            firmwareVersion = c.value(.firmwareVersion, nil)
            wireFormatVersion = c.value(.wireFormatVersion, 0)
            inputChannelCount = c.value(.inputChannelCount, 0)
            outputChannelCount = c.value(.outputChannelCount, 0)
            masterVolumeMode = c.value(.masterVolumeMode, nil)
            outputConfigMode = c.value(.outputConfigMode, nil)
        }
    }

    // MARK: - Global

    struct GlobalBlock: Codable {
        /// Per-input preamp trim, indexed by wire input 0..7.
        var inputPreampsDb: [Float] = Array(repeating: 0, count: MAX_MATRIX_INPUTS)
        var bypass = false
        /// Master volume.  Per-preset only when the device's master-volume mode
        /// says so; otherwise it is device-global and left alone on import.
        var masterVolumeDb: Float = 0
        /// The user/listening volume the firmware restores with a preset.
        var userVolumeDb: Float = 0
        /// Wire InputSource value (0=USB, 1=S/PDIF, 2=I2S, 3=ADAT, 4-6=S/PDIF 2-4).
        /// A listening choice rather than wiring, so it travels with the audio
        /// settings and not with the IO block.
        var inputSource: Int = INPUT_SOURCE_USB
        var lgSoundSyncEnabled = false
        /// Per-input-pair PEQ link state (pairs 0..3).  App-side only - the
        /// firmware has no notion of it, but losing it on import would be
        /// surprising.
        var inputPairLinked: [Bool] = Array(repeating: false, count: DSPViewModel.inputPairCount)

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            inputPreampsDb = c.value(.inputPreampsDb, Array(repeating: 0, count: MAX_MATRIX_INPUTS))
            bypass = c.value(.bypass, false)
            masterVolumeDb = c.value(.masterVolumeDb, 0)
            userVolumeDb = c.value(.userVolumeDb, 0)
            inputSource = c.value(.inputSource, INPUT_SOURCE_USB)
            lgSoundSyncEnabled = c.value(.lgSoundSyncEnabled, false)
            inputPairLinked = c.value(.inputPairLinked, Array(repeating: false, count: DSPViewModel.inputPairCount))
        }
    }

    // MARK: - Feature blocks

    struct LoudnessBlock: Codable {
        var enabled = false
        var refSpl: Float = 83
        var intensityPct: Float = 100
        var outputMask: Int = Int(LOUDNESS_DEFAULT_OUTPUT_MASK)

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = c.value(.enabled, false)
            refSpl = c.value(.refSpl, 83)
            intensityPct = c.value(.intensityPct, 100)
            outputMask = c.value(.outputMask, Int(LOUDNESS_DEFAULT_OUTPUT_MASK))
        }
    }

    struct CrossfeedBlock: Codable {
        var enabled = false
        var preset: Int = 0
        var freqHz: Float = 700
        var feedDb: Float = 4.5
        var itd = true
        var outputPairMask: Int = Int(CROSSFEED_DEFAULT_OUTPUT_MASK)

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = c.value(.enabled, false)
            preset = c.value(.preset, 0)
            freqHz = c.value(.freqHz, 700)
            feedDb = c.value(.feedDb, 4.5)
            itd = c.value(.itd, true)
            outputPairMask = c.value(.outputPairMask, Int(CROSSFEED_DEFAULT_OUTPUT_MASK))
        }
    }

    struct LevellerBlock: Codable {
        var enabled = false
        var speed: Int = 0              // 0=Slow, 1=Medium, 2=Fast
        var lookahead = true
        var amountPct: Float = 50
        var maxGainDb: Float = 15
        var gateDb: Float = -96
        var detectorMask: Int = 0xFF
        var applyMask: Int = 0xFF

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = c.value(.enabled, false)
            speed = c.value(.speed, 0)
            lookahead = c.value(.lookahead, true)
            amountPct = c.value(.amountPct, 50)
            maxGainDb = c.value(.maxGainDb, 15)
            gateDb = c.value(.gateDb, -96)
            detectorMask = c.value(.detectorMask, 0xFF)
            applyMask = c.value(.applyMask, 0xFF)
        }
    }

    struct PsybassBlock: Codable {
        var enabled = false
        var cutoffHz: Float = 80
        var harmonicsDb: Float = 0
        var driveDb: Float = 6
        var characterPct: Float = 50
        var originalDb: Float = 0
        var outputMask: Int = Int(PSYBASS_DEFAULT_OUTPUT_MASK)

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = c.value(.enabled, false)
            cutoffHz = c.value(.cutoffHz, 80)
            harmonicsDb = c.value(.harmonicsDb, 0)
            driveDb = c.value(.driveDb, 6)
            characterPct = c.value(.characterPct, 50)
            originalDb = c.value(.originalDb, 0)
            outputMask = c.value(.outputMask, Int(PSYBASS_DEFAULT_OUTPUT_MASK))
        }
    }

    struct UpmixBlock: Codable {
        var enabled = false
        var centerMode: Int = UPMIX_CENTER_MODE_ADAPTIVE
        var surroundMode: Int = UPMIX_SURROUND_MODE_ADAPTIVE
        var strengthPct: Float = 100
        var centerWidthPct: Float = 25
        var thresholdPct: Float = 30
        var attackMs: Float = 10
        var releaseMs: Float = 100
        var detectorHpfHz: Float = 200
        var surroundDelayMs: Float = 12
        var surroundHpfHz: Float = 300
        var surroundLpfHz: Float = 7000
        var decorrPct: Float = 90
        var presenceDb: Float = 0

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = c.value(.enabled, false)
            centerMode = c.value(.centerMode, UPMIX_CENTER_MODE_ADAPTIVE)
            surroundMode = c.value(.surroundMode, UPMIX_SURROUND_MODE_ADAPTIVE)
            strengthPct = c.value(.strengthPct, 100)
            centerWidthPct = c.value(.centerWidthPct, 25)
            thresholdPct = c.value(.thresholdPct, 30)
            attackMs = c.value(.attackMs, 10)
            releaseMs = c.value(.releaseMs, 100)
            detectorHpfHz = c.value(.detectorHpfHz, 200)
            surroundDelayMs = c.value(.surroundDelayMs, 12)
            surroundHpfHz = c.value(.surroundHpfHz, 300)
            surroundLpfHz = c.value(.surroundLpfHz, 7000)
            decorrPct = c.value(.decorrPct, 90)
            presenceDb = c.value(.presenceDb, 0)
        }
    }

    // MARK: - Channels

    /// One channel's full state.
    struct ChannelBlock: Codable {
        /// The Windows console's channel id, written for cross-platform reading.
        /// `eqChannel` is this app's own numbering and wins when present.
        var channelId: Int = 0
        var name: String = ""
        var isOutput = false

        /// additive: this app's V16 unified EQ channel, and the input/output
        /// index behind it.  Written so a document survives a future channel-id
        /// change on either side, and read in preference to `channelId`.
        var eqChannel: Int?
        var inputIndex: Int?
        var outputIndex: Int?

        /// Pre-matrix channel delay (REQ_SET_DELAY).
        var delayMs: Float = 0

        /// Output channels only.
        var gainDb: Float = 0
        var muted = false
        var enabled = true
        /// additive: post-matrix output delay (REQ_SET_OUTPUT_DELAY), which is a
        /// separate value from `delayMs` and which the Windows document omits.
        var outputDelayMs: Float?

        var eq: [BandBlock] = []
        /// Crossover bands 0..3.  Empty for inputs and for pre-V11 sources.
        var crossover: [BandBlock] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            channelId = c.value(.channelId, 0)
            name = c.value(.name, "")
            isOutput = c.value(.isOutput, false)
            eqChannel = c.value(.eqChannel, nil)
            inputIndex = c.value(.inputIndex, nil)
            outputIndex = c.value(.outputIndex, nil)
            delayMs = c.value(.delayMs, 0)
            gainDb = c.value(.gainDb, 0)
            muted = c.value(.muted, false)
            enabled = c.value(.enabled, true)
            outputDelayMs = c.value(.outputDelayMs, nil)
            eq = c.value(.eq, [])
            crossover = c.value(.crossover, [])
        }
    }

    /// One filter band.  Field meanings follow the wire encoding, including the
    /// Linkwitz Transform's reuse of them (`freqHz` = f0, `q` = Q0, `gain` = fp
    /// in Hz, `qp` = target pole Q).
    struct BandBlock: Codable {
        var type: Int = 0               // wire FilterType value
        var freqHz: Float = 1000
        var q: Float = 0.707
        var gain: Float = 0
        var qp: Float = FilterParams.defaultQp
        var bypass = false

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.value(.type, 0)
            freqHz = c.value(.freqHz, 1000)
            q = c.value(.q, 0.707)
            gain = c.value(.gain, 0)
            qp = c.value(.qp, FilterParams.defaultQp)
            bypass = c.value(.bypass, false)
        }

        init(_ p: FilterParams) {
            type = p.type.rawValue
            freqHz = p.freq
            q = p.q
            gain = p.gain
            qp = p.qp
            bypass = p.bypass
        }

        /// Back to app parameters.  An unknown wire type (a band from newer
        /// firmware) becomes flat rather than an arbitrary shape.
        var filterParams: FilterParams {
            var p = FilterParams(type: FilterType(rawValue: type) ?? .flat)
            p.freq = freqHz
            p.q = q
            p.gain = gain
            p.qp = qp
            p.bypass = bypass
            return p
        }
    }

    struct CrosspointBlock: Codable {
        var input: Int = 0
        var output: Int = 0
        var enabled = false
        var invert = false
        var gainDb: Float = 0

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            input = c.value(.input, 0)
            output = c.value(.output, 0)
            enabled = c.value(.enabled, false)
            invert = c.value(.invert, false)
            gainDb = c.value(.gainDb, 0)
        }
    }

    // MARK: - Physical IO

    /// GPIO assignments, clocking, and the optical/serial input wiring.  Kept in
    /// its own block because it describes a board, not a listening setup - the
    /// same split the firmware makes with output_config_mode.
    struct IoBlock: Codable {
        var outputPins: [UInt8] = [6, 7, 8, 9, 10]
        var outputSlotTypes: [UInt8] = [0, 0, 0, 0]     // 0=S/PDIF, 1=I2S

        var i2sBckPin: UInt8 = 14
        var mckEnabled = false
        var mckPin: UInt8 = 13
        var mckMultiplier: Int = 128
        var i2sClockMode: UInt8 = 0                     // 0=master, 1=slave
        var i2sClockPinMode: UInt8 = 0                  // 0=unified, 1=split
        var i2sBckPinSlave: UInt8 = 26

        /// S/PDIF RX GPIOs for inputs 1..3 (index 0 is the primary).  Three
        /// entries, matching the shared schema; the fourth input's pin lives in
        /// `spdifRxPin4` so a reader that indexes this array by its own fixed
        /// length can't walk off the end.
        var spdifRxPins: [UInt8] = Array(SPDIF_RX_PIN_DEFAULTS.prefix(3))
        /// additive: GPIO for the fourth S/PDIF input, which the shared schema
        /// predates.
        var spdifRxPin4: UInt8?
        /// Enable mask for the optional S/PDIF inputs: bit 0 = input 2, bit 1 =
        /// input 3, bit 2 = input 4.  Bit 2 is additive - a reader that only
        /// knows two optional inputs simply ignores it.
        var spdifEnabledExt: UInt8 = 0

        /// I2S RX data GPIOs for pairs 0..3.
        var i2sRxPins: [UInt8] = I2S_RX_PIN_DEFAULTS
        var i2sInputChannels: Int = 2
        var i2sInputRateHz: UInt32 = 48000

        var adatEnabled = false
        var adatPin: UInt8 = ADAT_PIN_DEFAULT
        var adatInputEnabled = false
        var adatInputPin: UInt8 = ADAT_INPUT_PIN_UNSET
        var adatInputClockMode: UInt8 = 0

        var dacHwMute: DacHwMuteBlock?

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            outputPins = c.value(.outputPins, [6, 7, 8, 9, 10])
            outputSlotTypes = c.value(.outputSlotTypes, [0, 0, 0, 0])
            i2sBckPin = c.value(.i2sBckPin, 14)
            mckEnabled = c.value(.mckEnabled, false)
            mckPin = c.value(.mckPin, 13)
            mckMultiplier = c.value(.mckMultiplier, 128)
            i2sClockMode = c.value(.i2sClockMode, 0)
            i2sClockPinMode = c.value(.i2sClockPinMode, 0)
            i2sBckPinSlave = c.value(.i2sBckPinSlave, 26)
            spdifRxPins = c.value(.spdifRxPins, Array(SPDIF_RX_PIN_DEFAULTS.prefix(3)))
            spdifRxPin4 = c.value(.spdifRxPin4, nil)
            spdifEnabledExt = c.value(.spdifEnabledExt, 0)
            i2sRxPins = c.value(.i2sRxPins, I2S_RX_PIN_DEFAULTS)
            i2sInputChannels = c.value(.i2sInputChannels, 2)
            i2sInputRateHz = c.value(.i2sInputRateHz, 48000)
            adatEnabled = c.value(.adatEnabled, false)
            adatPin = c.value(.adatPin, ADAT_PIN_DEFAULT)
            adatInputEnabled = c.value(.adatInputEnabled, false)
            adatInputPin = c.value(.adatInputPin, ADAT_INPUT_PIN_UNSET)
            adatInputClockMode = c.value(.adatInputClockMode, 0)
            dacHwMute = c.value(.dacHwMute, nil)
        }
    }

    struct DacHwMuteBlock: Codable {
        var enabled = false
        var activeLow = true
        var pin: UInt8 = DAC_HW_MUTE_PIN_NONE
        var holdMs: UInt16 = 0
        var releaseMs: UInt16 = 0

        init() {}

        init(_ config: DacHwMuteConfig) {
            enabled = config.enabled
            activeLow = config.activeLow
            pin = config.pin
            holdMs = config.holdMs
            releaseMs = config.releaseMs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = c.value(.enabled, false)
            activeLow = c.value(.activeLow, true)
            pin = c.value(.pin, DAC_HW_MUTE_PIN_NONE)
            holdMs = c.value(.holdMs, 0)
            releaseMs = c.value(.releaseMs, 0)
        }

        var config: DacHwMuteConfig {
            DacHwMuteConfig(enabled: enabled, activeLow: activeLow, pin: pin,
                            holdMs: holdMs, releaseMs: releaseMs)
        }
    }
}

// MARK: - Lenient decoding

private extension KeyedDecodingContainer {
    /// Decode a key, falling back to `fallback` when it is missing, null, or of
    /// the wrong type.  Every field in the document uses this: a hand-edited
    /// file, or one from a build that didn't have a given block yet, should load
    /// with sensible values rather than failing outright.  The one thing a
    /// reader must not be lenient about is the schema version, which is checked
    /// separately in `PresetDocumentFile`.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

// MARK: - Channel identity

/// Which channel a document block refers to, in this app's terms.
enum PresetChannelRef: Hashable {
    case input(Int)     // wire input index 0..7
    case output(Int)    // matrix output index 0..8
}

/// Translation between this app's V16 unified channel numbering and the Windows
/// console's channel ids.
///
/// The two schemes disagree because they grew differently: this app numbers
/// inputs 0..7 and puts outputs above them at `chOut1`, while the Windows ids
/// were laid down when there were two inputs and grew outputs in the middle
/// (inputs 0/1 and 11..16, outputs 2..10).  On RP2040 the Windows id 6 is PDM
/// rather than S/PDIF 3 L, which is why every conversion needs the platform.
enum PresetChannelID {

    /// Windows ids for the extra unified-model inputs 3..8.
    private static let extraInputBase = 11
    /// Windows id of the first output (S/PDIF 1 L).
    private static let outputBase = 2
    /// Windows id of the PDM output on RP2350.  On RP2040 PDM is the fifth
    /// output and lands at id 6 by the ordinary arithmetic.
    private static let pdmIDRp2350 = 10

    static func isRp2040(_ platform: String) -> Bool { platform == "RP2040" }

    /// Number of outputs on a platform, without needing a live view model.
    static func outputCount(platform: String) -> Int { isRp2040(platform) ? 5 : 9 }

    /// Windows channel id for a wire input index.
    static func id(forInput input: Int) -> Int {
        input < BASE_MATRIX_INPUTS ? input : extraInputBase + (input - BASE_MATRIX_INPUTS)
    }

    /// Windows channel id for a matrix output index.
    static func id(forOutput output: Int, platform: String) -> Int {
        // RP2350's PDM is the ninth output but sits at id 10, above S/PDIF 4 R.
        if !isRp2040(platform) && output == outputCount(platform: platform) - 1 {
            return pdmIDRp2350
        }
        return outputBase + output
    }

    /// Resolve a Windows channel id against a platform.  Returns nil for an id
    /// that platform has no channel for.
    static func ref(forID id: Int, platform: String) -> PresetChannelRef? {
        if id >= 0 && id < BASE_MATRIX_INPUTS { return .input(id) }
        if id >= extraInputBase && id < extraInputBase + (MAX_MATRIX_INPUTS - BASE_MATRIX_INPUTS) {
            return .input(BASE_MATRIX_INPUTS + (id - extraInputBase))
        }
        let outputs = outputCount(platform: platform)
        if !isRp2040(platform) && id == pdmIDRp2350 { return .output(outputs - 1) }
        let output = id - outputBase
        return (output >= 0 && output < outputs) ? .output(output) : nil
    }
}

extension PresetDocument.ChannelBlock {
    /// The channel this block refers to, read against the *target* platform.
    /// This app's own `inputIndex` / `outputIndex` win when present; otherwise
    /// the shared `channelId` is translated, which is what a Windows-written
    /// document carries.
    func ref(platform: String) -> PresetChannelRef? {
        if isOutput, let output = outputIndex { return .output(output) }
        if !isOutput, let input = inputIndex { return .input(input) }
        return PresetChannelID.ref(forID: channelId, platform: platform)
    }
}

// MARK: - File I/O

enum PresetDocumentError: LocalizedError {
    case notAPreset(String)
    case newerSchema(Int)

    var errorDescription: String? {
        switch self {
        case .notAPreset(let detail):
            return "Not a valid configuration file: \(detail)"
        case .newerSchema(let version):
            return "This configuration was written by a newer version of DSPi Console "
                 + "(format \(version), this build reads \(PresetDocument.currentSchemaVersion))."
        }
    }
}

enum PresetDocumentFile {

    static func encode(_ doc: PresetDocument) throws -> Data {
        let encoder = JSONEncoder()
        // Sorted keys so two exports of the same state diff cleanly; pretty
        // printed because these files are meant to be readable and hand-editable.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(doc)
    }

    static func decode(_ data: Data) throws -> PresetDocument {
        let doc: PresetDocument
        do {
            doc = try JSONDecoder().decode(PresetDocument.self, from: data)
        } catch {
            throw PresetDocumentError.notAPreset(error.localizedDescription)
        }

        // Checked after decoding rather than before: a document from the future
        // may well parse, and we want to name its version in the message.
        guard doc.schemaVersion > 0, !doc.channels.isEmpty else {
            throw PresetDocumentError.notAPreset("no channel data found.")
        }
        guard doc.schemaVersion <= PresetDocument.currentSchemaVersion else {
            throw PresetDocumentError.newerSchema(doc.schemaVersion)
        }
        return doc
    }
}
