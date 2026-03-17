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
let REQ_LOAD_PARAMS: UInt8  = 0x52
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

// Clip detection request codes
let REQ_CLEAR_CLIPS: UInt8            = 0x83

// Pin configuration status codes
let PIN_CONFIG_SUCCESS: UInt8        = 0x00
let PIN_CONFIG_INVALID_PIN: UInt8    = 0x01
let PIN_CONFIG_PIN_IN_USE: UInt8     = 0x02
let PIN_CONFIG_INVALID_OUTPUT: UInt8 = 0x03
let PIN_CONFIG_OUTPUT_ACTIVE: UInt8  = 0x04

// Preset request codes (0x90-0x9A)
let REQ_PRESET_SAVE: UInt8              = 0x90
let REQ_PRESET_LOAD: UInt8              = 0x91
let REQ_PRESET_DELETE: UInt8            = 0x92
let REQ_PRESET_GET_NAME: UInt8          = 0x93
let REQ_PRESET_SET_NAME: UInt8          = 0x94
let REQ_PRESET_GET_DIR: UInt8           = 0x95
let REQ_PRESET_SET_STARTUP: UInt8       = 0x96
let REQ_PRESET_GET_STARTUP: UInt8       = 0x97
let REQ_PRESET_SET_INCLUDE_PINS: UInt8  = 0x98
let REQ_PRESET_GET_INCLUDE_PINS: UInt8  = 0x99
let REQ_PRESET_GET_ACTIVE: UInt8        = 0x9A

// Channel name request codes
let REQ_SET_CHANNEL_NAME: UInt8  = 0x9B
let REQ_GET_CHANNEL_NAME: UInt8  = 0x9C

// Bulk parameter transfer request codes
let REQ_GET_ALL_PARAMS: UInt8           = 0xA0
let REQ_SET_ALL_PARAMS: UInt8           = 0xA1
let BULK_PARAMS_SIZE: UInt16            = 2832

// Buffer statistics request codes
let REQ_GET_BUFFER_STATS: UInt8         = 0xB0
let REQ_RESET_BUFFER_STATS: UInt8       = 0xB1

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
