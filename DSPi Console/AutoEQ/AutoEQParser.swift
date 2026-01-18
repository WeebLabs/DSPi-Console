//
//  AutoEQParser.swift
//  DSPi Console
//
//  Parses AutoEQ ParametricEQ.txt files into filter parameters.
//

import Foundation

struct AutoEQProfile {
    let preamp: Float
    let filters: [FilterParams]
}

struct AutoEQParser {
    /// Parse AutoEQ ParametricEQ.txt content into a profile
    /// Format:
    /// ```
    /// Preamp: -6.0 dB
    /// Filter 1: ON PK Fc 105 Hz Gain -5.2 dB Q 0.70
    /// Filter 2: ON LSC Fc 830 Hz Gain -4.5 dB Q 1.16
    /// ```
    static func parse(_ content: String) -> AutoEQProfile? {
        var preamp: Float = 0.0
        var filters: [FilterParams] = []

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Parse preamp line
            if trimmed.lowercased().hasPrefix("preamp:") {
                if let match = trimmed.range(of: #"-?\d+\.?\d*"#, options: .regularExpression) {
                    preamp = Float(trimmed[match]) ?? 0.0
                }
                continue
            }

            // Parse filter lines
            guard trimmed.contains("Filter") && trimmed.contains(":") else { continue }

            let enabled = trimmed.uppercased().contains(" ON ")
            if !enabled { continue }

            // Extract filter type
            var filterType: FilterType = .flat
            let upperLine = trimmed.uppercased()

            if upperLine.contains(" PK ") || upperLine.contains(" PEQ ") {
                filterType = .peaking
            } else if upperLine.contains(" LSC ") || upperLine.contains(" LSB ") || upperLine.contains(" LS ") {
                filterType = .lowShelf
            } else if upperLine.contains(" HSC ") || upperLine.contains(" HSB ") || upperLine.contains(" HS ") {
                filterType = .highShelf
            } else if upperLine.contains(" LP ") || upperLine.contains(" LPQ ") {
                filterType = .lowPass
            } else if upperLine.contains(" HP ") || upperLine.contains(" HPQ ") {
                filterType = .highPass
            } else {
                continue // Unknown filter type
            }

            // Extract frequency (Fc XXX Hz)
            var freq: Float = 1000.0
            if let fcRange = trimmed.range(of: "Fc", options: .caseInsensitive) {
                let afterFc = trimmed[fcRange.upperBound...]
                let components = afterFc.split(whereSeparator: { $0.isWhitespace })
                if let freqStr = components.first, let freqVal = Float(freqStr) {
                    freq = freqVal
                }
            }

            // Extract gain (Gain XXX dB)
            var gain: Float = 0.0
            if let gainRange = trimmed.range(of: "Gain", options: .caseInsensitive) {
                let afterGain = trimmed[gainRange.upperBound...]
                let components = afterGain.split(whereSeparator: { $0.isWhitespace })
                if let gainStr = components.first, let gainVal = Float(gainStr) {
                    gain = gainVal
                }
            }

            // Extract Q
            var q: Float = 0.707
            let qPattern = try? NSRegularExpression(pattern: "\\sQ\\s+([\\d.]+)", options: .caseInsensitive)
            if let match = qPattern?.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)),
               let qRange = Range(match.range(at: 1), in: trimmed),
               let qVal = Float(trimmed[qRange]) {
                q = qVal
            }

            let params = FilterParams(type: filterType, freq: freq, q: q, gain: gain)
            filters.append(params)
        }

        return AutoEQProfile(preamp: preamp, filters: filters)
    }
}
