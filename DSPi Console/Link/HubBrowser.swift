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
    /// Where to connect.  For a browsed service the endpoint; for a manual
    /// entry the host and port.
    var host: String
    var port: Int
    var isManual: Bool

    /// The WebSocket URL to open.
    var webSocketURL: URL? {
        URL(string: "\(tls ? "wss" : "ws")://\(host):\(port)\(path)")
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

    /// Add a hub by "host" or "host:port".  Resolved to a real id on hello.
    func addManual(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var host = trimmed, port = LinkDiscovery.defaultPort
        if let colon = trimmed.lastIndex(of: ":"), let p = Int(trimmed[trimmed.index(after: colon)...]) {
            host = String(trimmed[..<colon]); port = p
        }
        let hub = DiscoveredHub(id: "manual:\(host):\(port)", name: host, kind: "unknown",
                                authMode: "pin", deviceCount: 0, serials: [], path: "/dspi/v1",
                                tls: false, host: host, port: port, isManual: true)
        manual.removeAll { $0.id == hub.id }
        manual.append(hub)
        publish()
    }

    func removeManual(_ hub: DiscoveredHub) {
        manual.removeAll { $0.id == hub.id }
        publish()
    }

    // MARK: - Browsing

    private func apply(_ results: Set<NWBrowser.Result>) {
        var seen = Set<String>()
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            seen.insert(name)
            guard case let .bonjour(txt) = result.metadata else { continue }
            var hub = Self.hub(fromTXT: txt, serviceName: name)
            // Keep an already resolved host/port; resolve the rest.
            if let known = browsed[name] { hub.host = known.host; hub.port = known.port }
            browsed[name] = hub
            if hub.host.isEmpty { resolve(name: name, endpoint: result.endpoint) }
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
            let hostText: String
            switch host {
            case .ipv4(let a): hostText = "\(a)"
            case .ipv6(let a): hostText = "[\(a)]"
            case .name(let n, _): hostText = n
            @unknown default: hostText = "\(host)"
            }
            Task { @MainActor in
                guard let self = self, var hub = self.browsed[name] else { return }
                hub.host = hostText.replacingOccurrences(of: "%.*", with: "", options: .regularExpression)
                hub.port = Int(port.rawValue)
                self.browsed[name] = hub
                self.resolvers[name]?.cancel(); self.resolvers[name] = nil
                self.publish()
            }
        }
        resolvers[name] = conn
        conn.start(queue: .global(qos: .utility))
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
