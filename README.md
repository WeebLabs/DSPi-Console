# DSPi Console

![Platform](https://img.shields.io/badge/Platform-macOS-black)
![Language](https://img.shields.io/badge/Language-Swift_%7C_SwiftUI-orange)
![License](https://img.shields.io/badge/License-MIT-green)

**DSPi Console** is the macOS companion application for the [DSPi firmware](https://github.com/WeebLabs/DSPi). It is written in Swift and provides real-time control and monitoring for all functions.

![Screenshot](Images/DSPiConsole.png)

## Capabilities

### Real-Time Control
* **Parametric EQ**: Full control over the stereo master PEQ (10 bands per channel) and output crossover filters (2 bands per channel).
* **Filter Types**: Peaking, Low Shelf, High Shelf, Low Pass and High Pass filters.
* **Time Alignment**: Adjustable delay (0–170ms) for each output channel.
* **Gain**: Global digital preamp control (-60dB to +10dB) and master PEQ bypass.

### Hardware Monitoring
* **Live Metering**: Peak level indicators for USB Inputs, SPDIF Outputs, and the PDM subwoofer channel.
* **System Status**: Displays the real-time load of the RP2040's cores.
* **Hotplug**: Automatic device detection and connection status management via 'IOServiceMatching'.

### Visualization
* **Response Graph**: Renders the frequency response of the active filter chain.
* **Math Engine**: Implements a Swift port of the DSPi firmware's biquad coefficient logic to ensure the displayed graph represents hardware behavior.

## Technical Architecture

### Control Protocol
The application currently relies upon custom vendor requests to communicate with the RP2040. It interfaces with the device using `IOUSBDeviceInterface500`.

**Device Identification:**
* **Vendor ID**: `0x2e8a`
* **Product ID**: `0xfedd`

| Request | ID | Payload | Description |
| :--- | :--- | :--- | :--- |
| `REQ_SET_EQ_PARAM` | `0x42` | `struct { ch, band, type, freq, q, gain }` | Uploads filter parameters. |
| `REQ_GET_EQ_PARAM` | `0x43` | `(float32)` | Retrieves current filter values. |
| `REQ_SET_PREAMP` | `0x44` | `(float32)` | Sets global input gain in dB. |
| `REQ_SET_DELAY` | `0x48` | `(float32)` | Sets channel delay in milliseconds. |
| `REQ_GET_STATUS` | `0x50` | `struct { peaks[5], cpu[2] }` | Polls meters and CPU usage. |

## Channel Mapping

The application manages five distinct audio channels grouped into logical inputs and outputs:

| Channel | Description | Band Count |
| :--- | :--- | :--- |
| **Master L/R** | USB Input (1 & 2) | 10 |
| **Out L/R** | SPDIF Output (3 & 4) | 2 |
| **Sub** | PDM Output (Pin 10) | 2 |

## Building the Project

1.  Clone the repository.
2.  Open `DSPi Console.xcodeproj` in Xcode.
3.  Target **My Mac** and run.
4.  The application will automatically scan for the USB VID/PID and attach when the device is connected.
