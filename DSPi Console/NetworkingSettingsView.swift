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

    @State private var hubNameDraft: String = ""
    @State private var portDraft: String = ""
    @State private var manualDraft: String = ""
    @State private var showingAddHub = false

    /// The sidebar's Networking badge colour, so the header reads as the same page.
    private static let tint = Color(red: 0.290, green: 0.455, blue: 0.600)

    var body: some View {
        Form {
            headerSection
            hubSection
            if service.authMode == .pin { clientsSection }
            otherHubsSection
            backgroundSection
        }
        .formStyle(.grouped)
        .onChange(of: service.hubName) { _, name in hubNameDraft = name }   // a remote rename
        .onAppear {
            hubNameDraft = service.hubName
            portDraft = String(service.port)
            service.refreshClients()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Self.tint.gradient)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "network")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text("Share Devices on This Network")
                        .font(.headline)
                    if service.isRunning {
                        HStack(spacing: 5) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            // verbatim: a localized Text would print the port as "11,915".
                            Text(verbatim: statusLine)
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Lets phones, browsers and other Consoles control the DSPi devices plugged into this Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                Toggle("Share devices on this network",
                       isOn: Binding(get: { service.sharingEnabled }, set: { service.setSharing($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.vertical, 4)
            if let error = service.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private var statusLine: String {
        let count = service.sessionCount
        let clients = count == 0 ? "no clients connected"
                                 : "\(count) client\(count == 1 ? "" : "s") connected"
        return service.listenAddress.map { "On at \($0), \(clients)" } ?? "On, \(clients)"
    }

    // MARK: - This hub

    private var hubSection: some View {
        Section {
            LabeledContent("Name") {
                TextField("Hub name", text: $hubNameDraft)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260)
                    .onSubmit { service.hubName = hubNameDraft.isEmpty ? service.hubName : hubNameDraft }
            }
            Picker("Access", selection: Binding(get: { service.authMode },
                                                set: { service.authMode = $0 })) {
                Text("Paired clients only").tag(LinkAuthMode.pin)
                Text("Anyone on the network").tag(LinkAuthMode.none)
            }
            if service.authMode == .none {
                Label("Anyone on this network gets full control. Use this only on a network you trust.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            LabeledContent("Port") {
                TextField("Port", text: $portDraft)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .disabled(service.isRunning)
                    .onSubmit {
                        if let p = Int(portDraft), (1024...65535).contains(p) { service.port = p }
                        else { portDraft = String(service.port) }
                    }
            }
        } header: {
            Text("This Hub")
        } footer: {
            if service.isRunning {
                footerText("Turn sharing off to change the port.")
            }
        }
    }

    // MARK: - Paired clients

    private var clientsSection: some View {
        Section {
            if let pin = service.activePIN {
                pairingCodeRow(pin)
            }
            if service.clients.isEmpty {
                Text("No paired clients yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(service.clients) { client in
                    clientRow(client)
                }
            }
            if service.activePIN == nil {
                HStack {
                    Spacer()
                    Button("Pair a New Client…") { service.allowNewClient() }
                }
            }
        } header: {
            Text("Paired Clients")
        } footer: {
            footerText("A role sets what each client can do: Viewer watches, Control adjusts settings, Admin also changes the hub.")
        }
    }

    private func pairingCodeRow(_ pin: String) -> some View {
        VStack(spacing: 6) {
            Text("Enter this code on the new client")
                .font(.callout).foregroundStyle(.secondary)
            Text(pin)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .tracking(8)
                .textSelection(.enabled)
            if let expiry = service.pairingExpires {
                Text("Expires \(expiry, style: .relative) from now")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel) { service.cancelPairing() }
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func clientRow(_ client: PairedClient) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2).foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name)
                Group {
                    if let seen = client.lastSeen {
                        Text("Last seen \(seen, style: .relative) ago")
                    } else {
                        Text("Never connected")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Role", selection: Binding(get: { client.role },
                                              set: { service.setRole(client, $0) })) {
                Text("Viewer").tag(LinkRole.viewer)
                Text("Control").tag(LinkRole.control)
                Text("Admin").tag(LinkRole.admin)
            }
            .labelsHidden()
            .frame(width: 100)
            Button(role: .destructive) {
                service.revoke(client)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this client")
        }
    }

    // MARK: - Other hubs (client mode)

    private var otherHubsSection: some View {
        Section {
            Toggle("Find hubs automatically",
                   isOn: Binding(get: { client.lookForHubs }, set: { client.lookForHubs = $0 }))
            if let error = client.browseError, client.lookForHubs {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            ForEach(client.hubs) { hub in
                hubRow(hub)
            }
            if client.hubs.isEmpty && client.lookForHubs {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for hubs…").foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Add by Address…") { showingAddHub = true }
                    .popover(isPresented: $showingAddHub, arrowEdge: .bottom) { addHubPopover }
            }
        } header: {
            Text("Other Hubs")
        } footer: {
            footerText("Devices shared by other Consoles and bridges appear in the device menu, marked with the hub they live on.")
        }
    }

    private func hubRow(_ hub: DiscoveredHub) -> some View {
        HStack(spacing: 10) {
            Image(systemName: hub.kind == "bridge" ? "point.3.connected.trianglepath.dotted"
                            : hub.kind == "console" ? "desktopcomputer" : "network")
                .font(.title3).foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(hub.name)
                // verbatim: a localized Text would print the port as "11,915".
                Text(verbatim: hub.isSelf
                     ? "\(hub.displayAddress), this Mac's own hub"
                     : "\(hub.displayAddress), \(hub.deviceCount) device\(hub.deviceCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .opacity(hub.isSelf ? 0.6 : 1)
            Spacer()
            hubBadge(hub)
                .frame(width: 90, alignment: .trailing)
            // The column stays reserved on browsed hubs so the badges line up.
            Button(role: .destructive) { client.removeManual(hub) } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this hub")
            .opacity(hub.isManual ? 1 : 0)
            .disabled(!hub.isManual)
        }
    }

    private func hubBadge(_ hub: DiscoveredHub) -> some View {
        let (text, color): (String, Color) =
            hub.isSelf ? ("Not used", .secondary)
            : hub.authMode == "none" ? ("Open", .green)
            : ("Pairing", .blue)
        return Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var addHubPopover: some View {
        let valid = HubBrowser.parseAddress(manualDraft) != nil
        let add = {
            guard valid else { return }
            client.addManual(manualDraft)
            manualDraft = ""
            showingAddHub = false
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Add a Hub by Address").font(.headline)
            TextField("Address", text: $manualDraft, prompt: Text("192.168.1.20 or studio.local"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 240)
                .onSubmit(add)
            Text(verbatim: "Hostname or IP address. Add :port if the hub doesn't use \(LinkDiscovery.defaultPort).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { manualDraft = ""; showingAddHub = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding()
        .frame(width: 272)
    }

    // MARK: - Running in the background

    private var backgroundSection: some View {
        Section {
            Toggle(isOn: Binding(get: { menuBar.showInMenuBar },
                                 set: { menuBar.showInMenuBar = $0 })) {
                Text("Show in the menu bar")
                Text("Closing the window keeps Console running in the menu bar.")
            }
            Toggle("Start hidden in the menu bar",
                   isOn: Binding(get: { menuBar.startMinimised }, set: { menuBar.startMinimised = $0 }))
                .disabled(!menuBar.showInMenuBar)
            Toggle("Open at login",
                   isOn: Binding(get: { menuBar.startsAtLogin }, set: { menuBar.setStartsAtLogin($0) }))
            if let error = menuBar.loginItemError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            Toggle("Keep this Mac awake while sharing",
                   isOn: Binding(get: { service.preventSleepWhileConnected },
                                 set: { service.preventSleepWhileConnected = $0 }))
        } header: {
            Text("Running in the Background")
        } footer: {
            footerText("Sharing works only on your local network. To reach your devices away from home, use a VPN such as Tailscale or WireGuard; do not forward the port on your router.")
        }
    }

    private func footerText(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)   // grouped-Form footers otherwise wrap ragged-left
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
