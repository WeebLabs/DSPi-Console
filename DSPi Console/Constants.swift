import Foundation

// MARK: - USB Request Constants

// EQ / Preamp / Bypass / Delay
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
// 0x52 was the deprecated synchronous REQ_LOAD_PARAMS; repurposed as the
// device-global output-config save (see REQ_SAVE_OUTPUT_CONFIG below).
let REQ_SAVE_OUTPUT_CONFIG: UInt8 = 0x52
let REQ_FACTORY_RESET: UInt8 = 0x53
let REQ_SET_CHANNEL_GAIN: UInt8 = 0x54
let REQ_GET_CHANNEL_GAIN: UInt8 = 0x55
let REQ_SET_CHANNEL_MUTE: UInt8 = 0x56
let REQ_GET_CHANNEL_MUTE: UInt8 = 0x57
let REQ_SET_LOUDNESS: UInt8           = 0x58
let REQ_GET_LOUDNESS: UInt8           = 0x59
let REQ_SET_LOUDNESS_REF: UInt8       = 0x5A
let REQ_GET_LOUDNESS_REF: UInt8       = 0x5B
let REQ_SET_LOUDNESS_INTENSITY: UInt8 = 0x5C
let REQ_GET_LOUDNESS_INTENSITY: UInt8 = 0x5D
// Loudness output mask (V19): 2 bytes uint16 LE, bit k = output channel k
let REQ_SET_LOUDNESS_MASK: UInt8      = 0xFA
let REQ_GET_LOUDNESS_MASK: UInt8      = 0xFB
/// Factory-default loudness output mask (all outputs compensated).
let LOUDNESS_DEFAULT_OUTPUT_MASK: UInt16 = 0xFFFF
let REQ_SET_CROSSFEED: UInt8           = 0x5E
let REQ_GET_CROSSFEED: UInt8           = 0x5F
let REQ_SET_CROSSFEED_PRESET: UInt8    = 0x60
let REQ_GET_CROSSFEED_PRESET: UInt8    = 0x61
let REQ_SET_CROSSFEED_FREQ: UInt8      = 0x62
let REQ_GET_CROSSFEED_FREQ: UInt8      = 0x63
let REQ_SET_CROSSFEED_FEED: UInt8      = 0x64
let REQ_GET_CROSSFEED_FEED: UInt8      = 0x65
let REQ_SET_CROSSFEED_ITD: UInt8       = 0x66
let REQ_GET_CROSSFEED_ITD: UInt8       = 0x67
// Crossfeed output-pair mask (V20): 1 byte, bit p = run crossfeed on output pair p
// (outputs 2p / 2p+1).  Filter settings stay global; the mask only selects pairs.
let REQ_SET_CROSSFEED_OUTPUTS: UInt8   = 0xFC
let REQ_GET_CROSSFEED_OUTPUTS: UInt8   = 0xFD
/// Factory-default crossfeed output-pair mask (pair 1 only, i.e. outputs 0/1).
let CROSSFEED_DEFAULT_OUTPUT_MASK: UInt8 = 0x01

// Psychoacoustic Bass ("psybass", V23): missing-fundamental bass enhancement.
// One global parameter set applied per output channel selected by a 16-bit mask,
// exactly like loudness.  Value SETs take a 4-byte LE float; enable is 1 byte and
// the mask is 2 bytes LE uint16.  The firmware clamps every value to its range.
let REQ_SET_PSYBASS: UInt8            = 0x30
let REQ_GET_PSYBASS: UInt8            = 0x31
let REQ_SET_PSYBASS_CUTOFF: UInt8     = 0x32
let REQ_GET_PSYBASS_CUTOFF: UInt8     = 0x33
let REQ_SET_PSYBASS_HARMONICS: UInt8  = 0x34
let REQ_GET_PSYBASS_HARMONICS: UInt8  = 0x35
let REQ_SET_PSYBASS_DRIVE: UInt8      = 0x36
let REQ_GET_PSYBASS_DRIVE: UInt8      = 0x37
let REQ_SET_PSYBASS_CHARACTER: UInt8  = 0x38
let REQ_GET_PSYBASS_CHARACTER: UInt8  = 0x39
let REQ_SET_PSYBASS_ORIGINAL: UInt8   = 0x3A
let REQ_GET_PSYBASS_ORIGINAL: UInt8   = 0x3B
let REQ_SET_PSYBASS_MASK: UInt8       = 0x3C
let REQ_GET_PSYBASS_MASK: UInt8       = 0x3D
/// Factory-default psybass output mask (all outputs).  A typical setup masks off
/// the PDM sub and any full-range outputs, since synthesizing harmonics on a
/// channel that can reproduce real bass is counterproductive.
let PSYBASS_DEFAULT_OUTPUT_MASK: UInt16 = 0xFFFF

// Stereo Upmixer (V25): derives Centre + Left/Right Surround as ordinary matrix
// source rows (2 = C, 3 = Ls, 4 = Rs) from a plain stereo input.  RP2350 only;
// on RP2040 the SETs STALL and the GETs return all-zero payloads.  See
// Documentation/Features/upmixer_spec.md.  Live single-parameter SETs carry the
// param id in wValue and a 4-byte LE float payload (including enable/modes, which
// the firmware rounds).  SET_CONFIG applies a whole 44-byte packet atomically.
let REQ_UPMIX_SET_CONFIG: UInt8   = 0x4A   // OUT: UpmixConfigPacket, exactly 44 bytes
let REQ_UPMIX_GET_CONFIG: UInt8   = 0x4B   // IN 44 bytes: UpmixConfigPacket
let REQ_UPMIX_SET_PARAM:  UInt8   = 0x4C   // OUT: wValue = param id (0-12), 4-byte float
let REQ_UPMIX_GET_PARAM:  UInt8   = 0x4D   // IN 4 bytes: wValue = param id (0-12)
let REQ_UPMIX_GET_STATUS: UInt8   = 0x4E   // IN 16 bytes: UpmixStatus telemetry

// Upmix parameter ids (wValue of REQ_UPMIX_SET/GET_PARAM; spec §4 table).
let UPMIX_PARAM_ENABLED:       UInt16 = 0
let UPMIX_PARAM_CENTER_MODE:   UInt16 = 1
let UPMIX_PARAM_SURROUND_MODE: UInt16 = 2
let UPMIX_PARAM_STRENGTH:      UInt16 = 3
let UPMIX_PARAM_CENTER_WIDTH:  UInt16 = 4
let UPMIX_PARAM_THRESHOLD:     UInt16 = 5
let UPMIX_PARAM_ATTACK:        UInt16 = 6
let UPMIX_PARAM_RELEASE:       UInt16 = 7
let UPMIX_PARAM_DET_HPF:       UInt16 = 8
let UPMIX_PARAM_SUR_DELAY:     UInt16 = 9
let UPMIX_PARAM_SUR_HPF:       UInt16 = 10
let UPMIX_PARAM_SUR_LPF:       UInt16 = 11
let UPMIX_PARAM_DECORR:        UInt16 = 12
// Presence (V26+): centre presence bell gain at a fixed 3 kHz / Q 0.6.  Via
// SET/GET_PARAM the value is a plain float dB (-12..+12); in the config packet
// and presets it is packed into config byte 3 as `presence_q1` (i8 = dB x 2).
let UPMIX_PARAM_PRESENCE:      UInt16 = 13

// Centre engine modes (UPMIX_PARAM_CENTER_MODE).  OFF was appended as 2 rather
// than renumbered to match the surround enum's OFF-first layout, because moving
// 0/1 would have silently remapped existing hosts and saved presets.
let UPMIX_CENTER_MODE_PASSIVE:  Int = 0
let UPMIX_CENTER_MODE_ADAPTIVE: Int = 1
let UPMIX_CENTER_MODE_OFF:      Int = 2   // V27+: no C output, L/R bit-exact
// Surround engine modes (UPMIX_PARAM_SURROUND_MODE).
let UPMIX_SURROUND_MODE_OFF:      Int = 0
let UPMIX_SURROUND_MODE_PASSIVE:  Int = 1
let UPMIX_SURROUND_MODE_ADAPTIVE: Int = 2

