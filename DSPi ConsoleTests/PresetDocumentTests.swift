import XCTest
@testable import DSPi_Console

/// Pure-logic tests for the whole-device configuration document behind
/// File > Import / Export Device Configuration.  No device needed.
///
/// Two things matter here and are easy to break silently:
///
///  - **Channel identity.**  This app's V16 unified numbering and the Windows
///    console's channel ids are different schemes, and the Windows ids are not
///    even the same on both platforms (id 6 is S/PDIF 3 L on RP2350 and PDM on
///    RP2040).  A mapping slip lands a channel's EQ on the wrong speaker.
///
///  - **Key spelling.**  The file is meant to open in either app, which only
///    holds while the JSON keys stay exactly as the shared schema names them.
final class PresetDocumentTests: XCTestCase {

    // MARK: - Round-trip

    func testDocumentRoundTripsThroughJSON() throws {
        var doc = PresetDocument()
        doc.meta.name = "Living room"
        doc.meta.platform = "RP2350"
        doc.meta.firmwareVersion = "1.1.5"
        doc.meta.wireFormatVersion = 27
        doc.global.inputPreampsDb = [-6.5, -6.5, 0, 0, 0, 0, 0, 0]
        doc.global.bypass = true
        doc.global.masterVolumeDb = -12.5
        doc.global.userVolumeDb = -3
        doc.global.inputSource = INPUT_SOURCE_SPDIF2
        doc.global.inputPairLinked = [true, false, true, false]
        doc.loudness.enabled = true
        doc.loudness.outputMask = 0x00F0
        doc.crossfeed.freqHz = 650
        doc.leveller.detectorMask = 0x03
        doc.psybass = PresetDocument.PsybassBlock()
        doc.psybass?.cutoffHz = 95
        doc.upmix = PresetDocument.UpmixBlock()
        doc.upmix?.presenceDb = -1.5

        var channel = PresetDocument.ChannelBlock()
        channel.channelId = 2
        channel.eqChannel = 8
        channel.outputIndex = 0
        channel.isOutput = true
        channel.name = "Mains L"
        channel.delayMs = 3
        channel.outputDelayMs = 7
        channel.gainDb = -2.5
        channel.eq = [PresetDocument.BandBlock(FilterParams(type: .peaking, freq: 63, q: 4, gain: -5))]
        channel.crossover = [PresetDocument.BandBlock(FilterParams(type: .lr4_hp, freq: 80))]
        doc.channels = [channel]

        var crosspoint = PresetDocument.CrosspointBlock()
        crosspoint.input = 1
        crosspoint.output = 3
        crosspoint.enabled = true
        crosspoint.invert = true
        crosspoint.gainDb = -1.5
        doc.matrix = [crosspoint]

        doc.io.spdifRxPin4 = 22
        doc.io.spdifEnabledExt = 0b101
        doc.io.dacHwMute = PresetDocument.DacHwMuteBlock(
            DacHwMuteConfig(enabled: true, activeLow: false, pin: 9, holdMs: 20, releaseMs: 40))

        let decoded = try PresetDocumentFile.decode(PresetDocumentFile.encode(doc))

        XCTAssertEqual(decoded.schemaVersion, PresetDocument.currentSchemaVersion)
        XCTAssertEqual(decoded.meta.name, "Living room")
        XCTAssertEqual(decoded.meta.wireFormatVersion, 27)
        XCTAssertEqual(decoded.global.inputPreampsDb, doc.global.inputPreampsDb)
        XCTAssertTrue(decoded.global.bypass)
        XCTAssertEqual(decoded.global.masterVolumeDb, -12.5)
        XCTAssertEqual(decoded.global.inputSource, INPUT_SOURCE_SPDIF2)
        XCTAssertEqual(decoded.global.inputPairLinked, [true, false, true, false])
        XCTAssertEqual(decoded.loudness.outputMask, 0x00F0)
        XCTAssertEqual(decoded.crossfeed.freqHz, 650)
        XCTAssertEqual(decoded.leveller.detectorMask, 0x03)
        XCTAssertEqual(decoded.psybass?.cutoffHz, 95)
        XCTAssertEqual(decoded.upmix?.presenceDb, -1.5)

        let out = try XCTUnwrap(decoded.channels.first)
        XCTAssertEqual(out.channelId, 2)
        XCTAssertEqual(out.eqChannel, 8)
        XCTAssertEqual(out.outputIndex, 0)
        XCTAssertEqual(out.name, "Mains L")
        XCTAssertEqual(out.delayMs, 3)
        XCTAssertEqual(out.outputDelayMs, 7)
        XCTAssertEqual(out.gainDb, -2.5)
        XCTAssertEqual(out.eq.first?.type, FilterType.peaking.rawValue)
        XCTAssertEqual(out.crossover.first?.type, FilterType.lr4_hp.rawValue)

        let cp = try XCTUnwrap(decoded.matrix.first)
        XCTAssertEqual([cp.input, cp.output], [1, 3])
        XCTAssertTrue(cp.enabled && cp.invert)
        XCTAssertEqual(cp.gainDb, -1.5)

        XCTAssertEqual(decoded.io.spdifRxPin4, 22)
        XCTAssertEqual(decoded.io.spdifEnabledExt, 0b101)
        XCTAssertEqual(decoded.io.dacHwMute?.config,
                       DacHwMuteConfig(enabled: true, activeLow: false, pin: 9, holdMs: 20, releaseMs: 40))
    }

