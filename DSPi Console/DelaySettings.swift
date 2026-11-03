import Foundation

/// Keep the console's hundredth-millisecond controls inside the firmware ring buffer.
enum DelaySettings {
    static func maximumMS(platform: String, sampleRateHz: UInt32, isPDM: Bool) -> Float {
        guard sampleRateHz > 0, platform == "RP2040" || platform == "RP2350" else { return 0 }
        let bufferSamples = platform == "RP2040" ? 1024 : 2048
        // The PDM path adds 128 samples of alignment before using the same buffer.
        let usableSamples = bufferSamples - 1 - (isPDM ? 128 : 0)
        // Round DOWN so rounding a control value cannot reach the wrapping endpoint.
        return Float(floor(Double(usableSamples) * 100_000 / Double(sampleRateHz)) / 100)
    }

    static func roundedMS(_ ms: Float, maximum: Float) -> Float {
        guard ms.isFinite else { return 0 }
        let clamped = max(0, min(maximum, ms))
        return min(maximum, (clamped * 100).rounded() / 100)
    }
}
