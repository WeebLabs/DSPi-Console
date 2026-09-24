import AppKit
import SwiftUI
import simd

// The pure logic behind on-graph PEQ editing: coordinate mapping, what each
// filter type's dot means, the shapes a click creates, band colours, value
// text, and the response form the GPU evaluates.  No views here, so all of it
// is unit-testable.

// MARK: - Geometry

/// Point <-> frequency / dB mapping for the response graph.  Identical to
/// `BodePlotView.xPos`/`yPos` (log frequency across the full width, dB top to
/// bottom), so dots land exactly on the SwiftUI grid.  Flipped coordinates:
/// y grows downward.
struct PeqGraphGeometry: Equatable {
    var size: CGSize
    var minFreq: Double
    var maxFreq: Double
    var dbTop: Double
    var dbBottom: Double

    private var logMin: Double { log10(max(minFreq, 1)) }
    private var logSpan: Double { max(log10(max(maxFreq, 2)) - logMin, 1e-6) }
    var dbSpan: Double { max(dbTop - dbBottom, 1e-6) }

    func x(_ freq: Double) -> CGFloat {
        CGFloat((log10(max(freq, 1e-3)) - logMin) / logSpan) * size.width
    }
    func freq(_ x: CGFloat) -> Double {
        pow(10, logMin + Double(x / max(size.width, 1)) * logSpan)
    }
    func y(_ db: Double) -> CGFloat {
        CGFloat((dbTop - db) / dbSpan) * size.height
    }
    func db(_ y: CGFloat) -> Double {
        dbTop - Double(y / max(size.height, 1)) * dbSpan
    }
    /// dB per point, for turning a vertical drag into a gain change.
    var dbPerPoint: Double { dbSpan / Double(max(size.height, 1)) }
}

// MARK: - Shapes

/// The shapes the graph creates and offers, named as FabFilter names them.
/// Each maps onto the firmware's types; `order` picks the 6 dB/oct (first
/// order) or 12 dB/oct (second order) variant where both exist.
enum PeqShape: Int, CaseIterable {
    case bell, lowShelf, lowCut, highShelf, highCut, notch, allPass

    var title: String {
        switch self {
        case .bell: return "Bell"
        case .lowShelf: return "Low Shelf"
        case .lowCut: return "Low Cut"
        case .highShelf: return "High Shelf"
        case .highCut: return "High Cut"
        case .notch: return "Notch"
        case .allPass: return "All Pass"
        }
    }

    /// The firmware type for this shape at `order` (1 or 2), or nil when the
    /// shape has no such order.
    func type(order: Int) -> FilterType? {
        switch (self, order) {
        case (.bell, 2): return .peaking
        case (.lowShelf, 2): return .lowShelf
        case (.lowShelf, 1): return .lowShelf1
        case (.lowCut, 2): return .highPass
        case (.lowCut, 1): return .highPass1
        case (.highShelf, 2): return .highShelf
        case (.highShelf, 1): return .highShelf1
        case (.highCut, 2): return .lowPass
        case (.highCut, 1): return .lowPass1
        case (.notch, 2): return .notch
        case (.allPass, 2): return .allPass
        case (.allPass, 1): return .allPass1
        default: return nil
        }
    }

    /// The shape and order of a firmware type; nil for types the graph does
    /// not edit (off, crossovers, the Linkwitz Transform).
    static func of(_ type: FilterType) -> (shape: PeqShape, order: Int)? {
        for shape in allCases {
            for order in [2, 1] where shape.type(order: order) == type { return (shape, order) }
        }
        return nil
    }

    /// Slope labels for the two orders, when a shape has both.
    func orderTitle(_ order: Int) -> String {
        if self == .allPass { return order == 1 ? "1st Order" : "2nd Order" }
        return order == 1 ? "6 dB/oct" : "12 dB/oct"
    }

    var isCut: Bool { self == .lowCut || self == .highCut }

