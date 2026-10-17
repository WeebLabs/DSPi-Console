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

// MARK: - Misbehaving clients

/// A bare-socket WebSocket client, for what URLSession will not do: stop
/// reading, or never answer a ping.
final class RawWebSocketClient {
    private let fd: Int32

    /// `receiveBuffer` shrinks the socket's receive window so a client that
    /// never reads backs the server up quickly.
    init(port: Int, receiveBuffer: Int32? = nil) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("socket() failed") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if var size = receiveBuffer {
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { close(fd); throw XCTSkip("connect() failed") }
    }

    deinit { close(fd) }

    /// HTTP upgrade to dspi-link-1; reads only the response head, so no
    /// WebSocket bytes are consumed.
    func upgrade(port: Int) throws {
        let request = "GET /dspi/v1 HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: dspi-link-1\r\n\r\n"
        try write(Data(request.utf8))
        var head = Data()
        while head.suffix(4) != Data("\r\n\r\n".utf8) {
            var byte: UInt8 = 0
            guard recv(fd, &byte, 1, 0) == 1 else { throw XCTSkip("upgrade read failed") }
            head.append(byte)
        }
        guard String(decoding: head, as: UTF8.self).hasPrefix("HTTP/1.1 101") else {
            throw XCTSkip("upgrade refused")
        }
    }

    /// One masked text frame (clients must mask, RFC 6455 5.3).
    func sendText(_ payload: Data) throws {
        var frame = Data([0x81])
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else {
            frame.append(0x80 | 126)
            frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 0xFF))
        }
        let key: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        frame.append(contentsOf: key)
        for (i, b) in payload.enumerated() { frame.append(b ^ key[i % 4]) }
        try write(frame)
    }

    /// Read frames, answering nothing, until a close frame arrives; returns
    /// its code, or nil if the socket ended or timed out first.
    func readUntilClose() -> UInt16? {
        func read(_ n: Int) -> Data? {
            var out = Data()
            var buf = [UInt8](repeating: 0, count: n)
            while out.count < n {
                let got = recv(fd, &buf, n - out.count, 0)
                guard got > 0 else { return nil }
                out.append(contentsOf: buf[0..<got])
            }
            return out
        }
        while let h = read(2) {
            let opcode = h[0] & 0x0F
            var length = Int(h[1] & 0x7F)
            if length == 126 { guard let l = read(2) else { return nil }; length = Int(l[0]) << 8 | Int(l[1]) }
            else if length == 127 { guard let l = read(8) else { return nil }; length = l.reduce(0) { $0 << 8 | Int($1) } }
            guard let body = length > 0 ? read(length) : Data() else { return nil }
            if opcode == 0x8 {
                return body.count >= 2 ? UInt16(body[0]) << 8 | UInt16(body[1]) : 1005
            }
        }
        return nil
    }

    private func write(_ data: Data) throws {
        let sent = data.withUnsafeBytes { send(fd, $0.baseAddress, data.count, 0) }
        guard sent == data.count else { throw XCTSkip("send() failed") }
    }
}

extension LinkServerTests {
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    /// Open access, so a hello alone opens a session.
    private func startOpenServer(_ tune: (inout LinkServerTuning) -> Void) throws -> (LinkServer, LinkHub, Int) {
        let (hub, auth, policy) = makeStack()
        auth.authMode = LinkAuthMode.none
        let server = LinkServer(hub: hub, auth: auth, policy: policy)
        tune(&server.tuning)
        try server.start(port: 0)
        let port = try XCTUnwrap(server.boundPort)
        return (server, hub, port)
    }

    private func helloData() throws -> Data {
        try LinkMessage.helloClient(LinkHelloClient(client: LinkClientInfo(name: "Raw"))).encoded()
    }

    /// A client that stops reading must not grow the server's write buffer
    /// without bound: the server sheds NOTIFY and, once the socket has been
    /// unwritable past the stall deadline, closes the connection.
    func testClientThatStopsReadingIsClosedAtTheStallDeadline() throws {
        let (server, hub, port) = try startOpenServer {
            $0.writeBufferLow = 1024
            $0.writeBufferHigh = 4096
            $0.stallDeadline = 0.3
        }
        defer { server.stop() }
        let client = try RawWebSocketClient(port: port, receiveBuffer: 4096)
        try client.upgrade(port: port)
        try client.sendText(try helloData())
        XCTAssertTrue(waitUntil(5) { hub.sessionCount == 1 }, "hello opens a session")

        let packet = makeParamChangedPacket(source: 0)
        let closed = waitUntil(10) {
            for _ in 0..<500 {
                hub.ingest(LinkNotification(packet: packet, origin: 0, receivedAt: Date()))
            }
            return hub.sessionCount == 0
        }
        XCTAssertTrue(closed, "a client that never reads is closed, not buffered forever")
        withExtendedLifetime(client) {}
    }
}
