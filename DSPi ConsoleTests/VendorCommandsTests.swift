import XCTest
@testable import DSPi_Console

/// The generated VendorCommands.swift must describe exactly what the vendored
/// registry (Protocol/dspi_commands.json) says. A hand edit, or a registry
/// refreshed without regenerating, fails here.
final class VendorCommandsTests: XCTestCase {

    private func loadRegistry() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)        // .../DSPi ConsoleTests/VendorCommandsTests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Protocol/dspi_commands.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testGeneratedTableMatchesRegistry() throws {
        let root = try loadRegistry()
        let proto = try XCTUnwrap(root["protocol"] as? [String: Any])
        XCTAssertEqual(proto["major"] as? Int, Int(VendorProtocolVersion.major))
        XCTAssertEqual(proto["minor"] as? Int, Int(VendorProtocolVersion.minor))

        let pages = try XCTUnwrap(root["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.count, VendorCommandRegistry.pages.count)
        for (json, page) in zip(pages, VendorCommandRegistry.pages) {
            XCTAssertEqual(json["page"] as? Int, Int(page.number))
            XCTAssertEqual(json["mnemonic"] as? String, page.name)
            XCTAssertEqual(json["revision"] as? Int, page.revision)
        }

        let commands = pages.flatMap { page in
            (page["commands"] as? [[String: Any]] ?? []).map { (page["mnemonic"] as? String ?? "", $0) }
        }
        XCTAssertEqual(commands.count, VendorCommandRegistry.all.count)

        for ((pageName, json), info) in zip(commands, VendorCommandRegistry.all) {
            let label = info.qualifiedName
            XCTAssertEqual(pageName, info.pageName, label)
            XCTAssertEqual(json["name"] as? String, info.name, label)
            XCTAssertEqual(json["id"] as? Int, Int(info.command.id), label)
            XCTAssertEqual(json["get"] as? Bool, info.hasGet, label)
            XCTAssertEqual(json["set"] as? Bool, info.hasSet, label)
            XCTAssertEqual(json["addr"] as? String, info.address.rawValue, label)
            XCTAssertEqual(json["set_min"] as? Int, info.setMin, label)
            XCTAssertEqual(json["set_max"] as? Int, info.setMax, label)
            XCTAssertEqual(json["build"] as? String, info.build, label)

            let expectedLength: VendorReplyLength
            switch json["get_len"] {
            case let n as Int: expectedLength = .fixed(n)
            case let s as String where s == "var": expectedLength = .variable
            default: expectedLength = .none
            }
            XCTAssertEqual(expectedLength, info.getLength, label)

            var flags: VendorCommandFlags = []
            for name in json["flags"] as? [String] ?? [] {
                let match = VendorCommandFlags.registryNames.first { $0.0 == name }
                XCTAssertNotNil(match, "\(label): unknown flag \(name)")
                if let m = match { flags.insert(m.1) }
            }
            XCTAssertEqual(flags, info.flags, label)
        }
    }

    func testCommandAddressing() {
        // Guide section 1: page in the wIndex high byte, command in bRequest.
        XCTAssertEqual(VC.SYS.PROTOCOL_INFO.page, 0x01)
        XCTAssertEqual(VC.SYS.PROTOCOL_INFO.number, 0x10)
        XCTAssertEqual(VC.ROUTE.OUTPUT_GAIN.id, 0x0521)
        XCTAssertEqual(VC.FILTER.BAND.id, 0x0610)
        XCTAssertEqual(VC.SYS.ENTER_BOOTLOADER.id, 0x0130)
        XCTAssertEqual(VC.SYS.PROTOCOL_INFO.description, "SYS.PROTOCOL_INFO")
        XCTAssertEqual(VendorCommand(0x0001).description, "0x0001")
    }

    func testRegistryLookup() throws {
        let probe = try XCTUnwrap(VendorCommandRegistry.info(for: VC.SYS.PROTOCOL_INFO))
        XCTAssertEqual(probe.getLength, .fixed(16))
        XCTAssertFalse(probe.hasSet)
        let bulk = try XCTUnwrap(VendorCommandRegistry.info(for: VC.STORE.ALL_PARAMS))
        XCTAssertTrue(bulk.flags.contains(.bulk))
        XCTAssertEqual(bulk.getLength, .fixed(6136))
        XCTAssertEqual(VendorCommandRegistry.info(for: VC.FX.UPMIX_CONFIG)?.build, "PICO_RP2350")
    }
}