    /// The Linkwitz Transform reuses the band fields (gain carries fp in Hz),
    /// so it is the one type where a field mix-up is inaudible in the JSON and
    /// very audible on the device.
    func testLinkwitzTransformBandSurvivesTheDocument() throws {
        var band = FilterParams(type: .linkwitzTransform, freq: 40, q: 0.7)
        band.gain = 28      // fp in Hz
        band.qp = 1.1
        band.bypass = true

        let restored = PresetDocument.BandBlock(band).filterParams
        XCTAssertEqual(restored.type, .linkwitzTransform)
        XCTAssertEqual(restored.freq, 40)
        XCTAssertEqual(restored.q, 0.7)
        XCTAssertEqual(restored.gain, 28)
        XCTAssertEqual(restored.qp, 1.1)
        XCTAssertTrue(restored.bypass)
    }

    /// A band type from firmware newer than this build becomes flat rather than
    /// an arbitrary shape picked by raw-value proximity.
    func testUnknownBandTypeBecomesFlat() {
        var block = PresetDocument.BandBlock()
        block.type = 250
        XCTAssertEqual(block.filterParams.type, .flat)
    }

    // MARK: - Rejection

    func testDocumentFromANewerBuildIsRejected() throws {
        var doc = PresetDocument()
        doc.schemaVersion = PresetDocument.currentSchemaVersion + 1
        doc.channels = [PresetDocument.ChannelBlock()]

        XCTAssertThrowsError(try PresetDocumentFile.decode(PresetDocumentFile.encode(doc))) { error in
            guard case PresetDocumentError.newerSchema = error else {
                return XCTFail("expected a newer-schema error, got \(error)")
            }
        }
    }

    func testUnrelatedJSONIsRejected() {
        let json = Data(#"{"hello":"world"}"#.utf8)
        XCTAssertThrowsError(try PresetDocumentFile.decode(json)) { error in
            guard case PresetDocumentError.notAPreset = error else {
                return XCTFail("expected a not-a-preset error, got \(error)")
            }
        }
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try PresetDocumentFile.decode(Data("not json at all".utf8)))
    }

    /// Missing blocks and unknown keys must not fail the read: a hand-edited
    /// file, or one from a build that predates a block, should load with
    /// sensible values.
    func testSparseDocumentLoadsWithDefaults() throws {
        let json = Data("""
        {
          "schemaVersion": 1,
          "somethingFromTheFuture": {"a": 1},
          "channels": [{"channelId": 0, "name": "USB L", "isOutput": false}]
        }
        """.utf8)

        let doc = try PresetDocumentFile.decode(json)
        XCTAssertEqual(doc.channels.count, 1)
        XCTAssertEqual(doc.channels[0].name, "USB L")
        XCTAssertTrue(doc.channels[0].eq.isEmpty)
        XCTAssertNil(doc.psybass)
        XCTAssertEqual(doc.global.inputSource, INPUT_SOURCE_USB)
        XCTAssertEqual(doc.loudness.outputMask, Int(LOUDNESS_DEFAULT_OUTPUT_MASK))
        XCTAssertEqual(doc.io.mckMultiplier, 128)
    }

    // MARK: - Channel identity

