import Foundation

/// Text encoding of a single PEQ band, shared by File > Export Filters and both
/// import parsers (native "# DSPi Console" files and REW-style files).
///
/// One formatter and one parser live here on purpose: the previous per-call-site
/// if-ladders had drifted apart, so exports dropped Q on cuts, shelves and
/// notches, and imports couldn't read back notch, all-pass or Linkwitz bands at
/// all.
///
/// Line grammar (a superset of REW's, so REW files parse unchanged):
///
///     Filter  3: ON  PK      Fc   100.0 Hz  Gain  +3.0 dB  Q  1.00  [Bypassed]
///     Filter  4: ON  LT      Fc    40.0 Hz  Q  0.70  Fp    28.0 Hz  Qp  0.71
///     Filter  5: OFF
///
/// Everything after the type token is read as label/value pairs, so units and
/// any extra trailing text other tools emit are ignored rather than misread.
enum FilterFile {

    /// One parsed line.  `enabled` is false for "OFF" lines and for shapes this
    /// build doesn't know (REW's "None", a type from newer firmware); the caller
    /// decides whether that means "skip the entry" or "leave the band flat".
    struct Band {
        var params: FilterParams
        var enabled: Bool
    }

    // MARK: - Formatting

    static func format(index: Int, band: FilterParams) -> String {
        guard let code = band.type.fileCode else {
            return String(format: "Filter %2d: OFF\n", index)
        }

        let paddedType = code.padding(toLength: 8, withPad: " ", startingAt: 0)
        var line = String(format: "Filter %2d: ON  %@Fc %7.1f Hz", index, paddedType, band.freq)

        if band.type == .linkwitzTransform {
            // LT repurposes the wire fields: freq/q are the driver's (f0, Q0)
            // and gain carries fp in Hz, with Qp as a sidecar.  Spelled out with
            // distinct labels so the target alignment survives a round-trip.
            line += String(format: "  Q %5.2f  Fp %7.1f Hz  Qp %5.2f", band.q, band.gain, band.qp)
        } else {
            if band.type.usesGain { line += String(format: "  Gain %+5.1f dB", band.gain) }
            if band.type.usesQ    { line += String(format: "  Q %5.2f", band.q) }
        }

        if band.bypass { line += "  [Bypassed]" }

        return line + "\n"
    }

    // MARK: - Parsing

    /// Parses one line.  Returns nil when the line isn't a filter entry at all
    /// (headers, comments, blank lines).
    static func parse(line rawLine: String) -> Band? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)

        // "Filter <n>:" - requiring the index keeps unrelated "Filter…:" prose
        // (e.g. a "Filters: 5" summary line) from being read as a band.
        guard line.lowercased().hasPrefix("filter"),
              let colon = line.firstIndex(of: ":") else { return nil }
        let indexText = line[line.index(line.startIndex, offsetBy: 6)..<colon]
            .trimmingCharacters(in: .whitespaces)
        guard Int(indexText) != nil else { return nil }

        var tokens = line[line.index(after: colon)...]
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        let off = Band(params: FilterParams(type: .flat), enabled: false)
        guard !tokens.isEmpty, tokens.removeFirst().uppercased() == "ON" else { return off }
        guard !tokens.isEmpty, let type = FilterType(fileCode: tokens.removeFirst()) else { return off }

        var params = FilterParams(type: type)
        var fp: Float? = nil
        for (label, value) in labelledValues(tokens) {
            switch label {
            case "FC":   params.freq = value
            case "GAIN": params.gain = value
            case "Q":    params.q = value
            case "FP":   fp = value
            case "QP":   params.qp = value
            default:     break
            }
        }
        // LT's fp lives in the gain field on the wire; accept either spelling so
        // a file hand-written in the plain "Gain" style still lands correctly.
        if type == .linkwitzTransform, let fp { params.gain = fp }

        params.bypass = line.uppercased().contains("[BYPASSED]")

        return Band(params: params, enabled: true)
    }

    /// Pairs each non-numeric token with the number that follows it, skipping
    /// unit tokens and anything else that isn't a label/value pair.
    private static func labelledValues(_ tokens: [String]) -> [(String, Float)] {
        guard tokens.count > 1 else { return [] }
        var pairs: [(String, Float)] = []
        for i in 0..<(tokens.count - 1) {
            guard number(tokens[i]) == nil, let value = number(tokens[i + 1]) else { continue }
            pairs.append((tokens[i].uppercased(), value))
        }
        return pairs
    }

    /// Parses a numeric token, tolerating a glued unit ("100Hz").
    private static func number(_ token: String) -> Float? {
        var text = token
        while let last = text.last, !last.isNumber, last != "." { text.removeLast() }
        return text.isEmpty ? nil : Float(text)
    }
}
