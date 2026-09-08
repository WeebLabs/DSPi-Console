//
//  PairingPrompt.swift
//  DSPi Console
//
//  The modal that asks for a hub's pairing code, in the app's NSAlert style.
//

import AppKit

enum PairingPrompt {
    /// Ask for the six-digit code the hub is showing.  Main thread only.
    static func ask(hubName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Pair with \(hubName)"
        alert.informativeText = "On \(hubName), open Settings > Networking and choose Allow a New Client, then enter the code it shows."
        alert.alertStyle = .informational
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        field.placeholderString = "000000"
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        alert.accessoryView = field
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let pin = field.stringValue.trimmingCharacters(in: .whitespaces)
        return pin.isEmpty ? nil : pin
    }
}
