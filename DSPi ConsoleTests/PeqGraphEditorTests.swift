import XCTest
import AppKit
import SwiftUI
@testable import DSPi_Console

/// On-graph PEQ editing: the single-precision response the GPU evaluates, the
/// dot and creation rules, value parsing, and the editor driven by real mouse
/// and key events against a recording host.  No device traffic: the editor
/// only ever talks to `RecordingHost`.
final class PeqGraphEditorTests: XCTestCase {

    // MARK: - Fixtures

    private static let hardBands: [FilterParams] = [
        FilterParams(type: .peaking, freq: 10, q: 20, gain: 24),
        FilterParams(type: .peaking, freq: 12, q: 20, gain: -24),
        FilterParams(type: .peaking, freq: 25, q: 8, gain: 12),
        FilterParams(type: .peaking, freq: 1000, q: 1, gain: 6),
        FilterParams(type: .peaking, freq: 18000, q: 5, gain: -12),
        FilterParams(type: .lowShelf, freq: 30, q: 0.707, gain: 15),
        FilterParams(type: .highShelf, freq: 8000, q: 1.2, gain: -9),
        FilterParams(type: .lowShelf1, freq: 200, q: 0.707, gain: 6),
        FilterParams(type: .highShelf1, freq: 3000, q: 0.707, gain: -6),
        FilterParams(type: .highPass, freq: 15, q: 10, gain: 0),
        FilterParams(type: .highPass, freq: 80, q: 0.5, gain: 0),
        FilterParams(type: .lowPass, freq: 12000, q: 2, gain: 0),
        FilterParams(type: .highPass1, freq: 40, q: 0.707, gain: 0),
        FilterParams(type: .lowPass1, freq: 5000, q: 0.707, gain: 0),
        FilterParams(type: .allPass, freq: 500, q: 3, gain: 0),
        FilterParams(type: .allPass1, freq: 500, q: 0.707, gain: 0),
        FilterParams(type: .notch, freq: 60, q: 4, gain: 0),
        FilterParams(type: .lr4_hp, freq: 80, q: 0.707, gain: 0),
        FilterParams(type: .bw8_lp, freq: 2500, q: 0.707, gain: 0),
    ]

    private func logFrequencies(_ count: Int, from lo: Double = 10, to hi: Double = 20000) -> [Double] {
        (0..<count).map { lo * pow(hi / lo, Double($0) / Double(count - 1)) }
    }

    // MARK: - Response math

    /// An independent Double reference: each section's |H|^2 evaluated as
    /// the complex ratio B(e^jw)/A(e^jw) with the numerator and denominator
    /// expanded about w = 0 (1 - cos w written as 2 sin^2(w/2)), so neither
    /// cancels at low frequency.
    private func referenceDB(_ bands: [FilterParams], _ f: Double) -> Double {
        var db = 0.0
        for band in bands where band.type != .flat && !band.bypass {
            let coeffs = band.type.isCrossover ? DSPMath.crossoverSections(p: band) : [DSPMath.calculateCoefficients(p: band)]
            for c in coeffs {
                let w = 2 * Double.pi * f / DSPMath.sampleRate
                let h1 = 2 * pow(sin(w / 2), 2), h2 = 2 * pow(sin(w), 2)   // 1 - cos w, 1 - cos 2w
                func mag(_ x0: Double, _ x1: Double, _ x2: Double) -> Double {
                    let re = (x0 + x1 + x2) - x1 * h1 - x2 * h2
                    let im = -(x1 * sin(w) + x2 * sin(2 * w))
                    return re * re + im * im
                }
                db += 10 * log10(max(mag(c.b0, c.b1, c.b2), 1e-300) / mag(1, c.a1, c.a2))
            }
        }
        return db
    }

    /// The phi form in Float must track a Double reference, including the
    /// high-Q, low-frequency sections that motivated Double in the first
    /// place.  Near a notch's floor the numerator itself cancels, so the
    /// tolerance widens below -30 dB; nothing below -60 dB is drawn.
    func testPhiFormMatchesDoublePrecision() {
        for band in Self.hardBands {
            let sections = PeqPhiSection.sections(for: band)
            XCTAssertFalse(sections.isEmpty, "\(band.type)")
            for f in logFrequencies(600) {
                let reference = referenceDB([band], f)
                guard reference > -60 else { continue }
                let phi = Double(sections.reduce(Float(0)) { $0 + $1.db(freq: f) })
                XCTAssertEqual(phi, reference, accuracy: reference > -30 ? 0.02 : 0.1,
                               "\(band.type) \(band.freq) Hz Q\(band.q) at \(f) Hz")
            }
        }
    }

