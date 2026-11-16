//
//  PairingPrompt.swift
//  DSPi Console
//
//  Asks for a hub's pairing code.  Normally a sheet on the main window, like
//  the rename sheets, so it sits over the window and blocks it until
//  answered.  When the main window is hidden (minimised to the menu bar) or
//  already showing a sheet, an app-modal alert asks instead.
//

import AppKit
import SwiftUI

enum PairingPrompt {
    /// Ask for the six-digit code the hub is showing.  `reply` gets the code,
    /// or nil when the user cancels, exactly once.  Main thread only.
    @MainActor
    static func ask(hubName: String, reply: @escaping (String?) -> Void) {
        let center = PairingPromptCenter.shared
        if let window = NSApp.windows.first(where: { $0.title == "DSPi Console" }),
           window.isVisible, window.attachedSheet == nil || center.current != nil {
            center.present(hubName: hubName, reply: reply)
        } else {
            reply(askWithAlert(hubName: hubName))
        }
    }

    /// The fallback when no window can carry the sheet.
    @MainActor
    private static func askWithAlert(hubName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Pair with \(hubName)"
        alert.informativeText = instructions(hubName)
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
        let pin = sanitize(field.stringValue)
        return pin.isEmpty ? nil : pin
    }

    static func instructions(_ hubName: String) -> String {
        "On \(hubName), open Settings > Networking and choose Allow a New Client, then enter the code it shows."
    }

    /// The PIN is six digits (spec 6.2); anything else typed is dropped.
    static func sanitize(_ text: String) -> String {
        String(text.filter(\.isASCII).filter(\.isNumber).prefix(6))
    }
}

/// The pairing requests waiting for the main window's sheet.  Requests from
/// several hubs queue; each gets its answer in turn.
@MainActor
final class PairingPromptCenter: ObservableObject {
    static let shared = PairingPromptCenter()

    struct Request: Identifiable {
        let id = UUID()
        let hubName: String
        let reply: (String?) -> Void
    }

    @Published private(set) var current: Request?
    private var waiting: [Request] = []

    func present(hubName: String, reply: @escaping (String?) -> Void) {
        let request = Request(hubName: hubName, reply: reply)
        if current == nil { current = request } else { waiting.append(request) }
    }

    /// Answer the request on screen.  A second call (the sheet's dismissal
    /// after a button already answered) does nothing.
    func answer(_ pin: String?) {
        guard let request = current else { return }
        current = nil
        request.reply(pin)
        guard !waiting.isEmpty else { return }
        // Let the closing sheet finish before the next one opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.current == nil, !self.waiting.isEmpty else { return }
            self.current = self.waiting.removeFirst()
        }
    }
}

/// The sheet itself, laid out like the rename sheets.
struct PairingSheet: View {
    let hubName: String
    let onAnswer: (String?) -> Void
    @State private var pin = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair with \(hubName)").font(.headline)
            Text(PairingPrompt.instructions(hubName))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            TextField("000000", text: $pin)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 18, weight: .medium).monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 200)
                .onChange(of: pin) { _, new in
                    let clean = PairingPrompt.sanitize(new)
                    if clean != new { pin = clean }
                }
            HStack {
                Button("Cancel") { onAnswer(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Pair") { onAnswer(pin) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin.isEmpty)
            }
        }
        .padding()
        .frame(width: 280)
    }
}
