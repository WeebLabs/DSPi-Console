import AppKit

// The floating parameter display beside a band's dot, after FabFilter Pro-Q
// 4's: bypass and delete, the band's frequency, gain and Q, a shape button
// that opens a strip of shapes and slopes, and a chevron for the band menu.
// Values can be dragged, scrolled, or double-clicked to type one in.  All
// AppKit, so moving or updating it during a drag costs SwiftUI nothing.

enum PeqHUDField: Int, CaseIterable { case freq, gain, q }

enum PeqAdjustPhase { case began, changed, ended }

/// Small drawn glyphs for the shape button and strip, as template images.
enum PeqShapeGlyph {
    private static var cache: [PeqShape: NSImage] = [:]

    static func image(_ shape: PeqShape) -> NSImage {
        if let cached = cache[shape] { return cached }
        let size = NSSize(width: 18, height: 12)
        let image = NSImage(size: size, flipped: true) { _ in
            let p = NSBezierPath()
            p.lineWidth = 1.5
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            let mid: CGFloat = 7
            switch shape {
            case .bell:
                p.move(to: NSPoint(x: 1, y: 9))
                p.curve(to: NSPoint(x: 9, y: 2), controlPoint1: NSPoint(x: 5, y: 9), controlPoint2: NSPoint(x: 6.5, y: 2))
                p.curve(to: NSPoint(x: 17, y: 9), controlPoint1: NSPoint(x: 11.5, y: 2), controlPoint2: NSPoint(x: 13, y: 9))
            case .lowShelf:
                p.move(to: NSPoint(x: 1, y: 3))
                p.line(to: NSPoint(x: 6, y: 3))
                p.curve(to: NSPoint(x: 12, y: 9), controlPoint1: NSPoint(x: 9, y: 3), controlPoint2: NSPoint(x: 9, y: 9))
                p.line(to: NSPoint(x: 17, y: 9))
            case .highShelf:
                p.move(to: NSPoint(x: 1, y: 9))
                p.line(to: NSPoint(x: 6, y: 9))
                p.curve(to: NSPoint(x: 12, y: 3), controlPoint1: NSPoint(x: 9, y: 9), controlPoint2: NSPoint(x: 9, y: 3))
                p.line(to: NSPoint(x: 17, y: 3))
            case .lowCut:
                p.move(to: NSPoint(x: 3, y: 11))
                p.curve(to: NSPoint(x: 10, y: 4), controlPoint1: NSPoint(x: 5, y: 5), controlPoint2: NSPoint(x: 7, y: 4))
                p.line(to: NSPoint(x: 17, y: 4))
            case .highCut:
                p.move(to: NSPoint(x: 1, y: 4))
                p.line(to: NSPoint(x: 8, y: 4))
                p.curve(to: NSPoint(x: 15, y: 11), controlPoint1: NSPoint(x: 11, y: 4), controlPoint2: NSPoint(x: 13, y: 5))
            case .notch:
                p.move(to: NSPoint(x: 1, y: 3))
                p.line(to: NSPoint(x: 6.5, y: 3))
                p.curve(to: NSPoint(x: 9, y: 11), controlPoint1: NSPoint(x: 8.2, y: 3), controlPoint2: NSPoint(x: 8.6, y: 11))
                p.curve(to: NSPoint(x: 11.5, y: 3), controlPoint1: NSPoint(x: 9.4, y: 11), controlPoint2: NSPoint(x: 9.8, y: 3))
                p.line(to: NSPoint(x: 17, y: 3))
            case .allPass:
                p.move(to: NSPoint(x: 1, y: mid))
                p.line(to: NSPoint(x: 5, y: mid))
                p.curve(to: NSPoint(x: 13, y: mid), controlPoint1: NSPoint(x: 8, y: 0), controlPoint2: NSPoint(x: 10, y: 14))
                p.line(to: NSPoint(x: 17, y: mid))
            }
            NSColor.black.setStroke()
            p.stroke()
            return true
        }
        image.isTemplate = true
        cache[shape] = image
        return image
    }
}

/// A borderless HUD button: a template image or short title, a soft
/// highlight on hover, and an optional "on" tint.
final class PeqHUDButton: NSButton {
    var tint: NSColor = NSColor(white: 1, alpha: 0.82) { didSet { applyTint() } }
    var isOn = false { didSet { updateBackground() } }
    var handler: (() -> Void)?
    private var hovering = false { didSet { updateBackground() } }

