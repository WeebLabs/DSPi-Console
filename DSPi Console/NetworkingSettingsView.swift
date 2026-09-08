//
//  NetworkingSettingsView.swift
//  DSPi Console
//
//  The Networking settings page: turn local-network sharing on or off, name
//  the hub, choose the auth mode, pair new clients and manage the paired ones.
//  It drives the LinkService coordinator, which owns the server, the DNS-SD
//  advertisement and the auth store.  See networking_plan.md Phase 3.
//

import SwiftUI

struct NetworkingSettingsTab: View {
    @ObservedObject private var service = AppState.shared.linkService
    @ObservedObject private var menuBar = MenuBarController.shared
    @ObservedObject private var client = AppState.shared.linkClientCoordinator
    @State private var manualDraft: String = ""

    @State private var hubNameDraft: String = ""
    @State private var portDraft: String = ""

    var body: some View {
        Form {
            sharingSection
            identitySection
            authSection
            if service.authMode == .pin { clientsSection }
            gatewaySection
            otherHubsSection
            infoSection
        }
        .formStyle(.grouped)
        .navigationTitle("Networking")
        .onAppear {
            hubNameDraft = service.hubName
            portDraft = String(service.port)
            service.refreshClients()
        }
    }

    // MARK: - Sharing

    private var sharingSection: some View {
        Section {
            Toggle(isOn: Binding(get: { service.sharingEnabled },
                                 set: { service.setSharing($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share devices on this network")
                    Text("Lets phones, browsers and other Consoles on your local network control the DSPi devices plugged into this Mac.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if let error = service.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
            }
            if service.isRunning {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text(service.listenAddress.map { "Listening on \($0)" } ?? "Listening")
                    }
                }
                LabeledContent("Connected clients", value: "\(service.sessionCount)")
            }
        } header: {
            Text("Sharing")
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section("Hub") {
            LabeledContent("Name") {
                TextField("Hub name", text: $hubNameDraft)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220)
                    .onSubmit { service.hubName = hubNameDraft.isEmpty ? service.hubName : hubNameDraft }
            }
            LabeledContent("Port") {
                TextField("Port", text: $portDraft)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .disabled(service.isRunning)
                    .onSubmit {
                        if let p = Int(portDraft), (1024...65535).contains(p) { service.port = p }
                        else { portDraft = String(service.port) }
                    }
            }
            if service.isRunning {
                Text("Stop sharing to change the port.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Auth

    private var authSection: some View {
        Section("Security") {
            Picker("Access", selection: Binding(get: { service.authMode },
                                                set: { service.authMode = $0 })) {
                Text("Require pairing").tag(LinkAuthMode.pin)
                Text("Open (no pairing)").tag(LinkAuthMode.none)
            }
            .pickerStyle(.radioGroup)
            if service.authMode == .none {
                Label("Anyone on the network gets full control without pairing. Use only on a trusted network.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
            }
        }
    }

    // MARK: - Clients

    private var clientsSection: some View {
        Section("Clients") {
            if let pin = service.activePIN {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pairing code")
                        .font(.caption).foregroundColor(.secondary)
                    Text(pin)
                        .font(.system(.largeTitle, design: .monospaced))
                        .tracking(6)
                    if let expiry = service.pairingExpires {
                        Text("Enter this in the new client. Expires \(expiry, style: .relative) from now.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Button("Cancel", role: .cancel) { service.cancelPairing() }
                }
            } else {
                Button {
                    service.allowNewClient()
                } label: {
                    Label("Allow a new client", systemImage: "plus.circle")
                }
            }

            if service.clients.isEmpty {
                Text("No paired clients yet.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(service.clients) { client in
                    clientRow(client)
                }
            }
        }
    }

    private func clientRow(_ client: PairedClient) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name)
                if let seen = client.lastSeen {
                    Text("Last seen \(seen, style: .relative) ago")
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    Text("Never connected")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            Picker("", selection: Binding(get: { client.role },
                                          set: { service.setRole(client, $0) })) {
                Text("Viewer").tag(LinkRole.viewer)
                Text("Control").tag(LinkRole.control)
                Text("Admin").tag(LinkRole.admin)
            }
            .labelsHidden()
            .frame(width: 110)
            Button(role: .destructive) {
                service.revoke(client)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Gateway (menu bar and login)

    private var gatewaySection: some View {
        Section("Run as a Gateway") {
            Toggle(isOn: Binding(get: { menuBar.showInMenuBar },
                                 set: { menuBar.showInMenuBar = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show in the menu bar")
                    Text("Closing the window then hides Console to the menu bar while it keeps sharing. Window > Minimise to Menu Bar does the same.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Toggle("Start at login", isOn: Binding(get: { menuBar.startsAtLogin },
                                                   set: { menuBar.setStartsAtLogin($0) }))
            if let error = menuBar.loginItemError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
            }
            Toggle("Start hidden in the menu bar", isOn: Binding(get: { menuBar.startMinimised },
                                                                 set: { menuBar.startMinimised = $0 }))
                .disabled(!menuBar.showInMenuBar)
        }
    }

    // MARK: - Other hubs (client mode)

    private var otherHubsSection: some View {
        Section("Other Hubs") {
            Toggle(isOn: Binding(get: { client.lookForHubs }, set: { client.lookForHubs = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Look for DSPi devices shared on this network")
                    Text("Devices shared by other Consoles and bridges appear in the device menu, marked with the hub they live on.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if client.hubs.isEmpty {
                Text(client.lookForHubs ? "No hubs found yet." : "Not looking.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(client.hubs) { hub in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hub.name)
                            Text("\(hub.host):\(hub.port), \(hub.deviceCount) device\(hub.deviceCount == 1 ? "" : "s"), \(hub.authMode == "none" ? "open" : "pairing required")")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        if hub.isManual {
                            Button(role: .destructive) { client.removeManual(hub) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            HStack {
                TextField("Add a hub by address (host or host:port)", text: $manualDraft)
                    .onSubmit { client.addManual(manualDraft); manualDraft = "" }
                Button("Add") { client.addManual(manualDraft); manualDraft = "" }
                    .disabled(manualDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Info

    private var infoSection: some View {
        Section {
            Text("Sharing works only on your local network. Do not forward this port on your router. To reach your devices away from home, use a VPN such as Tailscale or WireGuard.\n\nKeep this Mac awake and Console running (it can sit in the menu bar) for clients to stay connected.")
                .font(.caption2).foregroundColor(.secondary)
            Toggle("Prevent this Mac from sleeping while sharing is on",
                   isOn: Binding(get: { service.preventSleepWhileConnected },
                                 set: { service.preventSleepWhileConnected = $0 }))
                .font(.caption)
        }
    }
}
