//
//  DSPi_ConsoleApp.swift
//  DSPi Console
//
//  Created by Troy Dunn-Higgins on 07/01/2026.
//

import SwiftUI

// MARK: - App State (Shared USB Device and View Model)
class AppState: ObservableObject {
    static let shared = AppState()
    let usb = USBDevice()
    lazy var viewModel: DSPViewModel = DSPViewModel(usb: usb)

    private init() {}
}

// MARK: - Stats Window Controller
class StatsWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    private var statsVM: StatsViewModel?
    @Published var isVisible: Bool = false

    func toggle(usb: USBDevice) {
        if isVisible {
            hide()
        } else {
            show(usb: usb)
        }
    }

    func show(usb: USBDevice) {
        if window == nil {
            statsVM = StatsViewModel(usb: usb)
            let statsView = StatsView(vm: statsVM!)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 280),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Buffer Statistics"
            window?.contentView = NSHostingView(rootView: statsView)
            window?.isReleasedWhenClosed = false
            window?.delegate = self
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }
}

extension StatsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}

// MARK: - Tools Menu Actions
struct ToolsMenuActions {
    static func commitParameters() {
        let alert = NSAlert()
        alert.messageText = "Commit Parameters"
        alert.informativeText = "Save current parameters to device?\n\nThis may cause a brief audio interruption."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let vm = AppState.shared.viewModel
            guard vm.isDeviceConnected else {
                showError("Not connected to device")
                return
            }
            let result = vm.saveParams()
            switch result {
            case FLASH_OK:
                showSuccess("Parameters saved successfully")
            default:
                showError("Failed to save parameters")
            }
        }
    }

    static func revertToSaved() {
        let alert = NSAlert()
        alert.messageText = "Revert to Saved"
        alert.informativeText = "Revert to last saved parameters?\n\nCurrent unsaved changes will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let vm = AppState.shared.viewModel
            guard vm.isDeviceConnected else {
                showError("Not connected to device")
                return
            }
            let result = vm.loadParams()
            switch result {
            case FLASH_OK:
                showSuccess("Parameters reverted successfully")
            case FLASH_ERR_NO_DATA:
                showInfo("No saved parameters found.\n\nThe device is using factory defaults.")
            case FLASH_ERR_CRC:
                showError("Saved data is corrupted")
            default:
                showError("Failed to load parameters")
            }
        }
    }

    static func factoryReset() {
        let alert = NSAlert()
        alert.messageText = "Factory Reset"
        alert.informativeText = "Reset all parameters to factory defaults?\n\nCurrent settings will be lost."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            let vm = AppState.shared.viewModel
            guard vm.isDeviceConnected else {
                showError("Not connected to device")
                return
            }
            let result = vm.factoryReset()
            switch result {
            case FLASH_OK:
                showSuccess("Factory reset complete")
            default:
                showError("Failed to reset parameters")
            }
        }
    }

    private static func showSuccess(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Success"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Information"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - App
@main
struct DSPi_ConsoleApp: App {
    @StateObject private var statsWindowController = StatsWindowController()

    var body: some Scene {
        WindowGroup {
            ContentView(vm: AppState.shared.viewModel)
        }
        .commands {
            // Tools Menu
            CommandMenu("Tools") {
                Button("Commit Parameters...") {
                    ToolsMenuActions.commitParameters()
                }

                Button("Revert to Saved...") {
                    ToolsMenuActions.revertToSaved()
                }

                Button("Factory Reset...") {
                    ToolsMenuActions.factoryReset()
                }

                Divider()

                Button("Stats for nerbs") {
                    // specific method depends on your controller's API (e.g., show, open)
                    statsWindowController.show(usb: AppState.shared.usb)
                }
                .keyboardShortcut("T", modifiers: [.command, .shift])
            }
        }
    }
}
