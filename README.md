# DSPi Console

![Platform](https://img.shields.io/badge/Platform-macOS-black)
![Language](https://img.shields.io/badge/Language-Swift_%7C_SwiftUI-orange)
![License](https://img.shields.io/badge/License-MIT-green)

**DSPi Console** is the native macOS companion application for the [DSPi firmware](https://github.com/WeebLabs/DSPi). It provides comprehensive control, configuration, and monitoring for the DSPi hardware platform.

![Screenshot](Images/DSPiConsole.png)

## Features

### Real-Time Control
* **Parametric EQ**:
    * **Master Inputs (USB)**: 10 parametric bands per channel.
    * **Outputs (SPDIF & Sub)**: 2 parametric bands per channel for output correction/crossover.
* **Filter Types**: Peaking, Low Shelf, High Shelf, Low Pass, and High Pass.
* **Per-Channel Gain & Mute**:
    * Independent gain control (-60dB to +10dB) for each output channel.
    * Quick-mute via clickable meter labels (L/R/S) or dedicated toggle on channel pages.
    * Visual feedback: muted channels show greyed-out labels and meters.
* **Time Alignment**: Adjustable delay (0–170ms) for each output channel.
* **Global Preamp**: Digital gain control (-60dB to +10dB) with a master hardware bypass toggle.

### Filter Management
* **Import**:
    * **DSPi Format**: Native text-based format supporting multi-channel configurations.
    * **REW Format**: Imports Room EQ Wizard text exports. Includes a channel selector to map single-channel filters to specific device channels (L/R).
* **Export**: Saves the full device configuration to a timestamped text file.
* **AutoEQ Integration**:
    * **Database**: Local database of [AutoEQ](https://github.com/jaakkopasanen/AutoEq) headphone profiles.
    * **Application**: One-click mapping of correction curves to Master PEQ bands.
    * **Updates**: Built-in tool to rebuild the database directly from the upstream GitHub repository.

### Device Configuration
* **Persistence**:
    * **Commit Parameters**: Saves the current configuration to the RP2040's non-volatile flash memory.
    * **Revert to Saved**: Reloads parameters from flash, discarding RAM changes.
* **Factory Reset**: Restores all parameters to default safe values (flat EQ, 0dB gain).

### Monitoring & Visualization
* **Response Graph**:
    * **Bode Plot**: Real-time magnitude response rendering (20Hz–20kHz).
    * **Accuracy**: Uses a Swift port of the firmware's biquad implementation to ensure the displayed curve matches hardware behavior.
    * **Interactive**: Per-channel visibility toggles via the legend.
* **Live Metering**: Real-time peak level monitoring for USB Inputs, SPDIF Outputs, and PDM Subwoofer.
* **System Status**: Live CPU load monitoring for both RP2040 cores.
* **Dashboard**: High-level overview of all active channels and filter states.

## Technical Architecture

### Control Protocol
The application communicates with the RP2040 via raw USB bulk transfers using `IOUSBDeviceInterface`.

**Device Identification:**
* **Vendor ID**: `0x2e8a`
* **Product ID**: `0xfedd`

| Request | ID | Payload | Description |
| :--- | :--- | :--- | :--- |
| `REQ_SET_EQ_PARAM` | `0x42` | `struct { ch, band, type, freq, q, gain }` | Uploads filter parameters. |
| `REQ_GET_EQ_PARAM` | `0x43` | `(float32)` | Retrieves current filter values. |
| `REQ_SET_PREAMP` | `0x44` | `(float32)` | Sets global input gain in dB. |
| `REQ_GET_PREAMP` | `0x45` | `(float32)` | Retrieves current preamp gain. |
| `REQ_SET_BYPASS` | `0x46` | `(uint8)` | Enables/Disables master hardware bypass. |
| `REQ_GET_BYPASS` | `0x47` | `(uint8)` | Retrieves bypass state. |
| `REQ_SET_DELAY` | `0x48` | `(float32)` | Sets channel delay in milliseconds. |
| `REQ_GET_DELAY` | `0x49` | `(float32)` | Retrieves channel delay. |
| `REQ_GET_STATUS` | `0x50` | `struct { peaks[5], cpu[2] }` | Polls meters and CPU usage. |
| `REQ_SET_CHANNEL_GAIN` | `0x54` | `(float32)` | Sets output channel gain in dB. |
| `REQ_GET_CHANNEL_GAIN` | `0x55` | `(float32)` | Retrieves output channel gain. |
| `REQ_SET_CHANNEL_MUTE` | `0x56` | `(uint8)` | Mutes/unmutes output channel. |
| `REQ_GET_CHANNEL_MUTE` | `0x57` | `(uint8)` | Retrieves output channel mute state. |
| `REQ_SAVE_PARAMS` | `0x51` | `(none)` | Persists current configuration to flash. |
| `REQ_LOAD_PARAMS` | `0x52` | `(none)` | Reloads configuration from flash. |
| `REQ_FACTORY_RESET` | `0x53` | `(none)` | Resets all settings to default. |

### Channel Mapping
The application manages five audio channels:

| Channel | Role | Band Count | Gain/Mute |
| :--- | :--- | :--- | :--- |
| **Master L/R** | USB Input | 10 per channel | No |
| **Out L/R** | SPDIF Output | 2 per channel | Yes |
| **Sub** | PDM Output (Pin 10) | 2 | Yes |

## Building the Project

1.  Clone the repository.
2.  Open `DSPi Console.xcodeproj` in Xcode 15+.
3.  Ensure the deployment target matches your macOS version (macOS 12.0+ recommended).
4.  Run the **DSPi Console** scheme.
5.  The app will automatically connect when a compatible DSPi device is detected.
