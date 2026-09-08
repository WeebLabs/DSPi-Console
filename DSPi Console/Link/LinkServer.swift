//
//  LinkServer.swift
//  DSPi Console
//
//  The NIO adapter that puts a WebSocket + HTTP front end on one LinkHub.  It
//  owns no protocol logic: every connection becomes one LinkSessionHandler and
//  this file only moves bytes between that handler and a socket.  HTTP/1 is the
//  entry point; GET /dspi/v1/info answers discovery (spec 3.2) and GET /dspi/v1
//  with the WebSocket headers upgrades to the protocol (spec 4).  See spec
//  sections 3, 4 and 5.
//

import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOFoundationCompat

final class LinkServer {
    private let hub: LinkHub
    private let auth: LinkAuthStore
    private let policy: LinkPolicy

    private var group: MultiThreadedEventLoopGroup?
    private var channel: NIOCore.Channel?
    private let lock = NSLock()

    init(hub: LinkHub, auth: LinkAuthStore, policy: LinkPolicy) {
        self.hub = hub
        self.auth = auth
        self.policy = policy
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return channel != nil
    }

    /// The port actually bound.  With `start(port: 0)` the OS picks one; read
    /// this to learn it (used by tests and by the discovery advertiser).
    var boundPort: Int? {
        lock.lock(); defer { lock.unlock() }
        return channel?.localAddress?.port
    }

    // MARK: - Lifecycle

    func start(port: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard channel == nil else { return }   // already running; start is idempotent

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let hub = self.hub, auth = self.auth, policy = self.policy

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // Refuse anything that is not on the local network before a
                // single byte of protocol runs.  The hub is LAN-only (spec 6.4).
                if let addr = channel.remoteAddress, !LinkServer.isLocalPeer(addr) {
                    return channel.close()
                }
                let httpHandler = LinkHTTPHandler(hub: hub, auth: auth)
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: LinkSessionHandler.maxFrame,
                    automaticErrorHandling: true,
                    shouldUpgrade: { channel, head in
                        LinkServer.shouldUpgrade(channel: channel, head: head)
                    },
                    upgradePipelineHandler: { channel, _ in
                        channel.pipeline.addHandler(
                            LinkWebSocketHandler(hub: hub, auth: auth, policy: policy))
                    })
                let upgradeConfig: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { context in
                        // The HTTP handler is done once the socket is a WebSocket.
                        context.channel.pipeline.removeHandler(httpHandler, promise: nil)
                    })
                return channel.pipeline
                    .configureHTTPServerPipeline(withServerUpgrade: upgradeConfig)
                    .flatMap { channel.pipeline.addHandler(httpHandler) }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        do {
            let ch = try bootstrap.bind(host: "0.0.0.0", port: port).wait()
            self.group = group
            self.channel = ch
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    func stop() {
        lock.lock()
        let ch = channel
        let grp = group
        channel = nil
        group = nil
        lock.unlock()

        try? ch?.close().wait()
        try? grp?.syncShutdownGracefully()
    }

    // MARK: - Upgrade decision

    /// Decide whether a GET can become a WebSocket.  Only /dspi/v1 that requests
    /// the `dspi-link-1` sub-protocol upgrades, and the reply echoes it (spec 4).
    /// Anything else declines (nil) and falls through to the HTTP handler, which
    /// answers 400/404.
    private static func shouldUpgrade(channel: NIOCore.Channel, head: HTTPRequestHead)
        -> EventLoopFuture<HTTPHeaders?> {
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        guard path == "/dspi/v1" else {
            return channel.eventLoop.makeSucceededFuture(nil)
        }
        let requested = head.headers[canonicalForm: "sec-websocket-protocol"]
        guard requested.contains(where: { $0.caseInsensitiveCompare("dspi-link-1") == .orderedSame }) else {
            return channel.eventLoop.makeSucceededFuture(nil)
        }
        var headers = HTTPHeaders()
        headers.add(name: "Sec-WebSocket-Protocol", value: "dspi-link-1")
        return channel.eventLoop.makeSucceededFuture(headers)
    }

    // MARK: - Peer locality

    /// True for loopback, private and link-local peers only.  A UNIX-domain or
    /// address-less peer counts as local; a routable public address does not.
    static func isLocalPeer(_ address: SocketAddress) -> Bool {
        guard let ip = address.ipAddress else { return true }
        return isLocalIP(ip)
    }

    static func isLocalIP(_ raw: String) -> Bool {
        var ip = raw.lowercased()
        if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }   // drop zone id
        // IPv4-mapped IPv6 (::ffff:192.168.0.1) is judged on its IPv4 part.
        if ip.hasPrefix("::ffff:"), ip.contains(".") {
            return isLocalIPv4(String(ip.dropFirst("::ffff:".count)))
        }
        if ip.contains(":") {
            if ip == "::1" { return true }                                 // loopback
            if ip.hasPrefix("fe8") || ip.hasPrefix("fe9")
                || ip.hasPrefix("fea") || ip.hasPrefix("feb") { return true } // fe80::/10
            if ip.hasPrefix("fc") || ip.hasPrefix("fd") { return true }    // fc00::/7 ULA
            return false
        }
        return isLocalIPv4(ip)
    }

    private static func isLocalIPv4(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        switch (p[0], p[1]) {
        case (127, _):                     return true   // 127.0.0.0/8 loopback
        case (10, _):                      return true   // 10.0.0.0/8
        case (172, 16...31):               return true   // 172.16.0.0/12
        case (192, 168):                   return true   // 192.168.0.0/16
        case (169, 254):                   return true   // 169.254.0.0/16 link-local
        default:                           return false
        }
    }
}

