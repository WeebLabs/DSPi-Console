//
//  HubBrowser.swift
//  DSPi Console
//
//  Finds DSPi Link hubs on the local network by browsing for _dspi._tcp and
//  decoding each service's TXT record (spec 3.1), and lets the user add a hub
//  by typed address (spec 3.3).  Publishes the list for the device picker.
//

import Foundation
import Network
import Combine

/// A hub as discovered or entered, before connecting to it.
struct DiscoveredHub: Identifiable, Equatable {
    /// The hub id from TXT, or a synthetic id for a manually entered address
    /// until its hello tells us the real one.
    var id: String
    var name: String
    var kind: String
    var authMode: String
    var deviceCount: Int
    var serials: [String]
    var path: String
    var tls: Bool
    /// Where to connect.  For a browsed service the resolved address; for a
    /// manual entry what the user typed.  IPv6 literals are stored without
    /// brackets and keep their zone ID ("fe80::1%en0"): a link-local address
    /// is unroutable without it on a Mac with several interfaces.
    var host: String
    var port: Int
    var isManual: Bool
    /// A typed address that turned out to be this Console's own hub.  Kept
    /// in the list so the user can remove it, never offered as a device source.
    var isSelf = false

    private var isIPv6Literal: Bool { host.contains(":") }

    /// The WebSocket URL to open.  A zone ID is written "%25" (RFC 6874),
    /// which URLSession accepts; a raw "%" makes URL(string:) fail.
    var webSocketURL: URL? {
        let urlHost = isIPv6Literal
            ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
        return URL(string: "\(tls ? "wss" : "ws")://\(urlHost):\(port)\(path)")
    }

    /// The plain-HTTP discovery endpoint (spec 3.2), which names the hub.
    var infoURL: URL? {
        guard var url = webSocketURL?.absoluteString else { return nil }
        url = url.replacingOccurrences(of: tls ? "wss://" : "ws://", with: tls ? "https://" : "http://")
        return URL(string: url + "/info")
    }

