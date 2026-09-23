import SwiftUI
import AppKit
import Combine
import simd

// On-graph PEQ band editing, modelled on FabFilter Pro-Q 4.
//
// Every interaction is handled here in AppKit and drawn by
// `PeqGraphMetalView`, so a drag never reaches SwiftUI: the device follows at
// up to 30 writes a second through `sendGraphBandsToDevice`, the band list
// follows through AppKit readouts, and the model is written once, on release.
// The editor also owns the active channel's combined curve, which
// `BodePlotView` then leaves out of its own drawing.
//
// Mouse (Command is FabFilter's Ctrl):
//   hover empty graph     a faint dot where a click would create a band
//   click empty graph     create it (deselects instead while bands are selected)
//   double-click / Cmd-click empty graph   always create
//   drag the curve        pull a new bell (shelf near either end) out of it
//   drag empty graph      marquee selection
//   click a dot or lobe   select; Cmd toggles, Shift selects a range
//   drag a dot            frequency and gain (or Q for cuts) of the selection
//   Cmd-drag              Q of the selection
//   Shift-drag            fine;  Option-drag  lock to one axis
//   Option-click          bypass; Cmd-Option-click cycle shape;
//   Option-Shift-click    cycle slope
//   double-click a dot    type values (Tab moves between them)
//   wheel over a band     Q (slope for cuts); Cmd-wheel gain; Shift fine
//   right-click           band or graph menu
// Keys: Delete removes the selection, Escape deselects, Cmd-A selects all,
// arrows move frequency and gain (Option-arrows Q), Tab steps through bands.

struct PeqGraphEditorConfig: Equatable {
    /// The channel being edited; nil leaves only the dB zoom strip active.
    var channel: Int?
    var bands: [FilterParams] = []
    var statics: [FilterParams] = []
    var offsetDB: Float = 0
    var flat = false
    var curveColor = SIMD4<Float>(1, 1, 1, 1)
    var lineWidth: Float = 2
    var glow = true
    var minFreq: Double = 20
    var maxFreq: Double = 20000
    var dbTop: Double = 25
    var dbBottom: Double = -25
    var availableTypes: [FilterType] = []
    var bypassSupported = false
}

struct PeqGraphEditorOverlay: NSViewRepresentable {
    let vm: DSPViewModel
    let config: PeqGraphEditorConfig

    func makeNSView(context: Context) -> PeqGraphEditorView {
        let view = PeqGraphEditorView(host: vm)
        view.apply(config)
        return view
    }
    func updateNSView(_ view: PeqGraphEditorView, context: Context) { view.apply(config) }
    static func dismantleNSView(_ view: PeqGraphEditorView, coordinator: ()) { view.teardown() }
}

final class PeqGraphEditorView: NSView {
    /// Whether this Mac can draw the editor at all.  Without Metal the graph
    /// keeps its SwiftUI curves and offers no on-graph editing.
    static var isAvailable: Bool { PeqGraphResources.shared != nil }

    private enum Tuning {
        static let nodeHitRadius: CGFloat = 10
        static let curveHitDistance: CGFloat = 6
        static let dragThreshold: CGFloat = 2
        static let zoomZone: CGFloat = 40
        static let qPointsPerOctave: Double = 60
        static let fine: CGFloat = 0.12
        static let bandAnimation: CFTimeInterval = 0.22
        static let emphasisTau: Double = 0.07
        static let commitDelay: TimeInterval = 0.45
        static let deviceInterval: TimeInterval = 1.0 / 30.0
    }

    private enum Gesture {
        case idle
        /// Mouse down on a band, not yet moved.
        case press(band: Int, at: CGPoint, modifiers: NSEvent.ModifierFlags)
        /// Mouse down on empty graph, not yet moved.
        case background(at: CGPoint, onCurve: Bool, modifiers: NSEvent.ModifierFlags)
        case drag(DragContext)
        case marquee(from: CGPoint, to: CGPoint, base: Set<Int>)
    }

    private struct DragContext {
        var grabbed: Int
        var start: [Int: FilterParams]
        var last: CGPoint
        var offset = CGPoint.zero
        var qMode: Bool
        var lockAxis: Bool
        var axis: Axis?
        enum Axis { case horizontal, vertical }
    }

    private struct Emphasis {
        var hover: Float = 0
        var select: Float = 0
        var hoverTarget: Float = 0
        var selectTarget: Float = 0
        var settled: Bool { hover == hoverTarget && select == selectTarget }
    }

    private weak var vm: PeqGraphEditorHost?
    private let metal: PeqGraphMetalView?
    private let hud = PeqBandHUD()
    private let strip = PeqShapeStrip()
    private let marqueeLayer = CAShapeLayer()
    private let axisLabel = NSTextField(labelWithString: "")
    private var config = PeqGraphEditorConfig()
    private var geometry = PeqGraphGeometry(size: .zero, minFreq: 20, maxFreq: 20000, dbTop: 25, dbBottom: -25)
    private var editing: Bool { config.channel != nil && metal != nil }
    private var available: Set<FilterType> = []

    // Bands: `committed` mirrors the model, `live` holds edits not yet
    // committed, `shown` is what is drawn (committed, live or mid-animation).
    private var committed: [FilterParams] = []
    private var shown: [FilterParams] = []
    private var live: [Int: FilterParams] = [:]
    private var animationFrom: [FilterParams]?
    private var animationStart: CFTimeInterval = 0

    private var selection: Set<Int> = []
    private var anchor: Int?
    private var hovered: Int?
    private var listHovered: Int?
    private var ghost: FilterParams?
    private var ghostShown: FilterParams?
    private var ghostAmount: Float = 0
    private var pointer: CGPoint?
    private var gesture = Gesture.idle
    private var emphasis = [Emphasis](repeating: Emphasis(), count: PeqGraphRenderer.bandRows)
    private var lastFrame: CFTimeInterval = 0
    private var lastCreation: CFTimeInterval = 0

    private var hudBand: Int?
    private var hudHideTimer: Timer?
    private var hudAdjustStart: FilterParams?
    private var deviceTimer: Timer?
    private var deviceDirty: Set<Int> = []
    private var commitTimer: Timer?
    private var wheelSlope: CGFloat = 0
    private var subscriptions: Set<AnyCancellable> = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { editing }
    override var mouseDownCanMoveWindow: Bool { false }