// MARK: - HTTP handler

/// Serves the two plain-HTTP endpoints on the port.  A GET that reaches here
/// was not upgraded, so /dspi/v1 answers 400 (upgrade required) and everything
/// but /dspi/v1/info is 404.
private final class LinkHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let hub: LinkHub
    private let auth: LinkAuthStore
    private var head: HTTPRequestHead?

    init(hub: LinkHub, auth: LinkAuthStore) {
        self.hub = hub
        self.auth = auth
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body: break
        case .end:
            guard let head = self.head else { return }
            self.head = nil
            route(context: context, head: head)
        }
    }

    private func route(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        if head.method == .GET, path == "/dspi/v1/info" {
            respond(context: context, status: .ok, body: infoJSON(),
                    extraHeaders: [("Content-Type", "application/json"),
                                   ("Access-Control-Allow-Origin", "*")])
        } else if path == "/dspi/v1" {
            respond(context: context, status: .badRequest, body: nil)
        } else {
            respond(context: context, status: .notFound, body: nil)
        }
    }

    /// The discovery document of spec 3.2.
    private func infoJSON() -> Data {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let devices = hub.registry.devices.map { ["serial": $0.info.serial, "name": $0.name] }
        let info: [String: Any] = [
            "proto": ["major": 1, "minor": 0],
            "hub": ["id": auth.hubID.uuidString.lowercased(),
                    "name": auth.hubName, "kind": "console", "version": version],
            "auth": auth.authMode.rawValue,
            "tls": false,
            "ws": "/dspi/v1",
            "devices": devices,
        ]
        return (try? JSONSerialization.data(withJSONObject: info)) ?? Data("{}".utf8)
    }

    private func respond(context: ChannelHandlerContext, status: HTTPResponseStatus,
                         body: Data?, extraHeaders: [(String, String)] = []) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: String(body?.count ?? 0))
        for (k, v) in extraHeaders { headers.add(name: k, value: v) }
        headers.add(name: "Connection", value: "close")
        let responseHead = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        if let body = body {
            var buf = context.channel.allocator.buffer(capacity: body.count)
            buf.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}

// MARK: - WebSocket handler

