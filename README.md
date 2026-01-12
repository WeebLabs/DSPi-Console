/# FoxDAC (RP2040 DSP)

![Platform](https://img.shields.io/badge/Platform-RP2040-red)
![Language](https://img.shields.io/badge/Language-Swift_%7C_C++-orange)
![License](https://img.shields.io/badge/License-MIT-green)

FoxDAC is a USB Audio Class 2.0 device implementation for the Raspberry Pi Pico (RP2040). It features a hardware-accelerated DSP pipeline, active crossover capabilities, and a native macOS control utility.

![Screenshot](path/to/screenshot.png)
*(Insert Screenshot Here)*

## Features

* **USB Audio Interface**: 48kHz / 16-bit PCM playback.
* **Active Crossover**:
    * **Mains**: SPDIF output (Left/Right).
    * **Subwoofer**: PDM (Pulse Density Modulation) mono output on **GPIO 10**.
* **DSP Engine**:
    * **Master EQ**: 10-band Parametric EQ on USB input channels.
    * **Output Correction**: 2-band PEQ on output channels.
    * **Filter Types**: Peaking, Low Shelf, High Shelf, Low Pass, High Pass, Flat.
* **Time Alignment**: Per-channel delay lines (0–170ms).

## Hardware Configuration

| Channel | Type | Physical Interface | Band Count |
| :--- | :--- | :--- | :--- |
| **Master L/R** | Input | USB (Virtual) | 10 |
| **Out L/R** | Output | SPDIF | 2 |
| **Sub** | Output | PDM (Pin 10) | 2 |

**Note**: The PDM output requires a passive RC low-pass filter to drive analog amplifier inputs.

## macOS Controller

The included macOS application utilizes `IOKit` for driverless communication with the device.

* **Visualization**: Real-time Bode plot rendering of the complex frequency response $H(z)$.
* **Monitoring**: Polling of CPU core load (Core 0/1) and peak levels for USB, SPDIF, and PDM rails.
* **USB ID**: Matches VID `0x2e8a` / PID `0xfedd`.

### Control Protocol

The device uses Vendor-Specific USB Control Transfers to update DSP parameters in real-time.

| Request | ID | Description | Payload |
| :--- | :--- | :--- | :--- |
| `REQ_SET_EQ_PARAM` | `0x42` | Set filter coefficients | Ch(u8), Band(u8), Type(u8), Freq(f32), Q(f32), Gain(f32) |
| `REQ_GET_EQ_PARAM` | `0x43` | Read filter coefficients | (Returns f32) |
| `REQ_SET_PREAMP` | `0x44` | Set global gain | dB(f32) |
| `REQ_SET_DELAY` | `0x48` | Set output delay | Channel(u16), ms(f32) |
| `REQ_GET_STATUS` | `0x50` | System health | Peak meters (norm. u16) & CPU load (u8) |

## Build Instructions

1.  Open `FoxDAC.xcodeproj` in Xcode.
2.  Select the **My Mac** target.
3.  Build and Run. The application handles device hot-plugging via `IOServiceAddMatchingNotification`.
