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

    /// Line keywords accepted on read.  No keyword is a prefix of another, so
    /// the order is presentational.  "Crossover" is the DSPi Console for
    /// Windows spelling of the same bank: the two apps write the
    /// keyword differently, and a file that lost its crossovers silently on the
    /// way across is worse than a slightly wider parser.
    private static let readKeywords: [(keyword: String, bank: Bank)] = [
        ("Crossover", .crossover),
        ("Filter", .peq),
        ("Xover", .crossover),
    ]

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
        guard let match = readKeywords.first(where: {
                  line.lowercased().hasPrefix($0.keyword.lowercased())
              }),
              let colon = line.firstIndex(of: ":") else { return nil }
        let bank = match.bank
        let keywordEnd = line.index(line.startIndex, offsetBy: match.keyword.count)
        guard keywordEnd <= colon else { return nil }
        let indexText = line[keywordEnd..<colon].trimmingCharacters(in: .whitespaces)
        guard Int(indexText) != nil else { return nil }

        var tokens = line[line.index(after: colon)...]
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        let off = Band(bank: bank, params: FilterParams(type: .flat), enabled: false)
        guard !tokens.isEmpty, tokens.removeFirst().uppercased() == "ON" else { return off }
        guard !tokens.isEmpty else { return off }

        let typeToken = tokens.removeFirst()
        let values = labelledValues(tokens)

        // A crossover band may be written either as a single code ("LR4LP",
        // what this app writes) or as family + shape + slope ("LR  HP ...
        // Slope 24 dB/oct", what the Windows app writes).  Both describe the
        // same firmware type.
        guard let type = FilterType(fileCode: typeToken)
                ?? crossoverType(family: typeToken, shape: tokens.first, slope: values["SLOPE"])
        else { return off }

        var params = FilterParams(type: type)
        var fp: Float? = nil
        for (label, value) in values {
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

        // "[Bypassed]" is this app's marker, a bare "BYP" token the Windows
        // app's.  Matched as a whole token so a channel name can't trip it.
        params.bypass = line.uppercased().contains("[BYPASSED]")
            || tokens.contains { $0.uppercased() == "BYP" }

        return Band(bank: bank, params: params, enabled: true)
    }

    /// Compose a crossover type from the family/shape/slope spelling.  Returns
    /// nil when any part is missing or the combination isn't a real filter (an
    /// odd-order Linkwitz-Riley, say).
    private static func crossoverType(family token: String, shape: String?, slope: Float?) -> FilterType? {
        guard let family = crossoverFamily(token), let shape, let slope, slope >= 6 else { return nil }
        let lowPass: Bool
        switch shape.uppercased() {
        case "LP": lowPass = true
        case "HP": lowPass = false
        default:   return nil
        }
        return family.filterType(order: Int(slope) / 6, lowPass: lowPass)
    }

    /// "BES" is this app's short name for Bessel, "Bessel" the Windows one.
    private static func crossoverFamily(_ token: String) -> CrossoverFamily? {
        switch token.uppercased() {
        case "LR":            return .linkwitzRiley
        case "BW":            return .butterworth
        case "BES", "BESSEL": return .bessel
        default:              return nil
        }
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

    /// Resolve a DSPi Console for Windows channel header - a bare default name
    /// like "Master L", "SPDIF 2 R", "PDM" or "Input 5" - to a channel here.
    ///
    /// The Windows export keys its sections by name rather than by index, and
    /// always writes the built-in default names (a user rename doesn't reach the
    /// file), so this small table is the whole mapping.  Returns nil for any
    /// header that isn't one of them, including this app's own index-keyed
    /// headers, which the caller has already tried.
    static func windowsChannel(header: String, pdmOutput: Int) -> PresetChannelRef? {
        let name = header.trimmingCharacters(in: .whitespaces).uppercased()

        if name == "MASTER L" { return .input(0) }
        if name == "MASTER R" { return .input(1) }
        if name == "PDM" { return .output(pdmOutput) }

        // "Input N" numbers from 1, so input 3 is wire input 2.
        if name.hasPrefix("INPUT "), let index = Int(name.dropFirst("INPUT ".count)),
           index > BASE_MATRIX_INPUTS, index <= MAX_MATRIX_INPUTS {
            return .input(index - 1)
        }

        // "SPDIF k L" / "SPDIF k R" - output pair k, left then right.
        if name.hasPrefix("SPDIF ") {
            let parts = name.dropFirst("SPDIF ".count).split(separator: " ")
            guard parts.count == 2, let pair = Int(parts[0]), pair >= 1 else { return nil }
            switch parts[1] {
            case "L": return .output((pair - 1) * 2)
            case "R": return .output((pair - 1) * 2 + 1)
            default:  return nil
            }
        }

        return nil
    }

    /// Pairs each non-numeric token with the number that follows it, skipping
    /// unit tokens and anything else that isn't a label/value pair.  A repeated
    /// label keeps its last value, matching the order a line is read in.
    private static func labelledValues(_ tokens: [String]) -> [String: Float] {
        guard tokens.count > 1 else { return [:] }
        var pairs: [String: Float] = [:]
        for i in 0..<(tokens.count - 1) {
            guard number(tokens[i]) == nil, let value = number(tokens[i + 1]) else { continue }
            pairs[tokens[i].uppercased()] = value
        }
        return pairs
    }

    /// Parses a numeric token, tolerating a glued unit ("100Hz") and either
    /// decimal separator.
    ///
    /// Separator rule, matching the Windows app so the two agree on the same
    /// file: when a token carries both '.' and ',' the last one is the decimal
    /// point and the other is thousands grouping; a lone ',' is a decimal point.
    /// That reads "1.234,5" and "0,707" correctly and gives up only on a
    /// thousands-grouped integer like "1,000", which neither app writes.
    private static func number(_ token: String) -> Float? {
        var text = token
        while let last = text.last, !last.isNumber, last != ".", last != "," { text.removeLast() }
        guard !text.isEmpty else { return nil }

        let lastDot = text.lastIndex(of: ".")
        let lastComma = text.lastIndex(of: ",")
        if let lastDot, let lastComma {
            let strip: Character = lastDot > lastComma ? "," : "."
            text = text.replacingOccurrences(of: String(strip), with: "")
        }
        return Float(text.replacingOccurrences(of: ",", with: "."))
    }
}
