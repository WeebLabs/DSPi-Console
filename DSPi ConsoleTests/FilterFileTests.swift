import XCTest
@testable import DSPi_Console

/// Pure-logic tests for the filter-file line codec (FilterFile.swift) behind
/// File > Import / Export Filters.  No device needed.
///
/// The round-trip test is the important one: every PEQ type the UI can produce
/// must survive export -> import with all of its editable parameters intact.
/// The previous hand-rolled formatter/parser pair silently dropped Q on cuts,
/// shelves and notches, and could not read back notch / all-pass / Linkwitz
/// bands at all.
final class FilterFileTests: XCTestCase {

    /// Every non-crossover type the PEQ picker offers.
    private static let peqTypes: [FilterType] = [
        .peaking, .lowShelf, .highShelf, .lowPass, .highPass,
        .notch, .allPass, .allPass1, .lowShelf1, .highShelf1, .linkwitzTransform,
        .lowPass1, .highPass1,
    ]

    // MARK: - Round-trip

    func testEveryPEQTypeRoundTrips() {
        for type in Self.peqTypes {
            // Values chosen to differ from every default, so a dropped field
            // shows up as a mismatch rather than an accidental pass.
            var band = FilterParams(type: type, freq: 123.0, q: 1.25, gain: -4.5)
            if type == .linkwitzTransform {
                band.gain = 28.0   // fp in Hz, not dB
                band.qp = 1.10
            }

            let line = FilterFile.format(index: 1, band: band)
            guard let parsed = FilterFile.parse(line: line) else {
                return XCTFail("\(type.name): formatted line did not parse: \(line)")
            }

            XCTAssertTrue(parsed.enabled, "\(type.name): parsed as disabled")
            XCTAssertEqual(parsed.params.type, type, "\(type.name): type lost")
            XCTAssertEqual(parsed.params.freq, band.freq, accuracy: 0.05, "\(type.name): freq lost")

            if type.usesGain || type == .linkwitzTransform {
                XCTAssertEqual(parsed.params.gain, band.gain, accuracy: 0.05, "\(type.name): gain/fp lost")
            }
            if type.usesQ || type == .linkwitzTransform {
                XCTAssertEqual(parsed.params.q, band.q, accuracy: 0.005, "\(type.name): Q lost")
            }
            if type == .linkwitzTransform {
                XCTAssertEqual(parsed.params.qp, band.qp, accuracy: 0.005, "Qp lost")
            }
        }
    }

    /// Crossover codes must not contain a space, or a re-import would read
    /// "LR4 LP" as a plain 2nd-order low pass.
    func testCrossoverCodesRoundTripUnambiguously() {
        for type in FilterType.allCases where type.isCrossover {
            guard let code = type.fileCode else { return XCTFail("\(type.name): no file code") }
            XCTAssertFalse(code.contains(" "), "\(type.name): code \"\(code)\" contains a space")
            XCTAssertEqual(FilterType(fileCode: code), type, "\(type.name): code \"\(code)\" did not resolve back")
        }
    }

    func testBypassRoundTrips() {
        var band = FilterParams(type: .peaking, freq: 100, q: 1, gain: 3)
        band.bypass = true
        let line = FilterFile.format(index: 2, band: band)
        XCTAssertTrue(line.contains("[Bypassed]"))
        XCTAssertEqual(FilterFile.parse(line: line)?.params.bypass, true)

        band.bypass = false
        XCTAssertEqual(FilterFile.parse(line: FilterFile.format(index: 2, band: band))?.params.bypass, false)
    }

    /// Crossover bands share the line grammar but need their own keyword, or
    /// they'd be read back as extra PEQ bands.
    func testCrossoverBankRoundTrips() {
        let band = FilterParams(type: .lr4_lp, freq: 2000, q: 0.707, gain: 0)
        let line = FilterFile.format(bank: .crossover, index: 1, band: band)

        let parsed = FilterFile.parse(line: line)
        XCTAssertEqual(parsed?.bank, .crossover)
        XCTAssertEqual(parsed?.params.type, .lr4_lp)
        XCTAssertEqual(parsed?.params.freq ?? 0, 2000, accuracy: 0.05)

        // A PEQ line must not be mistaken for a crossover one, or vice versa.
        XCTAssertEqual(FilterFile.parse(line: FilterFile.format(index: 1, band: band))?.bank, .peq)
    }

