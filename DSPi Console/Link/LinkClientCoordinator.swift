//
//  LinkClientCoordinator.swift
//  DSPi Console
//
//  Console as a client: owns the hub browser and the preference that turns it
//  on, feeds what it finds to the composite transport so shared devices show
//  up in the device picker, and keeps the manual hub list.  The Networking
//  settings page drives it.  See networking_plan.md Phase 5.
//

import Foundation
import Combine

@MainActor
final class LinkClientCoordinator: ObservableObject {
    let browser: HubBrowser
    private let composite: CompositeTransport
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    /// Look for hubs on the local network and list their devices.
    @Published var lookForHubs: Bool {
        didSet {
            defaults.set(lookForHubs, forKey: Keys.lookForHubs)
            lookForHubs ? browser.start() : browser.stop()
        }
    }
    @Published private(set) var hubs: [DiscoveredHub] = []
    /// Why the browser is finding nothing, when the system says.
    @Published private(set) var browseError: String?
    @Published var manualAddresses: [String] {
        didSet { defaults.set(manualAddresses, forKey: Keys.manual) }
    }

    private enum Keys {
        static let lookForHubs = "LinkLookForHubs"
        static let manual = "LinkManualHubs"
    }

    /// `ownHubID` is this Console's hub id, so its own advertisement is not
    /// listed as another hub.
    init(composite: CompositeTransport, ownHubID: String? = nil,
         defaults: UserDefaults = .standard) {
        self.browser = HubBrowser(ownHubID: ownHubID)
        self.composite = composite
        self.defaults = defaults
        self.lookForHubs = defaults.object(forKey: Keys.lookForHubs) as? Bool ?? false
        self.manualAddresses = defaults.stringArray(forKey: Keys.manual) ?? []

        // The browser republishes on every Bonjour event; only a changed list
        // is worth re-dialling hubs and recomputing the device list for.
        browser.$hubs
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hubs in
                self?.hubs = hubs
                self?.composite.updateHubs(hubs.filter { !$0.isSelf })
            }
            .store(in: &cancellables)
        browser.$browseError
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.browseError = $0 }
            .store(in: &cancellables)
        // A failed connection may mean the hub moved: look its address up again.
        composite.hubUnreachable = { [weak self] hubID in
            Task { @MainActor in self?.browser.refreshAddress(ofHub: hubID) }
        }

        for address in manualAddresses { browser.addManual(address) }
        if lookForHubs { browser.start() }
    }

    func addManual(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !manualAddresses.contains(trimmed) { manualAddresses.append(trimmed) }
        browser.addManual(trimmed)
    }

    func removeManual(_ hub: DiscoveredHub) {
        manualAddresses.removeAll {
            guard let parsed = HubBrowser.parseAddress($0) else { return false }
            return parsed.host == hub.host && parsed.port == hub.port
        }
        browser.removeManual(hub)
    }
}
