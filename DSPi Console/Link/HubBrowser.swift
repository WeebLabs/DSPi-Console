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
import os

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

    /// How often a running search is restarted.  A long-lived Bonjour browse
    /// re-queries ever more rarely (mDNSResponder backs off to once an hour),
    /// so a hub whose announcement was lost, or that was dropped after a
    /// missed query (an ESP32 on Wi-Fi misses multicast often), stayed
    /// unlisted for hours until the user turned the search off and on.  A
    /// restart is what that toggle did: a new browse queries at once.
    var refreshInterval: TimeInterval = 30
    /// Gap between cancelling the old browser and starting the new one.  A
    /// browse started while the old one is still registered joins it as a
    /// duplicate and inherits its backed-off schedule instead of querying.
    var refreshGap: TimeInterval = 1
    /// How long after a restart the new browser's results only add hubs.  Its
    /// first snapshot can be partial; absence counts only once it settles.
    var refreshSettle: TimeInterval = 5
    private var refreshWork: DispatchWorkItem?
    /// Bumped by every restart and by stop(), so a restart's delayed steps
    /// know whether they are still the current one.
    private var refreshGeneration = 0
    /// Names the restarted browser has reported, while its settle window is
    /// open; nil outside the window.
    private var seenSinceRefresh: Set<String>?
    private var resultsSinceRefresh = false
    private var browserReady = false
    /// Browsers started so far; lets a test see the restarts.
    private(set) var browserStarts = 0

    /// Resolve failures in a row before mDNSResponder is asked to reconfirm
    /// the hub's record.  One missed query is no evidence the hub is gone,
    /// and a reconfirm that also goes unanswered removes it from the browse.
    nonisolated static let reconfirmAfterFailures = 3

    /// False in tests: start and restart only count, and results are fed by
    /// hand through `ingest`, so no real hub on the test machine's network
    /// leaks in.
    var usesSystemBrowser = true
    private static let log = Logger(subsystem: "WeebLabs.DSPi-Console", category: "link")

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
        scheduleRefresh()
    }

    private func startBrowser() {
        guard browser == nil else { return }
        browserReady = false
        browserStarts += 1
        guard usesSystemBrowser else { return }
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
            browserReady = true
            isBrowsing = true
            browseError = nil
        case .waiting(let error):
            Self.log.notice("hub browser waiting: \(error.localizedDescription, privacy: .public)")
            browserReady = false
            isBrowsing = false
            browseError = Self.describe(error)
        case .failed(let error):
            Self.log.notice("hub browser failed, rebuilding: \(error.localizedDescription, privacy: .public)")
            browserReady = false
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

    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.wantBrowsing else { return }
            self.refreshWork = nil
            self.refresh()
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + refreshInterval, execute: work)
    }

    /// Restart the search without forgetting what it has found: cancel the
    /// browser, start a new one after `refreshGap`, and let the new one's
    /// results only add hubs until `refreshSettle` has passed.  Internal so a
    /// test can run one on demand.
    func refresh() {
        guard wantBrowsing else { return }
        Self.log.debug("hub browser: restarting the search")
        refreshGeneration += 1
        let generation = refreshGeneration
        restartWork?.cancel(); restartWork = nil
        browser?.cancel()
        browser = nil
        seenSinceRefresh = []
        resultsSinceRefresh = false
        DispatchQueue.main.asyncAfter(deadline: .now() + refreshGap) { [weak self] in
            guard let self = self, self.wantBrowsing, self.refreshGeneration == generation else { return }
            self.startBrowser()
            DispatchQueue.main.asyncAfter(deadline: .now() + self.refreshSettle) { [weak self] in
                guard let self = self, self.refreshGeneration == generation else { return }
                self.endRefreshWindow()
            }
        }
        scheduleRefresh()
    }

    /// The restarted browser has had its chance to report: drop what it did
    /// not.  A browser that neither reported nor became ready (still waiting,
    /// or failed and rebuilding) is no evidence, so nothing is dropped then.
    private func endRefreshWindow() {
        guard let seen = seenSinceRefresh else { return }
        seenSinceRefresh = nil
        guard resultsSinceRefresh || browserReady else { return }
        for name in browsed.keys where !seen.contains(name) { forget(name) }
        publish()
    }

    /// Stop browsing and forget every browsed hub, so the next start resolves
    /// each one afresh.  Manual entries stay.
    func stop() {
        wantBrowsing = false
        restartWork?.cancel(); restartWork = nil
        refreshWork?.cancel(); refreshWork = nil
        refreshGeneration += 1
        seenSinceRefresh = nil
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
    ///
    /// While a restart's settle window is open, absence removes nothing and a
    /// hub already resolved is not dialled again: the new browser reports
    /// every cached service as added, which says nothing about its address.
    func ingest(_ services: [(name: String, txt: NWTXTRecord?, endpoint: NWEndpoint)],
                changed: Set<String>? = nil) {
        let settling = seenSinceRefresh != nil
        var seen = Set<String>()
        for (name, txt, endpoint) in services {
            seen.insert(name)
            guard let txt = txt else {
                if browsed[name] == nil { Self.log.notice("hub \(name, privacy: .public) seen without its TXT record yet") }
                continue
            }
            var hub = Self.hub(fromTXT: txt, serviceName: name)
            // Left out of `seen`, so the sweep below drops it if it was listed.
            if let own = ownHubID, hub.id.lowercased() == own { seen.remove(name); continue }
            if browsed[name] == nil {
                Self.log.notice("hub \(name, privacy: .public) found (kind \(hub.kind, privacy: .public))")
            }
            // Keep an already resolved host/port; resolve the rest.
            if let known = browsed[name] { hub.host = known.host; hub.port = known.port }
            if hub.host.isEmpty, case let .hostPort(host, port) = endpoint {
                hub.host = Self.hostText(host); hub.port = Int(port.rawValue)
            }
            browsed[name] = hub
            endpoints[name] = endpoint
            // An endpoint that already carries an address has nothing to resolve.
            if case .hostPort = endpoint { continue }
            let announced = changed?.contains(name) ?? true
            if hub.host.isEmpty || (announced && !settling) { resolve(name: name) }
        }
        if settling {
            seenSinceRefresh?.formUnion(seen)
            resultsSinceRefresh = true
        } else {
            for name in browsed.keys where !seen.contains(name) { forget(name) }
        }
        publish()
    }

    private func forget(_ name: String) {
        if browsed[name] != nil { Self.log.notice("hub \(name, privacy: .public) gone from the browse") }
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
            if failures == 1 { Self.log.notice("hub \(name, privacy: .public) did not resolve; retrying") }
            if failures >= Self.reconfirmAfterFailures, let endpoint = endpoints[name] {
                Self.reconfirm(endpoint)
            }
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
        Self.log.notice("hub \(name, privacy: .public) at \(host, privacy: .public):\(port)")
        hub.host = host
        hub.port = port
        browsed[name] = hub
        publish()
    }

    /// A hub that lost power or its network sends no Bonjour goodbye, so the
    /// browse listing stays cached until its TTL runs out (75 minutes for the
    /// PTR record).  Asking mDNSResponder to reconfirm the record makes it
    /// re-query the network and drop the record within seconds when nothing
    /// answers, and the browser then sees an ordinary removal.
    nonisolated static func reconfirm(_ endpoint: NWEndpoint) {
        guard case let .service(name, type, domain, interface) = endpoint,
              let rdata = ptrRecordData(name: name, type: type, domain: domain) else { return }
        let fullname = "\(type).\(domain.isEmpty ? "local." : domain)"
        _ = rdata.withUnsafeBytes { raw in
            DNSServiceReconfirmRecord(0, UInt32(interface?.index ?? 0), fullname,
                                      UInt16(kDNSServiceType_PTR), UInt16(kDNSServiceClass_IN),
                                      UInt16(rdata.count), raw.baseAddress)
        }
    }

    /// The PTR record's data: the instance's full name in DNS wire form, one
    /// length-prefixed label per component.  The instance name is a single
    /// label however many dots it holds, so it needs no escaping.
    nonisolated static func ptrRecordData(name: String, type: String, domain: String) -> Data? {
        var labels = [Data(name.utf8)]
        let tail = (type + "." + (domain.isEmpty ? "local" : domain))
            .split(separator: ".", omittingEmptySubsequences: true)
        labels += tail.map { Data($0.utf8) }
        guard labels.allSatisfy({ (1...63).contains($0.count) }) else { return nil }
        var data = Data()
        for label in labels { data.append(UInt8(label.count)); data.append(label) }
        data.append(0)
        return data.count <= 255 ? data : nil
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
