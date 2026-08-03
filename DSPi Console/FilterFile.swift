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
///     Preamp -6.5 dB
///     Filter  3: ON  PK      Fc   100.0 Hz  Gain  +3.0 dB  Q  1.00  [Bypassed]
///     Filter  4: ON  LT      Fc    40.0 Hz  Q  0.70  Fp    28.0 Hz  Qp  0.71
///     Filter  5: OFF
///     Xover   1: ON  LR4LP   Fc  2000.0 Hz
///
/// Everything after the type token is read as label/value pairs, so units and
/// any extra trailing text other tools emit are ignored rather than misread.
enum FilterFile {

    /// Version stamped into exported files as "# Format: N".  Bumped when the
    /// layout gains sections older builds would silently skip; a file with no
    /// stamp is version 1 (inputs only, PEQ bands only, no preamp).
    ///   1 - PEQ bands per channel, name-keyed input headers.
    ///   2 - index-keyed input headers, all input channels, per-input preamp,
    ///       crossover bands, Linkwitz/bypass round-trip.
    static let formatVersion = 2

    /// Which bank a band line belongs to.  Crossover bands live in a separate
    /// per-output bank (4 bands at wire indices 20..23), so they need their own
    /// keyword rather than sharing "Filter" numbering with the PEQ bands.
    enum Bank: String, CaseIterable {
        case peq = "Filter"
        case crossover = "Xover"
    }

    /// One parsed line.  `enabled` is false for "OFF" lines and for shapes this
    /// build doesn't know (REW's "None", a type from newer firmware); the caller
    /// decides whether that means "skip the entry" or "leave the band flat".
    struct Band {
        var bank: Bank
        var params: FilterParams
        var enabled: Bool
    }

    // MARK: - Formatting

    /// `Preamp -6.5 dB`, the input trim applied ahead of the band chain.  Same
    /// spelling REW and AutoEQ use, so their files' preamp is honoured too.
    static func formatPreamp(_ db: Float) -> String {
        String(format: "Preamp %+.1f dB\n", db)
    }

    static func format(bank: Bank = .peq, index: Int, band: FilterParams) -> String {
        // Pad the keyword so "Xover" lines column-align with "Filter" ones.
        let keyword = bank.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)

        guard let code = band.type.fileCode else {
            return String(format: "%@ %2d: OFF\n", keyword, index)
        }

        let paddedType = code.padding(toLength: 8, withPad: " ", startingAt: 0)
        var line = String(format: "%@ %2d: ON  %@Fc %7.1f Hz", keyword, index, paddedType, band.freq)

        if band.type == .linkwitzTransform {
            // LT repurposes the wire fields: freq/q are the driver's (f0, Q0)
            // and gain carries fp in Hz, with Qp as a sidecar.  Spelled out with
            // distinct labels so the target alignment survives a round-trip.
            line += String(format: "  Q %6.3f  Fp %7.1f Hz  Qp %6.3f", band.q, band.gain, band.qp)
        } else {
            // Three decimals: gain is quantized to 0.001 dB, so a coarser field
            // would silently round every band on an export/import round-trip.
            if band.type.usesGain { line += String(format: "  Gain %+7.3f dB", band.gain) }
            if band.type.usesQ    { line += String(format: "  Q %6.3f", band.q) }
        }

        if band.bypass { line += "  [Bypassed]" }

        return line + "\n"
    }

    // MARK: - Parsing

    /// Reads a "Preamp -6.5 dB" line.  Returns nil for any other line.
    static func parsePreamp(line rawLine: String) -> Float? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.lowercased().hasPrefix("preamp") else { return nil }
        // Tolerates both "Preamp -6.5 dB" and REW's "Preamp: -6.5 dB".
        return line.dropFirst("preamp".count)
            .split(whereSeparator: { $0.isWhitespace || $0 == ":" })
            .compactMap { number(String($0)) }
            .first
    }

    /// Parses one band line.  Returns nil when the line isn't a band entry at
    /// all (headers, comments, preamp, blank lines).
    static func parse(line rawLine: String) -> Band? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)

        // "<keyword> <n>:" - requiring the index keeps unrelated prose (e.g. a
        // "Filters: 5" summary line) from being read as a band.
        guard let bank = Bank.allCases.first(where: {
                  line.lowercased().hasPrefix($0.rawValue.lowercased())
              }),
              let colon = line.firstIndex(of: ":") else { return nil }
        let keywordEnd = line.index(line.startIndex, offsetBy: bank.rawValue.count)
        guard keywordEnd <= colon else { return nil }
        let indexText = line[keywordEnd..<colon].trimmingCharacters(in: .whitespaces)
        guard Int(indexText) != nil else { return nil }

        var tokens = line[line.index(after: colon)...]
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        let off = Band(bank: bank, params: FilterParams(type: .flat), enabled: false)
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

        return Band(bank: bank, params: params, enabled: true)
    }

    /// Reads the "# Format: N" stamp.  Returns nil for any other line; a file
    /// with no stamp at all is version 1.
    static func parseFormatVersion(line rawLine: String) -> Int? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.lowercased().hasPrefix("# format") else { return nil }
        return line.split(whereSeparator: { $0.isWhitespace || $0 == ":" })
            .compactMap { Int($0) }
            .first
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
