//
//  LinkService.swift
//  DSPi Console
//
//  Coordinates the network-sharing feature: the persisted preferences (share
//  on/off, port), the WebSocket server, the DNS-SD advertisement, pairing and
//  the paired-client list, and the power assertions that keep the gateway
//  reachable while clients are connected.  The Networking settings page and the
//  menu bar both drive this one object.  See networking_plan.md Phase 3-4.
//

import Foundation
import Combine
import AppKit

/// The server the service starts and stops.  A protocol so the service builds
/// and tests without the NIO server present; LinkServer conforms to it.
protocol LinkServing: AnyObject {
    func start(port: Int) throws
    func stop()
    var isRunning: Bool { get }
    var boundPort: Int? { get }
}

@MainActor
final class LinkService: ObservableObject {
    private let hub: LinkHub
    private let auth: LinkAuthStore
    private let server: LinkServing
    private let discovery = LinkDiscovery()

    // Persisted preferences.
    @Published var sharingEnabled: Bool { didSet { defaults.set(sharingEnabled, forKey: Keys.enabled) } }
    @Published var port: Int { didSet { defaults.set(port, forKey: Keys.port) } }
    /// Holds an idle-sleep assertion for as long as sharing is on.  It is not
    /// tied to a client being connected: a phone that has gone to sleep would
    /// otherwise find the hub asleep too when it comes back.
    @Published var preventSleepWhileConnected: Bool {
        didSet {
            defaults.set(preventSleepWhileConnected, forKey: Keys.preventSleep)
            if isRunning { endPowerActivity(); beginPowerActivity() }
        }
    }

    // Live state, mirrored for the UI.
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published var hubName: String { didSet { auth.hubName = hubName } }
    @Published var authMode: LinkAuthMode { didSet { auth.authMode = authMode } }
    @Published private(set) var clients: [PairedClient] = []
    @Published private(set) var activePIN: String?
    @Published private(set) var pairingExpires: Date?

    private let defaults: UserDefaults
    private var activityToken: NSObjectProtocol?
    private var pinTimer: Timer?

    private enum Keys {
        static let enabled = "LinkSharingEnabled"
        static let port = "LinkSharingPort"
        static let preventSleep = "LinkPreventSleep"
    }

    init(hub: LinkHub, auth: LinkAuthStore, server: LinkServing, defaults: UserDefaults = .standard) {
        self.hub = hub
        self.auth = auth
        self.server = server
        self.defaults = defaults
        self.sharingEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        self.port = defaults.object(forKey: Keys.port) as? Int ?? LinkDiscovery.defaultPort
        self.preventSleepWhileConnected = defaults.object(forKey: Keys.preventSleep) as? Bool ?? false
        self.hubName = auth.hubName
        self.authMode = auth.authMode
        self.clients = auth.clients

        // Refresh the advertisement and the status line when devices change.
        hub.onRegistryChange = { [weak self] in
            Task { @MainActor in self?.refreshAdvertisement() }
        }

        if sharingEnabled { start() }
    }

    // MARK: - Lifecycle

    /// Turn sharing on: start the server, advertise, and hold the power
    /// assertions.  Persists the choice.
    func start() {
        lastError = nil
        do {
            try server.start(port: port)
        } catch {
            lastError = "Could not start on port \(port): \(error.localizedDescription)"
            isRunning = false
            return
        }
        sharingEnabled = true
        isRunning = true
        advertise()
        beginPowerActivity()
    }

    /// Turn sharing off: stop advertising and the server, drop the assertions.
    func stop() {
        discovery.stop()
        server.stop()
        isRunning = false
        sharingEnabled = false
        endPowerActivity()
    }

    func setSharing(_ on: Bool) { on ? start() : stop() }

    // MARK: - Advertisement

    private func advertise() {
        let boundPort = server.boundPort ?? port
        discovery.start(name: hubName, port: boundPort, ad: advertisement())
    }

    private func refreshAdvertisement() {
        guard isRunning else { return }
        discovery.updateTXT(advertisement())
    }

    private func advertisement() -> LinkAdvertisement {
        LinkAdvertisement(hubID: auth.hubID.uuidString.lowercased(),
                          auth: authMode.rawValue,
                          deviceCount: hub.sharedDeviceSerials.count,
                          serials: hub.sharedDeviceSerials)
    }

    // MARK: - Pairing and clients

    /// Show a PIN and accept pairing attempts for two minutes.
    func allowNewClient() {
        let pin = auth.beginPairing()
        activePIN = pin
        pairingExpires = auth.pairingExpires
        pinTimer?.invalidate()
        pinTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPairing() }
        }
    }

    func cancelPairing() {
        auth.cancelPairing()
        activePIN = nil
        pairingExpires = nil
        pinTimer?.invalidate(); pinTimer = nil
    }

    private func tickPairing() {
        clients = auth.clients                 // a new pairing shows up here
        if let expiry = pairingExpires, expiry <= Date() {
            cancelPairing()
        } else if auth.activePIN == nil {
            cancelPairing()                    // consumed by a successful pair
        }
    }

    func revoke(_ client: PairedClient) {
        auth.revoke(cid: client.id)
        clients = auth.clients
    }

    func setRole(_ client: PairedClient, _ role: LinkRole) {
        auth.setRole(cid: client.id, role: role)
        clients = auth.clients
    }

    func rename(_ client: PairedClient, to name: String) {
        auth.rename(cid: client.id, name: name)
        clients = auth.clients
    }

    func refreshClients() { clients = auth.clients }

    // MARK: - Status

    var sessionCount: Int { hub.sessionCount }

    /// The address a client on the LAN would type, best-effort.
    var listenAddress: String? {
        guard isRunning, let ip = Self.primaryLANAddress() else { return nil }
        return "\(ip):\(server.boundPort ?? port)"
    }

    // MARK: - Power assertions

    /// Keep the app out of App Nap while it is serving, so its timers and the
    /// meter relay do not get throttled in the background.
    private func beginPowerActivity() {
        guard activityToken == nil else { return }
        var options: ProcessInfo.ActivityOptions = [.userInitiated]
        if preventSleepWhileConnected { options.insert(.idleSystemSleepDisabled) }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: options, reason: "Sharing DSPi devices on the local network")
    }

    private func endPowerActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    // MARK: - Helpers

    /// First non-loopback IPv4 address on an up interface, for the status line.
    private static func primaryLANAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            let family = p.pointee.ifa_addr.pointee.sa_family
            if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
               (flags & IFF_LOOPBACK) == 0, family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(p.pointee.ifa_addr, socklen_t(p.pointee.ifa_addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    // Prefer a private-range address; skip anything odd.
                    if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
                        address = ip; break
                    }
                    if address == nil { address = ip }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return address
    }
}
