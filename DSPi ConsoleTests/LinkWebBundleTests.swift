//
//  LinkWebBundleTests.swift
//  DSPi ConsoleTests
//
//  The hub's static file lookup: what it serves, what it refuses.
//

import XCTest
@testable import DSPi_Console

final class LinkWebBundleTests: XCTestCase {

    /// A throwaway bundle laid out like the shipped Web folder.
    private func makeBundle() throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("webbundle-\(UUID().uuidString)")
        let web = root.appendingPathComponent("Web")
        try FileManager.default.createDirectory(at: web.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data("<html>hi</html>".utf8).write(to: web.appendingPathComponent("index.html"))
        try Data("console.log(1)".utf8).write(to: web.appendingPathComponent("assets/app-abc123.js"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("secret.txt"))
        try Data("k".utf8).write(to: web.appendingPathComponent("keys.txt"))
        return try XCTUnwrap(Bundle(url: root))
    }

    func testRootAndRoutesServeIndex() throws {
        let b = try makeBundle()
        XCTAssertEqual(LinkWebBundle.file(for: "/", in: b)?.1, "text/html; charset=utf-8")
        XCTAssertEqual(String(decoding: LinkWebBundle.file(for: "/", in: b)!.0, as: UTF8.self), "<html>hi</html>")
        XCTAssertNotNil(LinkWebBundle.file(for: "/devices/3", in: b), "client-side routes fall back to index")
    }

    func testAssetsServeWithTheirType() throws {
        let b = try makeBundle()
        let hit = LinkWebBundle.file(for: "/assets/app-abc123.js", in: b)
        XCTAssertEqual(hit?.1, "text/javascript; charset=utf-8")
        XCTAssertEqual(hit.map { String(decoding: $0.0, as: UTF8.self) }, "console.log(1)")
    }

    func testTraversalAndDisallowedTypesRefused() throws {
        let b = try makeBundle()
        XCTAssertNil(LinkWebBundle.file(for: "/../secret.txt", in: b), "no escaping the Web folder")
        XCTAssertNil(LinkWebBundle.file(for: "/keys.txt", in: b), "only static-site types are served")
        XCTAssertNil(LinkWebBundle.file(for: "/.hidden.js", in: b), "no dotfiles")
        XCTAssertNil(LinkWebBundle.file(for: "/missing.js", in: b))
    }

    func testAbsentBundleMeansNoWebCapability() {
        let empty = Bundle(url: FileManager.default.temporaryDirectory)!
        XCTAssertNil(LinkWebBundle.file(for: "/", in: empty))
    }
}