/// One of these per upgraded connection.  It owns a LinkSessionHandler, decodes
/// inbound frames into text/binary the handler understands, reassembles
/// fragmented messages, answers pings, and writes the handler's outbound frames
/// back.  The handler is not thread-safe, so every call into it runs on this
/// channel's event loop; the emit closure hops back onto the loop because the
/// hub delivers notifications on arbitrary queues.
private final class LinkWebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let hub: LinkHub
    private let auth: LinkAuthStore
    private let policy: LinkPolicy

    private var session: LinkSessionHandler?
    private var channel: NIOCore.Channel?

    // Fragmented-message reassembly (spec 4: one message may span frames).
    private var fragmentOpcode: WebSocketOpcode?
    private var fragmentBuffer: ByteBuffer?

    private var keepalive: RepeatedTask?
    private var authTimeout: Scheduled<Void>?

    private static let pingInterval: TimeAmount = .seconds(10)
    private static let authDeadline: TimeAmount = .seconds(30)

    init(hub: LinkHub, auth: LinkAuthStore, policy: LinkPolicy) {
        self.hub = hub
        self.auth = auth
        self.policy = policy
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        let eventLoop = context.eventLoop
        self.channel = channel
        let peer = channel.remoteAddress?.ipAddress ?? "?"

        self.session = LinkSessionHandler(hub: hub, auth: auth, policy: policy, peer: peer) { [weak self] outbound in
            if eventLoop.inEventLoop {
                self?.send(outbound)
            } else {
                eventLoop.execute { self?.send(outbound) }
            }
        }

        // Keepalive: ping every 10 s (spec 4).  The client's pongs keep it alive;
        // an unresponsive one is dropped when the TCP connection dies.
        keepalive = eventLoop.scheduleRepeatedTask(initialDelay: Self.pingInterval,
                                                   delay: Self.pingInterval) { [weak self] _ in
            self?.sendPing()
        }
        // Close an unauthenticated connection after 30 s (spec 5, close 4001).
        authTimeout = eventLoop.scheduleTask(in: Self.authDeadline) { [weak self] in
            guard let self = self, let session = self.session, !session.isAuthenticated else { return }
            self.send(.close(4001))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        teardown()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        teardown()
    }

    private func teardown() {
        keepalive?.cancel()
        keepalive = nil
        authTimeout?.cancel()
        authTimeout = nil
        session?.connectionClosed()
        session = nil
        channel = nil
    }

    // MARK: Inbound

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .connectionClose:
            // Echo a normal close and let the channel go.
            var payload = context.channel.allocator.buffer(capacity: 2)
            payload.writeInteger(UInt16(1000), endianness: .big)
            let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: payload)
            context.writeAndFlush(wrapOutboundOut(close)).whenComplete { _ in
                context.close(promise: nil)
            }
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .pong:
            break   // keepalive answered; nothing to do
        case .text:
            deliver(opcode: .text, frame: frame)
        case .binary:
            deliver(opcode: .binary, frame: frame)
        case .continuation:
            continueFragment(frame)
        default:
            break
        }
    }

    /// A text or binary frame.  If it is final it is one whole message; if not
    /// it opens a fragmented message closed by continuation frames.  The
    /// reassembled message is bounded at the advertised max_frame; a peer that
    /// exceeds it, authenticated or not, is closed rather than buffered.
    private func deliver(opcode: WebSocketOpcode, frame: WebSocketFrame) {
        if frame.fin {
            dispatch(opcode: opcode, data: Data(frame.unmaskedData.readableBytesView))
        } else {
            fragmentOpcode = opcode
            fragmentBuffer = frame.unmaskedData
            if fragmentBuffer!.readableBytes > LinkSessionHandler.maxFrame { overflow() }
        }
    }

    private func continueFragment(_ frame: WebSocketFrame) {
        guard let opcode = fragmentOpcode, var buffer = fragmentBuffer else { return }
        var more = frame.unmaskedData
        guard buffer.readableBytes + more.readableBytes <= LinkSessionHandler.maxFrame else {
            return overflow()
        }
        buffer.writeBuffer(&more)
        fragmentBuffer = buffer
        if frame.fin {
            dispatch(opcode: opcode, data: Data(buffer.readableBytesView))
            fragmentOpcode = nil
            fragmentBuffer = nil
        }
    }

    private func overflow() {
        fragmentOpcode = nil
        fragmentBuffer = nil
        send(.close(4000))
    }

    private func dispatch(opcode: WebSocketOpcode, data: Data) {
        switch opcode {
        case .text:   session?.receiveText(data)
        case .binary: session?.receiveBinary(data)
        default:      break
        }
    }

    // MARK: Outbound

    private func send(_ outbound: LinkOutbound) {
        guard let channel = channel else { return }
        switch outbound {
        case .text(let data):
            var buf = channel.allocator.buffer(capacity: data.count)
            buf.writeBytes(data)
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buf), promise: nil)
        case .binary(let data):
            var buf = channel.allocator.buffer(capacity: data.count)
            buf.writeBytes(data)
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: buf), promise: nil)
        case .close(let code):
            var buf = channel.allocator.buffer(capacity: 2)
            buf.writeInteger(code, endianness: .big)
            let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: buf)
            channel.writeAndFlush(frame).whenComplete { _ in channel.close(promise: nil) }
        }
    }

    private func sendPing() {
        guard let channel = channel else { return }
        let frame = WebSocketFrame(fin: true, opcode: .ping, data: channel.allocator.buffer(capacity: 0))
        channel.writeAndFlush(frame, promise: nil)
    }
}

// The network service starts and stops this server; the protocol lets the
// service build and test without NIO present.
extension LinkServer: LinkServing {}
