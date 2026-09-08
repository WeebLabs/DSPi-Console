//
//  LinkServerTests.swift
//  DSPi ConsoleTests
//
//  Drives the real NIO server over loopback sockets: the HTTP info endpoint and
//  a WebSocket hello handshake.  These are integration tests on 127.0.0.1, so
//  timeouts are generous.
//

import XCTest
@testable import DSPi_Console

final class LinkServerTests: XCTestCase {

    private func makeStack() -> (LinkHub, LinkAuthStore, LinkPolicy) {
        let usb = USBDevice(startMonitoring: false)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lst-\(UUID().uuidString).json")
        let auth = LinkAuthStore(storeURL: url)
        let policy = LinkPolicy.bundled ?? LinkPolicy.empty
        let hub = LinkHub(usb: usb, policy: policy, auth: auth)
        return (hub, auth, policy)
    }

    private func startServer() throws -> (LinkServer, Int) {
        let (hub, auth, policy) = makeStack()
        let server = LinkServer(hub: hub, auth: auth, policy: policy)
        try server.start(port: 0)
        guard let port = server.boundPort else {
            throw XCTSkip("server did not bind a port")
        }
        return (server, port)
    }

    // MARK: - HTTP info endpoint

    func testInfoEndpointReturnsConsoleHub() throws {
        let (server, port) = try startServer()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/dspi/v1/info")!
        let done = expectation(description: "info responds")
        var status: Int?
        var json: [String: Any]?
        URLSession.shared.dataTask(with: url) { data, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            if let data = data {
                json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)

        XCTAssertEqual(status, 200)
        let hub = json?["hub"] as? [String: Any]
        XCTAssertEqual(hub?["kind"] as? String, "console")
        XCTAssertEqual(json?["ws"] as? String, "/dspi/v1")
    }

    // MARK: - WebSocket hello handshake

    func testWebSocketHelloReturnsHubHelloWithPinAuth() throws {
        let (server, port) = try startServer()
        defer { server.stop() }

        let url = URL(string: "ws://127.0.0.1:\(port)/dspi/v1")!
        let task = URLSession.shared.webSocketTask(with: url, protocols: ["dspi-link-1"])
        task.resume()

        // Send the client hello as a text frame carrying JSON.
        let hello = LinkMessage.helloClient(LinkHelloClient(client: LinkClientInfo(name: "Test")))
        let helloData = try hello.encoded()
        let sent = expectation(description: "hello sent")
        task.send(.string(String(decoding: helloData, as: UTF8.self))) { error in
            XCTAssertNil(error)
            sent.fulfill()
        }
        wait(for: [sent], timeout: 5)

        // Expect the hub hello back.
        let replied = expectation(description: "hub hello received")
        var reply: LinkMessage?
        task.receive { result in
            if case .success(let message) = result {
                let data: Data
                switch message {
                case .string(let s): data = Data(s.utf8)
                case .data(let d):   data = d
                @unknown default:    data = Data()
                }
                reply = try? LinkMessage.decode(data)
            }
            replied.fulfill()
        }
        wait(for: [replied], timeout: 5)

        guard case .helloHub(let hubHello)? = reply else {
            return XCTFail("expected a hello reply, got \(String(describing: reply))")
        }
        XCTAssertEqual(hubHello.hub.kind, .console)
        XCTAssertEqual(hubHello.auth, .pin)

        task.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Stop

    func testStopClearsRunning() throws {
        let (server, port) = try startServer()
        XCTAssertTrue(server.isRunning)
        XCTAssertNotNil(server.boundPort)
        _ = port
        server.stop()
        XCTAssertFalse(server.isRunning)
    }
}

// MARK: - Web bundle over HTTP

extension LinkServerTests {
    /// With the built dspi-link-js app shipped in the bundle, the hub serves
    /// it at / and advertises it.
    func testWebBundleIsServedAndAdvertised() throws {
        let usb = USBDevice(startMonitoring: false)
        let auth = LinkAuthStore(storeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("web-\(UUID().uuidString).json"))
        let policy = LinkPolicy.bundled ?? LinkPolicy.empty
        let hub = LinkHub(usb: usb, policy: policy, auth: auth)
        let server = LinkServer(hub: hub, auth: auth, policy: policy)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try XCTUnwrap(server.boundPort)

        func get(_ path: String) throws -> (Int, Data, String?) {
            let e = expectation(description: path)
            var out: (Int, Data, String?) = (0, Data(), nil)
            URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)\(path)")!) { data, resp, _ in
                let http = resp as? HTTPURLResponse
                out = (http?.statusCode ?? 0, data ?? Data(), http?.value(forHTTPHeaderField: "Content-Type"))
                e.fulfill()
            }.resume()
            wait(for: [e], timeout: 5)
            return out
        }

        let (code, body, type) = try get("/")
        XCTAssertEqual(code, 200)
        XCTAssertEqual(type, "text/html; charset=utf-8")
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("<script"), "index.html of the web app")

        let (infoCode, info, _) = try get("/dspi/v1/info")
        XCTAssertEqual(infoCode, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: info) as? [String: Any])
        XCTAssertEqual(json["web"] as? Bool, true)

        let (missing, _, _) = try get("/../Info.plist")
        XCTAssertNotEqual(missing, 200, "nothing outside the Web folder is reachable")
    }
}
