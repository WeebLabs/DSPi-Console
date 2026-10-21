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
import dnssd

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
    /// Why browsing is not delivering results, when the system says: a denied
    /// Local Network permission leaves the browser waiting for good.
    @Published private(set) var browseError: String?

    /// Resolves a Bonjour service endpoint to the host and port to dial.  nil
    /// means the attempt failed and the browser will retry.  The returned
    /// cancellable abandons the attempt without calling back.  Injected so
    /// tests need no network.
    typealias Resolver = (_ endpoint: NWEndpoint,
                          _ completion: @escaping ((host: String, port: Int)?) -> Void) -> AnyCancellable

    private var browser: NWBrowser?
    /// True between start() and stop(), so a browser that fails is rebuilt.
    private var wantBrowsing = false
    private var restartWork: DispatchWorkItem?
    private var manual: [DiscoveredHub] = []
    private var browsed: [String: DiscoveredHub] = [:]   // keyed by service name
    private var endpoints: [String: NWEndpoint] = [:]
    /// The attempt in flight per service.  The token tells a late result from
    /// an earlier attempt apart from the current one's.
    private var resolvers: [String: (token: UUID, attempt: AnyCancellable)] = [:]
    private var resolveRetries: [String: DispatchWorkItem] = [:]
    private var resolveFailures: [String: Int] = [:]

    /// This Console's own hub id.  Bonjour hands back our own advertisement
    /// along with everyone else's; it is not an "other" hub.
    private let ownHubID: String?
    /// Fetches a hub's info document; injected so tests need no server.
    private let fetchInfo: (URL, @escaping (Data?) -> Void) -> Void
    private let resolver: Resolver
    /// First retry after a failed resolve; doubles up to 30 s.  Tests shorten it.
    var resolveRetryBase: TimeInterval = 1
    /// How long a dead browser waits before it is rebuilt.
    var browserRestartDelay: TimeInterval = 1

    init(ownHubID: String? = nil,
         fetchInfo: @escaping (URL, @escaping (Data?) -> Void) -> Void = HubBrowser.fetchOverHTTP,
         resolver: @escaping Resolver = HubBrowser.resolveOverTCP) {
        self.ownHubID = ownHubID?.lowercased()
        self.fetchInfo = fetchInfo
        self.resolver = resolver
    }

    nonisolated static func fetchOverHTTP(_ url: URL, _ completion: @escaping (Data?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in completion(data) }.resume()
    }

    func start() {
        wantBrowsing = true
        startBrowser()
    }

    private func startBrowser() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: LinkDiscovery.serviceType, domain: nil),
                          using: params)
        // Callbacks name the browser they came from: a cancelled browser can
        // still fire after its replacement started, and must not touch it.
        b.stateUpdateHandler = { [weak self, weak b] state in
            Task { @MainActor in
                guard let self = self, let b = b, self.browser === b else { return }
                self.browserStateChanged(state)
            }
        }
        b.browseResultsChangedHandler = { [weak self, weak b] results, changes in
            Task { @MainActor in
                guard let self = self, let b = b, self.browser === b else { return }
                self.apply(results, changes: changes)
            }
        }
        b.start(queue: .global(qos: .utility))
        browser = b
    }

    /// A browser that fails (an interface change, a lost daemon connection)
    /// never recovers on its own; it is cancelled and rebuilt.  One that waits
    /// (Local Network permission denied) keeps trying by itself, so only the
    /// reason is shown.
    private func browserStateChanged(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            isBrowsing = true
            browseError = nil
        case .waiting(let error):
            isBrowsing = false
            browseError = Self.describe(error)
        case .failed(let error):
            isBrowsing = false
            browseError = Self.describe(error)
            browser?.cancel()
            browser = nil
            scheduleBrowserRestart()
        case .cancelled:
            isBrowsing = false
        default:
            break
        }
    }

    private func scheduleBrowserRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.wantBrowsing else { return }
            self.restartWork = nil
            self.startBrowser()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + browserRestartDelay, execute: work)
    }

    private static func describe(_ error: NWError) -> String {
        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
            return "Local network access is not allowed for Console. Allow it in System Settings, Privacy & Security, Local Network."
        }
        return "Could not look for hubs: \(error.localizedDescription)"
    }

    /// Stop browsing and forget every browsed hub, so the next start resolves
    /// each one afresh.  Manual entries stay.
    func stop() {
        wantBrowsing = false
        restartWork?.cancel(); restartWork = nil
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.attempt.cancel() }
        resolvers.removeAll()
        resolveRetries.values.forEach { $0.cancel() }
        resolveRetries.removeAll()
        resolveFailures.removeAll()
        browsed.removeAll()
        endpoints.removeAll()
        isBrowsing = false
        browseError = nil
        publish()
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

    private func apply(_ results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        // Only a service Bonjour reports as new or changed is re-resolved; a
        // TXT update on one hub is no reason to dial every other.
        var changed = Set<String>()
        for change in changes {
            switch change {
            case .added(let r), .changed(_, let r, _):
                if case let .service(name, _, _, _) = r.endpoint { changed.insert(name) }
            default:
                break
            }
        }
        ingest(results.compactMap { result in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            if case let .bonjour(txt) = result.metadata { return (name, txt, result.endpoint) }
            return (name, nil, result.endpoint)
        }, changed: changed)
    }

    /// One browse snapshot.  Internal so a test can feed services without
    /// Bonjour; a nil TXT keeps whatever is already known for that name.  A
    /// service in `changed` (default: all of them) is resolved again even when
    /// an address is already known, since a hub that moved to a new lease
    /// re-announces the same name: the old address stays listed until the
    /// new one arrives.
    func ingest(_ services: [(name: String, txt: NWTXTRecord?, endpoint: NWEndpoint)],
                changed: Set<String>? = nil) {
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
            endpoints[name] = endpoint
            // An endpoint that already carries an address has nothing to resolve.
            if case .hostPort = endpoint { continue }
            if hub.host.isEmpty || changed?.contains(name) ?? true { resolve(name: name) }
        }
        for name in browsed.keys where !seen.contains(name) { forget(name) }
        publish()
    }

    private func forget(_ name: String) {
        browsed[name] = nil
        endpoints[name] = nil
        resolvers[name]?.attempt.cancel(); resolvers[name] = nil
        resolveRetries[name]?.cancel(); resolveRetries[name] = nil
        resolveFailures[name] = nil
    }

    /// Resolve a hub's address again, now.  The composite asks when a
    /// connection to the hub fails: the socket may have died because the hub
    /// is on a new address.
    func refreshAddress(ofHub id: String) {
        guard let name = browsed.first(where: { $0.value.id == id })?.key else { return }
        resolve(name: name)
    }

    /// Bonjour gives a service endpoint, not an address; a throwaway
    /// connection resolves it to the host and port to dial.  One attempt per
    /// service at a time; a failure is retried with backoff until the service
    /// leaves the browse results.
    private func resolve(name: String) {
        guard resolvers[name] == nil, let endpoint = endpoints[name] else { return }
        resolveRetries[name]?.cancel(); resolveRetries[name] = nil
        let token = UUID()
        let attempt = resolver(endpoint) { [weak self] result in
            Task { @MainActor in self?.resolved(name, token: token, result) }
        }
        resolvers[name] = (token, attempt)
    }

    /// A result that hopped to the main actor after its attempt was abandoned
    /// (the service left and came back, starting a new attempt) is ignored,
    /// or it would cancel the attempt now in flight.
    private func resolved(_ name: String, token: UUID, _ result: (host: String, port: Int)?) {
        guard resolvers[name]?.token == token else { return }
        resolvers[name] = nil
        guard var hub = browsed[name] else { return }
        guard let (host, port) = result else {
            let failures = (resolveFailures[name] ?? 0) + 1
            resolveFailures[name] = failures
            let delay = min(30, resolveRetryBase * pow(2, Double(failures - 1)))
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.resolveRetries[name] = nil
                self.resolve(name: name)
            }
            resolveRetries[name] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return
        }
        resolveFailures[name] = nil
        guard hub.host != host || hub.port != port else { return }
        hub.host = host
        hub.port = port
        browsed[name] = hub
        publish()
    }

    /// The default resolver: a TCP connection to the service, read for its
    /// remote address once it is up and dropped at once.  `.waiting` (no
    /// route yet) is bounded by the timeout rather than left to sit.
    nonisolated static func resolveOverTCP(_ endpoint: NWEndpoint,
                                           _ completion: @escaping ((host: String, port: Int)?) -> Void)
        -> AnyCancellable {
        let attempt = ResolveAttempt(connection: NWConnection(to: endpoint, using: .tcp), completion: completion)
        attempt.start()
        return AnyCancellable { attempt.abandon() }
    }

    nonisolated private static let resolveTimeout: TimeInterval = 5

    /// One resolve in flight: completes exactly once, or not at all when
    /// abandoned, whichever of ready, failure, timeout or cancel comes first.
    private final class ResolveAttempt: @unchecked Sendable {
        private let connection: NWConnection
        private let completion: ((host: String, port: Int)?) -> Void
        private let lock = NSLock()
        private var settled = false
        private let queue = DispatchQueue.global(qos: .utility)

        init(connection: NWConnection, completion: @escaping ((host: String, port: Int)?) -> Void) {
            self.connection = connection
            self.completion = completion
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    guard let remote = self.connection.currentPath?.remoteEndpoint,
                          case let .hostPort(host, port) = remote else { return self.finish(nil) }
                    self.finish((HubBrowser.hostText(host), Int(port.rawValue)))
                case .failed, .cancelled:
                    self.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + HubBrowser.resolveTimeout) { [weak self] in self?.finish(nil) }
        }

        private func finish(_ result: (host: String, port: Int)?) {
            guard settle() else { return }
            connection.cancel()
            completion(result)
        }

        func abandon() {
            guard settle() else { return }
            connection.cancel()
        }

        private func settle() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !settled else { return false }
            settled = true
            return true
        }
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