    func testChannelIDsMapBothWaysOnRP2350() {
        let platform = "RP2350"

        for input in 0..<MAX_MATRIX_INPUTS {
            let id = PresetChannelID.id(forInput: input)
            XCTAssertEqual(PresetChannelID.ref(forID: id, platform: platform), .input(input),
                           "input \(input) did not survive id \(id)")
        }
        for output in 0..<PresetChannelID.outputCount(platform: platform) {
            let id = PresetChannelID.id(forOutput: output, platform: platform)
            XCTAssertEqual(PresetChannelID.ref(forID: id, platform: platform), .output(output),
                           "output \(output) did not survive id \(id)")
        }

        // The specific ids the Windows console uses, spelled out: a silent
        // renumber here would move every channel's EQ.
        XCTAssertEqual(PresetChannelID.id(forInput: 0), 0)
        XCTAssertEqual(PresetChannelID.id(forInput: 2), 11)
        XCTAssertEqual(PresetChannelID.id(forInput: 7), 16)
        XCTAssertEqual(PresetChannelID.id(forOutput: 0, platform: platform), 2)
        XCTAssertEqual(PresetChannelID.id(forOutput: 7, platform: platform), 9)
        XCTAssertEqual(PresetChannelID.id(forOutput: 8, platform: platform), 10)   // PDM
    }

    /// RP2040 has no S/PDIF 3, and its PDM takes that channel id instead.  The
    /// same id therefore means different things on the two platforms, which is
    /// why every conversion is platform-aware.
    func testChannelIDsMapBothWaysOnRP2040() {
        let platform = "RP2040"

        for output in 0..<PresetChannelID.outputCount(platform: platform) {
            let id = PresetChannelID.id(forOutput: output, platform: platform)
            XCTAssertEqual(PresetChannelID.ref(forID: id, platform: platform), .output(output),
                           "output \(output) did not survive id \(id)")
        }

        XCTAssertEqual(PresetChannelID.id(forOutput: 4, platform: platform), 6)    // PDM
        XCTAssertEqual(PresetChannelID.ref(forID: 6, platform: "RP2040"), .output(4))
        XCTAssertEqual(PresetChannelID.ref(forID: 6, platform: "RP2350"), .output(4))
        // ...but those two "output 4"s are different speakers: PDM on RP2040,
        // S/PDIF 3 L on RP2350.  Beyond the RP2040's five outputs there is
        // nothing to land on.
        XCTAssertNil(PresetChannelID.ref(forID: 9, platform: "RP2040"))
        XCTAssertNil(PresetChannelID.ref(forID: 10, platform: "RP2040"))
        XCTAssertEqual(PresetChannelID.ref(forID: 10, platform: "RP2350"), .output(8))
    }

    /// This app's own index fields win over the shared id, so a document from
    /// this app is read by its own numbering even if the id scheme ever moves.
    func testOwnIndexFieldsWinOverTheSharedID() {
        var block = PresetDocument.ChannelBlock()
        block.isOutput = true
        block.channelId = 2          // Windows: S/PDIF 1 L
        block.outputIndex = 5        // ours: S/PDIF 3 R
        XCTAssertEqual(block.ref(platform: "RP2350"), .output(5))

        block.outputIndex = nil
        XCTAssertEqual(block.ref(platform: "RP2350"), .output(0))
    }

    // MARK: - Cross-app compatibility