// UpmixStatus.parked_reason (spec §6.3).
let UPMIX_PARKED_ACTIVE:        UInt8 = 0
let UPMIX_PARKED_DISABLED:      UInt8 = 1
let UPMIX_PARKED_NOT_STEREO:    UInt8 = 2
let UPMIX_PARKED_RATE_TOO_HIGH: UInt8 = 3

/// Exact byte length of UpmixConfigPacket / WireUpmixParams (spec §6.1).
let UPMIX_CONFIG_PACKET_SIZE: Int    = 44
/// Byte length of the UpmixStatus telemetry response (spec §6.3).
let UPMIX_STATUS_SIZE: UInt16        = 16

// Matrix mixer request codes
let REQ_SET_MATRIX_ROUTE: UInt8    = 0x70
let REQ_GET_MATRIX_ROUTE: UInt8    = 0x71
let REQ_SET_OUTPUT_ENABLE: UInt8   = 0x72
let REQ_GET_OUTPUT_ENABLE: UInt8   = 0x73
let REQ_SET_OUTPUT_GAIN: UInt8     = 0x74
let REQ_GET_OUTPUT_GAIN: UInt8     = 0x75
let REQ_SET_OUTPUT_MUTE: UInt8     = 0x76
let REQ_GET_OUTPUT_MUTE: UInt8     = 0x77
let REQ_SET_OUTPUT_DELAY: UInt8    = 0x78
let REQ_GET_OUTPUT_DELAY: UInt8    = 0x79

// Core 1 mode request codes
let REQ_GET_CORE1_MODE: UInt8      = 0x7A
let REQ_GET_CORE1_CONFLICT: UInt8  = 0x7B

// Pin configuration request codes
let REQ_SET_OUTPUT_PIN: UInt8      = 0x7C
let REQ_GET_OUTPUT_PIN: UInt8      = 0x7D

// Device identification request codes
let REQ_GET_SERIAL: UInt8          = 0x7E
let REQ_GET_PLATFORM: UInt8        = 0x7F

// I2S output configuration request codes
let REQ_SET_OUTPUT_TYPE: UInt8     = 0xC0
let REQ_GET_OUTPUT_TYPE: UInt8     = 0xC1
let REQ_SET_I2S_BCK_PIN: UInt8    = 0xC2   // IN: wValue = (role<<8)|GPIO, returns PIN_CONFIG_*
let REQ_GET_I2S_BCK_PIN: UInt8    = 0xC3   // IN 1 byte: wValue = role (0=master/1=slave pair)

/// Role byte carried in the REQ_SET/GET_I2S_BCK_PIN wValue high byte
/// (clock_pins_spec.md §3).  Legacy hosts send a bare GPIO (role 0 implicit).
let I2S_BCK_ROLE_MASTER: UInt8    = 0      // master/unified clock pair
let I2S_BCK_ROLE_SLAVE: UInt8     = 1      // slave clock pair (SPLIT mode only)
let REQ_SET_MCK_ENABLE: UInt8     = 0xC4
let REQ_GET_MCK_ENABLE: UInt8     = 0xC5
let REQ_SET_MCK_PIN: UInt8        = 0xC6
let REQ_GET_MCK_PIN: UInt8        = 0xC7
let REQ_SET_MCK_MULTIPLIER: UInt8 = 0xC8
let REQ_GET_MCK_MULTIPLIER: UInt8 = 0xC9

// ADAT bulk output request codes (RP2350 only).  Streams all 8 main output
// channels (post-EQ/crossover/gain/mute/delay) as one ADAT lightpipe signal on
// a single GPIO, concurrent with the SPDIF/I2S slots and PDM.  See
// Documentation/Features/adat_output_spec.md.  SETs are IN-direction transfers
// carrying the value in wValue and returning a PIN_CONFIG_* status byte (same
// shape as REQ_SET_SPDIF_RX_PIN).  On RP2040 both SETs return INVALID_OUTPUT
// and the GETs return zeros.
let REQ_SET_ADAT_ENABLE: UInt8    = 0xCA   // IN: wValue = 0/1, returns status
let REQ_GET_ADAT_ENABLE: UInt8    = 0xCB   // IN 1 byte: configured enable (0/1)
let REQ_SET_ADAT_PIN: UInt8       = 0xCC   // IN: wValue = GPIO (0 = default), returns status
let REQ_GET_ADAT_PIN: UInt8       = 0xCD   // IN 1 byte: configured GPIO
let REQ_GET_ADAT_STATUS: UInt8    = 0xCE   // IN 8 bytes: AdatStatus

/// Platform default ADAT data GPIO (PICO_ADAT_PIN); pin 0 in flash/wire means
/// "unset, use this default".
let ADAT_PIN_DEFAULT: UInt8       = 12

// ADAT input request codes (RP2350 only).  A selectable 8-channel input source
// (INPUT_SOURCE_ADAT = 3): one TOSLINK receiver feeds 8 channels of 24-bit audio
// into input channels 0..7 of the unified channel model.  See
// Documentation/Features/adat_input_spec.md.  SETs carry the value in wValue and
// return a PIN_CONFIG_* status byte; on RP2040 0x68/0x6A return INVALID_OUTPUT
// and 0x6E returns 20 zero bytes (the config GETs still round-trip).  There is no
// free default GPIO: the pin ships unset (0xFF) and must be assigned before
// enable.  Order matters - set the pin (0x6A) before enabling (0x68).
let REQ_SET_ADAT_INPUT_ENABLE: UInt8     = 0x68   // IN: wValue = 0/1, returns status
let REQ_GET_ADAT_INPUT_ENABLE: UInt8     = 0x69   // IN 1 byte: configured enable (0/1)
let REQ_SET_ADAT_INPUT_PIN: UInt8        = 0x6A   // IN: wValue = GPIO (0xFF clears), returns status
let REQ_GET_ADAT_INPUT_PIN: UInt8        = 0x6B   // IN 1 byte: configured GPIO (0xFF = unset)
let REQ_SET_ADAT_INPUT_CLOCK_MODE: UInt8 = 0x6C   // IN: wValue = 0/1, deferred, returns status
let REQ_GET_ADAT_INPUT_CLOCK_MODE: UInt8 = 0x6D   // IN 1 byte: live mode (0/1)
let REQ_GET_ADAT_INPUT_STATUS: UInt8     = 0x6E   // IN 20 bytes: AdatInputStatusPacket

/// ADAT input RX GPIO sentinel meaning "unset" (no default pin is free).
let ADAT_INPUT_PIN_UNSET: UInt8   = 0xFF

// ADAT input clock mode (REQ_SET/GET_ADAT_INPUT_CLOCK_MODE).  MASTER (default):
// DSPi owns the sample rate via REQ_SET_INPUT_RATE and the returning ADAT stream
// is already in DSPi's clock domain (no servo).  SLAVE: external gear owns the
// clock, the wire rate is auto-detected, and every output is servo rate-matched.
let ADAT_INPUT_CLOCK_MODE_MASTER: UInt8 = 0
let ADAT_INPUT_CLOCK_MODE_SLAVE: UInt8  = 1

// Clip detection request codes
let REQ_CLEAR_CLIPS: UInt8            = 0x83

// Pin configuration status codes
let PIN_CONFIG_SUCCESS: UInt8        = 0x00
let PIN_CONFIG_INVALID_PIN: UInt8    = 0x01
let PIN_CONFIG_PIN_IN_USE: UInt8     = 0x02
let PIN_CONFIG_INVALID_OUTPUT: UInt8 = 0x03
let PIN_CONFIG_OUTPUT_ACTIVE: UInt8  = 0x04
// A non-pin field is out of range (UART baud, I2C address).  Shared with the
// control-interface SET commands (0xF5 / 0xF7); see control_interfaces_spec.md §2.3.
let PIN_CONFIG_INVALID_PARAM: UInt8  = 0x05

// Preset request codes (0x90-0x9A)
let REQ_PRESET_SAVE: UInt8              = 0x90
let REQ_PRESET_LOAD: UInt8              = 0x91
let REQ_PRESET_DELETE: UInt8            = 0x92
let REQ_PRESET_GET_NAME: UInt8          = 0x93
let REQ_PRESET_SET_NAME: UInt8          = 0x94
let REQ_PRESET_GET_DIR: UInt8           = 0x95
let REQ_PRESET_SET_STARTUP: UInt8       = 0x96
let REQ_PRESET_GET_STARTUP: UInt8       = 0x97
// 0x98/0x99 were REQ_PRESET_SET/GET_INCLUDE_PINS; repurposed as the
// output-config persistence mode (the former include-pins flag is now a
// mode governing the whole IO block — pins, output types, I2S MCK/BCK, and
// the S/PDIF RX pin).  Payload/return is the 0/1 mode byte.
let REQ_SET_OUTPUT_CONFIG_MODE: UInt8   = 0x98
let REQ_GET_OUTPUT_CONFIG_MODE: UInt8   = 0x99
let REQ_PRESET_GET_ACTIVE: UInt8        = 0x9A

