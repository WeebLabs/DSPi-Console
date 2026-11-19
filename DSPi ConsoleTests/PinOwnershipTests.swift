import XCTest
@testable import DSPi_Console

/// How the app names and lists what the device reports about pins.  The pin
/// rules themselves are the firmware's; these tests feed a snapshot in.
@MainActor
final class PinOwnershipTests: XCTestCase {

    private func claim(_ gpio: UInt8, _ fn: PinFunction, _ idx: UInt8 = 0, active: Bool = true, role: UInt8 = 0) -> PinClaim {
        PinClaim(gpio: gpio, functionID: fn.rawValue, index: idx, active: active, role: role, csType: 0)
    }

    private func bits(_ pins: UInt8...) -> UInt64 { pins.reduce(0) { $0 | (1 << UInt64($1)) } }

    private func makeVM(_ claims: [PinClaim]) -> DSPViewModel {
        let vm = DSPViewModel(transport: AppState.shared.usb)
        vm.platformName = "RP2350"
        var snap = PinMapSnapshot()
        snap.support = .supported
        snap.claims = claims
        vm.pinMap.injectForTesting(snap)
        return vm
    }

    func testOwnerNames() {
        let vm = makeVM([])
        vm.i2sInputSupported = true
        XCTAssertEqual(vm.ownerName(claim(6, .output, 1)), "Output 2")
        XCTAssertEqual(vm.ownerName(claim(10, .pdm)), "Subwoofer")
        XCTAssertEqual(vm.ownerName(claim(14, .i2sClock, 0)), "I2S BCK")
        XCTAssertEqual(vm.ownerName(claim(15, .i2sClock, 0, role: 1)), "I2S LRCLK")
        XCTAssertEqual(vm.ownerName(claim(27, .i2sClock, 1, role: 1)), "I2S Slave LRCLK")
        XCTAssertEqual(vm.ownerName(claim(2, .i2sRx, 1)), "I2S RX 2")
        XCTAssertEqual(vm.ownerName(claim(20, .controlSurface, 3)), "Control Surface 4")
        XCTAssertEqual(vm.ownerName(PinClaim(gpio: 1, functionID: 99, index: 0, active: true, role: 0, csType: 0)),
                       "Function 99", "an unknown function still lists")
    }

    /// Only active claims of other functions count; a stored pin blocks nothing.
    func testPinOwnerIgnoresSelfAndStored() {
        let vm = makeVM([claim(6, .output, 0), claim(13, .mck, active: false), claim(12, .adatTx), claim(12, .adatRx)])
        XCTAssertEqual(vm.pinOwner(6), "Output 1")
        XCTAssertNil(vm.pinOwner(6, excluding: .output, index: 0))
        XCTAssertEqual(vm.pinOwner(6, excluding: .output, index: 1), "Output 1")
        XCTAssertNil(vm.pinOwner(13), "stored")
        XCTAssertEqual(vm.pinOwner(12), "ADAT Output, ADAT Input", "a shared pin lists every owner")
    }

    /// A pin outside `free` always gets a reason: its owner, then its pin + 1's
    /// owner for a clock pair, then a reason for a block that holds no pin.
    func testBlockReasonIsNeverEmpty() {
        let vm = makeVM([claim(15, .output, 0)])
        let clock = PinAvailability(status: 0, flags: [.pairPlusOne], generation: 1,
                                    masks: [[PinMaskPair(valid: bits(14, 16), free: bits(16))]])
        XCTAssertEqual(vm.pinBlockReason(14, avail: clock, function: .i2sClock), "GPIO 15: Output 1")
        let i2c = PinAvailability(status: 0, flags: [], generation: 1,
                                  masks: [[PinMaskPair(valid: bits(4), free: 0), PinMaskPair(valid: bits(5), free: 0)]])
        XCTAssertEqual(vm.pinBlockReason(4, avail: i2c, function: .i2cCtrl), "I2C bus in use")
    }

    func testChoicesInClaimAndStoreMode() {
        let vm = makeVM([claim(6, .output, 0)])
        let avail = PinAvailability(status: 0, flags: [], generation: 1,
                                    masks: [[PinMaskPair(valid: bits(5, 6, 7), free: bits(5, 7))]])
        // Claim mode: the held pin is listed, disabled, with its owner.
        let claim = vm.pinChoices(avail, mode: .claim, function: .mck, current: 5)
        XCTAssertEqual(claim.map(\.pin), [5, 6, 7])
        XCTAssertEqual(claim.first { $0.pin == 6 }, PinChoice(pin: 6, enabled: false, note: "Output 1"))
        // Store mode: it can be picked, marked held.
        let store = vm.pinChoices(avail, mode: .store, function: .mck, current: 5)
        XCTAssertEqual(store.first { $0.pin == 6 }, PinChoice(pin: 6, enabled: true, note: "held by Output 1"))
        // The current pin is always there, even outside `valid`.
        let odd = vm.pinChoices(avail, mode: .claim, function: .mck, current: 9)
        XCTAssertTrue(odd.contains { $0.pin == 9 })
        // The current pin stays pickable in claim mode even when held.
        XCTAssertTrue(vm.pinChoices(avail, mode: .claim, function: .mck, current: 6).first { $0.pin == 6 }!.enabled)
        // Extra free pins (a button's shareable mask) are offered as free.
        let shared = vm.pinChoices(avail, mode: .claim, function: .controlSurface, current: 5, extraFree: bits(6))
        XCTAssertEqual(shared.first { $0.pin == 6 }?.enabled, true)
    }

    func testChoicesForOneGroupAndRole() {
        let vm = makeVM([])
        let uart = PinAvailability(status: 0, flags: [], generation: 1, masks: [
            [PinMaskPair(valid: bits(0, 12), free: bits(0, 12)), PinMaskPair(valid: bits(1, 13), free: bits(1))],
            [PinMaskPair(valid: bits(4, 8), free: bits(4)), PinMaskPair(valid: bits(5, 9), free: bits(5, 9))],
        ])
        XCTAssertEqual(vm.pinChoices(uart, mode: .claim, function: .uartCtrl, role: 1, current: 1).map(\.pin), [1, 5, 9, 13])
        XCTAssertEqual(vm.pinChoices(uart, mode: .claim, function: .uartCtrl, role: 0, group: 1, current: nil).map(\.pin), [4, 8])
    }

    func testUnavailableReasons() {
        let vm = makeVM([])
        XCTAssertNil(vm.pinMapUnavailableReason)
        var snap = PinMapSnapshot()
        snap.support = .absent
        vm.pinMap.injectForTesting(snap)
        XCTAssertEqual(vm.pinMapUnavailableReason, "Update the firmware to change pins")
    }
}
