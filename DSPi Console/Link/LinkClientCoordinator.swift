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
    let browser = HubBrowser()
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
    @Published var manualAddresses: [String] {
        didSet { defaults.set(manualAddresses, forKey: Keys.manual) }
    }

    private enum Keys {
        static let lookForHubs = "LinkLookForHubs"
        static let manual = "LinkManualHubs"
    }

    init(composite: CompositeTransport, defaults: UserDefaults = .standard) {
        self.composite = composite
        self.defaults = defaults
        self.lookForHubs = defaults.object(forKey: Keys.lookForHubs) as? Bool ?? false
        self.manualAddresses = defaults.stringArray(forKey: Keys.manual) ?? []

        browser.$hubs
            .receive(on: RunLoop.main)
            .sink { [weak self] hubs in
                self?.hubs = hubs
                self?.composite.updateHubs(hubs)
            }
            .store(in: &cancellables)

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
        manualAddresses.removeAll { $0 == hub.host || $0 == "\(hub.host):\(hub.port)" }
        browser.removeManual(hub)
    }
}
