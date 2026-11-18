import XCTest
@testable import DSPi_Console

/// Coverage and behaviour tests for the DSPi Link command authorization table
/// (DSPi-Link spec 1.3, sections 6.3, 9.3 and 10 rule 7).
///
/// The coverage tests read the vendored firmware registry
/// (Protocol/dspi_commands.json) at test time rather than duplicating the
/// command list here: the point is to fail when the registry gains a command
/// and the table does not, and a hand-copied list would go stale alongside it.
final class LinkPolicyTests: XCTestCase {

    // MARK: - Loading

    private func loadPolicy() throws -> LinkPolicy {
        // The test bundle carries the app's resources when hosted; fall back
        // to the app bundle so this works either way.
        if let policy = try? LinkPolicy(bundle: Bundle(for: LinkPolicyTests.self)) { return policy }
        return try LinkPolicy()
    }

    func testBundledTableLoadsAndParses() throws {
        let policy = try loadPolicy()
        XCTAssertEqual(policy.specVersion, "1.3")
        XCTAssertFalse(policy.generated.isEmpty)

        var seen = Set<UInt16>()
        for entry in policy.entries {
            XCTAssertTrue(seen.insert(entry.id).inserted, "duplicate row for \(entry.name)")
            XCTAssertFalse(entry.directions.isEmpty, "\(entry.name) lists no direction")
            XCTAssertEqual(VendorCommandRegistry.info(for: VendorCommand(entry.id))?.qualifiedName, entry.name,
                           "row 0x\(String(entry.id, radix: 16)) is named for its command")
        }
    }

    // MARK: - Coverage

    /// Every command of the firmware has a row, with exactly the directions the
    /// firmware accepts, and the table names nothing the firmware lacks.
    func testTableMatchesTheFirmwareRegistry() throws {
        let policy = try loadPolicy()
        XCTAssertEqual(policy.entries.count, VendorCommandRegistry.all.count)
        for info in VendorCommandRegistry.all {
            let entry = policy.entry(for: info.command.id)
            XCTAssertNotNil(entry, "\(info.qualifiedName) has no policy row")
            XCTAssertEqual(entry?.commandClass(for: .get) != nil, info.hasGet, "\(info.qualifiedName) GET")
            XCTAssertEqual(entry?.commandClass(for: .set) != nil, info.hasSet, "\(info.qualifiedName) SET")
        }
    }

    // MARK: - Classification

    func testEveryGetIsARead() throws {
        let policy = try loadPolicy()
        for info in VendorCommandRegistry.all where info.hasGet {
            XCTAssertEqual(policy.classify(id: info.command.id, direction: .get), .read, info.qualifiedName)
        }
    }

    /// Unlisted IDs and directions fail safe to config.  Page 0 lists nothing,
    /// so a 1.1.6-style request from an old client is admin only.
    func testUnknownCommandsFailSafe() throws {
        let policy = try loadPolicy()
        XCTAssertEqual(policy.classify(id: 0x0050, direction: .get), .config, "old GET_STATUS on page 0")
        XCTAssertEqual(policy.classify(id: 0x00D2, direction: .set), .config, "old SET_MASTER_VOLUME on page 0")
        XCTAssertEqual(policy.classify(id: VC.SYS.PROTOCOL_INFO.id, direction: .set), .config, "a GET-only command's SET")
        XCTAssertEqual(LinkPolicy.empty.classify(id: VC.MEAS.LEVELS.id, direction: .get), .config)
    }

    /// The 15 SETs whose command number belonged to a control-class 1.1.6
    /// opcode, so a table carried over by number would have let a control
    /// session reboot the device or erase it (migration guide 13.3.8).
    func testTheEscalationRowsAreConfig() throws {
        let policy = try loadPolicy()
        let escalations: [VendorCommand] = [
            VC.SYS.ENTER_BOOTLOADER, VC.STORE.FACTORY_RESET, VC.STORE.STARTUP, VC.INPUT.I2S_RX_PIN,
            VC.INPUT.I2S_RX_RATE, VC.INPUT.ADAT_RX_CLOCK_MODE, VC.OUTPUT.TYPE, VC.OUTPUT.ADAT_TX_ENABLE,
            VC.CS.SAVE, VC.CS.IR_CMD, VC.CS.IR_LEARN_ARM, VC.CS.DISPLAY_CONFIG, VC.XPORT.UART_CONFIG,
            VC.CLOCK.I2S_BCK_PIN, VC.CLOCK.I2S_CLOCK_MODE,
        ]
        for cmd in escalations {
            XCTAssertEqual(policy.classify(id: cmd.id, direction: .set), .config, "\(cmd)")
            XCTAssertFalse(policy.isAllowed(role: .control, id: cmd.id, direction: .set), "\(cmd)")
        }
    }

    func testEverydayCommandsMatchTheirRoles() throws {
        let policy = try loadPolicy()
        XCTAssertTrue(policy.isAllowed(role: .viewer, id: VC.MEAS.LEVELS.id, direction: .get))
        XCTAssertTrue(policy.isAllowed(role: .viewer, id: VC.ROUTE.MASTER_VOLUME.id, direction: .get))
        XCTAssertFalse(policy.isAllowed(role: .viewer, id: VC.ROUTE.MASTER_VOLUME.id, direction: .set))
        XCTAssertTrue(policy.isAllowed(role: .control, id: VC.ROUTE.MASTER_VOLUME.id, direction: .set))
        XCTAssertTrue(policy.isAllowed(role: .control, id: VC.FILTER.BAND.id, direction: .set))
        XCTAssertTrue(policy.isAllowed(role: .control, id: VC.SYS.DEVICE_NAME.id, direction: .set), "renames are control")
        XCTAssertTrue(policy.isAllowed(role: .control, id: VC.STORE.ALL_PARAMS.id, direction: .set))
        XCTAssertTrue(policy.isAllowed(role: .control, id: VC.MEAS.RTA_STOP.id, direction: .set))
        XCTAssertTrue(policy.isAllowed(role: .admin, id: VC.STORE.FACTORY_RESET.id, direction: .set))
    }

    // MARK: - Denied lists

    func testDeniedListsMatchTheRoles() throws {
        let policy = try loadPolicy()
        XCTAssertTrue(policy.denied(for: .admin).isEmpty)

        let viewerDenied = policy.denied(for: .viewer)
        XCTAssertFalse(viewerDenied.isEmpty)
        for pair in viewerDenied {
            XCTAssertEqual(pair.direction, .set, "a viewer may read everything")
            XCTAssertNotEqual(policy.classify(id: pair.id, direction: pair.direction), .read)
        }
        let controlDenied = policy.denied(for: .control)
        for pair in controlDenied {
            XCTAssertEqual(policy.classify(id: pair.id, direction: pair.direction), .config)
        }
        XCTAssertTrue(controlDenied.contains { $0.id == VC.SYS.ENTER_BOOTLOADER.id && $0.direction == .set })
    }
}