    convenience init(symbol: String, size: CGFloat = 11, weight: NSFont.Weight = .semibold, help: String) {
        self.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?.withSymbolConfiguration(config)
        toolTip = help
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 5
        target = self
        action = #selector(fire)
        applyTint()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler?() }

    func setTitle(_ text: String, size: CGFloat = 10.5) {
        imagePosition = .noImage
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: tint,
        ])
    }

    private func applyTint() {
        contentTintColor = tint
        if imagePosition == .noImage { setTitle(title) }
    }

    private func updateBackground() {
        let alpha: CGFloat = isOn ? 0.16 : (hovering ? 0.09 : 0)
        layer?.backgroundColor = NSColor(white: 1, alpha: alpha).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// One value line: drag vertically or scroll to adjust, double-click to type.
final class PeqHUDValueField: NSTextField {
    let field: PeqHUDField
    var adjustable = true
    var onAdjust: ((PeqHUDField, CGFloat, Bool, PeqAdjustPhase) -> Void)?
    var onScroll: ((PeqHUDField, CGFloat, Bool) -> Void)?
    var onBeginEditing: ((PeqHUDField) -> Void)?
    private var dragStart: CGFloat = 0
    private var dragged: CGFloat = 0
    private var lastY: CGFloat = 0

    init(field: PeqHUDField) {
        self.field = field
        super.init(frame: .zero)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        focusRingType = .none
        alignment = .center
        lineBreakMode = .byClipping
        font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        textColor = NSColor(white: 1, alpha: 0.92)
        usesSingleLineMode = true
        cell?.isScrollable = true
    }
    required init?(coder: NSCoder) { fatalError() }

    var isEditingText: Bool { currentEditor() != nil }

    func beginTextEditing() {
        isEditable = true
        isSelectable = true
        drawsBackground = true
        backgroundColor = NSColor(white: 0, alpha: 0.35)
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    func endTextEditing() {
        isEditable = false
        isSelectable = false
        drawsBackground = false
    }

    override func resetCursorRects() {
        if adjustable, !isEditable { addCursorRect(bounds, cursor: .resizeUpDown) }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isEditable else { super.mouseDown(with: event); return }
        if event.clickCount == 2 { onBeginEditing?(field); return }
        guard adjustable else { return }
        lastY = NSEvent.mouseLocation.y
        dragged = 0
        onAdjust?(field, 0, false, .began)
    }
    override func mouseDragged(with event: NSEvent) {
        guard !isEditable, adjustable else { return }
        let y = NSEvent.mouseLocation.y
        let fine = event.modifierFlags.contains(.shift)
        dragged += (y - lastY) * (fine ? 0.12 : 1)
        lastY = y
        onAdjust?(field, dragged, fine, .changed)
    }
    override func mouseUp(with event: NSEvent) {
        guard !isEditable, adjustable else { return }
        onAdjust?(field, dragged, false, .ended)
    }
    override func scrollWheel(with event: NSEvent) {
        guard !isEditable, adjustable else { super.scrollWheel(with: event); return }
        let fine = event.modifierFlags.contains(.shift)
        let raw = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        onScroll?(field, event.hasPreciseScrollingDeltas ? raw : raw * 8, fine)
    }
}

final class PeqBandHUD: NSView, NSTextFieldDelegate {
    static let size = NSSize(width: 168, height: 60)

    var onBypass: (() -> Void)?
    var onDelete: (() -> Void)?
    var onShapeButton: (() -> Void)?
    var onMenu: ((NSView) -> Void)?
    var onAdjust: ((PeqHUDField, CGFloat, Bool, PeqAdjustPhase) -> Void)?
    var onScroll: ((PeqHUDField, CGFloat, Bool) -> Void)?
    /// Returns false when the text did not parse, which keeps the field open.
    var onText: ((PeqHUDField, String) -> Bool)?
    var onEditingChanged: ((Bool) -> Void)?

    private let power = PeqHUDButton(symbol: "power", help: "Bypass band (Option-click the dot)")
    private let close = PeqHUDButton(symbol: "xmark", size: 10, help: "Delete band")
    private let shapeButton = PeqHUDButton(frame: .zero)
    private let menuButton = PeqHUDButton(symbol: "chevron.down", size: 9, help: "Band menu")
    private let values: [PeqHUDValueField] = PeqHUDField.allCases.map(PeqHUDValueField.init)
    private var editingField: PeqHUDField?
    private var cancelling = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 0.94).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: 0.11).cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        power.frame = NSRect(x: 6, y: 6, width: 22, height: 20)
        close.frame = NSRect(x: Self.size.width - 28, y: 6, width: 22, height: 20)
        shapeButton.frame = NSRect(x: 6, y: 33, width: 26, height: 21)
        shapeButton.imagePosition = .imageOnly
        shapeButton.toolTip = "Shape and slope (Command-Option-click the dot cycles shapes)"
        menuButton.frame = NSRect(x: Self.size.width - 26, y: 36, width: 20, height: 18)
        power.handler = { [weak self] in self?.onBypass?() }
        close.handler = { [weak self] in self?.onDelete?() }
        shapeButton.handler = { [weak self] in self?.onShapeButton?() }
        menuButton.handler = { [weak self] in
            guard let self else { return }
            self.onMenu?(self.menuButton)
        }
        for (i, v) in values.enumerated() {
            v.frame = NSRect(x: 34, y: 4 + CGFloat(i) * 17, width: Self.size.width - 68, height: 17)
            v.delegate = self
            v.onAdjust = { [weak self] in self?.onAdjust?($0, $1, $2, $3) }
            v.onScroll = { [weak self] in self?.onScroll?($0, $1, $2) }
            v.onBeginEditing = { [weak self] in self?.beginEditing($0) }
            addSubview(v)
        }
        [power, close, shapeButton, menuButton].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    // The panel's own background swallows clicks, which would otherwise
    // fall through to the graph and create a band behind it.
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    var isEditingText: Bool { editingField != nil }

    /// Shows `p`.  `color` is the band's; bypass lights the power button.
    func show(_ p: FilterParams, color: NSColor, bypassSupported: Bool) {
        guard let (shape, order) = PeqShape.of(p.type) else {
            // The Linkwitz Transform: shown, edited in the band list.
            values[0].stringValue = "f0 " + PeqValueText.frequency(Double(p.freq))
            values[1].stringValue = "fp " + PeqValueText.frequency(Double(p.gain))
            values[2].stringValue = "Linkwitz"
            values.forEach { $0.adjustable = false; $0.textColor = NSColor(white: 1, alpha: 0.6) }
            shapeButton.isHidden = true
            power.isHidden = !bypassSupported
            power.tint = p.bypass ? NSColor(white: 1, alpha: 0.35) : color
            return
        }
        shapeButton.isHidden = false
        shapeButton.image = PeqShapeGlyph.image(shape)
        shapeButton.tint = color
        power.isHidden = !bypassSupported
        power.tint = p.bypass ? NSColor(white: 1, alpha: 0.35) : color
        power.toolTip = p.bypass ? "Enable band (Option-click the dot)" : "Bypass band (Option-click the dot)"
        let dim = NSColor(white: 1, alpha: 0.5)
        let bright = NSColor(white: 1, alpha: p.bypass ? 0.55 : 0.92)
        guard editingField == nil else { return }
        values[0].stringValue = PeqValueText.frequency(Double(p.freq))
        values[0].adjustable = true
        values[0].textColor = bright
        if p.type.usesGain {
            values[1].stringValue = PeqValueText.gain(Double(p.gain))
            values[1].adjustable = true
            values[1].textColor = bright
        } else {
            values[1].stringValue = shape.title
            values[1].adjustable = false
            values[1].textColor = dim
        }
        if p.type.usesQ {
            values[2].stringValue = "Q " + PeqValueText.q(Double(p.q))
            values[2].adjustable = true
            values[2].textColor = bright
        } else {
            values[2].stringValue = shape == .allPass ? shape.orderTitle(order) : "6 dB/oct"
            values[2].adjustable = false
            values[2].textColor = dim
        }
        values.forEach { window?.invalidateCursorRects(for: $0) }
    }

    func beginEditing(_ field: PeqHUDField) {
        guard values[field.rawValue].adjustable else {
            if let next = nextField(after: field, backwards: false) { beginEditing(next) }
            return
        }
        if let current = editingField, current != field { values[current.rawValue].endTextEditing() }
        editingField = field
        onEditingChanged?(true)
        let v = values[field.rawValue]
        // Type the bare number; the unit is implied.
        switch field {
        case .freq: v.stringValue = PeqValueText.shortFrequency(PeqValueText.parseFrequency(v.stringValue.replacingOccurrences(of: " kHz", with: "k")) ?? 0)
        case .gain: v.stringValue = v.stringValue.replacingOccurrences(of: " dB", with: "")
        case .q: v.stringValue = v.stringValue.replacingOccurrences(of: "Q ", with: "")
        }
        v.beginTextEditing()
    }

    func endEditing() {
        guard let field = editingField else { return }
        editingField = nil
        values[field.rawValue].endTextEditing()
        window?.makeFirstResponder(superview)
        onEditingChanged?(false)
    }

    private func nextField(after field: PeqHUDField, backwards: Bool) -> PeqHUDField? {
        let order = backwards ? PeqHUDField.allCases.reversed() : PeqHUDField.allCases
        let list = Array(order)
        guard let i = list.firstIndex(of: field) else { return nil }
        for candidate in list[(i + 1)...] + list[..<i] where values[candidate.rawValue].adjustable { return candidate }
        return nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelling = true
            endEditing()
            cancelling = false
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ note: Notification) {
        guard !cancelling, let field = editingField,
              let v = note.object as? PeqHUDValueField, v.field == field else { return }
        let movement = (note.userInfo?["NSTextMovement"] as? Int) ?? NSTextMovement.other.rawValue
        let accepted = onText?(field, v.stringValue) ?? true
        if !accepted { NSSound.beep() }
        switch NSTextMovement(rawValue: movement) {
        case .tab?, .backtab?:
            let next = nextField(after: field, backwards: movement == NSTextMovement.backtab.rawValue) ?? field
            editingField = nil
            v.endTextEditing()
            beginEditing(next)
        default:
            endEditing()
        }
    }
}