// Output-config persistence modes (payload of 0x98 / response of 0x99, and
// byte [5] of the REQ_PRESET_GET_DIR summary).  Mirrors the master-volume
// independent/with-preset mechanism, but defaults to WITH_PRESET.
let OUTPUT_CONFIG_MODE_INDEPENDENT: Int = 0   // Stored in directory, applied at boot, untouched by presets
let OUTPUT_CONFIG_MODE_WITH_PRESET: Int = 1   // Saved with each preset, restored on preset load (default)

// Channel name request codes
let REQ_SET_CHANNEL_NAME: UInt8  = 0x9B
let REQ_GET_CHANNEL_NAME: UInt8  = 0x9C

// Bulk parameter transfer request codes
let REQ_GET_ALL_PARAMS: UInt8           = 0xA0
let REQ_SET_ALL_PARAMS: UInt8           = 0xA1
/// Wire format V28 (fourth selectable S/PDIF input): WireInputConfig's
/// `spdif_rx_pin_ext` grows from 2 to 3 entries, consuming that section's last
/// reserved byte and shifting `spdif_rx_enabled_ext_p1`, `i2s_clock_mode` and
/// the three ADAT input fields down one byte each.  The section stays 16 bytes,
/// so no later section moved and the total size is unchanged.
/// Wire format V27 (Upmixer centre OFF): widens the centre-mode enum with
/// OFF (2) - a surrounds-only mode that leaves L/R bit-exact.  No struct or
/// offset change; the bump exists only because version discipline is strict.
/// Wire format V26 (Upmixer presence): claims the WireUpmixParams reserved byte
/// at offset +3 for `presence_q1` (i8 = dB x 2), so the section and total size are
/// unchanged from V25.  Version discipline is strict - a V26 client's bulk image
/// must carry format_version 26.
/// Wire format V25 (Stereo Upmixer): appends a 44-byte WireUpmixParams section
/// at offset 5900 (byte-identical to UpmixConfigPacket), growing the flat layout
/// from 5900 to 5944 bytes.  Present on both platforms for layout uniformity;
/// zero on GET and ignored on SET on RP2040.
/// Wire format V24 (ADAT input): claims three previously-reserved bytes of
/// WireInputConfig for the ADAT input pin / enable / clock mode (all with the
/// 0 = "absent, keep live" convention), so the struct and total size are
/// unchanged from V23.
/// V23 (Psychoacoustic Bass): appends a 24-byte WirePsybassParams
/// section at offset 5876, growing the flat layout from 5876 to 5900 bytes.
/// V22 (Linkwitz Transform): each WireBandParams' 2 reserved bytes
/// (offset 2) now carry the LT target Q as `qp_x512` when type == 11, zero
/// otherwise.  Struct and payload sizes are unchanged from V21 - only the
/// reserved-byte meaning changed.  V21 (unified channel model): inputs are
/// first-class channels (PEQ + metering), outputs follow them.  V21 claims a
/// previously-reserved byte
/// inside WireInputConfig for `i2s_clock_mode` (0=master, 1=slave) without
/// changing the section or total size.  V20 repurposes WireCrossfeedParams'
/// reserved byte (BULK_CROSSFEED_OFFSET + 3) as the crossfeed output_pair_mask;
/// struct and payload sizes are unchanged.  V19 adds loudness_output_mask in the
/// global section's former reserved[2] bytes (offset 22), so struct and payload
/// sizes are unchanged from V18.  V18 grew WireLevellerConfig from 16 to 20 bytes
/// (appending the detector/apply channel masks), shifting every section after the
/// leveller by +4 and the flat layout from 5872 to 5876 bytes (RP2350).
/// Compatibility is intentionally broken - only this layout is accepted.
let WIRE_FORMAT_VERSION: Int            = 28
/// Full V28 bulk transfer size (RP2350; RP2040 zero-pads the same layout).
/// Unchanged since V25 - V26/V27/V28 all reuse bytes inside existing sections.
let BULK_PARAMS_SIZE: UInt16            = 5944
let WIRE_BULK_PARAMS_V19_SIZE: Int      = 5876

// --- V16 absolute section offsets (see 8-channel-usb-input spec §9) ---
let BULK_GLOBAL_OFFSET: Int             = 16
let BULK_CROSSFEED_OFFSET: Int          = 32
let BULK_DELAYS_OFFSET: Int             = 64    // float delay_ms[17]
let BULK_CROSSPOINT_OFFSET: Int         = 132   // crosspoints[8][9]
let BULK_OUTPUTS_OFFSET: Int            = 708   // WireOutputChannel[9]
let BULK_PINS_OFFSET: Int               = 816
let BULK_EQ_OFFSET: Int                 = 824   // eq[17][12]
let BULK_CHANNEL_NAMES_OFFSET: Int      = 4088  // names[17][32]
let BULK_I2S_OFFSET: Int                = 4632
/// Byte +8 within WireI2SConfig: clock_pin_mode_p1 (+1 encoded: 0=absent,
/// 1=unified, 2=split).  Claims a former reserved byte; wire version unchanged.
let BULK_I2S_CLOCK_PIN_MODE_OFFSET: Int = 4640
/// Byte +9 within WireI2SConfig: bck_pin_slave GPIO (0=absent; LRCLK = +1).
let BULK_I2S_BCK_PIN_SLAVE_OFFSET: Int  = 4641
let BULK_LEVELLER_OFFSET: Int           = 4648  // WireLevellerConfig, 20 bytes (V18: +detector/apply masks at +16/+17)
let BULK_PREAMP_OFFSET: Int             = 4668  // preamp_db[8]
let BULK_MASTER_VOLUME_OFFSET: Int      = 4700
let BULK_INPUT_CONFIG_OFFSET: Int       = 4716  // input_source, spdif_rx_pin, i2s_rx_pin, i2s_rate
/// Byte +12 within WireInputConfig: i2s_clock_mode (0=master, 1=slave; V21+).
/// Bytes +8/+9/+10 are the optional SPDIF 2/3/4 pins and +11 the enable mask
/// (V28 grew the pin array from 2 to 3, pushing everything below it down one).
let BULK_INPUT_I2S_CLOCK_MODE_OFFSET: Int = 4728
/// ADAT input (V24+), claimed from WireInputConfig reserved bytes +13/+14/+15.
/// All use the 0 = "absent, keep live" convention; enable/clock-mode are +1
/// encoded (0=absent, 1=disabled/master, 2=enabled/slave) and the pin is a raw
/// GPIO with 0 = unset (0xFF never appears on the wire).
let BULK_INPUT_ADAT_PIN_OFFSET: Int          = 4729
let BULK_INPUT_ADAT_ENABLED_P1_OFFSET: Int   = 4730
let BULK_INPUT_ADAT_CLOCK_MODE_P1_OFFSET: Int = 4731
let BULK_LG_OFFSET: Int                 = 4732
let BULK_USER_VOLUME_OFFSET: Int        = 4748  // user_volume_db, user_mute
let BULK_DAC_HW_MUTE_OFFSET: Int        = 4764
let BULK_CROSSOVER_OFFSET: Int          = 4780  // crossovers[17][4]
let BULK_ADAT_OFFSET: Int               = 5868  // WireAdatConfig (enabled, pin, reserved[6])
/// WirePsybassParams (V23): enabled+reserved, output_mask u16 (+2), then five
/// floats cutoff/harmonics/drive/character/original (+4/+8/+12/+16/+20).
let BULK_PSYBASS_OFFSET: Int            = 5876
/// WireUpmixParams: byte-identical to UpmixConfigPacket (spec §6.1) -
/// enabled/center_mode/surround_mode (+0..2), presence_q1 i8 (+3, V26+), then ten
/// f32 params (+4..+40).
let BULK_UPMIX_OFFSET: Int              = 5900

