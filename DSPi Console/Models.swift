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

    var color: Color {
        switch self {
        case .masterLeft: return Color(red: 0.29, green: 0.56, blue: 0.89)
        case .masterRight: return Color(red: 0.96, green: 0.45, blue: 0.45)
        case .outLeft: return Color(red: 0.27, green: 0.76, blue: 0.64)
        case .outRight: return Color(red: 0.94, green: 0.77, blue: 0.35)
        case .sub: return Color(red: 0.73, green: 0.53, blue: 0.95)
        }
    }
}