/// The row of shapes, and slopes where the current shape has two, that opens
/// from the HUD's shape button.
final class PeqShapeStrip: NSView {
    var onPick: ((PeqShape, Int) -> Void)?
    private var buttons: [NSView] = []
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 0.96).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: 0.11).cgColor
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    /// Rebuilds for band `p`, offering only shapes the firmware supports.
    func configure(for p: FilterParams, available: Set<FilterType>, color: NSColor) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        let current = PeqShape.of(p.type)
        var x: CGFloat = 4
        for shape in PeqShape.allCases {
            let order = current?.shape == shape ? current!.order : 2
            guard let type = shape.type(order: order) ?? shape.type(order: 1), available.contains(type) else { continue }
            let b = PeqHUDButton(frame: NSRect(x: x, y: 4, width: 28, height: 22))
            b.imagePosition = .imageOnly
            b.image = PeqShapeGlyph.image(shape)
            b.toolTip = shape.title
            b.isOn = current?.shape == shape
            b.tint = current?.shape == shape ? color : NSColor(white: 1, alpha: 0.75)
            b.handler = { [weak self] in self?.onPick?(shape, order) }
            addSubview(b)
            buttons.append(b)
            x += 30
        }
        if let current, let first = current.shape.type(order: 1), let second = current.shape.type(order: 2),
           available.contains(first), available.contains(second) {
            let divider = NSView(frame: NSRect(x: x + 2, y: 7, width: 1, height: 16))
            divider.wantsLayer = true
            divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
            addSubview(divider)
            buttons.append(divider)
            x += 7
            for order in [1, 2] {
                let title = current.shape == .allPass ? (order == 1 ? "1st" : "2nd") : (order == 1 ? "6 dB" : "12 dB")
                let b = PeqHUDButton(frame: NSRect(x: x, y: 4, width: 40, height: 22))
                b.tint = current.order == order ? color : NSColor(white: 1, alpha: 0.75)
                b.setTitle(title)
                b.isOn = current.order == order
                b.toolTip = current.shape.orderTitle(order)
                b.handler = { [weak self] in self?.onPick?(current.shape, order) }
                addSubview(b)
                buttons.append(b)
                x += 42
            }
        }
        setFrameSize(NSSize(width: x + 2, height: 30))
    }
}
