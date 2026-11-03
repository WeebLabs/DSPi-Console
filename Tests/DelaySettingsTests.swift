import Foundation

// Run with:
// swiftc "DSPi Console/DelaySettings.swift" Tests/DelaySettingsTests.swift -o /tmp/delay-tests
// /tmp/delay-tests
@main
struct DelaySettingsTests {
    static func main() {
        let maximum: Float = 42.64
        let cases: [(Float, Float)] = [
            (0.004, 0), (0.005, 0.01), (0.014, 0.01), (0.015, 0.02),
            (1.234, 1.23), (1.235, 1.24), (1.005, 1.01), (11.51, 11.51),
            (-1, 0), (85, maximum), (.nan, 0), (.infinity, 0)
        ]
        for (input, expected) in cases {
            precondition(DelaySettings.roundedMS(input, maximum: maximum) == expected,
                         "Unexpected rounding for \(input)")
        }

        let rates: [UInt32] = [44100, 48000, 88200, 96000, 176400, 192000]
        for (platform, buffer) in [("RP2040", 1024), ("RP2350", 2048)] {
            for rate in rates {
                for isPDM in [false, true] {
                    let limit = DelaySettings.maximumMS(platform: platform, sampleRateHz: rate, isPDM: isPDM)
                    let alignment: Float = isPDM ? Float(128) / Float(rate) * 1000 : 0
                    // Reproduce firmware's Float conversion, including PDM alignment.
                    let samples = Int((limit + alignment) * Float(rate) / 1000)
                    precondition(samples < buffer, "Delay reaches wrapping endpoint")
                    precondition(DelaySettings.roundedMS(limit + 0.01, maximum: limit) == limit)
                    precondition(DelaySettings.roundedMS(limit, maximum: limit) == limit)
                }
            }
        }
        precondition(DelaySettings.maximumMS(platform: "RP2040", sampleRateHz: 48000, isPDM: false) == 21.31)
        precondition(DelaySettings.maximumMS(platform: "RP2350", sampleRateHz: 48000, isPDM: false) == 42.64)
        precondition(DelaySettings.maximumMS(platform: "RP2040", sampleRateHz: 48000, isPDM: true) == 18.64)
        precondition(DelaySettings.maximumMS(platform: "RP2350", sampleRateHz: 48000, isPDM: true) == 39.97)
        precondition(DelaySettings.maximumMS(platform: "", sampleRateHz: 48000, isPDM: false) == 0)
        precondition(DelaySettings.maximumMS(platform: "RP2350", sampleRateHz: 0, isPDM: false) == 0)
        print("Delay rounding and buffer limits passed")
    }
}