    /// The two-letter code the rest of the app shows for this shape
    /// (`FilterType.shortLabel`, without its order suffix).
    var code: String {
        switch self {
        case .bell: return "PK"
        case .lowShelf: return "LS"
        case .lowCut: return "LC"
        case .highShelf: return "HS"
        case .highCut: return "HC"
        case .notch: return "NT"
        case .allPass: return "AP"
        }
    }
}

// MARK: - Dots

/// What a band's dot stands for, which decides where it sits and what a
/// vertical drag changes.
enum PeqNodeRole: Equatable {
    /// The dot sits on the band's own curve at its frequency, `scale` dB per
    /// dB of gain (1 for a bell, one half for a shelf), and follows the
    /// cursor by changing gain.
    case gain(scale: Double)
    /// A second-order cut: the dot sits at the curve's level at the cutoff,
    /// which is 20 log10(Q), so following the cursor changes Q.
    case resonance
    /// Fixed height (0 dB for a notch or all-pass, the cutoff level of a
    /// first-order cut).  A drag moves frequency only; Q is the wheel's.
    case fixed(db: Double)
    /// Shown and selectable, but not dragged (the Linkwitz Transform, whose
    /// four values are edited in its own panel).
    case locked(db: Double)

    static func of(_ p: FilterParams) -> PeqNodeRole {
        var probe = p
        probe.bypass = false
        switch p.type {
        case .peaking, .lowShelf, .highShelf, .lowShelf1, .highShelf1:
            // Measured rather than assumed, so the dot stays on the curve for
            // whatever shelf formula the firmware uses.
            probe.gain = 12
            let atF0 = Double(DSPMath.responseAt(freq: probe.freq, filters: [probe]))
            return .gain(scale: max(abs(atF0 / 12), 0.05))
        case .lowPass, .highPass:
            return .resonance
        case .lowPass1, .highPass1:
            return .fixed(db: Double(DSPMath.responseAt(freq: probe.freq, filters: [probe])))
        case .linkwitzTransform:
            return .locked(db: Double(DSPMath.responseAt(freq: probe.freq, filters: [probe])))
        default:
            return .fixed(db: 0)
        }
    }

    /// The dot's height in dB for `p`.
    func db(for p: FilterParams) -> Double {
        switch self {
        case .gain(let scale): return Double(p.gain) * scale
        case .resonance: return 20 * log10(Double(max(p.q, 0.01)))
        case .fixed(let db), .locked(let db): return db
        }
    }
}

/// Limits the graph enforces.  Q and frequency match the firmware's own
/// clamps (dsp_compute_coefficients); gain is FabFilter's +/-30 dB, which the
/// firmware does not bound itself.
enum PeqLimits {
    static let gain: ClosedRange<Double> = -30...30
    static let q: ClosedRange<Double> = Double(FilterParams.qRange.lowerBound)...Double(FilterParams.qRange.upperBound)
    static var freq: ClosedRange<Double> { Double(FilterParams.minFreq)...(DSPMath.sampleRate * 0.45) }

    static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
}

extension FilterParams {
    /// True for the bands the graph draws a dot for.
    var isGraphBand: Bool { type != .flat && !type.isCrossover }
}

// MARK: - Creation

/// Which band a click on the empty graph makes, following FabFilter Pro-Q 4:
/// the far left and right make cuts, the bottom of the display a notch, and
/// anywhere else a bell at the cursor.  Dragging the curve itself makes a
/// shelf near either end and a bell elsewhere.
enum PeqCreation {
    static let cutZone: CGFloat = 0.06
    static let shelfZone: CGFloat = 0.12
    static let notchZone: CGFloat = 0.18

    static func band(at point: CGPoint, in g: PeqGraphGeometry, available: Set<FilterType>,
                     fromCurve: Bool) -> FilterParams {
        let fx = point.x / max(g.size.width, 1)
        let freq = PeqLimits.clamp(g.freq(point.x), PeqLimits.freq)
        var p = FilterParams(type: .peaking, freq: Float(freq), q: 1, gain: 0)
        if fromCurve {
            if fx < shelfZone, available.contains(.lowShelf) { p.type = .lowShelf; p.q = 0.707 }
            else if fx > 1 - shelfZone, available.contains(.highShelf) { p.type = .highShelf; p.q = 0.707 }
            return p
        }
        if fx < cutZone, available.contains(.highPass) {
            p.type = .highPass; p.q = 0.707
        } else if fx > 1 - cutZone, available.contains(.lowPass) {
            p.type = .lowPass; p.q = 0.707
        } else if point.y > g.size.height * (1 - notchZone), g.db(point.y) < -6, available.contains(.notch) {
            p.type = .notch
        } else {
            p.gain = Float(PeqLimits.clamp(g.db(point.y), PeqLimits.gain))
        }
        return p
    }
}