/// Bytes per WireCrosspoint (enabled, phase_invert, reserved[2], gain_db).
let WIRE_CROSSPOINT_SIZE: Int           = 8
/// Bytes per WireBandParams (matches firmware EqParamPacket layout).
let WIRE_BAND_PARAMS_SIZE: Int          = 16
/// Crossover bands per channel in the wire layout.
let WIRE_MAX_XOVER_BANDS: Int           = 4
/// Total channels in the V16 wire layout (inputs + outputs, RP2350 max).
let WIRE_MAX_CHANNELS: Int              = 17
/// Max matrix inputs (RP2350) and the stereo base count.
let MAX_MATRIX_INPUTS: Int              = 8
let BASE_MATRIX_INPUTS: Int             = 2

// Buffer statistics request codes
let REQ_GET_BUFFER_STATS: UInt8         = 0xB0
let REQ_RESET_BUFFER_STATS: UInt8       = 0xB1

// Volume Leveller request codes
let REQ_SET_LEVELLER: UInt8             = 0xB4
let REQ_GET_LEVELLER: UInt8             = 0xB5
let REQ_SET_LEVELLER_AMOUNT: UInt8      = 0xB6
let REQ_GET_LEVELLER_AMOUNT: UInt8      = 0xB7
let REQ_SET_LEVELLER_SPEED: UInt8       = 0xB8
let REQ_GET_LEVELLER_SPEED: UInt8       = 0xB9
let REQ_SET_LEVELLER_MAXGAIN: UInt8     = 0xBA
let REQ_GET_LEVELLER_MAXGAIN: UInt8     = 0xBB
let REQ_SET_LEVELLER_LOOKAHEAD: UInt8   = 0xBC
let REQ_GET_LEVELLER_LOOKAHEAD: UInt8   = 0xBD
let REQ_SET_LEVELLER_GATE: UInt8        = 0xBE
let REQ_GET_LEVELLER_GATE: UInt8        = 0xBF
// Channel masks (V18): 2 bytes [detector_mask, apply_mask], bit k = input channel k
let REQ_SET_LEVELLER_MASKS: UInt8       = 0xDE
let REQ_GET_LEVELLER_MASKS: UInt8       = 0xDF

// Per-channel preamp request codes
let REQ_SET_PREAMP_CH: UInt8           = 0xD0
let REQ_GET_PREAMP_CH: UInt8           = 0xD1

// Per-band bypass request codes (firmware 1.1.4+)
let REQ_SET_BAND_BYPASS: UInt8         = 0xD8
let REQ_GET_BAND_BYPASS: UInt8         = 0xD9

// User volume request codes — vendor-channel access to the same field
// the UAC1 host slider drives (audio_state.volume).  Applies regardless
// of input source so SPDIF/I2S playback honours user-perceived volume
// changes (and loudness compensation tracks them).
// Range: float dB, clamped to [-CENTER_VOLUME_INDEX, 0] = [-60, 0] dB.
let REQ_SET_USER_VOLUME: UInt8         = 0xDA
let REQ_GET_USER_VOLUME: UInt8         = 0xDB
let USER_VOLUME_MIN_DB: Float          = -60.0
let USER_VOLUME_MAX_DB: Float          = 0.0

// Master volume request codes
let REQ_SET_MASTER_VOLUME: UInt8         = 0xD2
let REQ_GET_MASTER_VOLUME: UInt8         = 0xD3
let REQ_SET_MASTER_VOLUME_MODE: UInt8    = 0xD4
let REQ_GET_MASTER_VOLUME_MODE: UInt8    = 0xD5
let REQ_SAVE_MASTER_VOLUME: UInt8        = 0xD6
let REQ_GET_SAVED_MASTER_VOLUME: UInt8   = 0xD7

// Master volume persistence modes (payload of 0xD4 / response of 0xD5)
let MASTER_VOLUME_MODE_INDEPENDENT: Int  = 0   // Saved in directory, applied at boot, untouched by presets
let MASTER_VOLUME_MODE_WITH_PRESET: Int  = 1   // Saved with each preset, restored on preset load

// Input source switching request codes
let REQ_SET_INPUT_SOURCE: UInt8       = 0xE0
let REQ_GET_INPUT_SOURCE: UInt8       = 0xE1
let REQ_GET_SPDIF_RX_STATUS: UInt8    = 0xE2
let REQ_GET_SPDIF_RX_CH_STATUS: UInt8 = 0xE3
// REQ_SET/GET_SPDIF_RX_PIN are indexed since firmware v1.1.5: wValue high byte
// selects the S/PDIF input (0..2), low byte is the GPIO.  A bare pin in wValue
// (high byte 0) still addresses input 1, so older callers keep working.  The
// SET is hot-swappable while the input is active (no OUTPUT_ACTIVE rejection).
let REQ_SET_SPDIF_RX_PIN: UInt8       = 0xE4
let REQ_GET_SPDIF_RX_PIN: UInt8       = 0xE5
// Multiple-S/PDIF-input commands (firmware v1.1.5+).  STALL on older firmware,
// which the app treats as "single S/PDIF input only".
let REQ_SET_SPDIF_INPUT_ENABLE: UInt8 = 0xE9   // IN: wValue = (index<<8)|enable, returns status
// IN, 2 + count bytes: count, enable_mask, then one GPIO per input.  Firmware
// that predates the fourth input answers with 5 bytes rather than 6, so read
// the count and treat the pin list as short rather than assuming a fixed size.
let REQ_GET_SPDIF_INPUT_CONFIG: UInt8 = 0xEF

// Input source enum values (payload of 0xE0 / response of 0xE1, and
// WireInputConfig byte 0).  Value 3 is the 8-channel ADAT input (RP2350 only);
// values 4/5/6 are the three optional S/PDIF inputs.
let INPUT_SOURCE_USB: Int    = 0
let INPUT_SOURCE_SPDIF: Int  = 1
let INPUT_SOURCE_I2S: Int    = 2
let INPUT_SOURCE_ADAT: Int   = 3
let INPUT_SOURCE_SPDIF2: Int = 4
let INPUT_SOURCE_SPDIF3: Int = 5
let INPUT_SOURCE_SPDIF4: Int = 6

// S/PDIF input inventory: input 1 is always present; inputs 2/3/4 are optional
// and disabled by default.  Default RX GPIOs are 5 / 20 / 21 / 22.  This is the
// count the app is built for; the live count comes from the device (0xEF byte 0)
// so a three-input firmware still drives the UI correctly.
let SPDIF_RX_NUM_INPUTS: Int         = 4
let SPDIF_RX_PIN_DEFAULTS: [UInt8]   = [5, 20, 21, 22]

// I2S input request codes (firmware wire format V12+).  See
// Documentation/Features/i2s_input_spec.md.  The SET pin command is an
// IN-direction transfer carrying the pin in wValue and returning a
// PIN_CONFIG_* status byte (same shape as REQ_SET_SPDIF_RX_PIN).
let REQ_SET_INPUT_RATE: UInt8         = 0xED   // OUT 4 bytes: uint32 LE Hz
let REQ_GET_INPUT_RATE: UInt8         = 0xEE   // IN 8 bytes: {current_hz, selected_i2s_hz}
let REQ_SET_I2S_RX_PIN: UInt8         = 0xF1   // IN: wValue = (pair<<8)|gpio, returns status
let REQ_GET_I2S_RX_PIN: UInt8         = 0xF2   // IN 1 byte: wValue = pair (0..3), returns that pair's pin
let REQ_SET_I2S_INPUT_CHANNELS: UInt8 = 0xF3   // IN: wValue = count 2/4/6/8, returns status
let REQ_GET_I2S_INPUT_CHANNELS: UInt8 = 0xF4   // IN 1 byte: active I2S input channel count

// I2S input defaults and rate table.  The wire/preset encoding stores the
// rate as an enum (0/1/2); vendor SET/GET commands use Hz.
let I2S_RX_PIN_DEFAULT: UInt8         = 4
/// Default I2S RX data GPIO per stereo pair (0..3).  Pairs 1..3 are placeholders
/// that must be wired to the user's ADC(s); pair 0 matches I2S_RX_PIN_DEFAULT.
let I2S_RX_PIN_DEFAULTS: [UInt8]      = [4, 16, 17, 18]
/// Max I2S stereo pairs / channels per platform (RP2350 = 4 pairs / 8 ch).
let I2S_RX_MAX_PAIRS_RP2350: Int      = 4
let I2S_INPUT_RATES_HZ: [UInt32]      = [44100, 48000, 96000]