    init(host: PeqGraphEditorHost) {
        self.vm = host
        let vm = host
        metal = PeqGraphResources.shared.map { PeqGraphMetalView(resources: $0) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        if let metal {
            metal.isHidden = true
            metal.onFrame = { [weak self] now in self?.frame(now) ?? false }
            addSubview(metal)
        }
        marqueeLayer.fillColor = NSColor(white: 1, alpha: 0.06).cgColor
        marqueeLayer.strokeColor = NSColor(white: 1, alpha: 0.45).cgColor
        marqueeLayer.lineWidth = 1
        marqueeLayer.lineDashPattern = [4, 3]
        marqueeLayer.isHidden = true
        marqueeLayer.actions = ["path": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(marqueeLayer)

        axisLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        axisLabel.textColor = NSColor(white: 1, alpha: 0.85)
        axisLabel.alignment = .center
        axisLabel.wantsLayer = true
        axisLabel.layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 0.92).cgColor
        axisLabel.layer?.cornerRadius = 4
        axisLabel.isHidden = true
        addSubview(axisLabel)

        hud.isHidden = true
        hud.alphaValue = 0
        addSubview(hud)
        strip.isHidden = true
        addSubview(strip)
        wireHUD()

        vm.peqSelection.$listHovered
            .removeDuplicates()
            .sink { [weak self] band in
                guard let self else { return }
                self.listHovered = band
                self.invalidate()
            }
            .store(in: &subscriptions)
        vm.peqSelection.$selected
            .removeDuplicates()
            .sink { [weak self] set in
                guard let self, set != self.selection else { return }
                self.selection = set
                self.anchor = set.count == 1 ? set.first : self.anchor
                self.invalidate()
            }
            .store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { fatalError() }

    #if DEBUG
    var rendererForTesting: PeqGraphRenderer? { metal?.renderer }
    var drawLoopPausedForTesting: Bool { metal?.isPaused ?? true }
    /// Test hooks: hover a point as the mouse would, and settle every
    /// animation at once.
    func hoverForTesting(_ p: CGPoint) {
        pointer = p
        updateHover(at: p)
    }
    func settleForTesting() {
        updateEmphasisTargets()
        metal?.renderer.picture = picture()
        _ = frame(.infinity)
    }
    #endif

    func teardown() {
        commitLive()
        metal?.stopAnimating()
        subscriptions.removeAll()
        [hudHideTimer, deviceTimer, commitTimer].forEach { $0?.invalidate() }
    }

    // MARK: - Configuration

    func apply(_ new: PeqGraphEditorConfig) {
        guard new != config else { return }
        // A pending wheel or key edit belongs to the channel it was made on,
        // so it is committed before the new one takes over.
        if new.channel != config.channel { commitLive() }
        let old = config
        config = new
        available = Set(new.availableTypes)
        updateGeometry()
        metal?.isHidden = !editing

        if old.channel != new.channel || !editing {
            resetInteraction()
            committed = new.bands
            shown = new.bands
            animationFrom = nil
        } else if new.bands != committed {
            committed = new.bands
            if case .idle = gesture, live.isEmpty {
                startBandAnimation()
            } else {
                // Mid-edit, only the bands not being edited follow the model.
                for i in shown.indices where live[i] == nil && i < committed.count { shown[i] = committed[i] }
                if shown.count != committed.count { shown = committed.enumerated().map { live[$0.offset] ?? $0.element } }
            }
        }
        refreshHUD()
        invalidate()
    }

    private func resetInteraction() {
        gesture = .idle
        selection = []
        anchor = nil
        hovered = nil
        listHovered = nil
        ghost = nil
        ghostShown = nil
        ghostAmount = 0
        marqueeLayer.isHidden = true
        axisLabel.isHidden = true
        hideHUD(animated: false)
        emphasis = [Emphasis](repeating: Emphasis(), count: PeqGraphRenderer.bandRows)
    }

    private func updateGeometry() {
        geometry = PeqGraphGeometry(size: bounds.size, minFreq: config.minFreq, maxFreq: config.maxFreq,
                                    dbTop: config.dbTop, dbBottom: config.dbBottom)
    }

    override func layout() {
        super.layout()
        // SwiftUI lays hosted views out often; only a new size needs a frame.
        guard metal.map({ $0.frame != bounds }) ?? false || bounds.size != geometry.size else { return }
        metal?.frame = bounds
        updateGeometry()
        layoutHUD()
        invalidate()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if editing { return super.hitTest(point) ?? self }
        return local.x <= Tuning.zoomZone ? self : nil
    }

    // MARK: - Band queries

    private var bandCount: Int { min(shown.count, PeqGraphRenderer.bandRows) }

    private func isBand(_ i: Int) -> Bool { i >= 0 && i < bandCount && shown[i].isGraphBand }

    private var graphBands: [Int] { (0..<bandCount).filter(isBand) }

    private func role(_ p: FilterParams) -> PeqNodeRole { PeqNodeRole.of(p) }

    private func nodePoint(_ p: FilterParams) -> CGPoint {
        let y = geometry.y(role(p).db(for: p))
        return CGPoint(x: geometry.x(Double(p.freq)), y: min(max(y, 6), max(bounds.height - 6, 6)))
    }

    private func bandDB(_ p: FilterParams, at freq: Double) -> Double {
        var probe = p
        probe.bypass = false
        return Double(DSPMath.responseAt(freq: Float(freq), filters: [probe]))
    }

    private func combinedDB(at freq: Double) -> Double {
        var db = Double(config.offsetDB)
        guard !config.flat else { return db }
        let audible = graphBands.map { shown[$0] }.filter { !$0.bypass }
        db += Double(DSPMath.responseAt(freq: Float(freq), filters: audible + config.statics))
        return db
    }

    /// The dot under `point`, preferring selected and hovered dots, which are
    /// drawn on top.
    private func node(at point: CGPoint) -> Int? {
        var best: (band: Int, score: CGFloat)?
        for b in graphBands {
            let d = hypot(nodePoint(shown[b]).x - point.x, nodePoint(shown[b]).y - point.y)
            guard d <= Tuning.nodeHitRadius else { continue }
            let score = d - (selection.contains(b) ? 3 : 0) - (hovered == b ? 2 : 0)
            if best == nil || score < best!.score { best = (b, score) }
        }
        return best?.band
    }

    /// The band whose filled area (between its curve and 0 dB) contains
    /// `point`; FabFilter selects on a click there too.
    private func lobe(at point: CGPoint) -> Int? {
        let freq = geometry.freq(point.x)
        let zero = geometry.y(0)
        var best: (band: Int, distance: CGFloat)?
        for b in graphBands {
            if case .locked = role(shown[b]) { continue }
            let y = geometry.y(bandDB(shown[b], at: freq))
            guard abs(y - zero) >= 3, point.y >= min(y, zero), point.y <= max(y, zero) else { continue }
            let d = abs(point.y - y)
            if best == nil || d < best!.distance { best = (b, d) }
        }
        return best?.band
    }

    private func band(at point: CGPoint) -> Int? { node(at: point) ?? lobe(at: point) }

    private func isNearCurve(_ point: CGPoint) -> Bool {
        abs(geometry.y(combinedDB(at: geometry.freq(point.x))) - point.y) <= Tuning.curveHitDistance
    }

    private var freeSlot: Int? {
        (0..<min(committed.count, PeqGraphRenderer.bandRows)).first { committed[$0].type == .flat && live[$0] == nil }
    }

    private var freqRange: ClosedRange<Double> {
        let lo = max(PeqLimits.freq.lowerBound, config.minFreq)
        let hi = min(PeqLimits.freq.upperBound, config.maxFreq)
        return lo...max(hi, lo)
    }

    private func frequencyOrder(_ bands: [Int]) -> [Int] {
        bands.sorted { (shown[$0].freq, $0) < (shown[$1].freq, $1) }
    }

    // MARK: - Drawing

    /// Requests a frame, running the display link while anything animates.
    private func invalidate() {
        guard let metal, editing else { return }
        updateEmphasisTargets()
        let animating = animationFrom != nil || ghostAmount != (ghost != nil ? 1 : 0)
            || emphasis.contains { !$0.settled }
        if animating { metal.animate() } else { metal.redraw() }
    }

    private func updateEmphasisTargets() {
        var dragged: Set<Int> = []
        if case .drag(let ctx) = gesture { dragged = Set(ctx.start.keys) }
        for i in emphasis.indices {
            let isShown = isBand(i)
            emphasis[i].selectTarget = isShown && selection.contains(i) ? 1 : 0
            emphasis[i].hoverTarget = isShown && (hovered == i || listHovered == i || dragged.contains(i) || hudBand == i) ? 1 : 0
        }
    }

    /// Called by the Metal view before each frame: advances animations and
    /// hands the renderer the picture.  `.infinity` finishes everything now.
    private func frame(_ now: CFTimeInterval) -> Bool {
        let dt = now.isFinite ? (lastFrame == 0 ? 1.0 / 60 : min(now - lastFrame, 0.1)) : 1
        lastFrame = now.isFinite ? now : 0
        var running = false

        if let from = animationFrom {
            let t = now.isFinite ? (now - animationStart) / Tuning.bandAnimation : 1
            let target = committed.enumerated().map { live[$0.offset] ?? $0.element }
            if t >= 1 || from.count != target.count {
                shown = target
                animationFrom = nil
                refreshHUD()
            } else {
                let eased = 1 - pow(1 - t, 3)
                shown = zip(from, target).map { $0.interpolated(to: $1, eased) }
                running = true
                layoutHUD()
            }
        }

        let k = Float(1 - exp(-dt / Tuning.emphasisTau))
        func approach(_ v: inout Float, _ target: Float) {
            v += (target - v) * k
            if abs(target - v) < 0.004 { v = target }
        }
        for i in emphasis.indices {
            approach(&emphasis[i].hover, emphasis[i].hoverTarget)
            approach(&emphasis[i].select, emphasis[i].selectTarget)
            if !emphasis[i].settled { running = true }
        }
        approach(&ghostAmount, ghost != nil ? 1 : 0)
        if ghost != nil { ghostShown = ghost }
        if ghostAmount == 0 { ghostShown = nil }
        if ghostAmount != (ghost != nil ? 1 : 0) { running = true }

        metal?.renderer.picture = picture()
        if !running { lastFrame = 0 }
        return running
    }

    private func picture() -> PeqGraphPicture {
        var p = PeqGraphPicture()
        p.geometry = geometry
        p.response.bands = (0..<PeqGraphRenderer.bandRows).map { isBand($0) ? shown[$0] : nil }
        p.response.statics = config.statics
        p.response.offsetDB = config.offsetDB
        p.response.flat = config.flat
        p.curveColor = config.curveColor
        p.lineWidth = config.lineWidth
        p.glow = config.glow

        let dimAll: Float = config.flat ? 0.5 : 1
        var nodes: [(order: Float, node: PeqNodeInstance)] = []
        for b in graphBands {
            let band = shown[b]
            let e = emphasis[b]
            let lift = max(e.hover, e.select)
            var color = PeqBandPalette.simd(b)
            if band.bypass {
                let grey = (color.x + color.y + color.z) / 3
                color = SIMD4(simd_mix(SIMD3(repeating: grey), SIMD3(color.x, color.y, color.z), SIMD3(repeating: 0.35)), 1)
            }
            // Every audible band keeps a faint fill; a bypassed one shows only
            // its outline, and only while hovered or selected.
            p.bandStyles.append(.init(row: b, color: color,
                                      lineOpacity: 0.9 * lift * (band.bypass ? 0.5 : 1) * dimAll,
                                      fillOpacity: band.bypass ? 0 : (0.22 + 0.2 * lift) * dimAll,
                                      reach: lobeReach(band)))
            let c = nodePoint(band)
            // Flat discs; hovering and selecting only enlarge them.
            nodes.append((lift + e.select, PeqNodeInstance(
                center: SIMD2(Float(c.x), Float(c.y)), radius: 5 + 1.5 * lift + 0.5 * e.select,
                color: color, state: SIMD4(0, 0, (band.bypass ? 0.55 : 1) * dimAll, 0))))
        }
        if let g = ghostShown, ghostAmount > 0 {
            let c = nodePoint(g)
            nodes.append((-1, PeqNodeInstance(center: SIMD2(Float(c.x), Float(c.y)), radius: 5,
                                              color: SIMD4(1, 1, 1, 1), state: SIMD4(0, 0, 0.3 * ghostAmount, 0))))
        }
        // Emphasised dots last, so they draw on top.
        p.nodes = nodes.sorted { $0.order < $1.order }.map(\.node)
        return p
    }

    /// The dB range a band's lobe spans, to bound its fill: 0 dB to the
    /// gain for bells and shelves, down off the plot for cuts and notches.
    private func lobeReach(_ p: FilterParams) -> ClosedRange<Double> {
        let bottom = config.dbBottom - 1
        switch p.type {
        case .peaking, .lowShelf, .highShelf, .lowShelf1, .highShelf1:
            return min(Double(p.gain), 0)...max(Double(p.gain), 0)
        case .lowPass, .highPass:
            return bottom...max(20 * log10(Double(max(p.q, 0.01))), 0)
        case .allPass, .allPass1:
            return 0...0
        default:
            return bottom...config.dbTop + 1
        }
    }

    private func startBandAnimation() {
        let target = committed
        guard shown.count == target.count else { shown = target; return }
        let significant = zip(shown, target).contains { a, b in
            a.type != b.type || a.bypass != b.bypass || abs(a.gain - b.gain) > 0.02
                || abs(log(Double(max(a.freq, 1)) / Double(max(b.freq, 1)))) > 0.002
                || abs(log(Double(max(a.q, 0.01)) / Double(max(b.q, 0.01)))) > 0.002
        }
        if significant {
            animationFrom = shown
            animationStart = CACurrentMediaTime()
        } else {
            shown = target
        }
    }

    // MARK: - Editing pipeline

    /// A change in progress: drawn, shown in the HUD and the list, sent to the
    /// device at most 30 times a second, and committed later.
    private func setLive(_ changes: [Int: FilterParams]) {
        guard !changes.isEmpty else { return }
        if animationFrom != nil {
            animationFrom = nil
            shown = committed.enumerated().map { live[$0.offset] ?? $0.element }
        }
        for (b, p) in changes where b < shown.count {
            live[b] = p
            shown[b] = p
            vm?.peqLive.show(band: b, p)
        }
        deviceDirty.formUnion(changes.keys)
        if deviceTimer == nil { sendToDevice() }
        refreshHUD()
        invalidate()
    }

    private func sendToDevice() {
        guard let ch = config.channel, !deviceDirty.isEmpty else { return }
        let changes = deviceDirty.sorted().compactMap { b in live[b].map { (band: b, params: $0) } }
        deviceDirty.removeAll()
        vm?.sendGraphBandsToDevice(ch: ch, changes)
        let timer = Timer(timeInterval: Tuning.deviceInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.deviceTimer = nil
            self.sendToDevice()
        }
        deviceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Writes live edits to the model, once.
    private func commitLive() {
        deviceTimer?.invalidate()
        deviceTimer = nil
        deviceDirty.removeAll()
        commitTimer?.invalidate()
        commitTimer = nil
        vm?.peqLive.endAll()
        let changes = live.keys.sorted().compactMap { b -> (band: Int, params: FilterParams)? in
            guard let p = live[b], b < committed.count, p != committed[b] else { return nil }
            return (b, p)
        }
        live.removeAll()
        guard !changes.isEmpty, let ch = config.channel else { return }
        for c in changes { committed[c.band] = c.params }
        vm?.commitGraphBands(ch: ch, changes)
    }

    /// For wheel and key edits: live now, committed once they pause.
    private func setLiveThenCommit(_ changes: [Int: FilterParams]) {
        setLive(changes)
        commitTimer?.invalidate()
        let timer = Timer(timeInterval: Tuning.commitDelay, repeats: false) { [weak self] _ in self?.commitLive() }
        commitTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Discrete edits (create, delete, shape, typed values) commit at once.
    private func commitNow(_ changes: [Int: FilterParams]) {
        commitLive()
        guard let ch = config.channel, !changes.isEmpty else { return }
        animationFrom = nil
        for (b, p) in changes where b < committed.count {
            committed[b] = p
            shown[b] = p
        }
        vm?.commitGraphBands(ch: ch, changes.keys.sorted().map { (band: $0, params: changes[$0]!) })
        refreshHUD()
        invalidate()
    }

    private func current(_ b: Int) -> FilterParams { live[b] ?? shown[b] }

    private func setSelection(_ new: Set<Int>) {
        let valid = new.filter(isBand)
        guard valid != selection else { return }
        selection = valid
        if vm?.peqSelection.selected != valid { vm?.peqSelection.selected = valid }
        invalidate()
    }

    private func setHovered(_ band: Int?) {
        guard band != hovered else { return }
        hovered = band
        if vm?.peqSelection.graphHovered != band { vm?.peqSelection.graphHovered = band }
        invalidate()
    }

    // MARK: - Band operations

    @discardableResult
    private func createBand(_ p: FilterParams, select: Bool = true) -> Int? {
        guard let slot = freeSlot else { NSSound.beep(); return nil }
        commitNow([slot: p])
        lastCreation = CACurrentMediaTime()
        if select {
            setSelection([slot])
            anchor = slot
        }
        ghost = nil
        return slot
    }

    private func deleteBands(_ bands: Set<Int>) {
        let targets = bands.filter(isBand)
        guard !targets.isEmpty else { return }
        var changes: [Int: FilterParams] = [:]
        for b in targets { changes[b] = FilterParams() }
        setSelection(selection.subtracting(targets))
        if let h = hudBand, targets.contains(h) { hideHUD(animated: true) }
        commitNow(changes)
    }

    private func toggleBypass(_ bands: Set<Int>) {
        guard config.bypassSupported, let ch = config.channel else { return }
        let targets = bands.filter(isBand).sorted()
        guard let first = targets.first else { return }
        commitLive()
        let bypass = !shown[first].bypass
        animationFrom = nil
        for b in targets {
            committed[b].bypass = bypass
            shown[b].bypass = bypass
            vm?.setGraphBandBypass(ch: ch, band: b, bypass: bypass)
        }
        refreshHUD()
        invalidate()
    }

    /// Changes shape (and order), keeping frequency, and carrying gain and Q
    /// over where the new shape uses them.
    private func setShape(_ bands: Set<Int>, shape: PeqShape, order: Int) {
        var changes: [Int: FilterParams] = [:]
        for b in bands.filter(isBand) {
            guard let type = shape.type(order: order) ?? shape.type(order: 2), available.contains(type) else { continue }
            var p = current(b).retyped(to: type)
            if !type.usesGain { p.gain = 0 }
            if type.usesQ, !current(b).type.usesQ { p.q = shape == .bell || shape == .notch ? 1 : 0.707 }
            changes[b] = p
        }
        commitNow(changes)
    }

    private func availableShapes() -> [(PeqShape, Int)] {
        PeqShape.allCases.compactMap { shape in
            if let t = shape.type(order: 2), available.contains(t) { return (shape, 2) }
            if let t = shape.type(order: 1), available.contains(t) { return (shape, 1) }
            return nil
        }
    }

    private func cycleShape(_ b: Int) {
        guard let (shape, order) = PeqShape.of(current(b).type) else { return }
        let shapes = availableShapes()
        guard let i = shapes.firstIndex(where: { $0.0 == shape }) else { return }
        let next = shapes[(i + 1) % shapes.count]
        let keep = next.0.type(order: order).map(available.contains) == true ? order : next.1
        setShape(targets(for: b), shape: next.0, order: keep)
    }

    private func cycleOrder(_ b: Int) {
        guard let (shape, order) = PeqShape.of(current(b).type),
              let other = shape.type(order: 3 - order), available.contains(other) else { NSSound.beep(); return }
        setShape(targets(for: b), shape: shape, order: 3 - order)
    }

    /// FabFilter applies a band action to the whole selection when the band
    /// is part of it, and to the band alone otherwise.
    private func targets(for b: Int) -> Set<Int> { selection.contains(b) ? selection : [b] }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseMoved(with event: NSEvent) {
        guard editing else { return }
        let p = location(event)
        pointer = p
        updateHover(at: p)
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        guard case .idle = gesture else { return }
        setHovered(nil)
        ghost = nil
        axisLabel.isHidden = true
        scheduleHUDHide()
        NSCursor.arrow.set()
        invalidate()
    }

    private func updateHover(at p: CGPoint) {
        guard case .idle = gesture else { return }
        guard bounds.contains(p) else {
            setHovered(nil)
            ghost = nil
            axisLabel.isHidden = true
            scheduleHUDHide()
            invalidate()
            return
        }
        if !hud.isHidden, hud.frame.insetBy(dx: -4, dy: -4).contains(p) || (!strip.isHidden && strip.frame.contains(p)) {
            hudHideTimer?.invalidate()
            ghost = nil
            axisLabel.isHidden = true
            NSCursor.arrow.set()
            invalidate()
            return
        }
        let dot = node(at: p)
        let hit = dot ?? lobe(at: p)
        setHovered(hit)
        if let dot {
            if hudBand != dot || hud.isHidden { showHUD(for: dot) } else { hudHideTimer?.invalidate() }
        } else if !hud.isHidden, !hud.isEditingText {
            scheduleHUDHide()
        }
        if hit == nil {
            if freeSlot != nil {
                ghost = PeqCreation.band(at: p, in: geometry, available: available, fromCurve: false)
                showAxisLabel(PeqValueText.frequency(geometry.freq(p.x)), at: p.x)
            } else {
                ghost = nil
                showAxisLabel("All \(min(committed.count, PeqGraphRenderer.bandRows)) bands in use", at: p.x)
            }
        } else {
            ghost = nil
            axisLabel.isHidden = true
        }
        (hit != nil ? NSCursor.openHand : NSCursor.arrow).set()
        invalidate()
    }

    override func cursorUpdate(with event: NSEvent) {
        guard editing else { super.cursorUpdate(with: event); return }
        (hovered != nil ? NSCursor.openHand : NSCursor.arrow).set()
    }

    override func mouseDown(with event: NSEvent) {
        guard editing else { return }
        window?.makeFirstResponder(self)
        closeStrip()
        if hud.isEditingText { hud.endEditing() }
        let p = location(event)
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])

        if event.clickCount == 2 {
            if let b = node(at: p) ?? lobe(at: p) {
                showHUD(for: b)
                hud.beginEditing(.freq)
            } else if CACurrentMediaTime() - lastCreation > NSEvent.doubleClickInterval {
                // The first click may already have made this band; then the
                // second one does nothing.
                createBand(PeqCreation.band(at: p, in: geometry, available: available, fromCurve: false))
            }
            gesture = .idle
            return
        }

        if let b = band(at: p) {
            if mods.contains(.option) {
                if mods.contains(.command) { cycleShape(b) }
                else if mods.contains(.shift) { cycleOrder(b) }
                else { toggleBypass(targets(for: b)) }
                gesture = .idle
                return
            }
            if mods.contains(.shift), !mods.contains(.command) {
                let order = frequencyOrder(graphBands)
                if let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: b) {
                    setSelection(Set(order[min(i, j)...max(i, j)]))
                } else {
                    setSelection([b])
                    anchor = b
                }
                gesture = .idle
                return
            }
            if !mods.contains(.command), !selection.contains(b) {
                setSelection([b])
                anchor = b
            }
            gesture = .press(band: b, at: p, modifiers: mods)
            showHUD(for: b)
            return
        }

        if mods.contains(.command) {
            createBand(PeqCreation.band(at: p, in: geometry, available: available, fromCurve: false))
            gesture = .idle
            return
        }
        gesture = .background(at: p, onCurve: freeSlot != nil && isNearCurve(p), modifiers: mods)
    }

    override func mouseDragged(with event: NSEvent) {
        guard editing else { return }
        let p = location(event)
        pointer = p
        switch gesture {
        case .press(let b, let start, let mods):
            guard hypot(p.x - start.x, p.y - start.y) >= Tuning.dragThreshold else { return }
            var bands = selection.contains(b) ? selection : [b]
            if mods.contains(.command) { bands.insert(b) }
            if case .locked = role(current(b)) { gesture = .idle; return }
            if mods.contains(.command), !selection.contains(b) { setSelection(selection.union([b])) }
            beginDrag(grabbed: b, bands: bands, at: start, qMode: mods.contains(.command), lock: mods.contains(.option))
            continueDrag(to: p, event: event)
        case .background(let start, let onCurve, let mods):
            guard hypot(p.x - start.x, p.y - start.y) >= Tuning.dragThreshold else { return }
            ghost = nil
            axisLabel.isHidden = true
            if onCurve, let slot = freeSlot {
                // Pull a new band out of the curve, starting flat so the
                // curve does not jump, then follow the pointer.
                var band = PeqCreation.band(at: start, in: geometry, available: available, fromCurve: true)
                band.gain = 0
                live[slot] = band
                if slot < shown.count { shown[slot] = band }
                setSelection([slot])
                anchor = slot
                lastCreation = CACurrentMediaTime()
                beginDrag(grabbed: slot, bands: [slot], at: start, qMode: false, lock: mods.contains(.option))
                continueDrag(to: p, event: event)
            } else {
                let base = mods.contains(.shift) || mods.contains(.command) ? selection : []
                gesture = .marquee(from: start, to: p, base: base)
                updateMarquee()
            }
        case .drag:
            continueDrag(to: p, event: event)
        case .marquee(let from, _, let base):
            gesture = .marquee(from: from, to: p, base: base)
            updateMarquee()
        case .idle:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard editing else { return }
        let p = location(event)
        switch gesture {
        case .press(let b, _, let mods):
            if mods.contains(.command) {
                setSelection(selection.symmetricDifference([b]))
                anchor = b
            } else {
                setSelection([b])
                anchor = b
            }
        case .background(let start, _, _):
            // FabFilter Pro-Q 4: a click on empty graph deselects when bands
            // are selected, and otherwise creates the previewed band.
            if !selection.isEmpty {
                setSelection([])
            } else if event.clickCount < 2 {
                createBand(PeqCreation.band(at: start, in: geometry, available: available, fromCurve: false))
            }
        case .drag:
            commitLive()
            NSCursor.openHand.set()
        case .marquee:
            marqueeLayer.isHidden = true
        case .idle:
            break
        }
        gesture = .idle
        invalidate()
        updateHover(at: p)
    }

    private func beginDrag(grabbed: Int, bands: Set<Int>, at point: CGPoint, qMode: Bool, lock: Bool) {
        commitTimer?.invalidate()
        var start: [Int: FilterParams] = [:]
        for b in bands where isBand(b) || live[b] != nil { start[b] = current(b) }
        start[grabbed] = current(grabbed)
        gesture = .drag(DragContext(grabbed: grabbed, start: start, last: point, qMode: qMode, lockAxis: lock))
        ghost = nil
        axisLabel.isHidden = true
        showHUD(for: grabbed)
        (qMode ? NSCursor.resizeUpDown : NSCursor.closedHand).set()
    }

    private func continueDrag(to p: CGPoint, event: NSEvent) {
        guard case .drag(var ctx) = gesture else { return }
        let fine = event.modifierFlags.contains(.shift)
        let scale = fine ? Tuning.fine : 1
        ctx.offset.x += (p.x - ctx.last.x) * scale
        ctx.offset.y += (p.y - ctx.last.y) * scale
        ctx.last = p
        if ctx.lockAxis, ctx.axis == nil, hypot(ctx.offset.x, ctx.offset.y) > 4 {
            ctx.axis = abs(ctx.offset.x) >= abs(ctx.offset.y) ? .horizontal : .vertical
        }
        gesture = .drag(ctx)
        var dx = ctx.offset.x, dy = ctx.offset.y
        if ctx.axis == .horizontal { dy = 0 }
        if ctx.axis == .vertical { dx = 0 }
        if ctx.lockAxis, ctx.axis == nil { dx = 0; dy = 0 }
        setLive(dragResult(ctx, dx: dx, dy: dy))
    }

    /// Applies a drag offset to the bands that were grabbed, FabFilter style:
    /// the grabbed dot follows the pointer, the others move by the same
    /// frequency ratio and have their gains scaled in proportion.
    private func dragResult(_ ctx: DragContext, dx: CGFloat, dy: CGFloat) -> [Int: FilterParams] {
        guard let g0 = ctx.start[ctx.grabbed] else { return [:] }
        var out: [Int: FilterParams] = [:]
        let qFactor = pow(2, -Double(dy) / Tuning.qPointsPerOctave)
        if ctx.qMode {
            for (b, s) in ctx.start where s.type.usesQ {
                var p = s
                p.q = Float(PeqLimits.clamp(Double(s.q) * qFactor, PeqLimits.q))
                out[b] = p
            }
            return out
        }

        let startX = geometry.x(Double(g0.freq))
        let newFreq = PeqLimits.clamp(geometry.freq(startX + dx), freqRange)
        let ratio = newFreq / Double(g0.freq)
        let dbDelta = -Double(dy) * geometry.dbPerPoint
        let r0 = role(g0)
        var g = g0
        g.freq = Float(newFreq)
        switch r0 {
        case .gain(let scale):
            g.gain = Float(PeqLimits.clamp(Double(g0.gain) + dbDelta / scale, PeqLimits.gain))
        case .resonance:
            let db = r0.db(for: g0) + dbDelta
            g.q = Float(PeqLimits.clamp(pow(10, db / 20), PeqLimits.q))
        case .fixed:
            if g0.type.usesQ { g.q = Float(PeqLimits.clamp(Double(g0.q) * qFactor, PeqLimits.q)) }
        case .locked:
            return [:]
        }
        out[ctx.grabbed] = g

        let gainFactor: Double? = {
            guard case .gain = r0, abs(g0.gain) >= 0.25 else { return nil }
            return Double(g.gain) / Double(g0.gain)
        }()
        for (b, s) in ctx.start where b != ctx.grabbed {
            var p = s
            if case .locked = role(s) { continue }
            p.freq = Float(PeqLimits.clamp(Double(s.freq) * ratio, freqRange))
            if s.type.usesGain {
                let gain = gainFactor.map { Double(s.gain) * $0 } ?? Double(s.gain) + dbDelta / max(role(s).gainScale, 0.05)
                p.gain = Float(PeqLimits.clamp(gain, PeqLimits.gain))
            }
            out[b] = p
        }
        return out
    }

    private func updateMarquee() {
        guard case .marquee(let from, let to, let base) = gesture else { return }
        let rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
        marqueeLayer.path = CGPath(rect: rect, transform: nil)
        marqueeLayer.isHidden = false
        let inside = graphBands.filter { rect.contains(nodePoint(shown[$0])) }
        setSelection(base.union(inside))
        if let first = frequencyOrder(inside).first { anchor = first }
    }

    override func scrollWheel(with event: NSEvent) {
        let p = location(event)
        let target: Int? = {
            guard editing else { return nil }
            if case .drag(let ctx) = gesture { return ctx.grabbed }
            if let b = band(at: p) { return b }
            if let h = hudBand, !hud.isHidden, hud.frame.contains(p) { return h }
            return nil
        }()
        guard let b = target else {
            if p.x <= Tuning.zoomZone { zoom(with: event) } else { super.scrollWheel(with: event) }
            return
        }
        let raw = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        let fine = event.modifierFlags.contains(.shift)
        let delta = (event.hasPreciseScrollingDeltas ? raw : raw * 8) * (fine ? Tuning.fine : 1)
        guard delta != 0 else { return }
        let bands = targets(for: b)
        var changes: [Int: FilterParams] = [:]

        if event.modifierFlags.contains(.command) {
            for i in bands where current(i).type.usesGain {
                var q = current(i)
                q.gain = Float(PeqLimits.clamp(Double(q.gain) + Double(delta) * 0.05, PeqLimits.gain))
                changes[i] = q
            }
        } else if let (shape, order) = PeqShape.of(current(b).type), shape.isCut {
            // FabFilter steps a cut's slope with the wheel.
            wheelSlope += delta
            guard abs(wheelSlope) >= 24 else { return }
            let newOrder = wheelSlope > 0 ? 2 : 1
            wheelSlope = 0
            guard newOrder != order, let type = shape.type(order: newOrder), available.contains(type) else { return }
            for i in bands {
                guard let (s, _) = PeqShape.of(current(i).type), s.isCut, let t = s.type(order: newOrder) else { continue }
                var q = current(i).retyped(to: t)
                if t.usesQ { q.q = 0.707 }
                changes[i] = q
            }
        } else {
            let factor = pow(2, Double(delta) / 100)
            for i in bands where current(i).type.usesQ {
                var q = current(i)
                q.q = Float(PeqLimits.clamp(Double(q.q) * factor, PeqLimits.q))
                changes[i] = q
            }
        }
        if case .drag = gesture { setLive(changes) } else { setLiveThenCommit(changes) }
        if hovered == nil { setHovered(b) }
        showHUD(for: b)
    }

    private func zoom(with event: NSEvent) {
        let settings = AppSettings.shared
        let delta = Double(event.scrollingDeltaY)
        let sensitivity = event.hasPreciseScrollingDeltas ? 0.3 : 3.0
        settings.graphDBRange = min(max(settings.graphDBRange - delta * sensitivity, 10), 100)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard editing else { super.rightMouseDown(with: event); return }
        let p = location(event)
        closeStrip()
        let menu: NSMenu
        if let b = band(at: p) {
            if !selection.contains(b) { setSelection([b]); anchor = b }
            menu = bandMenu(for: b)
        } else {
            menu = graphMenu(at: p)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard editing else { super.keyDown(with: event); return }
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        switch Int(event.keyCode) {
        case 51, 117: // delete, forward delete
            deleteBands(selection)
        case 53: // escape
            setSelection([])
            hideHUD(animated: true)
        case 48: // tab
            stepSelection(backwards: mods.contains(.shift))
        case 123, 124, 125, 126:
            nudge(keyCode: Int(event.keyCode), mods: mods)
        default:
            if mods == .command, event.charactersIgnoringModifiers == "a" {
                setSelection(Set(graphBands))
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func stepSelection(backwards: Bool) {
        let order = frequencyOrder(graphBands)
        guard !order.isEmpty else { return }
        let from = anchor.flatMap { order.firstIndex(of: $0) }
        let next = from.map { (($0 + (backwards ? -1 : 1)) % order.count + order.count) % order.count }
            ?? (backwards ? order.count - 1 : 0)
        setSelection([order[next]])
        anchor = order[next]
        showHUD(for: order[next])
    }

    private func nudge(keyCode: Int, mods: NSEvent.ModifierFlags) {
        let fine = mods.contains(.shift)
        var changes: [Int: FilterParams] = [:]
        for b in selection where isBand(b) {
            var p = current(b)
            switch keyCode {
            case 123, 124:
                let octaves = (fine ? 1.0 / 96 : 1.0 / 12) * (keyCode == 124 ? 1 : -1)
                p.freq = Float(PeqLimits.clamp(Double(p.freq) * pow(2, octaves), freqRange))
            default:
                let up = keyCode == 126
                if mods.contains(.option) || !p.type.usesGain {
                    guard p.type.usesQ else { continue }
                    p.q = Float(PeqLimits.clamp(Double(p.q) * pow(2, (fine ? 0.02 : 0.1) * (up ? 1 : -1)), PeqLimits.q))
                } else {
                    p.gain = Float(PeqLimits.clamp(Double(p.gain) + (fine ? 0.1 : 0.5) * (up ? 1 : -1), PeqLimits.gain))
                }
            }
            changes[b] = p
        }
        setLiveThenCommit(changes)
        if let a = anchor, selection.contains(a) { showHUD(for: a) }
    }

    // MARK: - Menus

    private func item(_ title: String, checked: Bool = false, enabled: Bool = true, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = PeqMenuItem(title: title, handler: action)
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        return item
    }

    private func bandMenu(for b: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let bands = targets(for: b)
        let p = current(b)
        let header = NSMenuItem(title: bands.count > 1 ? "\(bands.count) Bands" : "Band \(b + 1)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let (shape, order) = PeqShape.of(p.type) {
            let shapes = NSMenuItem(title: "Shape", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            for (s, defaultOrder) in availableShapes() {
                let o = s.type(order: order).map(available.contains) == true ? order : defaultOrder
                sub.addItem(item(s.title, checked: s == shape) { [weak self] in self?.setShape(bands, shape: s, order: o) })
            }
            shapes.submenu = sub
            menu.addItem(shapes)
            if let t1 = shape.type(order: 1), let t2 = shape.type(order: 2), available.contains(t1), available.contains(t2) {
                let slope = NSMenuItem(title: shape == .allPass ? "Order" : "Slope", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.autoenablesItems = false
                for o in [1, 2] {
                    sub.addItem(item(shape.orderTitle(o), checked: o == order) { [weak self] in self?.setShape(bands, shape: shape, order: o) })
                }
                slope.submenu = sub
                menu.addItem(slope)
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Edit Values...", enabled: PeqShape.of(p.type) != nil) { [weak self] in
            self?.showHUD(for: b)
            self?.hud.beginEditing(.freq)
        })
        if config.bypassSupported {
            menu.addItem(item(p.bypass ? "Enable" : "Bypass") { [weak self] in self?.toggleBypass(bands) })
        }
        if p.type.usesGain {
            menu.addItem(item("Invert Gain") { [weak self] in
                guard let self else { return }
                var changes: [Int: FilterParams] = [:]
                for i in bands where self.current(i).type.usesGain {
                    var q = self.current(i); q.gain = -q.gain; changes[i] = q
                }
                self.commitNow(changes)
            })
        }
        menu.addItem(.separator())
        menu.addItem(item(bands.count > 1 ? "Delete \(bands.count) Bands" : "Delete Band") { [weak self] in self?.deleteBands(bands) })
        return menu
    }

    private func graphMenu(at p: CGPoint) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let add = NSMenuItem(title: "Add Band Here", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for (shape, order) in availableShapes() {
            sub.addItem(item(shape.title, enabled: freeSlot != nil) { [weak self] in
                guard let self, let type = shape.type(order: order) else { return }
                var band = FilterParams(type: type, freq: Float(PeqLimits.clamp(self.geometry.freq(p.x), self.freqRange)),
                                        q: shape == .bell || shape == .notch ? 1 : 0.707, gain: 0)
                if type.usesGain { band.gain = Float(PeqLimits.clamp(self.geometry.db(p.y), PeqLimits.gain)) }
                self.createBand(band)
            })
        }
        add.submenu = sub
        add.isEnabled = freeSlot != nil
        menu.addItem(add)
        menu.addItem(.separator())
        menu.addItem(item("Select All Bands", enabled: !graphBands.isEmpty) { [weak self] in
            guard let self else { return }
            self.setSelection(Set(self.graphBands))
        })
        menu.addItem(item("Deselect All", enabled: !selection.isEmpty) { [weak self] in self?.setSelection([]) })
        if !selection.isEmpty {
            menu.addItem(.separator())
            let n = selection.count
            menu.addItem(item(n > 1 ? "Delete \(n) Selected Bands" : "Delete Selected Band") { [weak self] in
                guard let self else { return }
                self.deleteBands(self.selection)
            })
        }
        return menu
    }

    // MARK: - HUD

    private func wireHUD() {
        hud.onBypass = { [weak self] in
            guard let self, let b = self.hudBand else { return }
            self.toggleBypass(self.targets(for: b))
        }
        hud.onDelete = { [weak self] in
            guard let self, let b = self.hudBand else { return }
            self.deleteBands(self.targets(for: b))
        }
        hud.onShapeButton = { [weak self] in self?.toggleStrip() }
        hud.onMenu = { [weak self] anchorView in
            guard let self, let b = self.hudBand else { return }
            let menu = self.bandMenu(for: b)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.maxY + 2), in: anchorView)
        }
        hud.onEditingChanged = { [weak self] editing in
            guard let self else { return }
            if !editing { self.scheduleHUDHide() }
        }
        hud.onText = { [weak self] field, text in self?.applyTypedValue(field, text) ?? false }
        hud.onAdjust = { [weak self] field, delta, fine, phase in self?.adjustFromHUD(field, delta, phase) }
        hud.onScroll = { [weak self] field, delta, fine in
            guard let self, let b = self.hudBand else { return }
            let d = delta * (fine ? Tuning.fine : 1)
            if let p = self.adjusted(self.current(b), field, by: d * 0.5) { self.setLiveThenCommit([b: p]) }
        }
        strip.onPick = { [weak self] shape, order in
            guard let self, let b = self.hudBand else { return }
            self.setShape(self.targets(for: b), shape: shape, order: order)
            self.closeStrip()
        }
    }

    private func adjusted(_ p: FilterParams, _ field: PeqHUDField, by delta: CGFloat) -> FilterParams? {
        var q = p
        switch field {
        case .freq: q.freq = Float(PeqLimits.clamp(Double(p.freq) * pow(2, Double(delta) / 100), freqRange))
        case .gain:
            guard p.type.usesGain else { return nil }
            q.gain = Float(PeqLimits.clamp(Double(p.gain) + Double(delta) * 0.1, PeqLimits.gain))
        case .q:
            guard p.type.usesQ else { return nil }
            q.q = Float(PeqLimits.clamp(Double(p.q) * pow(2, Double(delta) / 80), PeqLimits.q))
        }
        return q
    }

    private func adjustFromHUD(_ field: PeqHUDField, _ delta: CGFloat, _ phase: PeqAdjustPhase) {
        guard let b = hudBand else { return }
        switch phase {
        case .began:
            commitTimer?.invalidate()
            hudAdjustStart = current(b)
        case .changed:
            if let start = hudAdjustStart, let p = adjusted(start, field, by: delta) { setLive([b: p]) }
        case .ended:
            hudAdjustStart = nil
            commitLive()
        }
    }

    private func applyTypedValue(_ field: PeqHUDField, _ text: String) -> Bool {
        guard let b = hudBand else { return false }
        var p = current(b)
        switch field {
        case .freq:
            guard let f = PeqValueText.parseFrequency(text) else { return false }
            p.freq = Float(PeqLimits.clamp(f, PeqLimits.freq))
        case .gain:
            guard p.type.usesGain, let g = PeqValueText.parseNumber(text, unit: "db") else { return false }
            p.gain = Float(PeqLimits.clamp(g, PeqLimits.gain))
        case .q:
            guard p.type.usesQ, let q = PeqValueText.parseNumber(text, unit: "") else { return false }
            p.q = Float(PeqLimits.clamp(q, PeqLimits.q))
        }
        if p != current(b) { commitNow([b: p]) }
        return true
    }

    private func showHUD(for b: Int) {
        guard isBand(b) else { return }
        hudHideTimer?.invalidate()
        if hudBand != b { closeStrip() }
        hudBand = b
        refreshHUD()
        if hud.isHidden {
            hud.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                hud.animator().alphaValue = 1
            }
        }
        invalidate()
    }

    private func refreshHUD() {
        guard let b = hudBand else { return }
        guard isBand(b) else { hideHUD(animated: true); return }
        hud.show(current(b), color: PeqBandPalette.nsColor(b), bypassSupported: config.bypassSupported)
        layoutHUD()
    }

    private func layoutHUD() {
        guard let b = hudBand, isBand(b) else { return }
        let p = current(b)
        let node = nodePoint(p)
        let size = PeqBandHUD.size
        let margin: CGFloat = 4
        let gap: CGFloat = 16
        let area = bounds.insetBy(dx: margin, dy: margin)
        func clampedX(_ x: CGFloat) -> CGFloat { min(max(x, area.minX), max(area.maxX - size.width, area.minX)) }
        func clampedY(_ y: CGFloat) -> CGFloat { min(max(y, area.minY), max(area.maxY - size.height, area.minY)) }
        // Away from 0 dB first, as FabFilter does, so the display never sits
        // on the band's own lobe; then beside the dot; the lobe side last.
        let above = NSRect(x: clampedX(node.x - size.width / 2), y: node.y - gap - size.height, width: size.width, height: size.height)
        let below = NSRect(x: clampedX(node.x - size.width / 2), y: node.y + gap, width: size.width, height: size.height)
        let right = NSRect(x: node.x + gap, y: clampedY(node.y - size.height / 2), width: size.width, height: size.height)
        let left = NSRect(x: node.x - gap - size.width, y: clampedY(node.y - size.height / 2), width: size.width, height: size.height)
        let boost = role(p).db(for: p) >= 0
        let candidates = boost ? [above, right, left, below] : [below, right, left, above]
        var frame = candidates.first { area.contains($0) } ?? candidates[0]
        frame.origin = NSPoint(x: clampedX(frame.minX), y: clampedY(frame.minY))
        hud.frame = frame
        if !strip.isHidden { layoutStrip() }
    }

    private func scheduleHUDHide() {
        guard !hud.isHidden, !hud.isEditingText else { return }
        if case .drag = gesture { return }
        hudHideTimer?.invalidate()
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in self?.hideHUD(animated: true) }
        hudHideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func hideHUD(animated: Bool) {
        hudHideTimer?.invalidate()
        closeStrip()
        if hud.isEditingText { hud.endEditing() }
        hudBand = nil
        guard !hud.isHidden else { return }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                hud.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.hudBand == nil else { return }
                self.hud.isHidden = true
            })
        } else {
            hud.alphaValue = 0
            hud.isHidden = true
        }
        invalidate()
    }

    private func toggleStrip() {
        guard let b = hudBand else { return }
        if !strip.isHidden { closeStrip(); return }
        strip.configure(for: current(b), available: available, color: PeqBandPalette.nsColor(b))
        strip.isHidden = false
        layoutStrip()
    }

    private func layoutStrip() {
        let size = strip.frame.size
        var x = hud.frame.minX
        x = min(max(x, 4), max(bounds.width - size.width - 4, 4))
        var y = hud.frame.maxY + 4
        if y + size.height > bounds.height - 4 { y = hud.frame.minY - size.height - 4 }
        strip.frame.origin = NSPoint(x: x, y: max(y, 4))
    }

    private func closeStrip() { strip.isHidden = true }

    private func showAxisLabel(_ text: String, at x: CGFloat) {
        axisLabel.stringValue = text
        let width = ceil(axisLabel.intrinsicContentSize.width) + 12
        let h: CGFloat = 16
        axisLabel.frame = NSRect(x: min(max(x - width / 2, 4), max(bounds.width - width - 4, 4)),
                                 y: bounds.height - h - 3, width: width, height: h)
        axisLabel.isHidden = false
    }
}

private extension PeqNodeRole {
    var gainScale: Double {
        if case .gain(let scale) = self { return scale }
        return 1
    }
}

/// A menu item that runs a closure.
final class PeqMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}