    /// DSPMath, which draws every other curve and places the dots, agrees
    /// with the reference too, including at the resonance it used to lose.
    func testDSPMathKeepsLowNarrowResonances() {
        for band in Self.hardBands {
            for f in logFrequencies(600) {
                let reference = referenceDB([band], f)
                guard reference > -60 else { continue }
                XCTAssertEqual(Double(DSPMath.responseAt(freq: Float(f), filters: [band])), reference, accuracy: 0.01,
                               "\(band.type) \(band.freq) Hz Q\(band.q) at \(f) Hz")
            }
        }
        let bell = FilterParams(type: .peaking, freq: 10, q: 20, gain: 24)
        XCTAssertEqual(DSPMath.responseAt(freq: 10, filters: [bell]), 24, accuracy: 0.01)
    }

    func testBypassedAndOffBandsContributeNothing() {
        var p = FilterParams(type: .peaking, freq: 1000, q: 1, gain: 6)
        p.bypass = true
        XCTAssertTrue(PeqPhiSection.sections(for: p).isEmpty)
        XCTAssertTrue(PeqPhiSection.sections(for: FilterParams()).isEmpty)
    }

    func testShaderABI() throws {
        XCTAssertEqual(MemoryLayout<PeqPhiSection>.stride, 32)
        XCTAssertEqual(MemoryLayout<PeqCurveRange>.stride, 16)
        XCTAssertEqual(MemoryLayout<PeqResponseParams>.stride, 32)
        XCTAssertEqual(MemoryLayout<PeqDrawUniforms>.stride, 80)
        XCTAssertEqual(MemoryLayout<PeqNodeInstance>.stride, 48)
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        XCTAssertNotNil(PeqGraphResources.shared, "PEQ graph shaders must compile and link")
    }

    /// The kernel itself, read back from the GPU: every band row and the
    /// combined row against DSPMath at each column's frequency.
    func testGPUResponseMatchesDSPMath() throws {
        guard let resources = PeqGraphResources.shared else { throw XCTSkip("No Metal device") }
        let renderer = PeqGraphRenderer(resources: resources)
        let bands = Array(Self.hardBands.prefix(PeqGraphRenderer.bandRows))
        let statics = [FilterParams(type: .lr4_hp, freq: 60, q: 0.707, gain: 0)]
        renderer.picture.geometry = PeqGraphGeometry(size: CGSize(width: 800, height: 300),
                                                     minFreq: 10, maxFreq: 20000, dbTop: 25, dbBottom: -25)
        renderer.picture.response = .init(bands: bands, statics: statics, offsetDB: -3)
        let columns = 700
        guard let table = renderer.evaluateForTesting(columns: columns) else { return XCTFail("kernel did not run") }
        let freqs = logFrequencies(columns)
        func check(row: Int, _ expected: (Double) -> Double, _ label: String) {
            for (col, f) in freqs.enumerated() {
                let e = expected(f)
                guard e > -60 else { continue }
                XCTAssertEqual(Double(table[row * columns + col]), e, accuracy: e > -30 ? 0.05 : 0.15, "\(label) at \(f) Hz")
            }
        }
        for (row, band) in bands.enumerated() {
            check(row: row, { self.referenceDB([band], $0) }, "band \(row) \(band.type)")
        }
        check(row: PeqGraphRenderer.staticRow, { self.referenceDB(statics, $0) - 3 }, "statics")
        check(row: PeqGraphRenderer.combinedRow, { self.referenceDB(bands + statics, $0) - 3 }, "combined")
    }

    // MARK: - Geometry and dots

    func testGeometryRoundTripsAndMatchesTheGraph() {
        let g = PeqGraphGeometry(size: CGSize(width: 900, height: 250), minFreq: 15, maxFreq: 20000, dbTop: 25, dbBottom: -25)
        XCTAssertEqual(g.x(15), 0, accuracy: 1e-6)
        XCTAssertEqual(g.x(20000), 900, accuracy: 1e-6)
        XCTAssertEqual(g.y(25), 0, accuracy: 1e-6)
        XCTAssertEqual(g.y(0), 125, accuracy: 1e-6)
        for f in [20.0, 440, 1000, 12345] { XCTAssertEqual(g.freq(g.x(f)), f, accuracy: f * 1e-9) }
        for db in [-20.0, 0, 7.5] { XCTAssertEqual(g.db(g.y(db)), db, accuracy: 1e-9) }
    }

    func testDotsSitOnTheirBandsOwnCurve() {
        for band in Self.hardBands where PeqShape.of(band.type) != nil {
            let role = PeqNodeRole.of(band)
            let dot = role.db(for: band)
            switch band.type {
            case .notch, .allPass, .allPass1:
                XCTAssertEqual(dot, 0, "\(band.type) sits on 0 dB")
            default:
                let curve = Double(DSPMath.responseAt(freq: band.freq, filters: [band]))
                XCTAssertEqual(dot, curve, accuracy: 0.05, "\(band.type) dot on its curve")
            }
        }
        guard case .gain(let scale) = PeqNodeRole.of(FilterParams(type: .lowShelf, freq: 100, q: 0.707, gain: 6)) else {
            return XCTFail("a shelf's dot follows its gain")
        }
        XCTAssertEqual(scale, 0.5, accuracy: 0.001, "an RBJ shelf is half its gain at the corner")
        XCTAssertEqual(PeqNodeRole.of(FilterParams(type: .lowPass, freq: 100, q: 2, gain: 0)), .resonance)
    }