/// Map the wire rate enum (0/1/2) to Hz; out-of-range falls back to 48 kHz.
func i2sRateEnumToHz(_ raw: UInt8) -> UInt32 {
    Int(raw) < I2S_INPUT_RATES_HZ.count ? I2S_INPUT_RATES_HZ[Int(raw)] : 48000
}

/// Map Hz to the wire rate enum (0/1/2); unknown rates fall back to 48 kHz (1).
func i2sRateHzToEnum(_ hz: UInt32) -> UInt8 {
    UInt8(I2S_INPUT_RATES_HZ.firstIndex(of: hz) ?? 1)
}

// I2S clock-slave input mode (firmware wire format V18+).  See
// Documentation/Features/i2s_slave_input_spec.md.  In SLAVE mode an external
// master drives BCK/LRCLK (DSPi's clock pins become inputs) and the rate is
// auto-detected; in MASTER mode (default) DSPi drives the clocks and the app
// picks the rate.  The mode is only meaningful while the input source is I2S.
let REQ_SET_I2S_CLOCK_MODE: UInt8   = 0x88   // OUT 1 byte: 0=master, 1=slave (deferred apply)
let REQ_GET_I2S_CLOCK_MODE: UInt8   = 0x89   // IN 1 byte: live mode (0/1)
let REQ_GET_I2S_SLAVE_STATUS: UInt8 = 0x8A   // IN 16 bytes: I2sSlaveStatusPacket

let I2S_CLOCK_MODE_MASTER: UInt8    = 0
let I2S_CLOCK_MODE_SLAVE: UInt8     = 1

// I2S clock-pin mode (firmware clock_pins_spec.md).  UNIFIED (default, legacy)
// shares one BCK/LRCLK pair for both master and slave clocking; SPLIT routes
// the slave role to its own pair (`i2sBckPinSlave`), so a board can wire both
// roles to separate connectors.  The slave pair is dormant (constrains nothing)
// in UNIFIED mode; in SPLIT both pairs are reserved.  Set/read via 0xFE/0xFF;
// the slave pair GPIO is set/read via REQ_SET/GET_I2S_BCK_PIN with role 1.
let REQ_SET_I2S_CLOCK_PIN_MODE: UInt8 = 0xFE  // IN 1 byte: wValue 0=unified/1=split, returns PIN_CONFIG_*
let REQ_GET_I2S_CLOCK_PIN_MODE: UInt8 = 0xFF  // IN 1 byte: live mode (0/1)

let I2S_CLOCK_PIN_MODE_UNIFIED: UInt8 = 0
let I2S_CLOCK_PIN_MODE_SPLIT: UInt8   = 1

// DAC hardware-mute request codes (firmware V10+ wire format).  SET takes
// a 16-byte DacHwMuteConfig OUT payload; GET returns 16 bytes; TEST is a
// fire-and-forget command that asserts mute for ~1 s.  See
// `dac_hardware_mute_spec.md`.
let REQ_SET_DAC_HW_MUTE_CONFIG: UInt8 = 0xEA
let REQ_GET_DAC_HW_MUTE_CONFIG: UInt8 = 0xEB
let REQ_TEST_DAC_HW_MUTE: UInt8       = 0xEC

let DAC_HW_MUTE_PIN_NONE: UInt8       = 0xFF
let DAC_HW_MUTE_HOLD_MIN_MS: UInt16   = 1
let DAC_HW_MUTE_HOLD_MAX_MS: UInt16   = 500
let DAC_HW_MUTE_RELEASE_MIN_MS: UInt16 = 0
let DAC_HW_MUTE_RELEASE_MAX_MS: UInt16 = 500

// LG Sound Sync request codes (firmware V8+ wire format)
// SET payload: 1 byte (0=off, anything else=on).
// GET_ENABLE returns: 1 byte.
// GET_STATUS returns: 16-byte LgSoundSyncStatus (enabled, present,
// volume 0..100 / 0xFF, muted, 12 reserved).
let REQ_SET_LG_SOUND_SYNC_ENABLE: UInt8 = 0xE6
let REQ_GET_LG_SOUND_SYNC_ENABLE: UInt8 = 0xE7
let REQ_GET_LG_SOUND_SYNC_STATUS: UInt8 = 0xE8

// Note: REQ_SET_SPDIF_RX_PIN (0xE4) reuses PIN_CONFIG_* status codes (0x00-0x04)

// External control interface request codes (UART / I2C target).  See
// Documentation/Features/control_interfaces_spec.md.  The two SET-config
// commands are USB-only (rejected over UART/I2C); the GET-config and status
// readbacks are available on every transport.  SET is an OUT transfer carrying
// the 8-byte config; its PIN_CONFIG_* outcome is read back via the last-status
// bytes of REQ_GET_CTRL_IFACE_STATUS (0xF9).
let REQ_SET_UART_CONFIG: UInt8         = 0xF5   // OUT 8 bytes: UartCtrlConfig (USB only)
let REQ_GET_UART_CONFIG: UInt8         = 0xF6   // IN 8 bytes: live UartCtrlConfig
let REQ_SET_I2C_CONFIG: UInt8          = 0xF7   // OUT 8 bytes: I2cCtrlConfig (USB only)
let REQ_GET_I2C_CONFIG: UInt8          = 0xF8   // IN 8 bytes: live I2cCtrlConfig
let REQ_GET_CTRL_IFACE_STATUS: UInt8   = 0xF9   // IN 8 bytes: CtrlIfaceStatus

// Control-interface defaults (control_interfaces_spec.md §2.2).  Both ship
// disabled; these are the pin/baud/address values a fresh flash populates.
let UART_CTRL_TX_PIN_DEFAULT: UInt8    = 16
let UART_CTRL_RX_PIN_DEFAULT: UInt8    = 17
let UART_CTRL_BAUD_DEFAULT: UInt32     = 115200
let UART_CTRL_BAUD_MIN: UInt32         = 9600
let UART_CTRL_BAUD_MAX: UInt32         = 1000000
let I2C_CTRL_SDA_PIN_DEFAULT: UInt8    = 18
let I2C_CTRL_SCL_PIN_DEFAULT: UInt8    = 19
let I2C_CTRL_ADDR_DEFAULT: UInt8       = 0x42
let I2C_CTRL_ADDR_MIN: UInt8           = 0x08
let I2C_CTRL_ADDR_MAX: UInt8           = 0x77
/// Current external wire-protocol version (CtrlIfaceStatus.proto_version).
let CTRL_IFACE_PROTO_VERSION: UInt8    = 1
/// A curated set of common UART baud rates to offer in the picker (all within
/// the 9600..1000000 range the firmware accepts).
let UART_CTRL_BAUD_CHOICES: [UInt32]   = [9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600, 1000000]

// Change-notification source tags for control commands arriving over the
// external transports (control_interfaces_spec.md §2.5).  Mirrors PARAM_SRC_*
// used by the notification endpoint.
let PARAM_SRC_UART: UInt8              = 8
let PARAM_SRC_I2C: UInt8               = 9

// Control Surfaces (user-wired physical controls and indicators).  See
// Documentation/Features/control_surfaces_spec.md.  Buttons, toggle switches,
// potentiometers, rotary encoders, and indicator LEDs on spare GPIOs, each
// bound to one firmware parameter.  Config is device-global (stored in the
// preset directory, survives factory reset), configured over USB.  SET is
// deferred: the outcome is polled back via REQ_GET_CS_STATUS.

// Change-notification source tag for parameter changes a physical control
// makes (spec §7.3); mirrors the firmware ParamSource enum.
let PARAM_SRC_GPIO: UInt8              = 5

