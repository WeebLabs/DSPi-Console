import SwiftUI
import AppKit

// MARK: - Pin pickers driven by the device
//
// Every GPIO picker builds its rows from the function's availability reply
// (pin_availability_query_spec.md 5 and 12.1) and labels held pins from the
// claim list.  SwiftUI's menu Picker cannot disable single items on macOS, so
// the menu is an NSPopUpButton with autoenablesItems off.

/// One row of a pin menu.
struct PinChoice: Hashable {
    let pin: UInt8
    /// False: shown, but it cannot be picked.
    let enabled: Bool
    /// Who holds the pin, or why it is unavailable; nil for a free pin.
    let note: String?
}

/// How a picker treats pins another function holds.
enum PinPickerMode {
    /// The function is in use (or will be once applied): held pins are shown disabled.
    case claim
    /// The function is off: any valid pin can be stored, held ones are marked.
    case store
}

extension DSPViewModel {

    /// Rows for a pin picker.  `role` and `group` pick the mask for multi-pin
    /// functions (group nil: every group).  `extraFree` adds pins the caller
    /// may also take (a Control Surfaces button's shareable pins).  The
    /// current pin is always listed.
    func pinChoices(_ avail: PinAvailability?, mode: PinPickerMode, function: PinFunction, index: Int = 0,
                    role: Int = 0, group: Int? = nil, current: UInt8?, extraFree: UInt64 = 0) -> [PinChoice] {
        guard let avail else {
            return current.map { [PinChoice(pin: $0, enabled: true, note: nil)] } ?? []
        }
        let valid: [UInt8]
        if let group, group < avail.groupCount, role < avail.roleCount {
            valid = pins(in: avail.masks[group][role].valid)
        } else {
            valid = avail.validPins(role: role)
        }
        var rows = valid.map { pin -> PinChoice in
            let free = avail.isFree(pin, role: role) || extraFree & (1 << UInt64(pin)) != 0
            if free { return PinChoice(pin: pin, enabled: true, note: nil) }
            let reason = pinBlockReason(pin, avail: avail, function: function, index: index)
            switch mode {
            case .claim:
                return PinChoice(pin: pin, enabled: pin == current, note: reason)
            case .store:
                return PinChoice(pin: pin, enabled: true, note: "held by \(reason)")
            }
        }
        if let current, current != 0xFF, !rows.contains(where: { $0.pin == current }) {
            rows.append(PinChoice(pin: current, enabled: true, note: "not valid here"))
            rows.sort { $0.pin < $1.pin }
        }
        return rows
    }

    /// Why every pin picker is read-only, when the device cannot answer.
    var pinMapUnavailableReason: String? {
        switch pinMap.snapshot.support {
        case .absent: return "Update the firmware to change pins"
        case .denied: return "Pin changes need an admin session on this DSPi Link hub"
        case .failed: return "The device did not report its pins; reconnect to try again"
        default: return nil
        }
    }

    /// The function-level block of an availability reply, as a reason line.
    func pinStateReason(_ avail: PinAvailability?, whenBlocked text: String) -> String? {
        avail?.status == VC_ERR_STATE_STATUS ? text : nil
    }
}

/// A pin pop-up: "GPIO n" on its face, the menu listing every row with its
/// owner in an aligned second column.
struct PinPopUpButton: NSViewRepresentable {
    let choices: [PinChoice]
    let selection: UInt8?
    var enabled: Bool = true
    /// Text for the face; defaults to "GPIO n".
    var faceTitle: ((UInt8) -> String)? = nil
    var rowTitle: ((UInt8) -> String)? = nil
    let onSelect: (UInt8) -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        // A pull-down keeps the face under our control: its first item is the
        // title, so an owner note never widens the closed button.
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.autoenablesItems = false
        button.controlSize = .regular
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = enabled
        button.menu?.delegate = context.coordinator
        context.coordinator.rebuild(button)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: PinPopUpButton
        private var signature: [String] = []
        private weak var button: NSPopUpButton?
        /// Rebuilding an open menu drops its highlight, so a change that
        /// arrives meanwhile waits for the menu to close.
        private var menuOpen = false
        private var rebuildPending = false