    func testCreationFollowsPositionLikeProQ() {
        let g = PeqGraphGeometry(size: CGSize(width: 1000, height: 300), minFreq: 20, maxFreq: 20000, dbTop: 25, dbBottom: -25)
        let all = Set(FilterType.allCases)
        func type(_ x: CGFloat, _ y: CGFloat, curve: Bool = false) -> FilterType {
            PeqCreation.band(at: CGPoint(x: x, y: y), in: g, available: all, fromCurve: curve).type
        }
        XCTAssertEqual(type(20, 150), .highPass, "far left makes a low cut")
        XCTAssertEqual(type(980, 150), .lowPass, "far right makes a high cut")
        XCTAssertEqual(type(500, 290), .notch, "the bottom makes a notch")
        XCTAssertEqual(type(500, 60), .peaking)
        XCTAssertEqual(type(60, 150, curve: true), .lowShelf, "pulling the curve near the left makes a shelf")
        XCTAssertEqual(type(940, 150, curve: true), .highShelf)
        let bell = PeqCreation.band(at: CGPoint(x: 500, y: 60), in: g, available: all, fromCurve: false)
        XCTAssertEqual(Double(bell.gain), g.db(60), accuracy: 0.01)
        XCTAssertEqual(Double(bell.freq), g.freq(500), accuracy: 0.01)
        XCTAssertEqual(type(500, 290), .notch)
        XCTAssertEqual(PeqCreation.band(at: CGPoint(x: 500, y: 290), in: g, available: all.subtracting([.notch]),
                                        fromCurve: false).type, .peaking, "no notch on firmware without one")
    }

    func testShapeMappingRoundTrips() {
        for shape in PeqShape.allCases {
            for order in [1, 2] {
                guard let t = shape.type(order: order) else { continue }
                XCTAssertEqual(PeqShape.of(t)?.shape, shape)
                XCTAssertEqual(PeqShape.of(t)?.order, order)
            }
        }
        XCTAssertNil(PeqShape.of(.linkwitzTransform))
        XCTAssertNil(PeqShape.of(.lr4_lp))
    }

    func testValueEntryAcceptsFabFilterShortcuts() {
        XCTAssertEqual(PeqValueText.parseFrequency("2k")!, 2000, accuracy: 1e-9)
        XCTAssertEqual(PeqValueText.parseFrequency("1.5 kHz")!, 1500, accuracy: 1e-9)
        XCTAssertEqual(PeqValueText.parseFrequency("100hz")!, 100, accuracy: 1e-9)
        XCTAssertEqual(PeqValueText.parseFrequency("A4")!, 440, accuracy: 1e-9)
        XCTAssertEqual(PeqValueText.parseFrequency("C4")!, 261.6256, accuracy: 1e-3)
        XCTAssertEqual(PeqValueText.parseFrequency("Bb3")!, 233.0819, accuracy: 1e-3)
        XCTAssertEqual(PeqValueText.parseFrequency("C#2+13")!, 69.2957 * pow(2, 13.0 / 1200), accuracy: 1e-3)
        XCTAssertNil(PeqValueText.parseFrequency("loud"))
        XCTAssertEqual(PeqValueText.parseNumber("+3.5 dB", unit: "db"), 3.5)
        XCTAssertEqual(PeqValueText.parseNumber("Q 2", unit: ""), 2)
    }

    /// The chip shows two decimals, truncated, never rounded up.
    func testChipValuesTruncateToTwoDecimals() {
        XCTAssertEqual(PeqBandHUD.truncated(4.999), "4.99")
        XCTAssertEqual(PeqBandHUD.truncated(Double(Float(1.1))), "1.10")
        XCTAssertEqual(PeqBandHUD.truncated(-6.506, sign: true), "-6.50")
        XCTAssertEqual(PeqBandHUD.truncated(5, sign: true), "+5.00")
        XCTAssertEqual(PeqBandHUD.truncated(-0.004, sign: true), "+0.00")
        XCTAssertEqual(PeqBandHUD.truncated(1799.99 / 1000), "1.79")
    }

    // MARK: - Band list