// Request codes (0x84-0x87, 0x8B-0x8F, 0x9D-0x9E).  Capability format version 6
// (spec §"Wire reference" / §11): v2 grew the binding 16 -> 24 bytes, the
// noun descriptor 8 -> 12, added per-slot names; v3 adds the IR remote receiver
// component with a learned-command table, and the Apply/Save/Revert preview
// model.  The caps header is 40 bytes (8 types + max_ir_commands tail).  v4
// changes no structure: it adds nouns 35-48 (stereo upmixer, psychoacoustic
// bass, per-output delay, preset reload) and the CS_UNIT_MS unit.  v5 is
// enum-only (UPMIX_CENTER_MODE gains Off = 2).  v6 raises the IR command table
// 8 -> 16 sub-slots, which widens the status packet 32 -> 41 bytes (see
// CsStatusPacket); the caps header is unchanged but max_ir_commands reads 16.
let REQ_SET_CS_BINDING: UInt8 = 0x84   // OUT 24 bytes: CsBinding, wValue = slot (0-15); live-only preview
let REQ_GET_CS_BINDING: UInt8 = 0x85   // IN 24 bytes: live CsBinding, wValue = slot
let REQ_GET_CS_CAPS: UInt8    = 0x86   // IN: wValue=0xFFFF -> 40-byte header+types; wValue=noun -> 12-byte CsNounDesc
let REQ_GET_CS_STATUS: UInt8  = 0x87   // IN CS_STATUS_LEN bytes: CsStatusPacket
let REQ_SET_CS_NAME: UInt8    = 0x8B   // OUT 1-32 byte name, wValue = slot; deferred, persists immediately
let REQ_GET_CS_NAME: UInt8    = 0x8C   // IN 32-byte NUL-terminated name, wValue = slot
let REQ_SET_CS_IR_CMD: UInt8  = 0x8D   // OUT 16 bytes: IrCommand, wValue = sub-slot (0-15); live-only preview
let REQ_GET_CS_IR_CMD: UInt8  = 0x8E   // IN 16 bytes: live IrCommand, wValue = sub-slot
let REQ_CS_IR_LEARN: UInt8    = 0x8F   // IN: wValue 1=arm/0=cancel -> 1 ack byte; wValue 2=read -> 8-byte result
let REQ_CS_SAVE: UInt8        = 0x9D   // IN 1 ack byte: persist the whole live config (deferred, lastSlot=0xFF)
let REQ_CS_REVERT: UInt8      = 0x9E   // IN 1 ack byte: discard the preview, reload flash (deferred, lastSlot=0xFF)

// Status codes (0x10+).  0x00-0x05 reuse the shared PIN_CONFIG_* namespace
// above; these extend it.  Returned in CsStatusPacket.lastStatus / slotStatus[].
let CS_STATUS_INVALID_SLOT: UInt8    = 0x10   // slot index >= 16 (IR sub-slot >= 16)
let CS_STATUS_INVALID_TYPE: UInt8    = 0x11   // type >= CS_TYPE_COUNT
let CS_STATUS_INVALID_NOUN: UInt8    = 0x12   // noun >= CS_NOUN_COUNT
let CS_STATUS_INVALID_ACTION: UInt8  = 0x13   // action not allowed for this type+noun (incl. platform-disabled noun)
let CS_STATUS_INVALID_VALUE: UInt8   = 0x14   // value/step/range out of bounds, unknown flags, misused ACCEL/REPEAT, non-zero reserved
let CS_STATUS_PIN_NOT_ADC: UInt8     = 0x15   // a pot on a non-ADC GPIO
let CS_STATUS_PENDING: UInt8         = 0x16   // SET accepted, main-loop apply not yet run (poll again)
let CS_STATUS_INVALID_TARGET: UInt8  = 0x17   // target/index out of range for the noun (or non-zero on untargeted)
let CS_STATUS_INVALID_EVENT: UInt8   = 0x18   // bad event, event on a non-button, or MOMENTARY/REPEAT on a non-press event
let CS_STATUS_PWM_CONFLICT: UInt8    = 0x19   // PWM LED collides with another on the same slice+channel
let CS_STATUS_EVENT_IN_USE: UInt8    = 0x1A   // another button binding already has this GPIO+event pair
let CS_STATUS_BUSY: UInt8            = 0x1B   // SET dropped; a previous SET (or save/revert) of the same kind is still queued
let CS_STATUS_FLASH_ERROR: UInt8     = 0x1C   // the directory persist failed (name SET or REQ_CS_SAVE)
let CS_STATUS_IR_IN_USE: UInt8       = 0x1D   // another slot already holds the IR component (one receiver per device)
let CS_STATUS_NO_IR: UInt8           = 0x1E   // learn was armed with no live CS_TYPE_IR binding

// Limits / sentinels (spec §2).
let CS_MAX_BINDINGS: Int       = 16
let CS_MAX_IR_COMMANDS: Int    = 16   // IR command sub-slots per device, caps v6 (spec §2.4)
let CS_NAME_LEN: Int           = 32   // per-slot name buffer, NUL-terminated (spec §3.4)
let CS_GPIO_UNUSED: UInt8      = 0xFF
let CS_CONFIG_VERSION: UInt8   = 2    // CsFlashConfig.version (binding table); caps format is v6
let CS_IR_CONFIG_VERSION: UInt8 = 2   // CsIrConfig.version (IR command table; v2 = 16 sub-slots)
/// REQ_GET_CS_STATUS response length: 41 bytes since caps v6 (16 IR sub-slots).
/// Older firmware short-reads it (32 bytes for caps v3-v5, 22 pre-v3) and
/// CsStatusPacket parses whichever of the three layouts comes back.
let CS_STATUS_LEN: UInt16      = 41
let CS_CAPS_ALL: UInt16        = 0xFFFF   // wValue selecting the caps header + type table
/// `lastSlot` sentinel for a save/revert outcome (spec §2.6).
let CS_LAST_SLOT_SAVE: UInt8   = 0xFF
/// `lastSlot` high bit marks an IR sub-slot outcome: 0x80 | sub-slot.
let CS_LAST_SLOT_IR_FLAG: UInt8 = 0x80
/// ADC-capable GPIOs (ADC0..2 on both platforms) - the only pins a
/// potentiometer may occupy.  GPIO 29 (VSYS/3 monitor) is excluded.
let CS_ADC_PINS: [UInt8]      = [26, 27, 28]

// CsType (component wired up).  Append-only; index into the caps type table.
let CS_TYPE_NONE: Int     = 0
let CS_TYPE_BUTTON: Int   = 1
let CS_TYPE_SWITCH: Int   = 2
let CS_TYPE_POT: Int      = 3
let CS_TYPE_ENCODER: Int  = 4
let CS_TYPE_LED: Int      = 5
let CS_TYPE_LED_PWM: Int  = 6   // hardware-PWM-dimmed LED (IND_LEVEL meter)
let CS_TYPE_IR: Int       = 7   // IR remote receiver (container: one pin + learned command sub-slots)

// CsNoun (firmware parameter driven or shown).  Append-only (v2 = 35 nouns,
// v4 = 49); the app reads the live count and per-noun descriptors from the
// caps, so these are only used by the display-label helpers.
let CS_NOUN_USER_VOLUME: Int       = 0
let CS_NOUN_MASTER_VOLUME: Int     = 1
let CS_NOUN_USER_MUTE: Int         = 2
let CS_NOUN_LOUDNESS: Int          = 3
let CS_NOUN_CROSSFEED: Int         = 4
let CS_NOUN_LEVELLER: Int          = 5
let CS_NOUN_PRESET: Int            = 6
let CS_NOUN_INPUT_SOURCE: Int      = 7
let CS_NOUN_CLIP: Int              = 8
let CS_NOUN_EQ_BYPASS: Int         = 9
let CS_NOUN_LG_SYNC: Int           = 10
let CS_NOUN_CROSSFEED_PRESET: Int  = 11
let CS_NOUN_CROSSFEED_ITD: Int     = 12
let CS_NOUN_LEVELLER_AMOUNT: Int   = 13
let CS_NOUN_LEVELLER_SPEED: Int    = 14
let CS_NOUN_LEVELLER_LOOKAHEAD: Int = 15
let CS_NOUN_PREAMP: Int            = 16
let CS_NOUN_OUTPUT_GAIN: Int       = 17
let CS_NOUN_OUTPUT_MUTE: Int       = 18
let CS_NOUN_OUTPUT_ENABLE: Int     = 19
let CS_NOUN_FILTER_FREQ: Int       = 20
let CS_NOUN_FILTER_GAIN: Int       = 21
let CS_NOUN_FILTER_Q: Int          = 22
let CS_NOUN_FILTER_TYPE: Int       = 23
let CS_NOUN_FILTER_BYPASS: Int     = 24
let CS_NOUN_SIGGEN: Int            = 25
let CS_NOUN_DAC_MUTE_TEST: Int     = 26
let CS_NOUN_CLIP_CH: Int           = 27
let CS_NOUN_LEVEL: Int             = 28
let CS_NOUN_SPDIF_LOCK: Int        = 29
let CS_NOUN_SAMPLE_RATE: Int       = 30
let CS_NOUN_USB_STREAMING: Int     = 31
let CS_NOUN_ADAT_ACTIVE: Int       = 32
let CS_NOUN_LG_PRESENT: Int        = 33
let CS_NOUN_LG_MUTED: Int          = 34
// Caps v4 additions (spec §11.1).  The six upmixer nouns are RP2350-only: on
// RP2040 their descriptor action masks read 0, like ADAT_ACTIVE.
let CS_NOUN_UPMIX: Int             = 35
let CS_NOUN_UPMIX_CENTER_MODE: Int = 36
let CS_NOUN_UPMIX_SURROUND_MODE: Int = 37
let CS_NOUN_UPMIX_STRENGTH: Int    = 38
let CS_NOUN_UPMIX_WIDTH: Int       = 39
let CS_NOUN_UPMIX_PRESENCE: Int    = 40
let CS_NOUN_PSYBASS: Int           = 41
let CS_NOUN_PSYBASS_CUTOFF: Int    = 42
let CS_NOUN_PSYBASS_HARMONICS: Int = 43
let CS_NOUN_PSYBASS_DRIVE: Int     = 44
let CS_NOUN_PSYBASS_CHARACTER: Int = 45
let CS_NOUN_PSYBASS_ORIGINAL: Int  = 46
let CS_NOUN_OUTPUT_DELAY: Int      = 47
let CS_NOUN_PRESET_RELOAD: Int     = 48

