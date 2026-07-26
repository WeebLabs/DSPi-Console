import XCTest
@testable import DSPi_Console

/// Document-level tests for File > Import / Export Filters: section headers,
/// per-input preamp, the crossover bank and the format stamp.
///
/// These read the shared view model (channel names, layout) but never write to
/// it or to a device, so they're safe to run with a DSPi attached.
final class FilterDocumentTests: XCTestCase {

    private var vm: DSPViewModel { AppState.shared.viewModel }

    // MARK: - Export -> import

    /// The exporter's own output must survive its own parser: every active
    /// input and every output comes back, keyed by channel index.
    func testExportRoundTripsThroughTheParser() {
        let text = FileMenuActions.generateExportString()
        XCTAssertTrue(text.hasPrefix("# DSPi Console"), "missing format marker header")
        XCTAssertTrue(text.contains("# Format: \(FilterFile.formatVersion)"), "missing version stamp")

        guard let parsed = FileMenuActions.parseDSPiFile(text) else {
            return XCTFail("exported document did not parse")
        }
        XCTAssertEqual(parsed.formatVersion, FilterFile.formatVersion)

        for eqCh in 0..<vm.numMatrixInputs {
            XCTAssertNotNil(parsed.channels[eqCh], "input \(eqCh) missing from round trip")
            XCTAssertEqual(parsed.channels[eqCh]?.filters.count, vm.channelData[eqCh]?.count,
                           "input \(eqCh) band count changed")
            XCTAssertNotNil(parsed.channels[eqCh]?.preamp, "input \(eqCh) preamp missing")
        }

        for output in 0..<vm.numOutputChannels {
            let eqCh = vm.eqChannel(forOutput: output)
            XCTAssertNotNil(parsed.channels[eqCh], "output \(output) missing from round trip")
            XCTAssertEqual(parsed.channels[eqCh]?.filters.count, vm.channelData[eqCh]?.count,
                           "output \(output) band count changed")
        }
    }

    /// Headers are keyed by index, so renaming a channel must not lose its
    /// bands - the previous name-keyed format dropped them silently.
    func testRenamedInputStillRoundTrips() {
        let original = vm.channelNames[0]
        vm.channelNames[0] = "Left Ear"
        defer { vm.channelNames[0] = original }

        let text = FileMenuActions.generateExportString()
        XCTAssertTrue(text.contains("[Input 0: Left Ear]"))

        let parsed = FileMenuActions.parseDSPiFile(text)
        XCTAssertNotNil(parsed?.channels[0], "renamed input was dropped")
    }

    // MARK: - Fixtures

    /// Files from before the index-keyed headers still load, and the sections
    /// they lack stay nil so an import leaves those settings alone.
    func testLegacyDocumentStillImports() {
        let legacy = """
        # DSPi Console Filter Settings
        # Exported: 2025-01-01 00:00:00

        [USB L]
        Filter  1: ON  PK      Fc   100.0 Hz  Gain  +3.0 dB  Q  1.00

        [Sub]
        Filter  1: OFF
        """

        guard let parsed = FileMenuActions.parseDSPiFile(legacy) else {
            return XCTFail("legacy document did not parse")
        }
        XCTAssertEqual(parsed.formatVersion, 1, "unstamped files are version 1")

        let usbL = parsed.channels[0]
        XCTAssertEqual(usbL?.filters.count, 1)
        XCTAssertEqual(usbL?.filters.first?.type, .peaking)
        XCTAssertNil(usbL?.preamp, "absent preamp must stay nil, not default to 0")
        XCTAssertNil(usbL?.xover, "absent crossover section must stay nil")

        XCTAssertNotNil(parsed.channels[vm.eqChannel(forOutput: vm.pdmOutputIndex)],
                        "legacy [Sub] header did not map to the PDM output")
    }

    func testCurrentDocumentSectionsParse() {
        let doc = """
        # DSPi Console Filter Settings
        # Exported: 2026-07-26 02:15:00
        # Format: 2

        [Input 0: USB L]
        Preamp -6.5 dB
        Filter  1: ON  PK      Fc   100.0 Hz  Gain  +3.0 dB  Q  1.00
        Filter  2: ON  HP      Fc    30.0 Hz  Q  0.50  [Bypassed]

        [Output 0: SPDIF 1 L (Disabled)]
        Filter  1: OFF
        Xover   1: ON  LR4LP   Fc  2000.0 Hz
        Xover   2: OFF
        """

        guard let parsed = FileMenuActions.parseDSPiFile(doc) else {
            return XCTFail("document did not parse")
        }
        XCTAssertEqual(parsed.formatVersion, 2)

        let input = parsed.channels[0]
        XCTAssertEqual(input?.preamp ?? 0, -6.5, accuracy: 0.01)
        XCTAssertEqual(input?.filters.count, 2)
        XCTAssertEqual(input?.filters.last?.type, .highPass)
        XCTAssertEqual(input?.filters.last?.q ?? 0, 0.5, accuracy: 0.005, "Q on a cut was dropped")
        XCTAssertEqual(input?.filters.last?.bypass, true)

        let output = parsed.channels[vm.eqChannel(forOutput: 0)]
        XCTAssertEqual(output?.enableState, false, "Disabled state not read")
        XCTAssertEqual(output?.filters.count, 1)
        // Crossover bands land in their own bank, not appended to the PEQ one.
        XCTAssertEqual(output?.xover?.count, 2)
        XCTAssertEqual(output?.xover?.first?.type, .lr4_lp)
        XCTAssertEqual(output?.xover?.first?.freq ?? 0, 2000, accuracy: 0.05)
        XCTAssertEqual(output?.xover?.last?.type, .flat)
    }

    /// A section with no recognised header is ignored rather than folded into
    /// whichever channel came before it.
    func testUnknownHeaderDoesNotCaptureBands() {
        let doc = """
        # DSPi Console Filter Settings

        [Input 0: USB L]
        Filter  1: ON  PK      Fc   100.0 Hz  Gain  +3.0 dB  Q  1.00

        [Something Else]
        Filter  1: ON  PK      Fc   200.0 Hz  Gain  +6.0 dB  Q  2.00
        """

        let parsed = FileMenuActions.parseDSPiFile(doc)
        XCTAssertEqual(parsed?.channels[0]?.filters.count, 1,
                       "bands under an unknown header leaked into the previous channel")
    }
}