// MARK: - Colours

/// One hue per band, so a band keeps its colour in the list below the graph.
/// Drawn from the same soft, mid-saturation family as `ChannelPalette`
/// (roughly 45-65 % saturation at high brightness) so the dots read as part
/// of the app rather than as neon on top of it.
enum PeqBandPalette {
    static let rgb: [SIMD3<Float>] = [
        SIMD3(0.93, 0.47, 0.45), // coral
        SIMD3(0.95, 0.64, 0.36), // orange
        SIMD3(0.92, 0.79, 0.40), // amber
        SIMD3(0.55, 0.80, 0.52), // sage
        SIMD3(0.36, 0.77, 0.68), // teal
        SIMD3(0.44, 0.68, 0.94), // sky
        SIMD3(0.58, 0.60, 0.94), // periwinkle
        SIMD3(0.73, 0.57, 0.92), // lavender
        SIMD3(0.89, 0.54, 0.72), // rose
        SIMD3(0.80, 0.62, 0.50), // clay
    ]

    static func simd(_ band: Int) -> SIMD4<Float> {
        let c = rgb[((band % rgb.count) + rgb.count) % rgb.count]
        return SIMD4(c.x, c.y, c.z, 1)
    }
    static func nsColor(_ band: Int) -> NSColor {
        let c = simd(band)
        return NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }
    static func color(_ band: Int) -> Color { Color(nsColor: nsColor(band)) }
}

// MARK: - Value text

/// Display and entry of band values, including FabFilter's shortcuts:
/// "2k" for 2000 Hz and note names such as "A4" or "C#2+13" (cents).
enum PeqValueText {
    static func frequency(_ hz: Double) -> String {
        if hz >= 10_000 { return String(format: "%.2f kHz", hz / 1000) }
        if hz >= 1000 { return String(format: "%.3f kHz", hz / 1000) }
        if hz >= 100 { return String(format: "%.1f Hz", hz) }
        return String(format: "%.2f Hz", hz)
    }
    static func shortFrequency(_ hz: Double) -> String {
        if hz >= 1000 { return String(format: hz >= 10_000 ? "%.1fk" : "%.2fk", hz / 1000) }
        return String(format: hz >= 100 ? "%.0f" : "%.1f", hz)
    }
    static func gain(_ db: Double) -> String {
        let v = abs(db) < 0.005 ? 0 : db
        return String(format: "%+.2f dB", v)
    }
    static func q(_ q: Double) -> String { String(format: "%.3f", q) }

    static func parseFrequency(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let note = parseNote(s) { return note }
        s = s.replacingOccurrences(of: " ", with: "")
        var scale = 1.0
        if s.hasSuffix("khz") { scale = 1000; s.removeLast(3) }
        else if s.hasSuffix("hz") { s.removeLast(2) }
        if s.hasSuffix("k") { scale = 1000; s.removeLast() }
        guard let v = Double(s), v.isFinite else { return nil }
        return v * scale
    }