    /// A document written by DSPi Console for Windows, trimmed to the blocks
    /// that decide where things land.  If this stops decoding, files stop
    /// moving between the two apps.
    func testWindowsWrittenDocumentDecodes() throws {
        let json = Data("""
        {
          "schemaVersion": 1,
          "meta": {
            "name": "Desk",
            "savedUtc": "2026-07-14T09:31:07.4821563+00:00",
            "appVersion": "1.1.5.0",
            "platform": "RP2350",
            "firmwareVersion": "1.1.5",
            "wireFormatVersion": 27,
            "inputChannelCount": 8,
            "outputChannelCount": 9
          },
          "global": {
            "inputPreampsDb": [-3, -3, 0, 0, 0, 0, 0, 0],
            "bypass": false,
            "masterVolumeDb": -20,
            "userVolumeDb": 0,
            "inputSource": 1,
            "lgSoundSyncEnabled": false,
            "inputPairLinked": [true, false, false, false]
          },
          "loudness": {"enabled": true, "refSpl": 80, "intensityPct": 60, "outputMask": 3},
          "crossfeed": {"enabled": false, "preset": 1, "freqHz": 700, "feedDb": 4.5, "itd": true, "outputPairMask": 1},
          "leveller": {"enabled": false, "speed": 1, "lookahead": true, "amountPct": 50,
                       "maxGainDb": 15, "gateDb": -96, "detectorMask": 255, "applyMask": 255},
          "psybass": null,
          "upmix": null,
          "channels": [
            {"channelId": 0, "name": "Master L", "isOutput": false, "delayMs": 0,
             "gainDb": 0, "muted": false, "enabled": true,
             "eq": [{"type": 1, "freqHz": 100, "q": 1, "gain": 3, "qp": 0.707, "bypass": false}],
             "crossover": []},
            {"channelId": 11, "name": "Input 3", "isOutput": false, "delayMs": 0,
             "gainDb": 0, "muted": false, "enabled": true, "eq": [], "crossover": []},
            {"channelId": 10, "name": "PDM", "isOutput": true, "delayMs": 2,
             "gainDb": -4, "muted": false, "enabled": true, "eq": [],
             "crossover": [{"type": 34, "freqHz": 80, "q": 0.707, "gain": 0, "qp": 0.707, "bypass": false}]}
          ],
          "matrix": [{"input": 0, "output": 8, "enabled": true, "invert": false, "gainDb": -3}],
          "io": {
            "outputPins": [6, 7, 8, 9, 10], "outputSlotTypes": [0, 0, 0, 0],
            "i2sBckPin": 14, "mckEnabled": false, "mckPin": 13, "mckMultiplier": 128,
            "i2sClockMode": 0, "i2sClockPinMode": 0, "i2sBckPinSlave": 26,
            "spdifRxPins": [5, 20, 21], "spdifEnabledExt": 1,
            "i2sRxPins": [4, 16, 17, 18], "i2sInputChannels": 2, "i2sInputRateHz": 48000,
            "adatEnabled": false, "adatPin": 12, "adatInputEnabled": false,
            "adatInputPin": 255, "adatInputClockMode": 0, "dacHwMute": null
          }
        }
        """.utf8)

        let doc = try PresetDocumentFile.decode(json)
        XCTAssertEqual(doc.meta.platform, "RP2350")
        XCTAssertEqual(doc.global.masterVolumeDb, -20)
        XCTAssertEqual(doc.loudness.intensityPct, 60)

        // The channels must land where the names say they should.  These blocks
        // carry no eqChannel/outputIndex, so this is the id table doing the work.
        XCTAssertEqual(doc.channels[0].ref(platform: "RP2350"), .input(0))
        XCTAssertEqual(doc.channels[1].ref(platform: "RP2350"), .input(2))
        XCTAssertEqual(doc.channels[2].ref(platform: "RP2350"), .output(8))

        // Band types are raw firmware values, so a renumber on either side shows
        // up here: 1 is a peaking PEQ, 34 an LR4 low pass (the sub's crossover).
        XCTAssertEqual(doc.channels[0].eq.first?.filterParams.type, .peaking)
        XCTAssertEqual(doc.channels[2].crossover.first?.filterParams.type, .lr4_lp)
        // The fourth S/PDIF pin postdates the shared schema, so a Windows file
        // simply doesn't carry one.
        XCTAssertNil(doc.io.spdifRxPin4)
    }

