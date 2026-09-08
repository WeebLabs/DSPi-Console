//
//  MenuBarMode.swift
//  DSPi Console
//
//  The menu bar service mode: Console hides its window and Dock icon and
//  keeps running as the DSPi Link gateway, reachable from a menu bar item
//  that shows the hub's state and offers the few actions a gateway needs.
//  Also owns the start-at-login registration.  See networking_plan.md
//  Phase 4.
//

import SwiftUI
import AppKit
import ServiceManagement

/// Preferences and the minimise/restore machinery.  One instance; the App
/// scene, the delegate's close handling and the settings page all drive it.
@MainActor
final class MenuBarController: ObservableObject {
    static let shared = MenuBarController()

    /// Show the menu bar item at all.  Turning it off while minimised
    /// restores the window, since there would be no way back otherwise.
    @AppStorage("showInMenuBar") var showInMenuBar: Bool = false {
        didSet { if !showInMenuBar && isMinimised { restore() } }
    }
    /// Hide to the menu bar as soon as the app has launched.
    @AppStorage("startMinimised") var startMinimised: Bool = false

    /// True while the window is hidden and the app is an accessory (no Dock
    /// icon).  The hub keeps serving throughout.
    @Published private(set) var isMinimised = false

    /// Mirrors the system's login-item state for this app.
    @Published private(set) var startsAtLogin: Bool = false
    @Published private(set) var loginItemError: String?

    private init() {
        refreshLoginItemState()
    }

    // MARK: - Minimise and restore

    /// Hide the main window and leave the Dock.  Nothing about the device or
    /// the network changes; this is purely presentation.
    func minimise() {
        guard !isMinimised else { return }
        showInMenuBar = true
        mainWindow()?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        isMinimised = true
    }

    /// Come back as a normal app with the window in front.
    func restore() {
        NSApp.setActivationPolicy(.regular)
        isMinimised = false
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow() {
            window.makeKeyAndOrderFront(nil)
        } else {
            // The window scene has not created its window yet (cold start
            // straight into the menu bar); ask the scene for it.
            reopenMainWindow?()
        }
    }

    /// Set by the App scene: opens the "main" window through SwiftUI when no
    /// NSWindow exists to reorder.
    var reopenMainWindow: (() -> Void)?

    private func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "DSPi Console" }
    }

    // MARK: - Start at login

    func refreshLoginItemState() {
        startsAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setStartsAtLogin(_ on: Bool) {
        loginItemError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItemState()
    }
}

// MARK: - The menu

/// Contents of the menu bar item.  Kept to what a gateway needs: what it is
/// doing, a way back to the window, pairing, sharing on or off, quit.
struct MenuBarMenu: View {
    @ObservedObject private var service = AppState.shared.linkService
    @ObservedObject private var controller = MenuBarController.shared
    @ObservedObject private var vm = AppState.shared.viewModel

    var body: some View {
        Group {
            Text(statusLine)
            if service.isRunning, let address = service.listenAddress {
                Text(address)
            }
            if let pin = service.activePIN {
                Text("Pairing code \(pin)")
            }
        }
        Divider()
        Button(controller.isMinimised ? "Open DSPi Console" : "Show DSPi Console") {
            controller.restore()
        }
        // A Toggle in a menu renders as a checkmark item.
        Toggle("Share on This Network", isOn: Binding(get: { service.sharingEnabled },
                                                       set: { service.setSharing($0) }))
        if service.authMode == .pin {
            Button(service.activePIN == nil ? "Allow a New Client..." : "Cancel Pairing") {
                if service.activePIN == nil { service.allowNewClient() } else { service.cancelPairing() }
            }
            .disabled(!service.isRunning)
        }
        Divider()
        Button("Quit DSPi Console") {
            NSApp.terminate(nil)
        }
    }

    private var statusLine: String {
        let device = vm.isDeviceConnected ? "DSPi connected" : "No DSPi connected"
        guard service.isRunning else { return "\(device), not sharing" }
        let n = service.sessionCount
        let clients = n == 1 ? "1 client" : "\(n) clients"
        return "\(device), sharing, \(clients)"
    }
}

/// The menu bar glyph: filled while sharing so the state reads at a glance.
struct MenuBarLabel: View {
    @ObservedObject private var service = AppState.shared.linkService
    var body: some View {
        Image(systemName: service.isRunning ? "waveform.circle.fill" : "waveform.circle")
    }
}