// CsAction (operation applied).  Action bit position in the caps masks is
// (1 << action); CS_ACT_BIT(a) below builds that mask.
let CS_ACT_ADJUST: Int     = 0   // pot: absolute position maps onto a value range
let CS_ACT_STEP: Int       = 1   // encoder: +/- step per detent (enum: next/prev)
let CS_ACT_INC: Int        = 2   // button: + step per press (enum: next)
let CS_ACT_DEC: Int        = 3   // button: - step per press (enum: previous)
let CS_ACT_TOGGLE: Int     = 4   // button: invert a bool per press
let CS_ACT_SET: Int        = 5   // button: set the noun to `value` per press
let CS_ACT_FOLLOW: Int     = 6   // switch: bool tracks the switch position
let CS_ACT_TRIGGER: Int    = 7   // button: fire the noun's command (e.g. clip clear)
let CS_ACT_IND_EQUALS: Int = 8   // LED: lit while noun value == `value`
let CS_ACT_MOMENTARY: Int  = 9   // button (press): set to `value` while held, restore on release
let CS_ACT_IND_ABOVE: Int  = 10  // LED: lit while a continuous noun value >= `value`
let CS_ACT_IND_LEVEL: Int  = 11  // PWM LED: brightness follows the noun across its range

/// Action-bit mask helper: `CS_ACT_BIT(CS_ACT_STEP)` == 0x0002.
func CS_ACT_BIT(_ action: Int) -> UInt16 { UInt16(1) << UInt16(action) }

// CsBinding.flags bitfield (spec §2.2.1 / §6).
let CS_FLAG_INVERT: UInt8  = 0x01   // input active-high w/ pull-down; LED active-low
let CS_FLAG_REVERSE: UInt8 = 0x02   // pot / encoder: invert direction
let CS_FLAG_WRAP: UInt8    = 0x04   // enum STEP/INC/DEC wraps around the ends
let CS_FLAG_ACCEL: UInt8   = 0x08   // encoder only: fast rotation multiplies the step
let CS_FLAG_REPEAT: UInt8  = 0x10   // button INC/DEC on the press event: auto-repeat while held

// CsBinding.event (buttons only; MUST be 0 for other types).  Spec §6.1.
let CS_EVENT_PRESS: UInt8  = 0   // short press
let CS_EVENT_LONG: UInt8   = 1   // held >= 500 ms
let CS_EVENT_DOUBLE: UInt8 = 2   // two taps within 350 ms

// CsNounDesc.kind values.
let CS_KIND_CONTINUOUS: UInt8 = 0   // numeric value, unit-encoded on the wire (see CS_UNIT_*)
let CS_KIND_BOOL: UInt8       = 1
let CS_KIND_ENUM: UInt8       = 2

// CsNounDesc.unit values (spec §2.1).  Fixes the wire encoding of
// value/range/step and the stepping law.
let CS_UNIT_NONE: UInt8    = 0   // plain integer (bool 0/1, enum 0..N-1)
let CS_UNIT_DB: UInt8      = 1   // signed 8.8 dB (1 dB = 256), linear stepping
let CS_UNIT_HZ: UInt8      = 2   // plain integer Hz, logarithmic stepping (step = 8.8 octaves)
let CS_UNIT_Q: UInt8       = 3   // 8.8 Q (0.707 = 181), logarithmic stepping (step = 8.8 octaves)
let CS_UNIT_PERCENT: UInt8 = 4   // 8.8 percent (1 % = 256), linear stepping
let CS_UNIT_MS: UInt8      = 5   // 8.8 milliseconds (1 ms = 256), linear stepping; default step 0.1 ms

/// The firmware's default step for a unit when `CsBinding.step` is 0 (spec
/// §2.1): one unit for the linear units, 1/12 octave for the log units, and
/// 0.1 ms for delay (whole-ms detents are too coarse for alignment).
func csDefaultStep(_ unit: UInt8) -> Float {
    switch unit {
    case CS_UNIT_HZ, CS_UNIT_Q: return 1.0 / 12.0
    case CS_UNIT_MS:            return 0.1
    default:                    return 1.0
    }
}

/// True when a unit steps multiplicatively (its `step` operand is in octaves).
func csUnitIsLog(_ unit: UInt8) -> Bool {
    unit == CS_UNIT_HZ || unit == CS_UNIT_Q
}

// CsNounDesc.target_kind values (spec §4.4).
let CS_TARGET_NONE: UInt8      = 0
let CS_TARGET_INPUT_CH: UInt8  = 1   // target = input channel 0..N-1
let CS_TARGET_OUTPUT_CH: UInt8 = 2   // target = output channel 0..N-1
let CS_TARGET_DSP_CH: UInt8    = 3   // target = DSP channel (inputs first, then outputs)
let CS_TARGET_DSP_BAND: UInt8  = 4   // target = DSP channel, index = filter band

// CsNounDesc.dflags bitfield.
let CS_NDF_DEFERRED: UInt8 = 0x01   // apply is deferred; the engine steps from a target shadow

// CsTypeDesc.pin_class values.
let CS_PINCLASS_ANY: UInt8 = 0
let CS_PINCLASS_ADC: UInt8 = 1      // GPIO 26..28

// IrCommand.protocol values (spec §2.7).  The host treats protocol+code as an
// opaque learned pair; the names are for display/diagnostics only.
let CS_IR_PROTO_NONE: UInt8 = 0     // empty sub-slot
let CS_IR_PROTO_NEC: UInt8  = 1
let CS_IR_PROTO_RC5: UInt8  = 2
let CS_IR_PROTO_RC6: UInt8  = 3
let CS_IR_PROTO_HASH: UInt8 = 4     // timing-signature hash (any undecoded remote)

// REQ_CS_IR_LEARN wValue actions (spec §3.6.1).
let CS_IR_LEARN_CANCEL: UInt16 = 0
let CS_IR_LEARN_ARM: UInt16    = 1
let CS_IR_LEARN_READ: UInt16   = 2

// CsStatusPacket.ir_learn_state / learn-result state values (spec §2.6 / §3.6.1).
let CS_IR_LEARN_STATE_IDLE: UInt8    = 0
let CS_IR_LEARN_STATE_ARMED: UInt8   = 1   // listening on the receiver
let CS_IR_LEARN_STATE_DONE: UInt8    = 2   // a code was captured
let CS_IR_LEARN_STATE_TIMEOUT: UInt8 = 3   // 10 s elapsed with no clean decode

