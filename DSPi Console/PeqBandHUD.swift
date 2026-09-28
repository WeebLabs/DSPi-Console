import AppKit

// The floating parameter display beside a band's dot, after FabFilter Pro-Q
// 4's: bypass, the band's frequency, gain and Q, and a shape button that
// turns the card to a page of shapes and slopes.
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
    /// A faint fill at rest, for a button that must read as one before it
    /// is hovered.
    var restingFill: CGFloat = 0 { didSet { updateBackground() } }
    var handler: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var hovering = false { didSet { updateBackground(); if hovering != oldValue { onHover?(hovering) } } }

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
        let alpha: CGFloat = isOn ? 0.16 : (hovering ? max(0.09, restingFill + 0.07) : restingFill)
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
    /// True while a scroll gesture that began on the graph is running; the
    /// field then passes the wheel on rather than taking it.
    var forwardsScroll: (() -> Bool)?
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
        // The chip follows its dot, so a gesture adjusting the band from the
        // graph can slide a field under the pointer.  That gesture keeps its
        // band: the event goes on up to the graph.  Cmd-wheel is always the
        // band's gain, so it goes up too, however long the pause before it.
        guard !isEditable, adjustable, !event.modifierFlags.contains(.command),
              forwardsScroll?() != true else { super.scrollWheel(with: event); return }
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
/// card never changes size with the type; click for the shape page), bypass on
/// the right, then one row per value.  Deleting is the Delete key or the band
/// menu, so the card spends no width on it.  Rows are label, number and
/// unit in fixed columns so the decimals line up.  The card is tall and
/// narrow on purpose: bands crowd along the frequency axis, so a narrow card
/// covers fewer neighbouring dots.  Only the rows a shape uses appear.
///
/// The shape page replaces the values in place, at exactly the same size,
/// and holds still while open.  It is a two-step choice: a grid of shapes,
/// then, for a shape with two orders, two slope (or all-pass phase) buttons,
/// marked only when the shape is the band's own.  The last click applies shape and order together
/// and turns the card back to its values; nothing changes before it.  The
/// band's own shape is marked in its colour.
final class PeqBandHUD: PeqFrostedPanel, NSTextFieldDelegate {
    var onBypass: (() -> Void)?
    var onShapeButton: (() -> Void)?
    /// A shape and order picked on the shape page.
    var onPick: ((PeqShape, Int) -> Void)?
    /// The card switched pages by itself (its back arrow); it may have
    /// changed size.
    var onPageChanged: (() -> Void)?
    var onAdjust: ((PeqHUDField, CGFloat, Bool, PeqAdjustPhase) -> Void)?
    var onScroll: ((PeqHUDField, CGFloat, Bool) -> Void)?
    /// Returns false when the text did not parse, which keeps the field open.
    var onText: ((PeqHUDField, String) -> Bool)?
    var onEditingChanged: ((Bool) -> Void)?
    /// See `PeqHUDValueField.forwardsScroll`.
    var forwardsScroll: (() -> Bool)?

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
        static func unit(slope: Bool) -> CGFloat { slope ? 32 : 19 }
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

    // Shape page
    private(set) var showsShapes = false
    /// The size the card had when the page opened, kept while it is open,
    /// however the band's values change underneath.
    private var pageSize: NSSize?
    private let chooser = PeqShapeChooser(backHelp: "Back to values")

    init() {
        super.init(cornerRadius: 8)
        shapeButton.imagePosition = .imageLeading
        shapeButton.imageHugsTitle = true
        shapeButton.toolTip = "Shape and slope"
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
            v.forwardsScroll = { [weak self] in self?.forwardsScroll?() ?? false }
            v.onBeginEditing = { [weak self] in self?.beginEditing($0) }
            for label in [labels[i], units[i]] {
                label.font = Self.quietFont
                label.lineBreakMode = .byClipping
                addSubview(label)
            }
            addSubview(v)
        }
        [ruleLine, shapeButton, power].forEach(addSubview)

        chooser.onPick = { [weak self] in self?.onPick?($0, $1) }
        chooser.onBack = { [weak self] in
            self?.showValues()
            self?.onPageChanged?()
        }
        chooser.isHidden = true
        addSubview(chooser)
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

        let onPage = showsShapes && PeqShape.of(p.type) != nil
        ([shapeButton, ruleLine] + values + labels + units).forEach { $0.isHidden = onPage }
        power.isHidden = onPage || !bypassSupported
        chooser.isHidden = !onPage
        if onPage {
            preferredSize = pageSize ?? NSSize(width: width, height: height)
            setFrameSize(preferredSize)
            chooser.frame = bounds
            chooser.mark(own: PeqShape.of(p.type), color: dim ? NSColor(white: 1, alpha: 0.4) : color)
            return
        }

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

    // MARK: Shape page