    /// The other direction: the JSON this app writes must use the key spellings
    /// the Windows reader looks for.  Nothing else keeps the two in step - one
    /// renamed Swift property silently produces a file that opens there with
    /// every value at its default.
    func testExportedKeysMatchTheSharedSchema() throws {
        var doc = PresetDocument()
        // The optional strings are omitted from the JSON when nil, so fill them
        // in: this test is about the spelling of the keys, not their presence.
        doc.meta.name = "Test"
        doc.meta.appVersion = "1.1.5"
        doc.meta.platform = "RP2350"
        doc.meta.firmwareVersion = "1.1.5"
        doc.channels = [PresetDocument.ChannelBlock()]
        doc.matrix = [PresetDocument.CrosspointBlock()]
        doc.psybass = PresetDocument.PsybassBlock()
        doc.upmix = PresetDocument.UpmixBlock()
        doc.io.dacHwMute = PresetDocument.DacHwMuteBlock()

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: PresetDocumentFile.encode(doc)) as? [String: Any])

        /// Keys of the object at `path`.  A step that lands on an array (the
        /// channel and matrix lists) descends into its first element, which is
        /// the shape a reader on the other side sees.
        func keys(_ path: [String]) throws -> Set<String> {
            var node: Any = object
            for step in path {
                let dict = try XCTUnwrap(node as? [String: Any], "\"\(step)\" is not inside an object")
                var next = try XCTUnwrap(dict[step], "missing block \"\(step)\"")
                if let array = next as? [Any] {
                    next = try XCTUnwrap(array.first, "block \"\(step)\" is empty")
                }
                node = next
            }
            return Set(try XCTUnwrap(node as? [String: Any], "not an object: \(path)").keys)
        }

        XCTAssertTrue(Set(object.keys).isSuperset(of: [
            "schemaVersion", "meta", "global", "loudness", "crossfeed",
            "leveller", "psybass", "upmix", "channels", "matrix", "io",
        ]), "top-level keys drifted: \(Set(object.keys).sorted())")

        try XCTAssertTrue(keys(["meta"]).isSuperset(of: [
            "savedUtc", "appVersion", "platform", "firmwareVersion",
            "wireFormatVersion", "inputChannelCount", "outputChannelCount",
        ]))
        try XCTAssertTrue(keys(["global"]).isSuperset(of: [
            "inputPreampsDb", "bypass", "masterVolumeDb", "userVolumeDb",
            "inputSource", "lgSoundSyncEnabled", "inputPairLinked",
        ]))
        try XCTAssertTrue(keys(["loudness"]).isSuperset(of: ["enabled", "refSpl", "intensityPct", "outputMask"]))
        try XCTAssertTrue(keys(["crossfeed"]).isSuperset(of: [
            "enabled", "preset", "freqHz", "feedDb", "itd", "outputPairMask",
        ]))
        try XCTAssertTrue(keys(["leveller"]).isSuperset(of: [
            "enabled", "speed", "lookahead", "amountPct", "maxGainDb", "gateDb",
            "detectorMask", "applyMask",
        ]))
        try XCTAssertTrue(keys(["psybass"]).isSuperset(of: [
            "enabled", "cutoffHz", "harmonicsDb", "driveDb", "characterPct",
            "originalDb", "outputMask",
        ]))
        try XCTAssertTrue(keys(["upmix"]).isSuperset(of: [
            "enabled", "centerMode", "surroundMode", "strengthPct", "centerWidthPct",
            "thresholdPct", "attackMs", "releaseMs", "detectorHpfHz",
            "surroundDelayMs", "surroundHpfHz", "surroundLpfHz", "decorrPct", "presenceDb",
        ]))
        try XCTAssertTrue(keys(["channels"]).isSuperset(of: [
            "channelId", "name", "isOutput", "delayMs", "gainDb", "muted",
            "enabled", "eq", "crossover",
        ]))
        try XCTAssertTrue(keys(["matrix"]).isSuperset(of: ["input", "output", "enabled", "invert", "gainDb"]))
        try XCTAssertTrue(keys(["io"]).isSuperset(of: [
            "outputPins", "outputSlotTypes", "i2sBckPin", "mckEnabled", "mckPin",
            "mckMultiplier", "i2sClockMode", "i2sClockPinMode", "i2sBckPinSlave",
            "spdifRxPins", "spdifEnabledExt", "i2sRxPins", "i2sInputChannels",
            "i2sInputRateHz", "adatEnabled", "adatPin", "adatInputEnabled",
            "adatInputPin", "adatInputClockMode", "dacHwMute",
        ]))
        try XCTAssertTrue(keys(["io", "dacHwMute"]).isSuperset(of: [
            "enabled", "activeLow", "pin", "holdMs", "releaseMs",
        ]))
    }

    /// The shared schema's S/PDIF pin array is three long.  Writing a fourth
    /// entry into it would push a reader that indexes it by its own fixed
    /// length off the end, so the fourth input's pin travels separately.
    func testSpdifPinArrayStaysThreeLong() throws {
        let vm = AppState.shared.viewModel
        let io = PresetDocument.capture(from: vm).io
        XCTAssertEqual(io.spdifRxPins.count, 3)
        XCTAssertEqual(io.spdifRxPin4, vm.spdifPin(index: 3))
    }
}