        init(parent: PinPopUpButton) { self.parent = parent }

        func menuWillOpen(_ menu: NSMenu) { menuOpen = true }

        func menuDidClose(_ menu: NSMenu) {
            menuOpen = false
            // AppKit sends the chosen item's action after the menu closes, so
            // the rebuild waits a turn rather than replacing that item first.
            guard rebuildPending else { return }
            rebuildPending = false
            DispatchQueue.main.async { [weak self] in
                guard let self, let button = self.button else { return }
                self.rebuild(button)
            }
        }

        func rebuild(_ button: NSPopUpButton) {
            self.button = button
            let p = parent
            let face = p.selection.map { p.faceTitle?($0) ?? "GPIO \($0)" } ?? "None"
            let titles = p.choices.map { p.rowTitle?($0.pin) ?? "GPIO \($0.pin)" }
            let sig = [face, "\(p.selection ?? 0xFF)"] + zip(p.choices, titles).map { c, t in
                "\(t)|\(c.enabled)|\(c.note ?? "")"
            }
            guard sig != signature else { return }
            if menuOpen { rebuildPending = true; return }
            signature = sig

            guard let menu = button.menu else { return }
            menu.removeAllItems()
            // A pull-down keeps the face under our control: its first item is
            // the title, so an owner note never widens the closed button.
            let title = NSMenuItem(title: face, action: nil, keyEquivalent: "")
            title.tag = -1
            menu.addItem(title)

            // One tab stop so every owner note starts in the same column.
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 72)]
            let font = NSFont.menuFont(ofSize: 0)
            for (choice, rowTitle) in zip(p.choices, titles) {
                let item = NSMenuItem(title: "", action: #selector(picked(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(choice.pin)
                item.isEnabled = choice.enabled
                item.state = choice.pin == p.selection ? .on : .off
                // Enabled text carries no colour of its own so the menu can
                // draw it highlighted; disabled text is dimmed explicitly.
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
                if !choice.enabled { attrs[.foregroundColor] = NSColor.disabledControlTextColor }
                let text = NSMutableAttributedString(string: rowTitle, attributes: attrs)
                if let note = choice.note {
                    text.append(NSAttributedString(string: "\t\(note)",
                                                   attributes: [.font: font, .paragraphStyle: paragraph,
                                                                .foregroundColor: NSColor.secondaryLabelColor]))
                }
                item.attributedTitle = text
                menu.addItem(item)
            }
        }

        @objc func picked(_ sender: Any) {
            guard let item = sender as? NSMenuItem, item.isEnabled, item.tag >= 0, item.tag < 256 else { return }
            let pin = UInt8(item.tag)
            guard pin != parent.selection else { return }
            parent.onSelect(pin)
        }
    }
}

/// Keeps the pin map's availability sweep running while a view is on screen.
struct PinMapWatcher: ViewModifier {
    let vm: DSPViewModel
    func body(content: Content) -> some View {
        content
            .onAppear { vm.pinMap.watch(shape: vm.pinMapShape) }
            .onDisappear { vm.pinMap.unwatch() }
    }
}

/// Keeps Control Surfaces availability fetched for a set of binding slots.
struct CsSlotWatcher: ViewModifier {
    let vm: DSPViewModel
    let slots: Set<Int>
    @State private var watched: Set<Int> = []

    func body(content: Content) -> some View {
        content
            .onAppear { sync(slots) }
            .onChange(of: slots) { _, new in sync(new) }
            .onDisappear { sync([]) }
    }

    private func sync(_ new: Set<Int>) {
        for s in watched.subtracting(new) { vm.pinMap.unwatchCS(slot: s) }
        for s in new.subtracting(watched) { vm.pinMap.watchCS(slot: s, shape: vm.pinMapShape) }
        watched = new
    }
}

extension View {
    func watchesPinMap(_ vm: DSPViewModel) -> some View { modifier(PinMapWatcher(vm: vm)) }
    func watchesCsSlots(_ vm: DSPViewModel, _ slots: Set<Int>) -> some View {
        modifier(CsSlotWatcher(vm: vm, slots: slots))
    }
}
