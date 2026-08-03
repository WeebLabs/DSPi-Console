import XCTest
@testable import DSPi_Console

/// Pure-logic tests for adjacent input pair links (1/2, 3/4, 5/6, 7/8).
///
/// These only touch the app-side link mask and its UserDefaults store - no
/// vendor traffic - so they're safe to run with a DSPi attached.  The mask is
/// saved and put back in tearDown so a run leaves the attached unit's stored
/// preference exactly as it found it.
final class InputPairLinkTests: XCTestCase {

    private var vm: DSPViewModel { AppState.shared.viewModel }
    private var savedMask: UInt8 = 0

    override func setUp() {
        super.setUp()
        savedMask = vm.linkedInputPairs
    }

    override func tearDown() {
        vm.linkedInputPairs = savedMask
        super.tearDown()
    }

    /// Run a body that scribbles on two channels' cached bands and trims, then
    /// put the originals back.  Purely local state - nothing is sent to a
    /// device - but an attached unit's UI would otherwise show the fixtures.
    private func withScratchBands(_ a: Int, _ b: Int, _ body: () -> Void) {
        let savedBands = (vm.channelData[a], vm.channelData[b])
        let savedPreamp = (vm.preampValue(a), vm.preampValue(b))
        defer {
            vm.channelData[a] = savedBands.0
            vm.channelData[b] = savedBands.1
            vm.preampDB[a] = savedPreamp.0
            vm.preampDB[b] = savedPreamp.1
        }
        body()
    }

    // MARK: - Defaults

    /// Pair 0 ships linked so the classic Link L/R behaviour is unchanged for
    /// anyone who never touches the new toggles.
    func testPairZeroIsLinkedByDefault() {
        XCTAssertEqual(DSPViewModel.defaultLinkedInputPairs, 0b0000_0001)
        XCTAssertEqual(DSPViewModel.inputPairCount, MAX_MATRIX_INPUTS / 2)
    }

    /// A serial we've never stored a mask for falls back to the default rather
    /// than to "nothing linked".
    func testUnknownSerialFallsBackToTheDefaultMask() {
        let serial = "TESTSERIAL-UNKNOWN-\(UUID().uuidString)"
        XCTAssertEqual(DSPViewModel.loadLinkedInputPairs(serial: serial),
                       DSPViewModel.defaultLinkedInputPairs)
    }

    // MARK: - Partner resolution

    /// Both halves of a linked pair resolve to each other, so an edit made from
    /// either side mirrors onto the other.
    func testLinkedPairResolvesPartnerBothWays() {
        vm.linkedInputPairs = 0b0000_0011  // pairs 0 and 1
        XCTAssertEqual(vm.linkedPartner(of: 0), 1)
        XCTAssertEqual(vm.linkedPartner(of: 1), 0)

        guard vm.numMatrixInputs >= 4 else { return }
        XCTAssertEqual(vm.linkedPartner(of: 2), 3)
        XCTAssertEqual(vm.linkedPartner(of: 3), 2)
    }

    /// An unlinked pair has no partner, so edits stay on the clicked channel.
    func testUnlinkedPairHasNoPartner() {
        vm.linkedInputPairs = 0
        for ch in 0..<vm.numMatrixInputs {
            XCTAssertNil(vm.linkedPartner(of: ch), "input \(ch) mirrored while unlinked")
        }
    }

    /// Each pair is its own switch: linking 3/4 must not drag 1/2 along.
    func testPairsToggleIndependently() {
        vm.linkedInputPairs = 0
        vm.setInputPairLinked(1, true)
        XCTAssertTrue(vm.isInputPairLinked(1))
        XCTAssertFalse(vm.isInputPairLinked(0))
        XCTAssertNil(vm.linkedPartner(of: 0))

        vm.setInputPairLinked(1, false)
        XCTAssertFalse(vm.isInputPairLinked(1))
    }

    /// Out-of-range pair indices are ignored rather than shifting into another
    /// pair's bit.
    func testOutOfRangePairsAreIgnored() {
        vm.linkedInputPairs = 0
        vm.setInputPairLinked(-1, true)
        vm.setInputPairLinked(DSPViewModel.inputPairCount, true)
        XCTAssertEqual(vm.linkedInputPairs, 0)
        XCTAssertFalse(vm.isInputPairLinked(-1))
        XCTAssertFalse(vm.isInputPairLinked(DSPViewModel.inputPairCount))
    }

    /// Linking is an input-only notion; output channels never pair up, whatever
    /// the mask says.
    func testOutputChannelsNeverPair() {
        vm.linkedInputPairs = 0xFF
        XCTAssertNil(vm.inputPair(for: vm.chOut1))
        XCTAssertNil(vm.linkedPartner(of: vm.chOut1))
        XCTAssertNil(vm.linkedPartner(of: vm.chOut1 + 1))
    }

