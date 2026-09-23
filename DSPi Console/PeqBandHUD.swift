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

    convenience init(symbol: String, size: CGFloat = 11, weight: NSFont.Weight = .regular, help: String) {
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
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
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

/// Frosted panel chrome shared by the chip and the shape strip: the graph
/// shows through, blurred, under a hairline edge and a soft shadow.  The
/// shadow has an explicit path, so the GPU never derives it from content.
class PeqFrostedPanel: NSView {
    private let effect = NSVisualEffectView()
    private let radius: CGFloat
    override var isFlipped: Bool { true }

    init(cornerRadius: CGFloat) {
        radius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        effect.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    // The panel's own background swallows clicks, which would otherwise
    // fall through to the graph and create a band behind it.
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
}

/// The compact card beside a hovered band's dot: a header with the shape's
/// glyph in the band colour and its two-letter code (a fixed width, so the
/// card never changes size with the type; click for the shape strip), bypass on
/// the right, then one row per value.  Deleting is the Delete key or the band
/// menu, so the card spends no width on it.  Rows are label, number and
/// unit in fixed columns so the decimals line up.  The card is tall and
/// narrow on purpose: bands crowd along the frequency axis, so a narrow card
/// covers fewer neighbouring dots.  Only the rows a shape uses appear.
final class PeqBandHUD: PeqFrostedPanel, NSTextFieldDelegate {
    var onBypass: (() -> Void)?
    var onShapeButton: (() -> Void)?
    var onAdjust: ((PeqHUDField, CGFloat, Bool, PeqAdjustPhase) -> Void)?
    var onScroll: ((PeqHUDField, CGFloat, Bool) -> Void)?
    /// Returns false when the text did not parse, which keeps the field open.
    var onText: ((PeqHUDField, String) -> Bool)?
    var onEditingChanged: ((Bool) -> Void)?

    /// The size for the band last shown; the editor positions it.
    private(set) var preferredSize = NSSize(width: 110, height: 78)

    private enum Metrics {
        static let pad: CGFloat = 8
        static let headerY: CGFloat = 4
        static let headerHeight: CGFloat = 17
        static let rule: CGFloat = 24
        static let firstRow: CGFloat = 28
        static let rowHeight: CGFloat = 15
        static let bottom: CGFloat = 5
        static let label: CGFloat = 28
        static let number: CGFloat = 44
        static let gap: CGFloat = 3
        /// Wide enough for "kHz"; a slope row needs room for "dB/oct".
        static func unit(slope: Bool) -> CGFloat { slope ? 28 : 19 }
    }

    private let power = PeqHUDButton(symbol: "power", size: 9, help: "Bypass band (Option-click the dot)")
    private let shapeButton = PeqHUDButton(frame: .zero)
    private let ruleLine = NSView()
    private let values: [PeqHUDValueField] = PeqHUDField.allCases.map(PeqHUDValueField.init)
    private let labels: [NSTextField] = PeqHUDField.allCases.map { _ in NSTextField(labelWithString: "") }
    private let units: [NSTextField] = PeqHUDField.allCases.map { _ in NSTextField(labelWithString: "") }
    private var editingField: PeqHUDField?
    private var cancelling = false
    private var shown: (params: FilterParams, color: NSColor, bypassSupported: Bool)?

    init() {
        super.init(cornerRadius: 8)
        shapeButton.imagePosition = .imageLeading
        shapeButton.imageHugsTitle = true
        shapeButton.toolTip = "Shape and slope (Command-Option-click the dot cycles shapes)"
        power.handler = { [weak self] in self?.onBypass?() }
        shapeButton.handler = { [weak self] in self?.onShapeButton?() }
        ruleLine.wantsLayer = true
        ruleLine.layer?.backgroundColor = NSColor(white: 1, alpha: 0.09).cgColor
        for (i, v) in values.enumerated() {
            v.delegate = self
            v.font = Self.valueFont
            v.alignment = .right
            v.onAdjust = { [weak self] in self?.onAdjust?($0, $1, $2, $3) }
            v.onScroll = { [weak self] in self?.onScroll?($0, $1, $2) }
            v.onBeginEditing = { [weak self] in self?.beginEditing($0) }
            for label in [labels[i], units[i]] {
                label.font = Self.quietFont
                label.lineBreakMode = .byClipping
                addSubview(label)
            }
            addSubview(v)
        }
        [ruleLine, shapeButton, power].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    var isEditingText: Bool { editingField != nil }

    // MARK: Text

    // Regular weight with monospaced digits, like the band list's fields.
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let quietFont = NSFont.systemFont(ofSize: 9.5, weight: .regular)

    private static func number(_ text: String, dim: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        return NSAttributedString(string: text, attributes: [
            .font: valueFont,
            .foregroundColor: NSColor(white: 1, alpha: dim ? 0.45 : 0.88),
            .paragraphStyle: paragraph,
        ])
    }

    /// Two decimal places, truncated rather than rounded, so the chip never
    /// shows a value the band does not quite have.  The small epsilon keeps
    /// Float noise (1.1 stored as 1.0999999) from dropping a digit.
    static func truncated(_ v: Double, sign: Bool = false) -> String {
        let t = (abs(v) * 100 + 1e-5).rounded(.down) / 100
        let text = String(format: "%.2f", t)
        if t == 0 { return sign ? "+" + text : text }
        return v < 0 ? "-" + text : (sign ? "+" + text : text)
    }

    private static func frequencyParts(_ hz: Double) -> (String, String) {
        hz >= 1000 ? (truncated(hz / 1000), "kHz") : (truncated(hz), "Hz")
    }

    private static let chevron: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 6.5, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 1, alpha: 0.42)]))
        return NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }()

    private func shapeTitle(_ text: String, dim: Bool) -> NSAttributedString {
        let title = NSMutableAttributedString(string: " " + text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 1, alpha: dim ? 0.5 : 0.85),
        ])
        if let chevron = Self.chevron {
            let attachment = NSTextAttachment()
            attachment.image = chevron
            attachment.bounds = CGRect(x: 0, y: 1.5, width: chevron.size.width, height: chevron.size.height)
            title.append(NSAttributedString(string: " "))
            title.append(NSAttributedString(attachment: attachment))
        }
        return title
    }

    // MARK: Content

    private struct Row {
        let field: PeqHUDField
        let label: String
        let number: String
        let unit: String
        let adjustable: Bool
    }

    /// Shows `p` in band colour `color`.  Bypass dims the card's content and
    /// greys the power button.
    func show(_ p: FilterParams, color: NSColor, bypassSupported: Bool) {
        shown = (p, color, bypassSupported)
        let dim = p.bypass
        let muted = NSColor(white: 1, alpha: 0.4)
        power.isHidden = !bypassSupported
        power.tint = dim ? muted : color
        power.toolTip = dim ? "Enable band (Option-click the dot)" : "Bypass band (Option-click the dot)"

        var rows: [Row] = []
        if let (shape, order) = PeqShape.of(p.type) {
            shapeButton.isEnabled = true
            shapeButton.image = PeqShapeGlyph.image(shape)
            shapeButton.tint = dim ? muted : color
            shapeButton.attributedTitle = shapeTitle(shape.code, dim: dim)
            shapeButton.toolTip = "\(shape.title) - click for shapes and slopes"
            let f = Self.frequencyParts(Double(p.freq))
            rows.append(Row(field: .freq, label: "Freq", number: f.0, unit: f.1, adjustable: true))
            if p.type.usesGain {
                rows.append(Row(field: .gain, label: "Gain", number: Self.truncated(Double(p.gain), sign: true),
                                unit: "dB", adjustable: true))
            }
            if p.type.usesQ {
                // "Width", as the band list's column header calls it, with Q
                // as the unit, so every row reads label, number, unit.
                rows.append(Row(field: .q, label: "Width", number: Self.truncated(Double(p.q)), unit: "Q", adjustable: true))
            } else if shape == .allPass {
                rows.append(Row(field: .q, label: "Order", number: "1st", unit: "", adjustable: false))
            } else {
                rows.append(Row(field: .q, label: "Slope", number: "6", unit: "dB/oct", adjustable: false))
            }
            _ = order
        } else {
            // The Linkwitz Transform: shown here, edited in the band list.
            shapeButton.isEnabled = false
            shapeButton.image = nil
            shapeButton.attributedTitle = NSAttributedString(string: "LT", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor(white: 1, alpha: 0.7),
            ])
            shapeButton.toolTip = "Linkwitz Transform - edit it in the band list"
            let f0 = Self.frequencyParts(Double(p.freq)), fp = Self.frequencyParts(Double(p.gain))
            rows.append(Row(field: .freq, label: "f0", number: f0.0, unit: f0.1, adjustable: false))
            rows.append(Row(field: .gain, label: "fp", number: fp.0, unit: fp.1, adjustable: false))
        }

        // A fixed header: the code is always two letters wide.
        let shapeWidth: CGFloat = 60
        let button: CGFloat = bypassSupported ? 20 : 0
        let unitWidth = Metrics.unit(slope: rows.contains { $0.label == "Slope" })
        let columns = Metrics.label + Metrics.number + Metrics.gap + unitWidth
        let width = ceil(max(Metrics.pad * 2 + columns, 4 + shapeWidth + 2 + button + 4))
        let height = Metrics.firstRow + CGFloat(rows.count) * Metrics.rowHeight + Metrics.bottom
        preferredSize = NSSize(width: width, height: height)
        setFrameSize(preferredSize)

        shapeButton.frame = NSRect(x: 4, y: Metrics.headerY, width: shapeWidth, height: Metrics.headerHeight)
        power.frame = NSRect(x: width - 22, y: Metrics.headerY, width: 18, height: Metrics.headerHeight)
        ruleLine.frame = NSRect(x: Metrics.pad, y: Metrics.rule, width: width - Metrics.pad * 2, height: 1)

        // Columns anchored to the right edge, so the numbers line up whatever
        // width the header asked for.
        let unitX = width - Metrics.pad - unitWidth
        let numberX = unitX - Metrics.gap - Metrics.number
        let quiet = NSColor(white: 1, alpha: dim ? 0.28 : 0.45)
        for field in PeqHUDField.allCases {
            let i = field.rawValue
            guard let r = rows.firstIndex(where: { $0.field == field }) else {
                [values[i], labels[i], units[i]].forEach { $0.isHidden = true }
                continue
            }
            let row = rows[r]
            let y = Metrics.firstRow + CGFloat(r) * Metrics.rowHeight
            labels[i].stringValue = row.label
            labels[i].textColor = quiet
            labels[i].frame = NSRect(x: Metrics.pad, y: y + 1, width: numberX - Metrics.pad, height: Metrics.rowHeight)
            units[i].stringValue = row.unit
            units[i].textColor = quiet
            units[i].frame = NSRect(x: unitX, y: y + 1, width: unitWidth, height: Metrics.rowHeight)
            let v = values[i]
            v.adjustable = row.adjustable
            v.frame = NSRect(x: numberX, y: y, width: Metrics.number, height: Metrics.rowHeight)
            if editingField != field { v.attributedStringValue = Self.number(row.number, dim: dim || !row.adjustable) }
            [v, labels[i], units[i]].forEach { $0.isHidden = false }
            window?.invalidateCursorRects(for: v)
        }
    }

    // MARK: Typing

    func beginEditing(_ field: PeqHUDField) {
        let v = values[field.rawValue]
        guard !v.isHidden, v.adjustable, let p = shown?.params else {
            if let next = nextField(after: field, backwards: false) { beginEditing(next) }
            return
        }
        if let current = editingField, current != field { values[current.rawValue].endTextEditing() }
        editingField = field
        onEditingChanged?(true)
        // Type the bare number; the unit is implied, and "2k" or "A4" work.
        switch field {
        case .freq: v.stringValue = PeqValueText.shortFrequency(Double(p.freq))
        case .gain: v.stringValue = String(format: "%.2f", p.gain)
        case .q: v.stringValue = String(format: "%.3f", p.q)
        }
        v.font = Self.valueFont
        v.textColor = NSColor(white: 1, alpha: 0.94)
        v.beginTextEditing()
    }

    func endEditing() {
        guard let field = editingField else { return }
        editingField = nil
        values[field.rawValue].endTextEditing()
        window?.makeFirstResponder(superview)
        if let s = shown { show(s.params, color: s.color, bypassSupported: s.bypassSupported) }
        onEditingChanged?(false)
    }

    private func nextField(after field: PeqHUDField, backwards: Bool) -> PeqHUDField? {
        let list = backwards ? Array(PeqHUDField.allCases.reversed()) : PeqHUDField.allCases
        guard let i = list.firstIndex(of: field) else { return nil }
        for candidate in list[(i + 1)...] + list[..<i]
        where !values[candidate.rawValue].isHidden && values[candidate.rawValue].adjustable { return candidate }
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
/// from the chip's shape button.
final class PeqShapeStrip: PeqFrostedPanel {
    var onPick: ((PeqShape, Int) -> Void)?
    private var buttons: [NSView] = []

    init() { super.init(cornerRadius: 8) }
    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds for band `p`, offering only shapes the firmware supports.
    func configure(for p: FilterParams, available: Set<FilterType>, color: NSColor) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        let current = PeqShape.of(p.type)
        var x: CGFloat = 4
        for shape in PeqShape.allCases {
            let order = current?.shape == shape ? current!.order : 2
            guard let type = shape.type(order: order) ?? shape.type(order: 1), available.contains(type) else { continue }
            let b = PeqHUDButton(frame: NSRect(x: x, y: 4, width: 26, height: 20))
            b.imagePosition = .imageOnly
            b.image = PeqShapeGlyph.image(shape)
            b.toolTip = shape.title
            b.isOn = current?.shape == shape
            b.tint = current?.shape == shape ? color : NSColor(white: 1, alpha: 0.7)
            b.handler = { [weak self] in self?.onPick?(shape, order) }
            addSubview(b)
            buttons.append(b)
            x += 27
        }
        if let current, let first = current.shape.type(order: 1), let second = current.shape.type(order: 2),
           available.contains(first), available.contains(second) {
            let divider = NSView(frame: NSRect(x: x + 2, y: 8, width: 1, height: 12))
            divider.wantsLayer = true
            divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
            addSubview(divider)
            buttons.append(divider)
            x += 7
            for order in [1, 2] {
                let title = current.shape == .allPass ? (order == 1 ? "1st" : "2nd") : (order == 1 ? "6 dB" : "12 dB")
                let b = PeqHUDButton(frame: NSRect(x: x, y: 4, width: 36, height: 20))
                b.tint = current.order == order ? color : NSColor(white: 1, alpha: 0.7)
                b.setTitle(title, size: 9.5)
                b.isOn = current.order == order
                b.toolTip = current.shape.orderTitle(order)
                b.handler = { [weak self] in self?.onPick?(current.shape, order) }
                addSubview(b)
                buttons.append(b)
                x += 37
            }
        }
        setFrameSize(NSSize(width: x + 3, height: 28))
    }
}