    /// Turns the card to its shape page, offering the shapes the firmware
    /// supports.
    func showShapes(available: Set<FilterType>) {
        if isEditingText { endEditing() }
        chooser.configure(available: available)
        showsShapes = true
        pageSize = preferredSize
        relayout()
    }

    /// Back to the values.
    func showValues() {
        guard showsShapes else { return }
        showsShapes = false
        pageSize = nil
        chooser.reset()
        relayout()
    }

    private func relayout() {
        if let s = shown { show(s.params, color: s.color, bypassSupported: s.bypassSupported) }
    }

    #if DEBUG
    var chooserForTesting: PeqShapeChooser { chooser }
    #endif

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

/// Chooses a shape and its order: a header with a back arrow and the
/// shape's name, a grid of shapes, then, for a shape with two orders, its two
/// slopes (or all-pass phases).  The last click reports shape and order
/// together; nothing is reported before it.  The chip shows it as its shape
/// page, marking the band's own shape (and, on that shape, its order), and
/// Cmd-click on the graph shows it on a card of its own.
final class PeqShapeChooser: NSView {
    var onPick: ((PeqShape, Int) -> Void)?
    /// The back arrow on the first step.
    var onBack: (() -> Void)?
    /// The shape picked in step one, awaiting its order in step two.
    private(set) var pendingShape: PeqShape?

    private var available: Set<FilterType> = []
    private var own: (shape: PeqShape, order: Int)?
    private var markColor = NSColor.white
    private let backHelp: String
    private let backButton = PeqHUDButton(symbol: "chevron.left", size: 9, weight: .semibold, help: "")
    private let shapeName = NSTextField(labelWithString: "")
    private let ruleLine = NSView()
    private var shapeCells: [(shape: PeqShape, view: PeqHUDButton)] = []
    private let slopeChoices = [PeqHUDButton(frame: .zero), PeqHUDButton(frame: .zero)]
    private var hoveredShape: PeqShape?

    // The chip's header geometry, so both pages share one header line.
    private enum Metrics {
        static let pad: CGFloat = 8
        static let headerY: CGFloat = 4
        static let headerHeight: CGFloat = 17
        static let rule: CGFloat = 24
    }

    override var isFlipped: Bool { true }