    /// Selecting a band on the graph scrolls the band list to show its row,
    /// by the least amount, and a row already in view does not move it.
    @MainActor
    func testBandListScrollsToABandSelectedOnTheGraph() throws {
        let selection = PeqGraphSelection()
        let bands = (0..<10).map { FilterParams(type: .peaking, freq: Float(100 * ($0 + 1)), q: 1, gain: 3) }
        let list = FilterListView(bands: bands, channelId: 0, availableTypes: FilterType.allCases,
                                  bypassSupported: true, onUpdate: { _, _ in }, graphSelection: selection)
            .frame(width: 700, height: 220)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: list)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        spin(0.3)
        func find(_ view: NSView) -> NSScrollView? {
            if let s = view as? NSScrollView { return s }
            for sub in view.subviews { if let s = find(sub) { return s } }
            return nil
        }
        let scroll = try XCTUnwrap(find(host))
        let top = scroll.contentView.bounds.origin.y
        selection.selected = [1]
        spin(0.5)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, top, accuracy: 0.5, "a visible row does not scroll")
        selection.selected = [9]
        spin(0.6)
        let scrolled = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(scrolled, top + 20, "the last band's row is scrolled into view")
        selection.selected = [0]
        spin(0.6)
        XCTAssertLessThan(scroll.contentView.bounds.origin.y, scrolled - 20, "and back up for the first")
    }

    // MARK: - Editor interaction

    private final class RecordingHost: PeqGraphEditorHost {
        let peqSelection = PeqGraphSelection()
        let peqLive = PeqLiveReadouts()
        var commits: [[(band: Int, params: FilterParams)]] = []
        var sends = 0
        var bypasses: [(band: Int, bypass: Bool)] = []
        func commitGraphBands(ch: Int, _ changes: [(band: Int, params: FilterParams)]) { commits.append(changes) }
        func sendGraphBandsToDevice(ch: Int, _ changes: [(band: Int, params: FilterParams)]) { sends += 1 }
        func setGraphBandBypass(ch: Int, band: Int, bypass: Bool) { bypasses.append((band, bypass)) }
    }

    private struct Rig {
        let host: RecordingHost
        let view: PeqGraphEditorView
        let window: NSWindow
        let geometry: PeqGraphGeometry
    }

    private func makeRig(bands: [FilterParams] = Array(repeating: FilterParams(), count: 10)) throws -> Rig {
        guard PeqGraphEditorView.isAvailable else { throw XCTSkip("No Metal device") }
        let host = RecordingHost()
        let view = PeqGraphEditorView(host: host)
        let size = CGSize(width: 800, height: 300)
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        var config = PeqGraphEditorConfig()
        config.channel = 0
        config.bands = bands
        config.minFreq = 20
        config.maxFreq = 20000
        config.availableTypes = FilterType.allCases.filter { !$0.isCrossover }
        config.bypassSupported = true
        view.apply(config)
        view.layoutSubtreeIfNeeded()
        let geometry = PeqGraphGeometry(size: size, minFreq: 20, maxFreq: 20000, dbTop: 25, dbBottom: -25)
        return Rig(host: host, view: view, window: window, geometry: geometry)
    }

    private func mouse(_ type: NSEvent.EventType, _ rig: Rig, _ p: CGPoint,
                       _ mods: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        let w = rig.view.convert(p, to: nil)
        return NSEvent.mouseEvent(with: type, location: w, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: clicks, pressure: 1)!
    }

    private func click(_ rig: Rig, _ p: CGPoint, _ mods: NSEvent.ModifierFlags = []) {
        rig.view.mouseDown(with: mouse(.leftMouseDown, rig, p, mods))
        rig.view.mouseUp(with: mouse(.leftMouseUp, rig, p, mods))
    }

    private func drag(_ rig: Rig, from a: CGPoint, to b: CGPoint, _ mods: NSEvent.ModifierFlags = [], steps: Int = 8) {
        rig.view.mouseDown(with: mouse(.leftMouseDown, rig, a, mods))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            rig.view.mouseDragged(with: mouse(.leftMouseDragged, rig, p, mods))
        }
        rig.view.mouseUp(with: mouse(.leftMouseUp, rig, b, mods))
    }

    private func key(_ rig: Rig, code: UInt16, chars: String, _ mods: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                 windowNumber: rig.window.windowNumber, context: nil, characters: chars,
                                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        rig.view.keyDown(with: e)
    }

    /// A trackpad-style scroll event with its amounts set explicitly, not
    /// left for the system to derive, so the delta the editor reads is fixed.
    /// `windowPoint` places it: such an event has no window, so its
    /// `locationInWindow` is its screen location, which is set to match.
    private func scrollEvent(points: Int64, flags: CGEventFlags = [], windowPoint: CGPoint? = nil) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                       wheel1: Int32(points), wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: points)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        cg.flags = flags
        if let w = windowPoint, let top = NSScreen.screens.first?.frame.maxY {
            cg.location = CGPoint(x: w.x, y: top - w.y)
        }
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertEqual(event.scrollingDeltaY, CGFloat(points), "the event carries the delta it was given")
        return event
    }

    private func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func doubleClick(_ rig: Rig, _ p: CGPoint) {
        rig.view.mouseDown(with: mouse(.leftMouseDown, rig, p))
        rig.view.mouseUp(with: mouse(.leftMouseUp, rig, p))
        rig.view.mouseDown(with: mouse(.leftMouseDown, rig, p, clicks: 2))
        rig.view.mouseUp(with: mouse(.leftMouseUp, rig, p, clicks: 2))
    }

    @MainActor
    func testSingleClickOnEmptyGraphCreatesNothing() throws {
        let rig = try makeRig()
        defer { rig.window.orderOut(nil) }
        click(rig, CGPoint(x: 400, y: 90))
        XCTAssertTrue(rig.host.commits.isEmpty, "a single click never creates a band")
    }

    @MainActor
    func testDoubleClickOnEmptyGraphCreatesTheBandUnderThePointer() throws {
        let rig = try makeRig()
        defer { rig.window.orderOut(nil) }
        let p = CGPoint(x: 400, y: 90)
        doubleClick(rig, p)
        XCTAssertEqual(rig.host.commits.count, 1, "exactly one band")
        let created = try XCTUnwrap(rig.host.commits.last?.first)
        XCTAssertEqual(created.band, 0, "the first free slot")
        XCTAssertEqual(created.params.type, .peaking)
        XCTAssertEqual(Double(created.params.freq), rig.geometry.freq(p.x), accuracy: 0.01)
        XCTAssertEqual(Double(created.params.gain), rig.geometry.db(p.y), accuracy: 0.01)
        XCTAssertEqual(rig.host.peqSelection.selected, [0], "a new band is selected")
    }

    @MainActor
    func testClickOnEmptyGraphDeselectsWhenBandsAreSelected() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[3] = FilterParams(type: .peaking, freq: 1000, q: 1, gain: 6)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let dot = CGPoint(x: rig.geometry.x(1000), y: rig.geometry.y(6))
        click(rig, dot)
        XCTAssertEqual(rig.host.peqSelection.selected, [3])
        click(rig, CGPoint(x: 150, y: 60))
        XCTAssertEqual(rig.host.peqSelection.selected, [], "the click deselects")
        XCTAssertTrue(rig.host.commits.isEmpty, "and creates nothing")
    }

    /// A drag reaches the device while it happens and the model exactly once,
    /// on release: the whole point of keeping it out of SwiftUI.
    @MainActor
    func testDragCommitsOnceOnRelease() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[2] = FilterParams(type: .peaking, freq: 1000, q: 1.5, gain: 3)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let g = rig.geometry
        let start = CGPoint(x: g.x(1000), y: g.y(3))
        let end = CGPoint(x: g.x(2000), y: g.y(9))
        rig.view.mouseDown(with: mouse(.leftMouseDown, rig, start))
        for i in 1...10 {
            let t = CGFloat(i) / 10
            rig.view.mouseDragged(with: mouse(.leftMouseDragged, rig,
                CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)))
        }
        XCTAssertTrue(rig.host.commits.isEmpty, "nothing reaches the model mid-drag")
        XCTAssertGreaterThan(rig.host.sends, 0, "the device follows the drag")
        rig.view.mouseUp(with: mouse(.leftMouseUp, rig, end))
        XCTAssertEqual(rig.host.commits.count, 1)
        let moved = try XCTUnwrap(rig.host.commits.first?.first)
        XCTAssertEqual(moved.band, 2)
        XCTAssertEqual(Double(moved.params.freq), 2000, accuracy: 2)
        XCTAssertEqual(Double(moved.params.gain), 9, accuracy: 0.05)
        XCTAssertEqual(moved.params.q, 1.5, "a plain drag leaves Q alone")
    }

    /// Scrolling Q in the middle of a drag must survive further movement:
    /// the drag rebuilds the band from its starting snapshot each event.
    @MainActor
    func testWheelQDuringDragSurvivesMovement() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = FilterParams(type: .peaking, freq: 1000, q: 1.5, gain: 3)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let g = rig.geometry
        let dot = CGPoint(x: g.x(1000), y: g.y(3))
        rig.view.mouseDown(with: mouse(.leftMouseDown, rig, dot))
        rig.view.mouseDragged(with: mouse(.leftMouseDragged, rig, CGPoint(x: dot.x + 10, y: dot.y)))
        let wheel = try scrollEvent(points: 100)
        rig.view.scrollWheel(with: wheel)
        rig.view.mouseDragged(with: mouse(.leftMouseDragged, rig, CGPoint(x: dot.x + 30, y: dot.y - 10)))
        rig.view.mouseUp(with: mouse(.leftMouseUp, rig, CGPoint(x: dot.x + 30, y: dot.y - 10)))
        let p = try XCTUnwrap(rig.host.commits.last?.first?.params)
        XCTAssertGreaterThan(p.q, 1.6, "the scrolled Q is kept after the drag moves on")
        XCTAssertGreaterThan(p.freq, 1000, "and the drag still moved the band")
    }

    /// Cmd-wheel gain moves the dot away from the pointer; the gesture must
    /// stay with its band so the gain can come back up.
    @MainActor
    func testCommandWheelGainStaysWithItsBand() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = FilterParams(type: .peaking, freq: 1000, q: 4, gain: 3)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let dot = CGPoint(x: rig.geometry.x(1000), y: rig.geometry.y(3))
        // Down 9 dB: the dot, and the narrow band's area, leave the pointer.
        for _ in 0..<18 { XCTAssertTrue(rig.view.handleWheel(at: dot, delta: -10, modifiers: .command)) }
        spin(0.3) // a pause within the gesture, shorter than its timeout
        // Back up two thirds of the way from the same pointer position.
        for _ in 0..<12 { XCTAssertTrue(rig.view.handleWheel(at: dot, delta: 10, modifiers: .command)) }
        spin(0.7)
        let p = try XCTUnwrap(rig.host.commits.last?.first?.params)
        XCTAssertEqual(p.gain, 0, accuracy: 0.01, "down 9 dB then up 6 dB, all on the one band")
    }

    /// The chip follows its dot, so Cmd-wheel gain can slide a chip field
    /// under the pointer.  The gesture must keep adjusting gain, not that
    /// field.
    @MainActor
    func testGraphWheelGestureIgnoresChipFieldSlidingUnderPointer() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = FilterParams(type: .peaking, freq: 1000, q: 2, gain: 6)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let dot = CGPoint(x: rig.geometry.x(1000), y: rig.geometry.y(6))
        rig.view.hoverForTesting(dot)
        XCTAssertTrue(rig.view.handleWheel(at: dot, delta: -10, modifiers: .command))
        // The next event of the same gesture lands on the chip's Width field.
        let wheel = try scrollEvent(points: -10, flags: .maskCommand)
        try XCTUnwrap(rig.view.hudFieldForTesting(.q)).scrollWheel(with: wheel)
        spin(0.7)
        let p = try XCTUnwrap(rig.host.commits.last?.first?.params)
        XCTAssertEqual(p.q, 2, "Width was not touched")
        XCTAssertLessThan(p.gain, 5.6, "both steps went to the gain")
    }

    /// A pause longer than a gesture ends the graph's hold on the band, but
    /// Cmd-wheel on a chip field is still the band's gain, never the field.
    @MainActor
    func testCommandWheelOnChipFieldAfterPauseAdjustsGain() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = FilterParams(type: .peaking, freq: 1000, q: 2, gain: 6)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let dot = CGPoint(x: rig.geometry.x(1000), y: rig.geometry.y(6))
        rig.view.hoverForTesting(dot)
        XCTAssertTrue(rig.view.handleWheel(at: dot, delta: -10, modifiers: .command))
        spin(0.7) // longer than a gesture
        for field in [PeqHUDField.q, .freq] {
            let target = try XCTUnwrap(rig.view.hudFieldForTesting(field))
            let onField = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: rig.view)
            let wheel = try scrollEvent(points: -10, flags: .maskCommand, windowPoint: rig.view.convert(onField, to: nil))
            let seen = rig.view.convert(wheel.locationInWindow, from: nil)
            XCTAssertEqual(seen.x, onField.x, accuracy: 1, "the editor sees the event on the field")
            XCTAssertEqual(seen.y, onField.y, accuracy: 1)
            target.scrollWheel(with: wheel)
        }
        spin(0.7)
        let p = try XCTUnwrap(rig.host.commits.last?.first?.params)
        XCTAssertEqual(p.q, 2, "Width was not touched")
        XCTAssertEqual(p.freq, 1000, "nor Frequency")
        XCTAssertEqual(p.gain, 4.5, accuracy: 0.01, "all three steps went to the gain")
    }

    /// Option held on a dot: a drag locks to one axis, a click bypasses.
    @MainActor
    func testOptionDragLocksToOneAxis() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = FilterParams(type: .peaking, freq: 1000, q: 1, gain: 3)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let dot = CGPoint(x: rig.geometry.x(1000), y: rig.geometry.y(3))
        // Mostly sideways, a little down: the lock takes frequency only.
        drag(rig, from: dot, to: CGPoint(x: dot.x + 60, y: dot.y + 12), .option)
        let p = try XCTUnwrap(rig.host.commits.last?.first?.params)
        XCTAssertGreaterThan(p.freq, 1100)
        XCTAssertEqual(p.gain, 3, "the vertical part of the drag was locked out")
        XCTAssertTrue(rig.host.bypasses.isEmpty, "a drag is not a bypass click")
    }

    /// Option pressed part-way through a drag locks to the axis moved along
    /// so far, freezing the other where it is (no jump); releasing it frees
    /// the drag again from there, also without a jump.
    @MainActor
    func testOptionMidDragLocksWithoutAJump() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = FilterParams(type: .peaking, freq: 1000, q: 1, gain: 0)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let g = rig.geometry
        let dot = CGPoint(x: g.x(1000), y: g.y(0))
        func move(_ p: CGPoint, _ mods: NSEvent.ModifierFlags = []) {
            rig.view.mouseDragged(with: mouse(.leftMouseDragged, rig, p, mods))
        }
        rig.view.mouseDown(with: mouse(.leftMouseDown, rig, dot))
        // Free drag, mostly sideways, drifting up to +2 dB.
        let a = CGPoint(x: dot.x + 60, y: g.y(2))
        move(CGPoint(x: dot.x + 30, y: g.y(1)))
        move(a)
        // Option now: locked to frequency; gain holds at +2 dB.
        move(CGPoint(x: a.x + 20, y: g.y(8)), .option)
        let b = CGPoint(x: a.x + 40, y: g.y(-5))
        move(b, .option)
        // Release Option: vertical movement counts again, from +2 dB.
        move(CGPoint(x: b.x, y: b.y - (g.y(0) - g.y(3))))
        rig.view.mouseUp(with: mouse(.leftMouseUp, rig, CGPoint(x: b.x, y: b.y)))
        let p = try XCTUnwrap(rig.host.commits.last?.first?.params)
        XCTAssertEqual(Double(p.freq), g.freq(dot.x + 100), accuracy: 2, "frequency followed all the sideways movement")
        XCTAssertEqual(Double(p.gain), 5, accuracy: 0.05, "held at +2 dB while locked, then +3 dB more once free")
    }

    /// Shift held on a dot: a drag is fine adjustment, not a range select.
    @MainActor
    func testShiftDragIsFine() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = FilterParams(type: .peaking, freq: 1000, q: 1, gain: 0)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let g = rig.geometry
        let dot = CGPoint(x: g.x(1000), y: g.y(0))
        drag(rig, from: dot, to: CGPoint(x: dot.x, y: g.y(10)), .shift)
        let p = try XCTUnwrap(rig.host.commits.last?.first?.params)
        XCTAssertEqual(Double(p.gain), 10 * 0.12, accuracy: 0.15, "fine drag moves about an eighth as far")
    }

    @MainActor
    func testNotchDragMovesFrequencyOnly() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = FilterParams(type: .notch, freq: 1000, q: 3, gain: 0)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let dot = CGPoint(x: rig.geometry.x(1000), y: rig.geometry.y(0))
        drag(rig, from: dot, to: CGPoint(x: dot.x + 40, y: dot.y - 50))
        let p = try XCTUnwrap(rig.host.commits.last?.first?.params)
        XCTAssertGreaterThan(p.freq, 1050)
        XCTAssertEqual(p.q, 3, "vertical movement does not touch a notch's Q")
    }

    @MainActor
    func testWheelOnACutChangesQNotSlope() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = FilterParams(type: .highPass, freq: 100, q: 0.707, gain: 0)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let dot = CGPoint(x: rig.geometry.x(100), y: rig.geometry.y(20 * log10(0.707)))
        for _ in 0..<5 { XCTAssertTrue(rig.view.handleWheel(at: dot, delta: 20, modifiers: [])) }
        spin(0.7)
        let p = try XCTUnwrap(rig.host.commits.last?.first?.params)
        XCTAssertEqual(p.type, .highPass, "still second order")
        XCTAssertGreaterThan(p.q, 0.9, "the wheel raised Q")
    }

    @MainActor
    func testCommandDragChangesOnlyQ() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = FilterParams(type: .peaking, freq: 500, q: 1, gain: 4)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let dot = CGPoint(x: rig.geometry.x(500), y: rig.geometry.y(4))
        drag(rig, from: dot, to: CGPoint(x: dot.x + 40, y: dot.y - 60), .command)
        let p = try XCTUnwrap(rig.host.commits.last?.first?.params)
        XCTAssertEqual(p.freq, 500)
        XCTAssertEqual(p.gain, 4)
        XCTAssertEqual(Double(p.q), 2, accuracy: 0.01, "60 points up doubles Q")
    }

    @MainActor
    func testDraggingASecondOrderCutSetsQFromItsHeight() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = FilterParams(type: .highPass, freq: 100, q: 0.707, gain: 0)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let g = rig.geometry
        let dot = CGPoint(x: g.x(100), y: g.y(20 * log10(0.707)))
        drag(rig, from: dot, to: CGPoint(x: dot.x, y: g.y(6)))
        let p = try XCTUnwrap(rig.host.commits.last?.first?.params)
        XCTAssertEqual(Double(p.q), pow(10, 6.0 / 20), accuracy: 0.02, "the dot follows the pointer to +6 dB")
    }

    @MainActor
    func testMultiSelectionMovesTogetherAndScalesGains() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = FilterParams(type: .peaking, freq: 200, q: 1, gain: 4)
        bands[1] = FilterParams(type: .peaking, freq: 2000, q: 1, gain: -2)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let g = rig.geometry
        rig.host.peqSelection.selected = [0, 1]
        let dot = CGPoint(x: g.x(200), y: g.y(4))
        drag(rig, from: dot, to: CGPoint(x: g.x(400), y: g.y(8)))
        let changes = try XCTUnwrap(rig.host.commits.last)
        let byBand = Dictionary(uniqueKeysWithValues: changes.map { ($0.band, $0.params) })
        XCTAssertEqual(Double(byBand[0]!.freq), 400, accuracy: 1)
        XCTAssertEqual(Double(byBand[1]!.freq), 4000, accuracy: 4, "same frequency ratio")
        XCTAssertEqual(Double(byBand[1]!.gain), -4, accuracy: 0.05, "gains scale in proportion")
    }

    @MainActor
    func testOptionClickBypassesAndDeleteKeyRemoves() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[5] = FilterParams(type: .peaking, freq: 3000, q: 2, gain: -6)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let dot = CGPoint(x: rig.geometry.x(3000), y: rig.geometry.y(-6))
        click(rig, dot, .option)
        XCTAssertEqual(rig.host.bypasses.last?.band, 5)
        XCTAssertEqual(rig.host.bypasses.last?.bypass, true)
        click(rig, dot)
        key(rig, code: 51, chars: "\u{7f}")
        let removed = try XCTUnwrap(rig.host.commits.last?.first)
        XCTAssertEqual(removed.band, 5)
        XCTAssertEqual(removed.params.type, .flat)
        XCTAssertEqual(rig.host.peqSelection.selected, [])
    }

    @MainActor
    func testPullingTheCurveCreatesABandFromFlat() throws {
        let rig = try makeRig()
        defer { rig.window.orderOut(nil) }
        let g = rig.geometry
        let onCurve = CGPoint(x: g.x(800), y: g.y(0))
        drag(rig, from: onCurve, to: CGPoint(x: onCurve.x, y: g.y(-7)))
        let created = try XCTUnwrap(rig.host.commits.last?.first)
        XCTAssertEqual(created.params.type, .peaking)
        XCTAssertEqual(Double(created.params.gain), -7, accuracy: 0.05)
        XCTAssertEqual(Double(created.params.freq), 800, accuracy: 1)
    }

    @MainActor
    func testMarqueeSelectsTheDotsInside() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = FilterParams(type: .peaking, freq: 100, q: 1, gain: 6)
        bands[1] = FilterParams(type: .peaking, freq: 300, q: 1, gain: 6)
        bands[2] = FilterParams(type: .peaking, freq: 5000, q: 1, gain: 6)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let g = rig.geometry
        drag(rig, from: CGPoint(x: g.x(70), y: g.y(12)), to: CGPoint(x: g.x(500), y: g.y(2)))
        XCTAssertEqual(rig.host.peqSelection.selected, [0, 1])
        XCTAssertTrue(rig.host.commits.isEmpty)
    }

    /// Idle means idle: once hover animations settle the draw loop stops, and
    /// hovering a dot redraws without recomputing any curve.
    @MainActor
    func testRendersOnDemandOnly() throws {
        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = FilterParams(type: .peaking, freq: 1000, q: 1, gain: 6)
        let rig = try makeRig(bands: bands)
        defer { rig.window.orderOut(nil) }
        let renderer = try XCTUnwrap(rig.view.rendererForTesting)
        // A window-visibility change (another test's window closing) draws
        // one fresh frame by design, so let those land first.
        spin(1.0)
        // An occluded window draws nothing at all, by design; that says
        // nothing about on-demand drawing.
        guard rig.window.occlusionState.contains(.visible), renderer.frames > 0 else {
            throw XCTSkip("Test window is not visible on screen")
        }
        let passes = renderer.responsePasses
        let frames = renderer.frames
        spin(0.4)
        // A running loop would draw ~50 frames here; a window-visibility
        // change may legitimately draw one.
        XCTAssertTrue(rig.view.drawLoopPausedForTesting, "no draw loop while nothing changes")
        XCTAssertLessThanOrEqual(renderer.frames - frames, 1, "no frames while nothing changes")
        let dot = CGPoint(x: rig.geometry.x(1000), y: rig.geometry.y(6))
        rig.view.mouseMoved(with: mouse(.mouseMoved, rig, dot))
        spin(0.5)
        XCTAssertGreaterThan(renderer.frames, frames, "the hover animates")
        XCTAssertEqual(renderer.responsePasses, passes, "hovering a dot recomputes nothing")
        let settled = renderer.frames
        spin(0.4)
        XCTAssertTrue(rig.view.drawLoopPausedForTesting, "and the loop stops once it settles")
        XCTAssertLessThanOrEqual(renderer.frames - settled, 1)
    }
}