    /// A pair whose channels aren't live stops mirroring but keeps its bit, so
    /// the link returns when the input count grows back.
    func testInactivePairSuspendsWithoutForgetting() {
        vm.linkedInputPairs = 0xFF
        for ch in vm.numMatrixInputs..<vm.chOut1 {
            XCTAssertNil(vm.linkedPartner(of: ch), "input \(ch) mirrored while inactive")
        }
        for pair in 0..<DSPViewModel.inputPairCount {
            XCTAssertTrue(vm.isInputPairLinked(pair), "pair \(pair) lost its bit")
        }
    }

    // MARK: - Mismatch detection

    /// Bands and trims that already agree link silently - no prompt.
    func testMatchingChannelsReportNoMismatch() {
        withScratchBands(0, 1) {
            let bands = [FilterParams(type: .peaking, freq: 100, q: 1.0, gain: 3.0)]
            vm.channelData[0] = bands
            vm.channelData[1] = bands
            vm.preampDB[0] = -6.0
            vm.preampDB[1] = -6.0

            let mismatch = vm.inputPairMismatch(0, 1)
            XCTAssertFalse(mismatch.bands)
            XCTAssertFalse(mismatch.preamp)
        }
    }

    /// A single differing band parameter is enough to prompt.
    func testDifferingBandsAreDetected() {
        withScratchBands(0, 1) {
            vm.channelData[0] = [FilterParams(type: .peaking, freq: 100, q: 1.0, gain: 3.0)]
            vm.channelData[1] = [FilterParams(type: .peaking, freq: 100, q: 1.0, gain: -3.0)]
            XCTAssertTrue(vm.inputPairMismatch(0, 1).bands)
        }
    }

    /// Bypass is part of the audible state, so a bypassed band on one side only
    /// counts as a mismatch even when every other field agrees.
    func testBypassDifferenceIsAMismatch() {
        withScratchBands(0, 1) {
            var band = FilterParams(type: .peaking, freq: 100, q: 1.0, gain: 3.0)
            vm.channelData[0] = [band]
            band.bypass = true
            vm.channelData[1] = [band]
            XCTAssertTrue(vm.inputPairMismatch(0, 1).bands)
        }
    }

    /// Trims are reported separately from bands so the prompt can name what
    /// actually differs.
    func testPreampDifferenceIsReportedSeparately() {
        withScratchBands(0, 1) {
            let bands = [FilterParams(type: .peaking, freq: 100, q: 1.0, gain: 3.0)]
            vm.channelData[0] = bands
            vm.channelData[1] = bands
            vm.preampDB[0] = -6.0
            vm.preampDB[1] = -3.0

            let mismatch = vm.inputPairMismatch(0, 1)
            XCTAssertFalse(mismatch.bands)
            XCTAssertTrue(mismatch.preamp)
        }
    }

    /// Band data we haven't fetched yet must not fake a mismatch - there'd be
    /// nothing to copy in either direction.
    func testUnfetchedBandsReportNoMismatch() {
        withScratchBands(0, 1) {
            vm.channelData[0] = []
            vm.channelData[1] = [FilterParams(type: .peaking, freq: 100, q: 1.0, gain: 3.0)]
            XCTAssertFalse(vm.inputPairMismatch(0, 1).bands)
        }
    }

    // MARK: - Persistence

    /// The mask survives a store/load round trip under a device serial.
    func testMaskRoundTripsThroughUserDefaults() {
        let serial = "TESTSERIAL-ROUNDTRIP-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "linkedInputPairs.\(serial)") }

        DSPViewModel.storeLinkedInputPairs(0b0000_1010, serial: serial)
        XCTAssertEqual(DSPViewModel.loadLinkedInputPairs(serial: serial), 0b0000_1010)

        // Nothing linked has to persist as "nothing linked", not fall back to
        // the default - otherwise unlinking 1/2 wouldn't survive a relaunch.
        DSPViewModel.storeLinkedInputPairs(0, serial: serial)
        XCTAssertEqual(DSPViewModel.loadLinkedInputPairs(serial: serial), 0)
    }

    /// With no device attached there's no key to write under, so storing is a
    /// no-op instead of collapsing every unit onto one shared preference.
    func testMissingSerialIsNotPersisted() {
        DSPViewModel.storeLinkedInputPairs(0b0000_0100, serial: nil)
        DSPViewModel.storeLinkedInputPairs(0b0000_0100, serial: "")
        XCTAssertEqual(DSPViewModel.loadLinkedInputPairs(serial: nil),
                       DSPViewModel.defaultLinkedInputPairs)
        XCTAssertEqual(DSPViewModel.loadLinkedInputPairs(serial: ""),
                       DSPViewModel.defaultLinkedInputPairs)
    }

    /// Restoring is keyed off a real serial; an absent one leaves the in-memory
    /// mask alone so a disconnect doesn't wipe the user's toggles.
    func testRestoreWithoutSerialLeavesMaskAlone() {
        vm.linkedInputPairs = 0b0000_0110
        vm.restoreInputPairLinks(forSerial: nil)
        XCTAssertEqual(vm.linkedInputPairs, 0b0000_0110)
        vm.restoreInputPairLinks(forSerial: "")
        XCTAssertEqual(vm.linkedInputPairs, 0b0000_0110)
    }
}
