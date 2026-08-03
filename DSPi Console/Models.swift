import SwiftUI

// MARK: - Data Structures

struct SystemStatus {
    var peaks: [Float] = Array(repeating: 0, count: WIRE_MAX_CHANNELS)  // up to 17 channels (RP2350)
    var cpu0: Int = 0
    var cpu1: Int = 0
    var clipFlags: UInt32 = 0      // Sticky bitmask from firmware (one bit per channel, up to 17)
    var clipLatched: UInt32 = 0    // App-side latch (OR'd from firmware flags)
    var clipTimestamp: Date? = nil  // When last clip was detected (for auto-clear)
}

class DSPMeterModel: ObservableObject {
    @Published var status = SystemStatus()
}

// MARK: - Channel Model

enum Channel: Int, CaseIterable {
    case masterLeft = 0
    case masterRight = 1
    case outLeft = 2
    case outRight = 3
    case sub = 4

    var name: String {
        switch self {
        case .masterLeft: return "USB L"
        case .masterRight: return "USB R"
        case .outLeft: return "Out L"
        case .outRight: return "Out R"
        case .sub: return "Sub"
        }
    }

    var shortName: String {
        switch self {
        case .masterLeft: return "ML"
        case .masterRight: return "MR"
        case .outLeft: return "OL"
        case .outRight: return "OR"
        case .sub: return "SUB"
        }
    }

    var descriptor: String {
        switch self {
        case .masterLeft: return "IN1"
        case .masterRight: return "IN2"
        case .outLeft, .outRight: return "SPDIF"
        case .sub: return "PDM (Pin 10)"
        }
    }

    var bandCount: Int {
        return 10
    }

    var isOutput: Bool {
        switch self {
        case .outLeft, .outRight, .sub: return true
        default: return false
        }
    }

    /// Legacy 5-channel view of the palette.  Every value is the one this
    /// enum has always returned; they just come from `ChannelPalette` now
    /// instead of being a third copy of the same literals.
    ///
    /// `outRight` maps to output *2*, not output 1, which is what its literal
    /// has always been.  By the channel model it should be output 1 (EQ channel
    /// = output + 2, so Out R is matrix output 1), so this looks like drift
    /// that crept in while the copies were separate - preserved here rather
    /// than silently recolored.
    var color: Color {
        switch self {
        case .masterLeft:  return ChannelPalette.input(0)
        case .masterRight: return ChannelPalette.input(1)
        case .outLeft:     return ChannelPalette.output(0)
        case .outRight:    return ChannelPalette.output(2)
        case .sub:         return ChannelPalette.pdm
        }
    }
}