/// Short display name for an IR protocol (spec §2.7).
func csIrProtocolName(_ proto: UInt8) -> String {
    switch proto {
    case CS_IR_PROTO_NEC:  return "NEC"
    case CS_IR_PROTO_RC5:  return "RC5"
    case CS_IR_PROTO_RC6:  return "RC6"
    case CS_IR_PROTO_HASH: return "Generic"
    default:               return "None"
    }
}

/// Continuous (dB) operands are signed 8.8 fixed point: 1.0 dB = 256.
func csDbToQ8(_ db: Float) -> Int16 {
    let v = (db * 256.0).rounded()
    return Int16(max(Float(Int16.min), min(Float(Int16.max), v)))
}
/// Inverse of `csDbToQ8`.
func csQ8ToDb(_ q8: Int16) -> Float { Float(q8) / 256.0 }

/// Clamp a rounded float to the Int16 range.
private func csClampInt16(_ v: Float) -> Int16 {
    Int16(max(Float(Int16.min), min(Float(Int16.max), v.rounded())))
}

/// True when a unit encodes value/range as 8.8 fixed point (dB, Q, percent,
/// ms); false for the plain-integer units (none, Hz).
func csUnitIsFixedPoint(_ unit: UInt8) -> Bool {
    unit == CS_UNIT_DB || unit == CS_UNIT_Q || unit == CS_UNIT_PERCENT || unit == CS_UNIT_MS
}

/// Encode a natural-unit value (dB / Hz / Q / percent / plain) to the wire
/// int16 per the noun's unit (spec §2.1).
func csEncodeValue(_ v: Float, unit: UInt8) -> Int16 {
    csClampInt16(csUnitIsFixedPoint(unit) ? v * 256.0 : v)
}
/// Inverse of `csEncodeValue`.
func csDecodeValue(_ q: Int16, unit: UInt8) -> Float {
    csUnitIsFixedPoint(unit) ? Float(q) / 256.0 : Float(q)
}

/// Encode a step operand.  Continuous units carry the step as 8.8 (dB / octaves
/// / percent); the enum/plain unit carries a plain position count.
func csEncodeStep(_ v: Float, unit: UInt8) -> Int16 {
    csClampInt16(unit == CS_UNIT_NONE ? v : v * 256.0)
}
/// Inverse of `csEncodeStep`.
func csDecodeStep(_ q: Int16, unit: UInt8) -> Float {
    unit == CS_UNIT_NONE ? Float(q) : Float(q) / 256.0
}

/// Short symbol for a unit, for value/range field labels.
func csUnitSymbol(_ unit: UInt8) -> String {
    switch unit {
    case CS_UNIT_DB:      return "dB"
    case CS_UNIT_HZ:      return "Hz"
    case CS_UNIT_Q:       return "Q"
    case CS_UNIT_PERCENT: return "%"
    case CS_UNIT_MS:      return "ms"
    default:              return ""
    }
}

// Test signal generator ("siggen") request codes (0xA4-0xA8; 0xA9-0xAF
// reserved).  See Documentation/Features/test_signals_spec.md.  Transient
// only: never persisted, stopped by preset load / factory reset.  SET_CONFIG
// is an OUT transfer carrying the 36-byte SiggenConfig (never auto-starts;
// restarts with a fade if already running); CONTROL is write-as-read (an IN
// transfer carrying the action in wValue, returning 1 status byte).
let REQ_SIGGEN_SET_CONFIG: UInt8 = 0xA4   // OUT 36 bytes: SiggenConfig
let REQ_SIGGEN_GET_CONFIG: UInt8 = 0xA5   // IN 36 bytes: applied SiggenConfig
let REQ_SIGGEN_CONTROL: UInt8    = 0xA6   // IN 1 byte: wValue = SIGGEN_CTL_*
let REQ_SIGGEN_GET_STATUS: UInt8 = 0xA7   // IN 16 bytes: SiggenStatus
let REQ_SIGGEN_GET_CAPS: UInt8   = 0xA8   // IN: wValue=0xFFFF header, else SiggenTypeDesc

let SIGGEN_CFG_VERSION: UInt8 = 1
let SIGGEN_CAPS_HEADER: UInt16 = 0xFFFF   // wValue selecting the caps header

// SiggenConfig.flags bitmask (spec §5).
let SIGGEN_FLAG_RAW: UInt8    = 0x01   // bypass per-channel crossover + PEQ
let SIGGEN_FLAG_DECORR: UInt8 = 0x02   // independent noise per channel (WHITE/PINK)
let SIGGEN_FLAG_WALK: UInt8   = 0x04   // play masked channels one at a time

// REQ_SIGGEN_CONTROL actions (wValue).
let SIGGEN_CTL_STOP: UInt16     = 0    // fade out, then idle
let SIGGEN_CTL_START: UInt16    = 1    // (re)start with the applied config
let SIGGEN_CTL_STOP_NOW: UInt16 = 2    // immediate hard stop, no fade

// SiggenStatus.state / NOTIFY_EVT_SIGGEN_STATE state byte.
let SIGGEN_STATE_IDLE: UInt8     = 0
let SIGGEN_STATE_FADE_IN: UInt8  = 1
let SIGGEN_STATE_RUN: UInt8      = 2
let SIGGEN_STATE_GAP: UInt8      = 3
let SIGGEN_STATE_FADE_OUT: UInt8 = 4

// SiggenStatus.stopReason / notification reason byte.
let SIGGEN_STOP_NONE: UInt8      = 0
let SIGGEN_STOP_HOST: UInt8      = 1
let SIGGEN_STOP_COMPLETED: UInt8 = 2
let SIGGEN_STOP_PRESET: UInt8    = 3
let SIGGEN_STOP_RECONFIG: UInt8  = 4

// SiggenTypeDesc.timingModel (spec §6): how duration/repeat/gap are read.
let SIGGEN_TIMING_CONTINUOUS: UInt8 = 0
let SIGGEN_TIMING_SWEEP: UInt8      = 1
let SIGGEN_TIMING_PATTERN: UInt8    = 2

// SiggenParamDesc.semantic: what each of p1..p4 means for a type.
let SIGGEN_PARAM_UNUSED: UInt8  = 0
let SIGGEN_PARAM_FREQ_HZ: UInt8 = 1
let SIGGEN_PARAM_MS: UInt8      = 2
let SIGGEN_PARAM_CYCLES: UInt8  = 3
let SIGGEN_PARAM_COUNT: UInt8   = 4
let SIGGEN_PARAM_RATIO: UInt8   = 5
let SIGGEN_PARAM_PATTERN: UInt8 = 6

// SiggenType ids (spec §2).  The catalogue is device-served via GET_CAPS;
// these ids are only used for type-specific UI (labels, glyphs, presets).
let SIGGEN_SINE: UInt8       = 0
let SIGGEN_SQUARE: UInt8     = 1
let SIGGEN_WHITE: UInt8      = 2
let SIGGEN_PINK: UInt8       = 3
let SIGGEN_SWEEP_LOG: UInt8  = 4
let SIGGEN_SWEEP_LIN: UInt8  = 5
let SIGGEN_SWEEP_STEP: UInt8 = 6
let SIGGEN_IMPULSE: UInt8    = 7
let SIGGEN_CLICKS_ALT: UInt8 = 8
let SIGGEN_POLARITY: UInt8   = 9
let SIGGEN_TONE_BURST: UInt8 = 10
let SIGGEN_TONE_PAIR: UInt8  = 11
let SIGGEN_MULTITONE: UInt8  = 12
let SIGGEN_ISP: UInt8        = 13
let SIGGEN_CHANNEL_ID: UInt8 = 14

let SIGGEN_LEVEL_MIN_DB: Float = -120.0
let SIGGEN_LEVEL_MAX_DB: Float = 0.0

// Firmware update request codes
let REQ_ENTER_BOOTLOADER: UInt8        = 0xF0

// Preset status codes
let PRESET_OK: UInt8                    = 0x00
let PRESET_ERR_INVALID_SLOT: UInt8      = 0x01
let PRESET_ERR_SLOT_EMPTY: UInt8        = 0x02  // reserved
let PRESET_ERR_CRC: UInt8               = 0x03
let PRESET_ERR_FLASH_WRITE: UInt8       = 0x04

// Flash result codes
let FLASH_OK: UInt8           = 0
let FLASH_ERR_WRITE: UInt8    = 1
let FLASH_ERR_NO_DATA: UInt8  = 2
let FLASH_ERR_CRC: UInt8      = 3
