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

    // MARK: - Type metadata

    /// usesGain / usesQ drive both the row layout and what the exporter writes,
    /// so pin the contract down here.
    func testGainAndQApplicability() {
        for type in [FilterType.peaking, .lowShelf, .highShelf, .lowShelf1, .highShelf1] {
            XCTAssertTrue(type.usesGain, "\(type.name) should use gain")
        }
        for type in [FilterType.lowPass, .highPass, .notch, .allPass, .allPass1, .linkwitzTransform, .flat] {
            XCTAssertFalse(type.usesGain, "\(type.name) should not use gain")
        }

        for type in [FilterType.peaking, .lowShelf, .highShelf, .lowPass, .highPass, .notch, .allPass] {
            XCTAssertTrue(type.usesQ, "\(type.name) should use Q")
        }
        for type in [FilterType.allPass1, .lowShelf1, .highShelf1, .linkwitzTransform, .flat, .lr4_lp] {
            XCTAssertFalse(type.usesQ, "\(type.name) should not use Q")
        }
    }
}
