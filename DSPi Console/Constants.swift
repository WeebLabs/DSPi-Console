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
let REQ_SET_I2S_BCK_PIN: UInt8    = 0xC2
let REQ_GET_I2S_BCK_PIN: UInt8    = 0xC3
let REQ_SET_MCK_ENABLE: UInt8     = 0xC4
let REQ_GET_MCK_ENABLE: UInt8     = 0xC5
let REQ_SET_MCK_PIN: UInt8        = 0xC6
let REQ_GET_MCK_PIN: UInt8        = 0xC7
let REQ_SET_MCK_MULTIPLIER: UInt8 = 0xC8
let REQ_GET_MCK_MULTIPLIER: UInt8 = 0xC9

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
/// Wire format V16 (unified channel model): inputs are first-class channels
/// (PEQ + metering), outputs follow them.  Flat 5864-byte layout (RP2350).
/// Compatibility is intentionally broken at V16 - only this layout is accepted.
let WIRE_FORMAT_VERSION: Int            = 16
/// Full V16 bulk transfer size (RP2350; RP2040 zero-pads the same layout).
let BULK_PARAMS_SIZE: UInt16            = 5864
let WIRE_BULK_PARAMS_V16_SIZE: Int      = 5864

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
let BULK_LEVELLER_OFFSET: Int           = 4648
let BULK_PREAMP_OFFSET: Int             = 4664  // preamp_db[8]
let BULK_MASTER_VOLUME_OFFSET: Int      = 4696
let BULK_INPUT_CONFIG_OFFSET: Int       = 4712  // input_source, spdif_rx_pin, i2s_rx_pin, i2s_rate
let BULK_LG_OFFSET: Int                 = 4728
let BULK_USER_VOLUME_OFFSET: Int        = 4744  // user_volume_db, user_mute
let BULK_DAC_HW_MUTE_OFFSET: Int        = 4760
let BULK_CROSSOVER_OFFSET: Int          = 4776  // crossovers[17][4]

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
let REQ_SET_SPDIF_RX_PIN: UInt8       = 0xE4
let REQ_GET_SPDIF_RX_PIN: UInt8       = 0xE5

// Input source enum values (payload of 0xE0 / response of 0xE1, and
// WireInputConfig byte 0).
let INPUT_SOURCE_USB: Int   = 0
let INPUT_SOURCE_SPDIF: Int = 1
let INPUT_SOURCE_I2S: Int   = 2

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
