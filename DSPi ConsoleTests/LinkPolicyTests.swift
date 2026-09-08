import XCTest
@testable import DSPi_Console

/// Coverage and behaviour tests for the DSPi Link command authorization table
/// (Documentation/dspi_link_protocol_spec.md sections 6.3, 9.3 and 10 rule 7).
///
/// The coverage tests read the app's own Constants.swift and the firmware's
/// config.h at test time rather than duplicating the opcode lists here: the
/// point is to fail when somebody adds an opcode and forgets the table, and a
/// hand-copied list would just go stale alongside it.
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
        XCTAssertEqual(policy.specVersion, "1.0")
        XCTAssertFalse(policy.generated.isEmpty)
        XCTAssertGreaterThan(policy.entries.count, 200, "the table should cover the whole vendor surface")

        // One entry per code, sorted, and no code carries an empty direction
        // list (a row nobody can ever match is a silent hole).
        var seen = Set<UInt8>()
        var previous = -1
        for entry in policy.entries {
            XCTAssertTrue(seen.insert(entry.code).inserted,
                          "duplicate entry for 0x\(String(entry.code, radix: 16))")
            XCTAssertGreaterThan(Int(entry.code), previous, "entries must be sorted by code")
            previous = Int(entry.code)
            XCTAssertFalse(entry.dirs.isEmpty, "\(entry.name) lists no direction")
            XCTAssertFalse(entry.name.isEmpty)
        }

        // 0x01 and 0x02 are the MS OS 2.0 and WebUSB platform requests, not
        // application commands.
        XCTAssertNil(policy.entry(for: 0x01))
        XCTAssertNil(policy.entry(for: 0x02))
    }

    // MARK: - Coverage

    /// Path of a file in the repo, reached from this test source file.
    private func repoFile(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)          // .../DSPi ConsoleTests/LinkPolicyTests.swift
            .deletingLastPathComponent()         // .../DSPi ConsoleTests
            .deletingLastPathComponent()         // repo root
            .appendingPathComponent(relative)
    }

    func testEveryAppRequestConstantIsInTheTable() throws {
        let policy = try loadPolicy()
        let url = repoFile("DSPi Console/Constants.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        let pattern = #"let\s+(REQ_[A-Za-z0-9_]+)\s*:\s*UInt8\s*=\s*(0x[0-9A-Fa-f]+|\d+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)

        var found = 0
        var missing: [String] = []
        regex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match = match,
                  let nameRange = Range(match.range(at: 1), in: source),
                  let valueRange = Range(match.range(at: 2), in: source) else { return }
            let name = String(source[nameRange])
            let text = String(source[valueRange])
            let value = text.hasPrefix("0x")
                ? UInt8(text.dropFirst(2), radix: 16)
                : UInt8(text)
            guard let code = value else { return }
            found += 1
            if policy.entry(for: code) == nil {
                missing.append("\(name) (0x\(String(code, radix: 16, uppercase: true)))")
            }
        }

        XCTAssertGreaterThan(found, 200, "failed to parse Constants.swift; the regex has drifted")
        XCTAssertTrue(missing.isEmpty, "app REQ_ constants absent from commands.json: \(missing.joined(separator: ", "))")
    }

    func testEveryFirmwareRequestCodeIsInTheTable() throws {
        let url = URL(fileURLWithPath: "/Users/weeblabs/DSPi/firmware/DSPi/config.h")
        guard FileManager.default.fileExists(atPath: url.path),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("firmware config.h not present on this machine")
        }
        let policy = try loadPolicy()

        let pattern = #"#define\s+(REQ_[A-Z0-9_]+)\s+(0x[0-9A-Fa-f]+|\d+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)

        var found = 0
        var missing: [String] = []
        regex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match = match,
                  let nameRange = Range(match.range(at: 1), in: source),
                  let valueRange = Range(match.range(at: 2), in: source) else { return }
            let name = String(source[nameRange])
            let text = String(source[valueRange])
            let value = text.hasPrefix("0x")
                ? UInt8(text.dropFirst(2), radix: 16)
                : UInt8(text)
            guard let code = value else { return }
            found += 1
            if policy.entry(for: code) == nil {
                missing.append("\(name) (0x\(String(code, radix: 16, uppercase: true)))")
            }
        }

        XCTAssertGreaterThan(found, 200, "failed to parse config.h; the regex has drifted")
        XCTAssertTrue(missing.isEmpty, "firmware REQ_ codes absent from commands.json: \(missing.joined(separator: ", "))")
    }

    // MARK: - Classification

    func testUnknownCodeIsConfig() throws {
        let policy = try loadPolicy()
        // 0x03 is unallocated in config.h and must stay admin-only.
        XCTAssertNil(policy.entry(for: 0x03))
        XCTAssertEqual(policy.classify(code: 0x03, direction: .set), .config)
        XCTAssertEqual(policy.classify(code: 0x03, direction: .get), .config)
    }

    func testDirectionTheTableDoesNotListIsConfig() throws {
        let policy = try loadPolicy()
        // GET_STATUS is read on IN, but the firmware has no OUT handler for
        // it; an unexpected direction must fail safe rather than inherit the
        // entry's class.
        XCTAssertEqual(policy.classify(code: 0x50, direction: .get), .read)
        XCTAssertEqual(policy.classify(code: 0x50, direction: .set), .config)
    }

    func testSpotChecks() throws {
        let policy = try loadPolicy()
        // ENTER_BOOTLOADER and FACTORY_RESET are write-as-read: GET direction,
        // but config by what they do.
        XCTAssertEqual(policy.classify(code: 0xF0, direction: .get), .config)
        XCTAssertEqual(policy.classify(code: 0x53, direction: .get), .config)
        XCTAssertEqual(policy.classify(code: 0xD2, direction: .set), .control)
        XCTAssertEqual(policy.classify(code: 0x50, direction: .get), .read)
        XCTAssertEqual(policy.classify(code: 0xA0, direction: .get), .read)
        XCTAssertEqual(policy.classify(code: 0xA1, direction: .set), .control)
        XCTAssertEqual(policy.classify(code: 0x7C, direction: .get), .config)
        XCTAssertEqual(policy.classify(code: 0x42, direction: .set), .control)
        XCTAssertEqual(policy.classify(code: 0x43, direction: .get), .read)
    }

    /// Every write-as-read command must be classified by what it does, not by
    /// its direction (spec section 6.3).  These are the ones commands.md
    /// section 1.1 names; none of them may be `read`.
    func testWriteAsReadCommandsAreNeverRead() throws {
        let policy = try loadPolicy()
        let writeAsRead: [UInt8] = [0x51, 0x52, 0x53, 0x7C, 0x83, 0x90, 0x91, 0x92,
                                    0xB1, 0xB3, 0xC0, 0xC2, 0xC4, 0xC6, 0xC8, 0xD6,
                                    0xE4, 0xEC, 0xF0, 0xF1]
        for code in writeAsRead {
            XCTAssertNotEqual(policy.classify(code: code, direction: .get), .read,
                              "0x\(String(code, radix: 16, uppercase: true)) mutates and must not be classed read")
        }
    }

    // MARK: - Roles

    func testRolePermissions() throws {
        let policy = try loadPolicy()

        XCTAssertFalse(policy.isAllowed(role: .viewer, code: 0xD2, direction: .set))
        XCTAssertTrue(policy.isAllowed(role: .viewer, code: 0xD3, direction: .get))

        XCTAssertTrue(policy.isAllowed(role: .control, code: 0xD2, direction: .set))
        XCTAssertFalse(policy.isAllowed(role: .control, code: 0xF0, direction: .get))

        for entry in policy.entries {
            for dir in entry.dirs {
                XCTAssertTrue(policy.isAllowed(role: .admin, code: entry.code, direction: dir),
                              "admin must be allowed \(entry.name)")
            }
        }
        // Even an unlisted code is admin-allowed, since unlisted means config.
        XCTAssertTrue(policy.isAllowed(role: .admin, code: 0x03, direction: .set))
    }

    func testDeniedLists() throws {
        let policy = try loadPolicy()

        let viewerDenied = policy.denied(for: .viewer)
        XCTAssertFalse(viewerDenied.isEmpty)
        for pair in viewerDenied {
            XCTAssertNotEqual(policy.classify(code: pair.code, direction: pair.direction), .read,
                              "viewer's denial list must not contain read commands")
        }
        // and everything not denied is readable by a viewer
        let deniedSet = Set(viewerDenied.map { "\($0.code)-\($0.direction.rawValue)" })
        for entry in policy.entries where entry.commandClass == .read {
            for dir in entry.dirs {
                XCTAssertFalse(deniedSet.contains("\(entry.code)-\(dir.rawValue)"))
            }
        }

        XCTAssertTrue(policy.denied(for: .admin).isEmpty)

        let controlDenied = policy.denied(for: .control)
        for pair in controlDenied {
            XCTAssertEqual(policy.classify(code: pair.code, direction: pair.direction), .config)
        }
        XCTAssertTrue(controlDenied.contains { $0.code == 0xF0 })
    }
}