    /// Both banks' lines must line up in the file, and an OFF crossover band
    /// still has to be recognised as a crossover slot.
    func testCrossoverLinesAlignAndSurviveOff() {
        let peq = FilterFile.format(index: 1, band: FilterParams(type: .peaking, freq: 100, q: 1, gain: 3))
        let xover = FilterFile.format(bank: .crossover, index: 1, band: FilterParams(type: .flat))
        XCTAssertEqual(peq.prefix(10).count, xover.prefix(10).count)
        XCTAssertTrue(peq.hasPrefix("Filter  1:"))
        XCTAssertTrue(xover.hasPrefix("Xover   1:"))

        let parsed = FilterFile.parse(line: xover)
        XCTAssertEqual(parsed?.bank, .crossover)
        XCTAssertEqual(parsed?.enabled, false)
    }

    // MARK: - Preamp

    func testPreampRoundTrips() {
        XCTAssertEqual(FilterFile.formatPreamp(-6.5), "Preamp -6.5 dB\n")
        XCTAssertEqual(FilterFile.parsePreamp(line: FilterFile.formatPreamp(-6.5)) ?? 0, -6.5, accuracy: 0.01)
        XCTAssertEqual(FilterFile.parsePreamp(line: FilterFile.formatPreamp(0)) ?? -1, 0, accuracy: 0.01)
    }

    /// AutoEQ's ParametricEQ.txt and REW both lead with a preamp line; the
    /// colon-separated spelling has to work too.
    func testParsesForeignPreampSpellings() {
        XCTAssertEqual(FilterFile.parsePreamp(line: "Preamp: -6.5 dB") ?? 0, -6.5, accuracy: 0.01)
        XCTAssertEqual(FilterFile.parsePreamp(line: "  preamp -3 dB  ") ?? 0, -3, accuracy: 0.01)
        XCTAssertNil(FilterFile.parsePreamp(line: "Filter  1: ON  PK  Fc 100 Hz  Gain -3.0 dB  Q 1.00"))
        XCTAssertNil(FilterFile.parsePreamp(line: "[Input 0: USB L]"))
    }

    /// A preamp line must not also parse as a band, or it would consume a slot.
    func testPreampIsNotABandLine() {
        XCTAssertNil(FilterFile.parse(line: "Preamp -6.5 dB"))
    }

    // MARK: - Format version

    func testFormatVersionStamp() {
        XCTAssertEqual(FilterFile.parseFormatVersion(line: "# Format: 2"), 2)
        XCTAssertEqual(FilterFile.parseFormatVersion(line: "# format 17"), 17)
        XCTAssertNil(FilterFile.parseFormatVersion(line: "# Exported: 2026-07-26 02:15:00"))
        XCTAssertNil(FilterFile.parseFormatVersion(line: "# DSPi Console Filter Settings"))
    }

