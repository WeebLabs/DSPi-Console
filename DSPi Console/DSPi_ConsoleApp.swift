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

// MARK: - File Menu Actions
struct FileMenuActions {
    static func importFilters() {
        let panel = NSOpenPanel()
        panel.title = "Import Filters"
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let contents = try String(contentsOf: url, encoding: .utf8)

            if contents.hasPrefix("# DSPi Console") {
                // DSPi Console format - parse and show multi-channel picker
                if let channelFilters = parseDSPiFile(contents) {
                    showMultiChannelPicker(channelFilters: channelFilters)
                } else {
                    showError("Failed to parse DSPi Console filter file")
                }
            } else {
                // REW format - parse and show single-channel picker
                if let filters = parseREWFile(contents) {
                    if filters.isEmpty {
                        showError("No valid filters found in file")
                    } else {
                        showSingleChannelPicker(filters: filters)
                    }
                } else {
                    showError("Failed to parse filter file")
                }
            }
        } catch {
            showError("Failed to read file: \(error.localizedDescription)")
        }
    }

    static func exportFilters() {
        let panel = NSSavePanel()
        panel.title = "Export Filters"
        panel.nameFieldStringValue = "DSPi Filters.txt"
        panel.allowedContentTypes = [.plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let output = generateExportString()

        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
            showSuccess("Filters exported successfully")
        } catch {
            showError("Failed to write file: \(error.localizedDescription)")
        }
    }

    // MARK: - Parsing

    private static func parseREWFile(_ contents: String) -> [FilterParams]? {
        var filters: [FilterParams] = []

        for line in contents.components(separatedBy: .newlines) {
            // Match lines like: "Filter  1: ON  PK       Fc    63.0 Hz  Gain  -5.0 dB  Q  4.00"
            guard line.contains("Filter") && line.contains(":") else { continue }

            let enabled = line.uppercased().contains(" ON ")
            if !enabled { continue }

            // Extract filter type
            var filterType: FilterType = .flat
            let upperLine = line.uppercased()
            if upperLine.contains(" PK ") || upperLine.contains(" PEQ ") {
                filterType = .peaking
            } else if upperLine.contains(" LP ") || upperLine.contains(" LPQ ") {
                filterType = .lowPass
            } else if upperLine.contains(" HP ") || upperLine.contains(" HPQ ") {
                filterType = .highPass
            } else if upperLine.contains(" LS ") || upperLine.contains(" LSC ") {
                filterType = .lowShelf
            } else if upperLine.contains(" HS ") || upperLine.contains(" HSC ") {
                filterType = .highShelf
            } else {
                continue // Unknown filter type, skip
            }

            // Extract frequency (Fc XXX Hz)
            var freq: Float = 1000.0
            if let fcRange = line.range(of: "Fc", options: .caseInsensitive) {
                let afterFc = line[fcRange.upperBound...]
                let components = afterFc.split(whereSeparator: { $0.isWhitespace })
                if let freqStr = components.first, let freqVal = Float(freqStr) {
                    freq = freqVal
                }
            }

            // Extract gain (Gain XXX dB) - optional
            var gain: Float = 0.0
            if let gainRange = line.range(of: "Gain", options: .caseInsensitive) {
                let afterGain = line[gainRange.upperBound...]
                let components = afterGain.split(whereSeparator: { $0.isWhitespace })
                if let gainStr = components.first, let gainVal = Float(gainStr) {
                    gain = gainVal
                }
            }

            // Extract Q (Q XXX) - optional
            var q: Float = 0.707
            // Look for " Q " followed by a number (not "EQ" or other Q-containing words)
            let qPattern = try? NSRegularExpression(pattern: "\\sQ\\s+([\\d.]+)", options: .caseInsensitive)
            if let match = qPattern?.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
               let qRange = Range(match.range(at: 1), in: line),
               let qVal = Float(line[qRange]) {
                q = qVal
            }

            let params = FilterParams(type: filterType, freq: freq, q: q, gain: gain)
            filters.append(params)
        }

        return filters
    }

    private static func parseDSPiFile(_ contents: String) -> [Int: [FilterParams]]? {
        var result: [Int: [FilterParams]] = [:]
        var currentChannel: Int? = nil

        for line in contents.components(separatedBy: .newlines) {
            // Check for channel header [Channel Name]
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let channelName = String(line.dropFirst().dropLast())
                // Find matching channel
                for ch in Channel.allCases {
                    if ch.name == channelName {
                        currentChannel = ch.rawValue
                        result[ch.rawValue] = []
                        break
                    }
                }
                continue
            }

            // Parse filter line
            guard let channel = currentChannel,
                  line.contains("Filter") && line.contains(":") else { continue }

            // Check if filter is disabled (OFF or just no type)
            if line.uppercased().contains(" OFF") || (!line.uppercased().contains(" ON ")) {
                // Add a flat filter placeholder
                result[channel]?.append(FilterParams(type: .flat, freq: 1000, q: 0.707, gain: 0))
                continue
            }

            // Parse same as REW format
            var filterType: FilterType = .flat
            let upperLine = line.uppercased()
            if upperLine.contains(" PK ") || upperLine.contains(" PEQ ") {
                filterType = .peaking
            } else if upperLine.contains(" LP ") || upperLine.contains(" LPQ ") {
                filterType = .lowPass
            } else if upperLine.contains(" HP ") || upperLine.contains(" HPQ ") {
                filterType = .highPass
            } else if upperLine.contains(" LS ") || upperLine.contains(" LSC ") {
                filterType = .lowShelf
            } else if upperLine.contains(" HS ") || upperLine.contains(" HSC ") {
                filterType = .highShelf
            }

            var freq: Float = 1000.0
            if let fcRange = line.range(of: "Fc", options: .caseInsensitive) {
                let afterFc = line[fcRange.upperBound...]
                let components = afterFc.split(whereSeparator: { $0.isWhitespace })
                if let freqStr = components.first, let freqVal = Float(freqStr) {
                    freq = freqVal
                }
            }

            var gain: Float = 0.0
            if let gainRange = line.range(of: "Gain", options: .caseInsensitive) {
                let afterGain = line[gainRange.upperBound...]
                let components = afterGain.split(whereSeparator: { $0.isWhitespace })
                if let gainStr = components.first, let gainVal = Float(gainStr) {
                    gain = gainVal
                }
            }

            var q: Float = 0.707
            let qPattern = try? NSRegularExpression(pattern: "\\sQ\\s+([\\d.]+)", options: .caseInsensitive)
            if let match = qPattern?.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
               let qRange = Range(match.range(at: 1), in: line),
               let qVal = Float(line[qRange]) {
                q = qVal
            }

            result[channel]?.append(FilterParams(type: filterType, freq: freq, q: q, gain: gain))
        }

        return result.isEmpty ? nil : result
    }

    // MARK: - Export

    private static func generateExportString() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var output = "# DSPi Console Filter Settings\n"
        output += "# Exported: \(dateFormatter.string(from: Date()))\n\n"

        let vm = AppState.shared.viewModel

        for channel in Channel.allCases {
            output += "[\(channel.name)]\n"
            let filters = vm.channelData[channel.rawValue] ?? []

            for (i, filter) in filters.enumerated() {
                output += formatFilter(index: i + 1, filter: filter)
            }
            output += "\n"
        }

        return output
    }

    private static func formatFilter(index: Int, filter: FilterParams) -> String {
        let typeCode: String
        switch filter.type {
        case .flat: return String(format: "Filter %2d: OFF\n", index)
        case .peaking: typeCode = "PK"
        case .lowPass: typeCode = "LP"
        case .highPass: typeCode = "HP"
        case .lowShelf: typeCode = "LS"
        case .highShelf: typeCode = "HS"
        }

        let paddedType = typeCode.padding(toLength: 8, withPad: " ", startingAt: 0)
        var line = String(format: "Filter %2d: ON  %@Fc %7.1f Hz", index, paddedType, filter.freq)

        // Add gain for types that use it
        if filter.type == .peaking || filter.type == .lowShelf || filter.type == .highShelf {
            line += String(format: "  Gain %+5.1f dB", filter.gain)
        }

        // Add Q for peaking filters
        if filter.type == .peaking {
            line += String(format: "  Q %5.2f", filter.q)
        }

        return line + "\n"
    }

    // MARK: - Dialogs

    private static func showSingleChannelPicker(filters: [FilterParams]) {
        let alert = NSAlert()
        alert.messageText = "Import Filters"
        alert.informativeText = "Found \(filters.count) filter(s). Select which channel(s) to apply them to:"
        alert.alertStyle = .informational

        // Create checkboxes for master channels
        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8

        let masterChannels: [Channel] = [.masterLeft, .masterRight]
        var checkboxes: [NSButton] = []

        for ch in masterChannels {
            let checkbox = NSButton(checkboxWithTitle: ch.name, target: nil, action: nil)
            checkbox.tag = ch.rawValue
            checkbox.state = .on // Both checked by default
            checkboxes.append(checkbox)
            accessory.addArrangedSubview(checkbox)
        }

        accessory.setFrameSize(NSSize(width: 200, height: CGFloat(masterChannels.count * 24)))
        alert.accessoryView = accessory

        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            var importedCount = 0
            for checkbox in checkboxes where checkbox.state == .on {
                applyFilters(filters, to: checkbox.tag)
                importedCount += 1
            }
            if importedCount > 0 {
                showSuccess("Filters imported to \(importedCount) channel(s)")
            }
        }
    }

    private static func showMultiChannelPicker(channelFilters: [Int: [FilterParams]]) {
        let alert = NSAlert()
        alert.messageText = "Import Filters"
        alert.informativeText = "This file contains filter settings for multiple channels. Select which channels to import:"
        alert.alertStyle = .informational

        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8

        var checkboxes: [NSButton] = []

        for channel in Channel.allCases {
            if channelFilters[channel.rawValue] != nil {
                let checkbox = NSButton(checkboxWithTitle: channel.name, target: nil, action: nil)
                checkbox.tag = channel.rawValue
                checkbox.state = .on // All checked by default
                checkboxes.append(checkbox)
                accessory.addArrangedSubview(checkbox)
            }
        }

        accessory.setFrameSize(NSSize(width: 200, height: CGFloat(checkboxes.count * 24)))
        alert.accessoryView = accessory

        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            for checkbox in checkboxes where checkbox.state == .on {
                let channelIndex = checkbox.tag
                if let filters = channelFilters[channelIndex] {
                    applyFilters(filters, to: channelIndex)
                }
            }
            showSuccess("Filters imported successfully")
        }
    }

    private static func applyFilters(_ filters: [FilterParams], to channelIndex: Int) {
        let vm = AppState.shared.viewModel
        guard let channel = Channel(rawValue: channelIndex) else { return }

        let bandCount = channel.bandCount
        for (i, filter) in filters.prefix(bandCount).enumerated() {
            vm.setFilter(ch: channelIndex, band: i, p: filter)
        }

        // Clear remaining bands if imported fewer filters
        for i in filters.count..<bandCount {
            vm.setFilter(ch: channelIndex, band: i, p: FilterParams(type: .flat, freq: 1000, q: 0.707, gain: 0))
        }
    }

    // MARK: - Alerts

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
    @StateObject private var autoEQBrowserController = AutoEQBrowserController()

    var body: some Scene {
        WindowGroup {
            ContentView(vm: AppState.shared.viewModel)
        }
        .commands {
            // Add to native File menu
            CommandGroup(after: .newItem) {
                Divider()

                Button("Import Filters...") {
                    FileMenuActions.importFilters()
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Export Filters...") {
                    FileMenuActions.exportFilters()
                }
                .keyboardShortcut("e", modifiers: .command)
            }

            // AutoEQ Menu
            CommandMenu("AutoEQ") {
                Button("Browse Profiles...") {
                    autoEQBrowserController.show()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Menu("Recent Profiles") {
                    ForEach(AutoEQManager.shared.recentProfiles) { entry in
                        Button("\(entry.manufacturer) \(entry.model)") {
                            Task {
                                await AutoEQManager.shared.applyRecent(entry)
                            }
                        }
                    }

                    if AutoEQManager.shared.recentProfiles.isEmpty {
                        Text("No recent profiles")
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    Button("Clear Recent") {
                        AutoEQManager.shared.clearRecent()
                    }
                    .disabled(AutoEQManager.shared.recentProfiles.isEmpty)
                }
            }

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
