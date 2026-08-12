import XCTest
@testable import DSPi_Console

/// Pure-logic tests for GPIO ownership - `pinAssignment` and the `pinInUseBy`
/// wrapper every pin picker in the app consults.
///
/// This is the one place that decides whether a GPIO is free, so a wrong answer
/// either blocks a legal assignment or, worse, lets two features claim one pin
/// and only shows up as silence on an output. It had no coverage before the
/// Overview page needed structured results out of it; these pin the labels it
/// has always returned, the roles the Overview groups by, and the rule that a
/// merely-configured feature reserves nothing. No device.
final class PinAssignmentTests: XCTestCase {

    /// A view model with no device behind it: the pin tables are plain stored
    /// state, so ownership can be exercised entirely in memory.
    ///
    /// Note this is not a blank board - a fresh model carries the stock output
    /// pins, BCK and MCK, so a test that wants to prove one feature owns a pin
    /// has to place it somewhere nothing already sits.  Hence the two helpers.
    private func makeVM() -> DSPViewModel { DSPViewModel() }

    /// A GPIO nothing claims in the model's current state.
    private func freePin(_ vm: DSPViewModel) -> UInt8 {
        guard let pin = HardwareSettingsTab.validPins.first(where: { vm.pinAssignment($0) == nil }) else {
            XCTFail("no free GPIO to test with")
            return 0
        }
        return pin
    }

    /// Two consecutive free GPIOs, for the clock pairs that reserve `pin` and
    /// `pin + 1` together.
    private func freeConsecutivePair(_ vm: DSPViewModel) -> UInt8 {
        let valid = Set(HardwareSettingsTab.validPins)
        guard let pin = HardwareSettingsTab.validPins.first(where: {
            vm.pinAssignment($0) == nil && valid.contains($0 &+ 1) && vm.pinAssignment($0 &+ 1) == nil
        }) else {
            XCTFail("no free consecutive GPIO pair")
            return 0
        }
        return pin
    }

    // MARK: - The wrapper agrees with the structured answer

    /// `pinInUseBy` must stay a pure read of `pinAssignment`: 31 call sites
    /// depend on the label, and any drift between the two would let the
    /// Overview and the pickers disagree about the same pin.
    func testWrapperMatchesStructuredResult() {
        let vm = makeVM()
        for pin in HardwareSettingsTab.validPins {
            XCTAssertEqual(vm.pinInUseBy(pin), vm.pinAssignment(pin)?.label,
                           "GP\(pin): wrapper and structured result disagree")
        }
    }

    // MARK: - Output slots

    func testOutputSlotOwnsItsPin() {
        let vm = makeVM()
        let pin = vm.outputPins[0]
        let claim = vm.pinAssignment(pin)
        XCTAssertEqual(claim?.label, "Output 1")
        XCTAssertEqual(claim?.role, .output)
        XCTAssertEqual(claim?.pin, pin)
    }

    /// `excluding` is how a picker asks "ignoring my own claim, is this free?".
    /// Without it every picker would report its own current pin as a conflict.
    func testExcludingSkipsOwnClaim() {
        let vm = makeVM()
        let pin = vm.outputPins[0]
        XCTAssertNotNil(vm.pinAssignment(pin))
        XCTAssertNil(vm.pinAssignment(pin, excluding: .output(0)))
        // Excluding one consumer must not blind the check to a different one.
        XCTAssertNotNil(vm.pinAssignment(pin, excluding: .mck))
    }

    // MARK: - Clocks

    /// BCK reserves the next pin up for LRCLK, which is implicit in the wire
    /// format rather than stored anywhere: a caller that only checked the BCK
    /// pin itself would hand LRCLK's GPIO to something else.
    func testBckAlsoReservesLrclk() {
        let vm = makeVM()
        let bck = freeConsecutivePair(vm)
        vm.i2sBckPin = bck
        XCTAssertEqual(vm.pinAssignment(bck)?.label, "I2S BCK")
        XCTAssertEqual(vm.pinAssignment(bck &+ 1)?.label, "I2S LRCLK")
        XCTAssertEqual(vm.pinAssignment(bck &+ 1)?.role, .clock)
    }

    /// The slave clock pair is dormant in UNIFIED mode and constrains nothing;
    /// only SPLIT gives it its own pins to hold.
    func testSlaveClockPairReservedOnlyInSplitMode() {
        let vm = makeVM()
        let bck = freeConsecutivePair(vm)
        vm.i2sBckPinSlave = bck
        vm.i2sClockPinMode = I2S_CLOCK_PIN_MODE_UNIFIED
        XCTAssertNil(vm.pinAssignment(bck))
        XCTAssertNil(vm.pinAssignment(bck &+ 1))

        vm.i2sClockPinMode = I2S_CLOCK_PIN_MODE_SPLIT
        XCTAssertEqual(vm.pinAssignment(bck)?.label, "I2S Slave BCK")
        XCTAssertEqual(vm.pinAssignment(bck &+ 1)?.label, "I2S Slave LRCLK")
    }

