import XCTest
@testable import DSPi_Console

/// The graph spectrum's channel selection: its stored form, which must keep
/// reading the old single-channel "Dashboard FFT" values, and the rule that
/// inputs and outputs are never mixed.
final class RtaChannelSelectionTests: XCTestCase {

    func testStorageKeyRoundTrips() {
        let s = RtaChannelSelection(tap: RTA_TAP_INPUT, channels: [2, 0, 2])
        XCTAssertEqual(s.channels, [0, 2])
        XCTAssertEqual(s.storageKey, "in:0,2")
        XCTAssertEqual(RtaChannelSelection(storageKey: s.storageKey), s)
    }

    func testLegacySingleChannelKeysStillParse() {
        XCTAssertEqual(RtaChannelSelection(storageKey: "in:3"),
                       RtaChannelSelection(tap: RTA_TAP_INPUT, channels: [3]))
        XCTAssertEqual(RtaChannelSelection(storageKey: "out:8"),
                       RtaChannelSelection(tap: RTA_TAP_OUTPUT, channels: [8]))
    }

    func testEmptyListIsADeliberateNothing() {
        let hidden = RtaChannelSelection(storageKey: RtaChannelSelection.none.storageKey)
        XCTAssertNotNil(hidden)
        XCTAssertTrue(hidden!.isEmpty)
    }

    func testMalformedKeysAreRejected() {
        XCTAssertNil(RtaChannelSelection(storageKey: ""))
        XCTAssertNil(RtaChannelSelection(storageKey: "both:1"))
        XCTAssertNil(RtaChannelSelection(storageKey: "in:a"))
        XCTAssertNil(RtaChannelSelection(storageKey: "out:16"))
    }

    func testTogglingAddsAndRemovesAtOneTap() {
        var s = RtaChannelSelection.none.toggling(tap: RTA_TAP_INPUT, channel: 1)
        XCTAssertEqual(s, RtaChannelSelection(tap: RTA_TAP_INPUT, channels: [1]))
        s = s.toggling(tap: RTA_TAP_INPUT, channel: 0)
        XCTAssertEqual(s.channels, [0, 1])
        XCTAssertEqual(s.mask, 0b11)
        s = s.toggling(tap: RTA_TAP_INPUT, channel: 1)
        XCTAssertEqual(s.channels, [0])
    }

    func testTheOtherTapCannotBeMixedIn() {
        let inputs = RtaChannelSelection(tap: RTA_TAP_INPUT, channels: [0])
        XCTAssertFalse(inputs.accepts(tap: RTA_TAP_OUTPUT))
        XCTAssertEqual(inputs.toggling(tap: RTA_TAP_OUTPUT, channel: 0), inputs)

        // Once emptied, either tap can start a new selection.
        let emptied = inputs.toggling(tap: RTA_TAP_INPUT, channel: 0)
        XCTAssertTrue(emptied.accepts(tap: RTA_TAP_OUTPUT))
        XCTAssertEqual(emptied.toggling(tap: RTA_TAP_OUTPUT, channel: 4),
                       RtaChannelSelection(tap: RTA_TAP_OUTPUT, channels: [4]))
    }

    func testRestrictingDropsDeadChannelsAndKeepsTheTap() {
        let s = RtaChannelSelection(tap: RTA_TAP_OUTPUT, channels: [0, 3, 8])
        XCTAssertEqual(s.restricted(to: [0, 1, 8]),
                       RtaChannelSelection(tap: RTA_TAP_OUTPUT, channels: [0, 8]))
    }
}