    /// "host:port" for display, bracketing an IPv6 literal.
    var displayAddress: String {
        isIPv6Literal ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

@MainActor
final class HubBrowser: ObservableObject {
    @Published private(set) var hubs: [DiscoveredHub] = []
    @Published private(set) var isBrowsing = false

    private var browser: NWBrowser?
    private var manual: [DiscoveredHub] = []
    private var browsed: [String: DiscoveredHub] = [:]   // keyed by service name
    private var resolvers: [String: NWConnection] = [:]

    /// This Console's own hub id.  Bonjour hands back our own advertisement
    /// along with everyone else's; it is not an "other" hub.
    private let ownHubID: String?
    /// Fetches a hub's info document; injected so tests need no server.
    private let fetchInfo: (URL, @escaping (Data?) -> Void) -> Void

    init(ownHubID: String? = nil,
         fetchInfo: @escaping (URL, @escaping (Data?) -> Void) -> Void = HubBrowser.fetchOverHTTP) {
        self.ownHubID = ownHubID?.lowercased()
        self.fetchInfo = fetchInfo
    }

    nonisolated static func fetchOverHTTP(_ url: URL, _ completion: @escaping (Data?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in completion(data) }.resume()
    }

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: LinkDiscovery.serviceType, domain: nil),
                          using: params)
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.isBrowsing = (state == .ready) }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.apply(results) }
        }
        b.start(queue: .global(qos: .utility))
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        isBrowsing = false
    }

    /// Split "host", "host:port", "[v6]", "[v6]:port" or a bare IPv6
    /// literal into host and port.  A bare literal has several colons, so its
    /// last group is never mistaken for a port.
    nonisolated static func parseAddress(_ text: String) -> (host: String, port: Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let defaultPort = LinkDiscovery.defaultPort
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty { return host.isEmpty ? nil : (host, defaultPort) }
            guard rest.hasPrefix(":"), let p = Int(rest.dropFirst()), !host.isEmpty else { return nil }
            return (host, p)
        }
        if trimmed.filter({ $0 == ":" }).count > 1 { return (trimmed, defaultPort) }
        if let colon = trimmed.lastIndex(of: ":") {
            guard let p = Int(trimmed[trimmed.index(after: colon)...]) else { return nil }
            let host = String(trimmed[..<colon])
            return host.isEmpty ? nil : (host, p)
        }
        return (trimmed, defaultPort)
    }

    /// Add a hub by typed address (see parseAddress).  Resolved to a real id
    /// on hello.
    func addManual(_ text: String) {
        guard let (host, port) = Self.parseAddress(text) else { return }
        let hub = DiscoveredHub(id: "manual:\(host):\(port)", name: host, kind: "unknown",
                                authMode: "pin", deviceCount: 0, serials: [], path: "/dspi/v1",
                                tls: false, host: host, port: port, isManual: true)
        manual.removeAll { $0.id == hub.id }
        manual.append(hub)
        publish()
        checkManualIsSelf(hub)
    }

    /// A typed address carries no hub id until something asks.  The info
    /// endpoint answers without a session, so ask it whether this is us.
    private func checkManualIsSelf(_ hub: DiscoveredHub) {
        guard let own = ownHubID, let url = hub.infoURL else { return }
        let id = hub.id
        fetchInfo(url) { [weak self] data in
            struct Info: Decodable { struct Hub: Decodable { let id: String }; let hub: Hub }
            guard let data = data, let info = try? JSONDecoder().decode(Info.self, from: data),
                  info.hub.id.lowercased() == own else { return }
            Task { @MainActor in
                guard let self = self, let index = self.manual.firstIndex(where: { $0.id == id }) else { return }
                self.manual[index].isSelf = true
                self.publish()
            }
        }
    }

    func removeManual(_ hub: DiscoveredHub) {
        manual.removeAll { $0.id == hub.id }
        publish()
    }

    // MARK: - Browsing

    private func apply(_ results: Set<NWBrowser.Result>) {
        ingest(results.compactMap { result in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            if case let .bonjour(txt) = result.metadata { return (name, txt, result.endpoint) }
            return (name, nil, result.endpoint)
        })
    }

    /// One browse snapshot.  Internal so a test can feed services without
    /// Bonjour; a nil TXT keeps whatever is already known for that name.
    func ingest(_ services: [(name: String, txt: NWTXTRecord?, endpoint: NWEndpoint)]) {
        var seen = Set<String>()
        for (name, txt, endpoint) in services {
            seen.insert(name)
            guard let txt = txt else { continue }
            var hub = Self.hub(fromTXT: txt, serviceName: name)
            // Left out of `seen`, so the sweep below drops it if it was listed.
            if let own = ownHubID, hub.id.lowercased() == own { seen.remove(name); continue }
            // Keep an already resolved host/port; resolve the rest.
            if let known = browsed[name] { hub.host = known.host; hub.port = known.port }
            if hub.host.isEmpty, case let .hostPort(host, port) = endpoint {
                hub.host = Self.hostText(host); hub.port = Int(port.rawValue)
            }
            browsed[name] = hub
            if hub.host.isEmpty { resolve(name: name, endpoint: endpoint) }
        }
        for name in browsed.keys where !seen.contains(name) {
            browsed[name] = nil
            resolvers[name]?.cancel(); resolvers[name] = nil
        }
        publish()
    }

    /// Bonjour gives a service endpoint, not an address; a throwaway
    /// connection resolves it to the host and port to dial.
    private func resolve(name: String, endpoint: NWEndpoint) {
        guard resolvers[name] == nil else { return }
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard case .ready = state, let path = conn?.currentPath,
                  let remote = path.remoteEndpoint,
                  case let .hostPort(host, port) = remote else { return }
            let hostText = Self.hostText(host)
            Task { @MainActor in
                guard let self = self, var hub = self.browsed[name] else { return }
                hub.host = hostText
                hub.port = Int(port.rawValue)
                self.browsed[name] = hub
                self.resolvers[name]?.cancel(); self.resolvers[name] = nil
                self.publish()
            }
        }
        resolvers[name] = conn
        conn.start(queue: .global(qos: .utility))
    }

    /// The resolved address as DiscoveredHub.host stores it.  Bonjour on a
    /// LAN without IPv6 routing resolves to a link-local address, so the zone
    /// ID must survive; add it from the interface if the text lacks it.
    nonisolated static func hostText(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let a):
            return "\(a)".components(separatedBy: "%")[0]
        case .ipv6(let a):
            let text = "\(a)"
            if a.isLinkLocal, !text.contains("%"), let iface = a.interface {
                return "\(text)%\(iface.name)"
            }
            return text
        case .name(let n, _):
            return n
        @unknown default:
            return "\(host)"
        }
    }

    private func publish() {
        hubs = browsed.values.filter { !$0.host.isEmpty }.sorted { $0.name < $1.name } + manual
    }

    /// Decode the TXT keys of spec 3.1.  Unknown keys are ignored.
    static func hub(fromTXT txt: NWTXTRecord, serviceName: String) -> DiscoveredHub {
        func s(_ k: String) -> String? { if case let .string(v)? = txt.getEntry(for: k) { return v }; return nil }
        return DiscoveredHub(
            id: s("hid") ?? "service:\(serviceName)",
            name: serviceName,
            kind: s("kind") ?? "console",
            authMode: s("auth") ?? "pin",
            deviceCount: Int(s("n") ?? "") ?? 0,
            serials: (s("d") ?? "").split(separator: ",").map(String.init),
            path: s("path") ?? "/dspi/v1",
            tls: s("tls") == "1",
            host: "", port: 0, isManual: false)
    }
}