    func testFlatBandFormatsAsOff() {
        let line = FilterFile.format(index: 5, band: FilterParams(type: .flat))
        XCTAssertEqual(line, "Filter  5: OFF\n")

        let parsed = FilterFile.parse(line: line)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.enabled, false)
    }

    // MARK: - Foreign input

    /// A representative REW line, plus the aliases REW and older DSPi Console
    /// builds emit for the same shapes.
    func testParsesREWLine() {
        let parsed = FilterFile.parse(line: "Filter  1: ON  PK       Fc    63.0 Hz  Gain  -5.0 dB  Q  4.00")
        XCTAssertEqual(parsed?.params.type, .peaking)
        XCTAssertEqual(parsed?.params.freq ?? 0, 63.0, accuracy: 0.01)
        XCTAssertEqual(parsed?.params.gain ?? 0, -5.0, accuracy: 0.01)
        XCTAssertEqual(parsed?.params.q ?? 0, 4.0, accuracy: 0.01)
    }

    func testParsesTypeAliases() {
        XCTAssertEqual(FilterType(fileCode: "PEQ"), .peaking)
        XCTAssertEqual(FilterType(fileCode: "lpq"), .lowPass)
        XCTAssertEqual(FilterType(fileCode: "HPQ"), .highPass)
        XCTAssertEqual(FilterType(fileCode: "LSC"), .lowShelf)
        XCTAssertEqual(FilterType(fileCode: "HSC"), .highShelf)
        // "NO" is what DSPi Console wrote for notch before the codes unified on
        // shortLabel ("NT"); both must still load.
        XCTAssertEqual(FilterType(fileCode: "NO"), .notch)
        XCTAssertEqual(FilterType(fileCode: "NT"), .notch)
        XCTAssertNil(FilterType(fileCode: "None"))
    }

    /// AutoEQ's ParametricEQ.txt style: single-spaced, integer frequencies.
    func testParsesAutoEQStyleLine() {
        let parsed = FilterFile.parse(line: "Filter 3: ON PK Fc 105 Hz Gain -4.2 dB Q 0.71")
        XCTAssertEqual(parsed?.params.type, .peaking)
        XCTAssertEqual(parsed?.params.freq ?? 0, 105, accuracy: 0.01)
        XCTAssertEqual(parsed?.params.gain ?? 0, -4.2, accuracy: 0.01)
    }

    func testRejectsNonFilterLines() {
        XCTAssertNil(FilterFile.parse(line: ""))
        XCTAssertNil(FilterFile.parse(line: "# DSPi Console Filter Settings"))
        XCTAssertNil(FilterFile.parse(line: "[Output 0: SPDIF 1 L (Enabled)]"))
        XCTAssertNil(FilterFile.parse(line: "Filter Settings file"))
        // "Filter…:" prose without a band index is not a filter entry.
        XCTAssertNil(FilterFile.parse(line: "Filters: 5"))
    }

    /// An unknown shape (REW's "None", or a type from newer firmware) parses as
    /// a recognised-but-disabled entry so the caller can keep band alignment.
    func testUnknownTypeParsesAsDisabled() {
        let parsed = FilterFile.parse(line: "Filter  2: ON  None")
        XCTAssertEqual(parsed?.enabled, false)
        XCTAssertEqual(parsed?.params.type, .flat)
    }

    // MARK: - DSPi Console for Windows dialect

    /// The Windows app writes the same format with different spellings.  Its
    /// files used to lose their crossovers and bypass flags on the way in here,
    /// which reads as "the import worked" right up until you listen.

    func testWindowsCrossoverLineParses() {
        let parsed = FilterFile.parse(
            line: "Crossover  1: ON  LR     HP  Fc    80.0 Hz  Slope  24 dB/oct")
        XCTAssertEqual(parsed?.bank, .crossover)
        XCTAssertEqual(parsed?.enabled, true)
        XCTAssertEqual(parsed?.params.type, .lr4_hp)
        XCTAssertEqual(parsed?.params.freq ?? 0, 80.0, accuracy: 0.05)
    }

    /// Family and slope together pick the type, so both have to be read - not
    /// defaulted to the common case.
    func testWindowsCrossoverFamiliesAndSlopes() {
        let cases: [(String, FilterType)] = [
            ("Crossover  1: ON  LR     LP  Fc  2000.0 Hz  Slope  48 dB/oct", .lr8_lp),
            ("Crossover  2: ON  BW     HP  Fc   100.0 Hz  Slope  18 dB/oct", .bw3_hp),
            ("Crossover  3: ON  Bessel LP  Fc   500.0 Hz  Slope  12 dB/oct", .bes2_lp),
        ]
        for (line, expected) in cases {
            XCTAssertEqual(FilterFile.parse(line: line)?.params.type, expected, "line: \(line)")
        }
    }

    func testWindowsDisabledCrossoverParsesAsDisabled() {
        let parsed = FilterFile.parse(line: "Crossover  2: OFF")
        XCTAssertEqual(parsed?.bank, .crossover)
        XCTAssertEqual(parsed?.enabled, false)
    }

    /// An unresolvable family/slope combination is a disabled entry, not a
    /// guess - an odd-order Linkwitz-Riley doesn't exist.
    func testWindowsCrossoverWithImpossibleSlopeIsDisabled() {
        let parsed = FilterFile.parse(line: "Crossover  1: ON  LR     HP  Fc 80.0 Hz  Slope  18 dB/oct")
        XCTAssertEqual(parsed?.enabled, false)
    }

    func testWindowsBypassTagParses() {
        let parsed = FilterFile.parse(line: "Filter  3: ON  PK      Fc 100.0 Hz  Gain +3.0 dB  Q 1.00  BYP")
        XCTAssertEqual(parsed?.params.bypass, true)
        XCTAssertEqual(FilterFile.parse(line: "Filter  3: ON  PK      Fc 100.0 Hz  Gain +3.0 dB  Q 1.00")?
            .params.bypass, false)
    }

    /// REW exports from comma-decimal locales, and the Windows app reads them.
    func testCommaDecimalsParse() {
        let parsed = FilterFile.parse(line: "Filter  1: ON  PK  Fc 1.234,5 Hz  Gain -4,2 dB  Q 0,707")
        XCTAssertEqual(parsed?.params.freq ?? 0, 1234.5, accuracy: 0.05)
        XCTAssertEqual(parsed?.params.gain ?? 0, -4.2, accuracy: 0.005)
        XCTAssertEqual(parsed?.params.q ?? 0, 0.707, accuracy: 0.0005)
    }

    func testWindowsChannelHeadersResolve() {
        // PDM's output index is platform-dependent, so it is passed in.
        XCTAssertEqual(FilterFile.windowsChannel(header: "Master L", pdmOutput: 8), .input(0))
        XCTAssertEqual(FilterFile.windowsChannel(header: "Master R", pdmOutput: 8), .input(1))
        XCTAssertEqual(FilterFile.windowsChannel(header: "Input 5", pdmOutput: 8), .input(4))
        XCTAssertEqual(FilterFile.windowsChannel(header: "SPDIF 1 L", pdmOutput: 8), .output(0))
        XCTAssertEqual(FilterFile.windowsChannel(header: "SPDIF 2 R", pdmOutput: 8), .output(3))
        XCTAssertEqual(FilterFile.windowsChannel(header: "SPDIF 4 L", pdmOutput: 8), .output(6))
        XCTAssertEqual(FilterFile.windowsChannel(header: "PDM", pdmOutput: 8), .output(8))
        XCTAssertEqual(FilterFile.windowsChannel(header: "PDM", pdmOutput: 4), .output(4))

        // This app's own headers and anything else are left to the index parser.
        XCTAssertNil(FilterFile.windowsChannel(header: "Input 0: USB L", pdmOutput: 8))
        XCTAssertNil(FilterFile.windowsChannel(header: "Input 2", pdmOutput: 8))   // 1-based: no such input
        XCTAssertNil(FilterFile.windowsChannel(header: "Sub", pdmOutput: 8))
        XCTAssertNil(FilterFile.windowsChannel(header: "SPDIF 2", pdmOutput: 8))
    }

    /// The dialect additions must not change what this app writes: an export
    /// still has to read back as itself.
    func testOwnCrossoverSpellingStillParses() {
        let band = FilterParams(type: .lr4_lp, freq: 2000)
        let parsed = FilterFile.parse(line: FilterFile.format(bank: .crossover, index: 1, band: band))
        XCTAssertEqual(parsed?.bank, .crossover)
        XCTAssertEqual(parsed?.params.type, .lr4_lp)
        XCTAssertEqual(parsed?.params.freq ?? 0, 2000, accuracy: 0.05)
    }

    // MARK: - Type metadata

    /// usesGain / usesQ drive both the row layout and what the exporter writes,
    /// so pin the contract down here.
    func testGainAndQApplicability() {
        for type in [FilterType.peaking, .lowShelf, .highShelf, .lowShelf1, .highShelf1] {
            XCTAssertTrue(type.usesGain, "\(type.name) should use gain")
        }
        for type in [FilterType.lowPass, .highPass, .notch, .allPass, .allPass1,
                     .lowPass1, .highPass1, .linkwitzTransform, .flat] {
            XCTAssertFalse(type.usesGain, "\(type.name) should not use gain")
        }

        for type in [FilterType.peaking, .lowShelf, .highShelf, .lowPass, .highPass, .notch, .allPass] {
            XCTAssertTrue(type.usesQ, "\(type.name) should use Q")
        }
        for type in [FilterType.allPass1, .lowShelf1, .highShelf1, .lowPass1, .highPass1,
                     .linkwitzTransform, .flat, .lr4_lp] {
            XCTAssertFalse(type.usesQ, "\(type.name) should not use Q")
        }
    }
}