    // MARK: - Reservation follows enablement, not configuration

    /// A configured-but-off feature holds no GPIO on the device, so it must
    /// hold none here either - otherwise the app locks out pins the firmware
    /// would happily give away.
    func testDacMuteReservesOnlyWhenEnabled() {
        let vm = makeVM()
        let pin = freePin(vm)
        vm.dacHwMuteConfig = DacHwMuteConfig(enabled: false, activeLow: true, pin: pin)
        XCTAssertNil(vm.pinAssignment(pin))

        vm.dacHwMuteConfig = DacHwMuteConfig(enabled: true, activeLow: true, pin: pin)
        let claim = vm.pinAssignment(pin)
        XCTAssertEqual(claim?.label, "DAC Mute")
        XCTAssertEqual(claim?.role, .utility)
    }

    func testAdatOutputReservesOnlyWhenEnabled() {
        let vm = makeVM()
        let pin = freePin(vm)
        vm.adatSupported = true
        vm.adatPin = pin
        vm.adatEnabled = false
        XCTAssertNil(vm.pinAssignment(pin))

        vm.adatEnabled = true
        XCTAssertEqual(vm.pinAssignment(pin)?.label, "ADAT Output")
        XCTAssertEqual(vm.pinAssignment(pin)?.role, .output)
    }

    /// A control interface reserves its pins only while the device reports it
    /// live, so one held down by a boot pin-collision does not keep the GPIOs.
    func testControlInterfacesReserveOnlyWhileLive() {
        let vm = makeVM()
        let tx = freeConsecutivePair(vm)
        let rx = tx &+ 1
        vm.uartCtrlConfig.txPin = tx
        vm.uartCtrlConfig.rxPin = rx
        vm.ctrlIfaceStatus = CtrlIfaceStatus(uartLive: false, i2cLive: false)
        XCTAssertNil(vm.pinAssignment(tx))
        XCTAssertNil(vm.pinAssignment(rx))

        vm.ctrlIfaceStatus = CtrlIfaceStatus(uartLive: true, i2cLive: false)
        // Both pins of the pair are held, under the one interface name.
        XCTAssertEqual(vm.pinAssignment(tx)?.label, "UART Control")
        XCTAssertEqual(vm.pinAssignment(rx)?.label, "UART Control")
        XCTAssertEqual(vm.pinAssignment(rx)?.role, .control)
    }

    // MARK: - The Overview's view of the header

    /// The page lists claimed pins and calls the rest free, so the two sets
    /// must partition the valid GPIOs exactly - no pin counted twice, none lost.
    func testAssignmentsAndFreePinsPartitionTheHeader() {
        let vm = makeVM()
        vm.dacHwMuteConfig = DacHwMuteConfig(enabled: true, activeLow: true, pin: freePin(vm))

        let valid = HardwareSettingsTab.validPins
        let assigned = vm.activePinAssignments(from: valid)
        let assignedPins = assigned.map(\.pin)

        XCTAssertEqual(Set(assignedPins).count, assignedPins.count, "a pin is listed twice")
        let free = valid.filter { vm.pinAssignment($0) == nil }
        XCTAssertEqual(Set(assignedPins).union(free), Set(valid))
        XCTAssertTrue(Set(assignedPins).isDisjoint(with: Set(free)))
    }

    /// Rows arrive in pin order, which is what the page renders without sorting.
    func testAssignmentsComeBackInPinOrder() {
        let vm = makeVM()
        let pins = vm.activePinAssignments(from: HardwareSettingsTab.validPins).map(\.pin)
        XCTAssertEqual(pins, pins.sorted())
    }

    /// Only valid GPIOs are ever offered, so a pin outside that list is never
    /// enumerated even if some feature is parked on it.
    func testEnumerationIsLimitedToTheGivenPins() {
        let vm = makeVM()
        let pin = freePin(vm)
        vm.dacHwMuteConfig = DacHwMuteConfig(enabled: true, activeLow: true, pin: pin)
        let other = HardwareSettingsTab.validPins.filter { $0 != pin && vm.pinAssignment($0) == nil }
        XCTAssertTrue(vm.activePinAssignments(from: Array(other.prefix(2))).isEmpty)
        XCTAssertEqual(vm.activePinAssignments(from: [pin]).first?.label, "DAC Mute")
    }
}