    /// `backHelp` names what the back arrow does on the first step.
    init(backHelp: String) {
        self.backHelp = backHelp
        super.init(frame: .zero)
        backButton.handler = { [weak self] in
            guard let self else { return }
            if self.pendingShape != nil {
                self.pendingShape = nil
                self.layoutContent()
            } else {
                self.onBack?()
            }
        }
        shapeName.textColor = NSColor(white: 1, alpha: 0.85)
        shapeName.lineBreakMode = .byTruncatingTail
        shapeName.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        ruleLine.wantsLayer = true
        ruleLine.layer?.backgroundColor = NSColor(white: 1, alpha: 0.09).cgColor
        for (i, choice) in slopeChoices.enumerated() {
            choice.layer?.cornerRadius = 5
            choice.restingFill = 0.07
            choice.handler = { [weak self] in self?.pickOrder(i + 1) }
        }
        ([backButton, shapeName, ruleLine] + slopeChoices).forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Offers the shapes the firmware supports, from the first step.
    func configure(available: Set<FilterType>) {
        if available != self.available || shapeCells.isEmpty {
            self.available = available
            shapeCells.forEach { $0.view.removeFromSuperview() }
            shapeCells = PeqShape.allCases.filter { Self.defaultOrder($0, available) != nil }.map { shape in
                let b = PeqHUDButton(frame: .zero)
                b.image = PeqShapeGlyph.image(shape)
                b.imagePosition = .imageOnly
                b.toolTip = shape.title
                b.handler = { [weak self] in self?.pickShape(shape) }
                b.onHover = { [weak self] in
                    guard let self else { return }
                    if $0 { self.hoveredShape = shape } else if self.hoveredShape == shape { self.hoveredShape = nil }
                    self.updateShapeName()
                }
                addSubview(b)
                return (shape, b)
            }
        }
        reset()
    }

    /// Marks the band's own shape, and its order on that shape, in `color`;
    /// nil marks nothing.
    func mark(own: (shape: PeqShape, order: Int)?, color: NSColor) {
        self.own = own
        markColor = color
        layoutContent()
    }

    /// Back to the first step.
    func reset() {
        pendingShape = nil
        hoveredShape = nil
        layoutContent()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutContent()
    }

    private func layoutContent() {
        let width = bounds.width
        backButton.frame = NSRect(x: 3, y: Metrics.headerY, width: 15, height: Metrics.headerHeight)
        backButton.toolTip = pendingShape == nil ? backHelp : "Back to shapes"
        shapeName.frame = NSRect(x: 18, y: Metrics.headerY + 1.5, width: max(width - 18 - Metrics.pad, 0), height: Metrics.headerHeight)
        ruleLine.frame = NSRect(x: Metrics.pad, y: Metrics.rule, width: max(width - Metrics.pad * 2, 0), height: 1)
        let top = Metrics.rule + 3, bottom = bounds.height - 4
        let quiet = NSColor(white: 1, alpha: 0.7)

        // Step two: the picked shape's two orders, centred in the body.  Only
        // the band's own shape shows its order; another starts unselected.
        if let pending = pendingShape {
            shapeCells.forEach { $0.view.isHidden = true }
            let choice = NSSize(width: 42, height: 20), gap: CGFloat = 6
            let x0 = (width - choice.width * 2 - gap) / 2
            let y = ((top + bottom) / 2 - choice.height / 2).rounded()
            for (i, button) in slopeChoices.enumerated() {
                let o = i + 1
                let marked = own.map { $0.shape == pending && $0.order == o } ?? false
                button.isHidden = false
                button.frame = NSRect(x: x0 + CGFloat(i) * (choice.width + gap), y: y, width: choice.width, height: choice.height)
                button.isOn = marked
                button.tint = marked ? markColor : NSColor(white: 1, alpha: 0.85)
                button.setTitle(Self.orderLabel(pending, o), size: 11)
                button.toolTip = pending == .allPass
                    ? (o == 1 ? "First order, 180° of phase" : "Second order, 360° of phase")
                    : "\(o == 1 ? 6 : 12) dB per octave"
            }
            updateShapeName()
            return
        }

        // Step one: the grid fills the body; a short last row is centred.
        slopeChoices.forEach { $0.isHidden = true }
        let columns = 4
        let rows = (shapeCells.count + columns - 1) / columns
        let cellHeight = (bottom - top + 1) / CGFloat(max(rows, 1))
        let cellWidth = (width - Metrics.pad * 2) / CGFloat(columns)
        for (i, cell) in shapeCells.enumerated() {
            let r = i / columns, c = i % columns
            let inRow = min(columns, shapeCells.count - r * columns)
            let inset = CGFloat(columns - inRow) * cellWidth / 2
            let marked = cell.shape == own?.shape
            cell.view.isHidden = false
            cell.view.frame = NSRect(x: Metrics.pad + inset + CGFloat(c) * cellWidth, y: top + CGFloat(r) * cellHeight,
                                     width: cellWidth, height: cellHeight - 1)
            cell.view.isOn = marked
            cell.view.tint = marked ? markColor : quiet
        }
        updateShapeName()
    }

    /// The header names the shape being chosen: the picked one in step two,
    /// else the one under the pointer, else the band's own.
    private func updateShapeName() {
        shapeName.stringValue = (pendingShape ?? hoveredShape ?? own?.shape)?.title ?? "Add Band"
    }

    /// Step one: a shape with one order is reported now; one with two goes on
    /// to step two.
    private func pickShape(_ shape: PeqShape) {
        let orders = [1, 2].filter { shape.type(order: $0).map(available.contains) ?? false }
        if orders.count == 2 {
            pendingShape = shape
            hoveredShape = nil
            layoutContent()
        } else if let order = orders.first {
            onPick?(shape, order)
        }
    }

    /// Step two: the order completes the choice.
    private func pickOrder(_ order: Int) {
        guard let shape = pendingShape else { return }
        onPick?(shape, order)
    }

    /// The order a shape on its own creates: second where available.
    static func defaultOrder(_ shape: PeqShape, _ available: Set<FilterType>) -> Int? {
        [2, 1].first { shape.type(order: $0).map(available.contains) ?? false }
    }

    /// The compact label for `order`: the slope in dB, or the phase for an
    /// all-pass, whose orders are not slopes.
    static func orderLabel(_ shape: PeqShape, _ order: Int) -> String {
        if shape == .allPass { return order == 1 ? "180°" : "360°" }
        return order == 1 ? "6 dB" : "12 dB"
    }

    #if DEBUG
    func shapeButtonForTesting(_ shape: PeqShape) -> NSButton? { shapeCells.first { $0.shape == shape }?.view }
    func slopeChoiceForTesting(_ order: Int) -> NSButton? {
        pendingShape == nil || !slopeChoices.indices.contains(order - 1) ? nil : slopeChoices[order - 1]
    }
    var backButtonForTesting: NSButton { backButton }
    #endif
}

/// The Cmd-click card: the shape chooser on a frosted panel of its own, the
/// size of a band's chip, for a band not made yet.
final class PeqShapeCard: PeqFrostedPanel {
    let chooser = PeqShapeChooser(backHelp: "Cancel")

    init() {
        super.init(cornerRadius: 8)
        setFrameSize(NSSize(width: 110, height: 78))
        chooser.frame = bounds
        chooser.autoresizingMask = [.width, .height]
        addSubview(chooser)
    }
    required init?(coder: NSCoder) { fatalError() }
}