    static func parseNumber(_ text: String, unit: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "")
        if s.hasSuffix(unit) { s.removeLast(unit.count) }
        if s.hasPrefix("q") { s.removeFirst() }
        if s.hasPrefix("+") { s.removeFirst() }
        guard let v = Double(s), v.isFinite else { return nil }
        return v
    }

    /// "A4" = 440 Hz; "C#2+13" is C sharp 2 raised 13 cents.  Octave numbers
    /// follow the C4 = middle C convention.
    static func parseNote(_ s: String) -> Double? {
        let chars = Array(s)
        guard let first = chars.first, let base = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11][first] else { return nil }
        var i = 1
        var semitone = base
        if i < chars.count, chars[i] == "#" { semitone += 1; i += 1 }
        else if i < chars.count, chars[i] == "b", i + 1 < chars.count, chars[i + 1].isNumber || chars[i + 1] == "-" {
            semitone -= 1; i += 1
        }
        var octaveText = ""
        if i < chars.count, chars[i] == "-" { octaveText.append("-"); i += 1 }
        while i < chars.count, chars[i].isNumber { octaveText.append(chars[i]); i += 1 }
        guard let octave = Int(octaveText) else { return nil }
        var cents = 0.0
        if i < chars.count {
            guard let c = Double(String(chars[i...])) else { return nil }
            cents = c
        }
        let midi = Double((octave + 1) * 12 + semitone) + cents / 100
        return 440 * pow(2, (midi - 69) / 12)
    }
}

// MARK: - GPU response form

/// One biquad section prepared for evaluation in single precision.
///
/// The obvious form, 1 + a1 cos w + a2 cos 2w, cancels catastrophically at
/// low frequencies and high Q, which is why `DSPMath` works in Double.  The
/// GPU has no Double, so the section is rewritten in terms of
/// phi = sin^2(w/2):
///   |B|^2 = (b0+b1+b2)^2 - 4 (b0 b1 + b1 b2 + 4 b0 b2) phi + 16 b0 b2 phi^2
/// and the same for the denominator with b0 = 1.  Every cancelling sum is
/// formed here in Double; what is left for the GPU is a well-conditioned
/// quadratic in phi.
struct PeqPhiSection {
    var n: SIMD4<Float>
    var d: SIMD4<Float>

    init(_ c: DSPMath.Coeffs) {
        let (b0, b1, b2, a1, a2) = (c.b0, c.b1, c.b2, c.a1, c.a2)
        let sb = b0 + b1 + b2
        let sa = 1 + a1 + a2
        n = SIMD4(Float(sb * sb), Float(-4 * (b0 * b1 + b1 * b2 + 4 * b0 * b2)), Float(16 * b0 * b2), 0)
        d = SIMD4(Float(sa * sa), Float(-4 * (a1 + a1 * a2 + 4 * a2)), Float(16 * a2), 0)
    }

    /// The shader's arithmetic, in Swift, for tests.
    func db(freq: Double, sampleRate: Double = DSPMath.sampleRate) -> Float {
        let s = Float(sin(Double.pi * freq / sampleRate))
        let phi = s * s
        let num = n.x + phi * (n.y + phi * n.z)
        let den = d.x + phi * (d.y + phi * d.z)
        return 10 * (log10(max(num, 1e-30)) - log10(max(den, 1e-30)))
    }

    /// The biquad sections a band contributes, empty when it is off or
    /// bypassed.  Crossovers cascade several.
    static func sections(for p: FilterParams) -> [PeqPhiSection] {
        guard p.type != .flat, p.active, !p.bypass else { return [] }
        let coeffs = p.type.isCrossover ? DSPMath.crossoverSections(p: p) : [DSPMath.calculateCoefficients(p: p)]
        return coeffs.map(PeqPhiSection.init)
    }
}

// MARK: - Interpolation

extension FilterParams {
    /// A band part-way to `target`, for animating a change made elsewhere:
    /// frequency and Q move in the log domain, as the eye reads them.  A
    /// change of type cannot be blended, so it lands at once.
    func interpolated(to target: FilterParams, _ t: Double) -> FilterParams {
        guard type == target.type, bypass == target.bypass, t < 1 else { return target }
        var p = target
        let f = Double(t)
        p.freq = Float(exp(log(Double(freq)) + (log(Double(target.freq)) - log(Double(freq))) * f))
        p.q = Float(exp(log(Double(max(q, 0.01))) + (log(Double(max(target.q, 0.01))) - log(Double(max(q, 0.01)))) * f))
        p.gain = gain + (target.gain - gain) * Float(f)
        return p
    }
}
