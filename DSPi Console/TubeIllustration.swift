import SwiftUI
import Combine

// MARK: - Tube Families

/// The visibly different kinds of tube among the sixteen the firmware models.
/// Tubes that look alike on a shelf share a drawing: the six 9-pin dual triodes
/// are one family, as are the two octal glass dual triodes.
enum TubeFamily: Equatable {
    case novalTriode        // 12AX7, 5751, 12AT7, 12AY7, 12AU7, 6DJ8
    case novalPentode       // EF86
    case novalPower         // EL84
    case octalGlass         // 6SN7, 6SL7
    case octalMetal         // 6SJ7 (steel envelope)
    case octalPowerLarge    // EL34
    case octalPowerSmall    // 6V6
    case shoulderedPower    // 6L6 (ST "coke bottle")
    case beamBottle         // KT88
    case directlyHeated     // 300B / 2A3

    /// Custom has no tube of its own, so it shows the default 12AX7 shape.
    static func of(_ tubeType: Int) -> TubeFamily {
        switch tubeType {
        case 6, 7: return .octalGlass
        case 9:    return .novalPentode
        case 10:   return .octalMetal
        case 11:   return .novalPower
        case 12:   return .octalPowerLarge
        case 13:   return .shoulderedPower
        case 14:   return .octalPowerSmall
        case 15:   return .beamBottle
        case 16:   return .directlyHeated
        default:   return .novalTriode
        }
    }
}

// MARK: - Geometry

/// One tube, described on a 120 x 200 design grid: x runs -60...60 about the
/// tube's axis, y runs 0 (top) to 200 (pin tips).  Every family is drawn by the
/// same renderer from one of these, so the families differ only in numbers.
private struct TubeGeometry {
    struct Plate {
        var rect: CGRect
        var fins: CGFloat = 0          // width of the side flanges on power plates
        var ribs: [CGFloat] = []       // x of the pressed stiffening ribs
        var mesh = false               // the 300B's woven plate
    }
    struct Glow {
        var at: CGPoint
        var radius: CGFloat
    }
    enum Base {
        case none                                       // 9-pin: pins leave the glass
        case bakelite(top: CGFloat, bottom: CGFloat, topHalf: CGFloat, bottomHalf: CGFloat, key: Bool)
    }

    /// Left edge of the envelope as (half-width, y) pairs, bottom to top; the
    /// right edge mirrors it and a dome closes it at `top`.
    var profile: [CGPoint]
    var top: CGFloat
    var metal = false
    var base: Base = .none
    var pins: [CGFloat]
    var pinTop: CGFloat
    var pinBottom: CGFloat
    var pinWidth: CGFloat = 1.6
    var getter: ClosedRange<CGFloat>? = nil
    var micas: [(y: CGFloat, half: CGFloat)] = []
    var rods: [(x: CGFloat, from: CGFloat, to: CGFloat)] = []
    var plates: [Plate] = []
    var filament: [CGPoint]? = nil
    var glows: [Glow] = []
    /// Steel envelopes carry a pressed ring near the base.
    var ring: ClosedRange<CGFloat>? = nil

    var glassBottom: CGFloat { profile.first!.y }
    var widestHalf: CGFloat { profile.map(\.x).max() ?? 30 }

    static func of(_ family: TubeFamily) -> TubeGeometry {
        switch family {
        case .novalTriode:
            return TubeGeometry(
                profile: [CGPoint(x: 28, y: 166), CGPoint(x: 28, y: 72)], top: 52,
                pins: [-20, -10, 0, 10, 20], pinTop: 166, pinBottom: 190,
                getter: 52...67,
                micas: [(80, 25), (142, 25)],
                rods: [(-25, 76, 164), (0, 76, 164), (25, 76, 164)],
                plates: [Plate(rect: CGRect(x: -23, y: 84, width: 20, height: 54), ribs: [-13]),
                         Plate(rect: CGRect(x: 3, y: 84, width: 20, height: 54), ribs: [13])],
                glows: [Glow(at: CGPoint(x: -13, y: 80), radius: 12), Glow(at: CGPoint(x: 13, y: 80), radius: 12),
                        Glow(at: CGPoint(x: -13, y: 142), radius: 11), Glow(at: CGPoint(x: 13, y: 142), radius: 11)])
        case .novalPentode:
            return TubeGeometry(
                profile: [CGPoint(x: 28, y: 166), CGPoint(x: 28, y: 72)], top: 52,
                pins: [-20, -10, 0, 10, 20], pinTop: 166, pinBottom: 190,
                getter: 52...67,
                micas: [(80, 25), (142, 25)],
                rods: [(-22, 76, 164), (22, 76, 164)],
                plates: [Plate(rect: CGRect(x: -17, y: 86, width: 34, height: 52), ribs: [-6, 6])],
                glows: [Glow(at: CGPoint(x: 0, y: 81), radius: 14), Glow(at: CGPoint(x: 0, y: 143), radius: 12)])
        case .novalPower:
            return TubeGeometry(
                profile: [CGPoint(x: 32, y: 168), CGPoint(x: 32, y: 58)], top: 34,
                pins: [-22, -11, 0, 11, 22], pinTop: 168, pinBottom: 192,
                getter: 34...50,
                micas: [(60, 29), (144, 29)],
                rods: [(-29, 56, 166), (29, 56, 166)],
                plates: [Plate(rect: CGRect(x: -20, y: 66, width: 40, height: 72), fins: 5, ribs: [-7, 7])],
                glows: [Glow(at: CGPoint(x: 0, y: 61), radius: 16), Glow(at: CGPoint(x: 0, y: 144), radius: 14)])
        case .octalGlass:
            return TubeGeometry(
                profile: [CGPoint(x: 30, y: 148), CGPoint(x: 30, y: 50)], top: 26,
                base: .bakelite(top: 146, bottom: 176, topHalf: 33, bottomHalf: 31, key: true),
                pins: [-21, -7, 7, 21], pinTop: 176, pinBottom: 196, pinWidth: 2.6,
                getter: 26...41,
                micas: [(58, 27), (128, 27)],
                rods: [(-26, 54, 146), (0, 54, 146), (26, 54, 146)],
                plates: [Plate(rect: CGRect(x: -22, y: 62, width: 19, height: 62), ribs: [-12.5]),
                         Plate(rect: CGRect(x: 3, y: 62, width: 19, height: 62), ribs: [12.5])],
                glows: [Glow(at: CGPoint(x: -12.5, y: 58), radius: 12), Glow(at: CGPoint(x: 12.5, y: 58), radius: 12),
                        Glow(at: CGPoint(x: -12.5, y: 128), radius: 11), Glow(at: CGPoint(x: 12.5, y: 128), radius: 11)])
        case .octalMetal:
            // A metal tube shows no glow; the one light it gives is a faint warmth
            // where the can meets the base.
            return TubeGeometry(
                profile: [CGPoint(x: 27, y: 150), CGPoint(x: 27, y: 60)], top: 52, metal: true,
                base: .bakelite(top: 148, bottom: 176, topHalf: 30, bottomHalf: 28, key: true),
                pins: [-19, -6.5, 6.5, 19], pinTop: 176, pinBottom: 196, pinWidth: 2.6,
                glows: [Glow(at: CGPoint(x: 0, y: 149), radius: 9)],
                ring: 126...132)
        case .octalPowerLarge:
            return TubeGeometry(
                profile: [CGPoint(x: 34, y: 152), CGPoint(x: 34, y: 44)], top: 14,
                base: .bakelite(top: 150, bottom: 180, topHalf: 37, bottomHalf: 35, key: true),
                pins: [-24, -8, 8, 24], pinTop: 180, pinBottom: 199, pinWidth: 2.8,
                getter: 14...31,
                micas: [(46, 31), (134, 31)],
                rods: [(-30, 42, 150), (30, 42, 150)],
                plates: [Plate(rect: CGRect(x: -23, y: 52, width: 46, height: 78), fins: 6, ribs: [0])],
                glows: [Glow(at: CGPoint(x: 0, y: 47), radius: 18), Glow(at: CGPoint(x: 0, y: 135), radius: 16)])
        case .octalPowerSmall:
            return TubeGeometry(
                profile: [CGPoint(x: 27, y: 152), CGPoint(x: 27, y: 66)], top: 44,
                base: .bakelite(top: 150, bottom: 178, topHalf: 31, bottomHalf: 29, key: true),
                pins: [-20, -7, 7, 20], pinTop: 178, pinBottom: 197, pinWidth: 2.6,
                getter: 44...59,
                micas: [(68, 24), (136, 24)],
                rods: [(-24, 64, 150), (24, 64, 150)],
                plates: [Plate(rect: CGRect(x: -17, y: 74, width: 34, height: 58), fins: 5, ribs: [0])],
                glows: [Glow(at: CGPoint(x: 0, y: 69), radius: 14), Glow(at: CGPoint(x: 0, y: 137), radius: 12)])
        case .shoulderedPower:
            return TubeGeometry(
                profile: [CGPoint(x: 26, y: 152), CGPoint(x: 30, y: 140), CGPoint(x: 36, y: 116),
                          CGPoint(x: 36, y: 104), CGPoint(x: 27, y: 76), CGPoint(x: 26, y: 60)], top: 24,
                base: .bakelite(top: 150, bottom: 180, topHalf: 34, bottomHalf: 32, key: true),
                pins: [-22, -7, 7, 22], pinTop: 180, pinBottom: 199, pinWidth: 2.8,
                getter: 24...40,
                micas: [(66, 22), (136, 30)],
                rods: [(-24, 62, 150), (24, 62, 150)],
                plates: [Plate(rect: CGRect(x: -20, y: 72, width: 40, height: 60), fins: 7, ribs: [0])],
                glows: [Glow(at: CGPoint(x: 0, y: 68), radius: 16), Glow(at: CGPoint(x: 0, y: 137), radius: 14)])
        case .beamBottle:
            return TubeGeometry(
                profile: [CGPoint(x: 30, y: 156), CGPoint(x: 32, y: 144), CGPoint(x: 42, y: 108),
                          CGPoint(x: 42, y: 40)], top: 8,
                base: .bakelite(top: 154, bottom: 184, topHalf: 36, bottomHalf: 34, key: true),
                pins: [-24, -8, 8, 24], pinTop: 184, pinBottom: 200, pinWidth: 2.8,
                getter: 8...25,
                micas: [(46, 39), (138, 36)],
                rods: [(-34, 42, 154), (34, 42, 154)],
                plates: [Plate(rect: CGRect(x: -26, y: 54, width: 52, height: 80), fins: 7, ribs: [-9, 9])],
                glows: [Glow(at: CGPoint(x: 0, y: 49), radius: 20), Glow(at: CGPoint(x: 0, y: 139), radius: 16)])
        case .directlyHeated:
            // The filament is the cathode, strung above the plate on springs, so
            // it is the thing that glows rather than anything inside the plate.
            return TubeGeometry(
                profile: [CGPoint(x: 22, y: 162), CGPoint(x: 25, y: 152), CGPoint(x: 42, y: 118),
                          CGPoint(x: 43, y: 98), CGPoint(x: 34, y: 56), CGPoint(x: 23, y: 36)], top: 10,
                base: .bakelite(top: 160, bottom: 188, topHalf: 36, bottomHalf: 34, key: false),
                pins: [-13, 13], pinTop: 188, pinBottom: 200, pinWidth: 4.5,
                getter: 10...22,
                micas: [(50, 24), (140, 27)],
                rods: [(-24, 48, 160), (24, 48, 160), (-7, 50, 57), (7, 50, 57)],
                plates: [Plate(rect: CGRect(x: -19, y: 74, width: 38, height: 62), mesh: true)],
                filament: [CGPoint(x: -15, y: 74), CGPoint(x: -7, y: 57), CGPoint(x: 0, y: 74),
                           CGPoint(x: 7, y: 57), CGPoint(x: 15, y: 74)],
                glows: [Glow(at: CGPoint(x: 0, y: 66), radius: 34)])
        }
    }
}

// MARK: - Illustration

/// The artwork is rasterized once per family, size and display scale. Audio
/// goes straight from the existing status stream to a Core Animation opacity:
/// no extra USB requests, SwiftUI invalidations, or per-frame drawing.
struct TubeIllustration: NSViewRepresentable {
    let family: TubeFamily
    let lit: Bool
    let meters: DSPMeterModel
    let outputStart: Int
    let outputCount: Int
    let outputMask: UInt16
    let active: Bool

    func makeNSView(context: Context) -> TubeIllustrationNSView {
        TubeIllustrationNSView(frame: .zero)
    }

    func updateNSView(_ view: TubeIllustrationNSView, context: Context) {
        view.configure(family: family, lit: lit, meters: meters,
                       outputStart: outputStart, outputCount: outputCount,
                       outputMask: outputMask, active: active)
    }

    static func dismantleNSView(_ view: TubeIllustrationNSView, coordinator: ()) {
        view.stopFollowingAudio()
    }
}

/// Select only routed outputs, using the platform's offset in the status
/// packet. A square-root envelope keeps ordinary listening levels visible;
/// 8-bit opacity avoids compositor commits for imperceptible changes.
enum TubeAudioPulse {
    static func opacity(peaks: [Float], outputStart: Int, outputCount: Int,
                        outputMask: UInt16) -> Float {
        var peak: Float = 0
        for output in 0..<min(max(outputCount, 0), 16)
        where outputMask & (UInt16(1) << output) != 0 {
            let channel = outputStart + output
            guard peaks.indices.contains(channel), peaks[channel].isFinite else { continue }
            peak = max(peak, peaks[channel])
        }
        return (sqrt(min(peak, 1)) * 255).rounded() / 255
    }
}

final class TubeIllustrationNSView: NSView {
    private let tube = CALayer()
    private let heater = CALayer()
    private let bloom = CALayer()
    private var family: TubeFamily = .novalTriode
    private var lit = false
    private var active = false
    private weak var meters: DSPMeterModel?
    private var outputStart = 0
    private var outputCount = 0
    private var outputMask: UInt16 = 0
    private var audioSubscription: AnyCancellable?
    private var windowSubscriptions: [AnyCancellable] = []

    private struct ArtworkKey: Equatable {
        let family: TubeFamily
        let size: CGSize
        let scale: CGFloat
    }
    private var artworkKey: ArtworkKey?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for part in [tube, heater, bloom] {
            part.actions = ["contents": NSNull(), "bounds": NSNull(),
                            "position": NSNull(), "opacity": NSNull()]
            layer?.addSublayer(part)
        }
        heater.opacity = 0
        bloom.opacity = 0
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(family: TubeFamily, lit: Bool, meters: DSPMeterModel,
                   outputStart: Int, outputCount: Int, outputMask: UInt16, active: Bool) {
        if self.meters !== meters || self.outputStart != outputStart ||
            self.outputCount != outputCount || self.outputMask != outputMask {
            audioSubscription = nil
        }
        self.meters = meters
        self.outputStart = outputStart
        self.outputCount = outputCount
        self.outputMask = outputMask
        self.active = active
        if self.family != family {
            self.family = family
            needsLayout = true
        }
        if self.lit != lit {
            self.lit = lit
            fade(heater, to: lit ? 1 : 0, duration: lit ? 0.9 : 0.6)
        }
        updateAudioSubscription()
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        let key = ArtworkKey(family: family, size: bounds.size, scale: scale)
        guard bounds.width > 0, bounds.height > 0 else { return }
        if key != artworkKey {
            let g = TubeGeometry.of(family)
            // Keep only the current family's three images, rather than a
            // growing cache of every tube and display size ever visited.
            for (index, part) in [tube, heater, bloom].enumerated() {
                let drawing = Canvas { ctx, size in
                    if index == 0 {
                        TubeRenderer.drawTube(g, in: &ctx, size: size)
                    } else {
                        TubeRenderer.drawGlow(g, in: &ctx, size: size, bloom: index == 2)
                    }
                }.frame(width: bounds.width, height: bounds.height)
                let renderer = ImageRenderer(content: drawing)
                renderer.scale = scale
                part.contents = renderer.cgImage
                part.contentsScale = scale
            }
            artworkKey = key
        }
        for part in [tube, heater, bloom] { part.frame = bounds }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowSubscriptions.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                windowSubscriptions.append(NotificationCenter.default.publisher(for: name, object: window)
                    .sink { [weak self] _ in self?.updateAudioSubscription() })
            }
        }
        needsLayout = true
        updateAudioSubscription()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateAudioSubscription()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAudioSubscription()
    }

    private func updateAudioSubscription() {
        guard active, lit, outputMask != 0, !isHiddenOrHasHiddenAncestor,
              let window, window.occlusionState.contains(.visible), !window.isMiniaturized,
              let meters else {
            stopFollowingAudio()
            return
        }
        guard audioSubscription == nil else { return }
        // @Published sends before storing; consume the event, not meters.status.
        audioSubscription = meters.$status.sink { [weak self] status in
            guard let self else { return }
            let opacity = TubeAudioPulse.opacity(peaks: status.peaks, outputStart: self.outputStart,
                                                outputCount: self.outputCount, outputMask: self.outputMask)
            self.fade(self.bloom, to: opacity, duration: 0.1)
        }
    }

    func stopFollowingAudio() {
        audioSubscription = nil
        bloom.removeAllAnimations()
        bloom.opacity = 0
    }

    private func fade(_ part: CALayer, to opacity: Float, duration: CFTimeInterval) {
        guard part.opacity != opacity else { return }
        let from = part.presentation()?.opacity ?? part.opacity
        part.opacity = opacity
        guard window?.occlusionState.contains(.visible) == true else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = opacity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        part.add(animation, forKey: "opacity")
    }
}

private enum TubeRenderer {
    static let heaterColor = Color(red: 1.0, green: 0.52, blue: 0.16)
    static let coreColor = Color(red: 1.0, green: 0.78, blue: 0.45)

    /// Centres the 120 x 200 grid in `size`, preserving its aspect.
    static func place(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let s = min(size.height / 200, size.width / 120)
        ctx.translateBy(x: size.width / 2, y: (size.height - 200 * s) / 2)
        ctx.scaleBy(x: s, y: s)
    }

    // MARK: Paths

    /// Catmull-Rom through `pts`, starting from the path's current point.
    static func smooth(_ path: inout Path, _ pts: [CGPoint]) {
        guard pts.count > 1 else { return }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    static func envelope(_ g: TubeGeometry) -> Path {
        let left = g.profile.map { CGPoint(x: -$0.x, y: $0.y) }
        let right = g.profile.reversed().map { CGPoint(x: $0.x, y: $0.y) }
        let last = g.profile.last!
        let k: CGFloat = 0.5523
        let rise = last.y - g.top
        var p = Path()
        p.move(to: left[0])
        smooth(&p, left)
        // Elliptical dome, one quarter each side of the crown.
        p.addCurve(to: CGPoint(x: 0, y: g.top),
                   control1: CGPoint(x: -last.x, y: last.y - rise * k),
                   control2: CGPoint(x: -last.x * k, y: g.top))
        p.addCurve(to: CGPoint(x: last.x, y: last.y),
                   control1: CGPoint(x: last.x * k, y: g.top),
                   control2: CGPoint(x: last.x, y: last.y - rise * k))
        smooth(&p, right)
        // A 9-pin tube's glass ends in a pressed button that bulges slightly.
        p.addQuadCurve(to: left[0], control: CGPoint(x: 0, y: g.glassBottom + 5))
        p.closeSubpath()
        return p
    }

    /// Half-width of the envelope at `y`, for sizing the reflection.
    static func halfWidth(_ g: TubeGeometry, at y: CGFloat) -> CGFloat {
        let pts = g.profile
        for i in 0..<(pts.count - 1) where y <= pts[i].y && y >= pts[i + 1].y {
            let t = (pts[i].y - y) / max(pts[i].y - pts[i + 1].y, 0.001)
            return pts[i].x + (pts[i + 1].x - pts[i].x) * t
        }
        return pts.last!.x
    }

    // MARK: Tube

    static func drawTube(_ g: TubeGeometry, in ctx: inout GraphicsContext, size: CGSize) {
        place(&ctx, size)
        let env = envelope(g)
        let w = g.widestHalf

        // Contact shadow on the shelf.
        var shadow = ctx
        shadow.addFilter(.blur(radius: 3))
        shadow.fill(Path(ellipseIn: CGRect(x: -w * 0.9, y: g.pinBottom - 3, width: w * 1.8, height: 7)),
                    with: .color(.black.opacity(0.45)))

        drawPins(g, in: &ctx)
        drawBase(g, in: &ctx)

        if g.metal {
            drawCan(g, env, in: &ctx)
            return
        }

        // Glass body: a faint cylinder shade, lighter at the rims.
        ctx.fill(env, with: .color(.black.opacity(0.22)))
        ctx.fill(env, with: .linearGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.16), location: 0),
                .init(color: .white.opacity(0.04), location: 0.2),
                .init(color: .white.opacity(0.02), location: 0.65),
                .init(color: .white.opacity(0.10), location: 0.92),
                .init(color: .white.opacity(0.14), location: 1),
            ]),
            startPoint: CGPoint(x: -w, y: 0), endPoint: CGPoint(x: w, y: 0)))

        var inner = ctx
        inner.clip(to: env)

        for rod in g.rods {
            var p = Path()
            p.move(to: CGPoint(x: rod.x, y: rod.from))
            p.addLine(to: CGPoint(x: rod.x, y: rod.to))
            inner.stroke(p, with: .color(.white.opacity(0.32)), lineWidth: 0.8)
        }
        for plate in g.plates { drawPlate(plate, in: &inner) }
        for mica in g.micas {
            inner.fill(Path(roundedRect: CGRect(x: -mica.half, y: mica.y - 0.9, width: mica.half * 2, height: 1.8),
                            cornerRadius: 0.9),
                       with: .color(.white.opacity(0.38)))
        }
        if let fil = g.filament {
            // The unlit filament: a dull wire.  The glow layer lights it.
            var p = Path()
            p.addLines(fil)
            inner.stroke(p, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 0.9, lineJoin: .round))
        }

        // Getter flash: the silvered patch the getter leaves inside the crown.
        if let getter = g.getter {
            let span = getter.upperBound - getter.lowerBound
            inner.fill(Path(CGRect(x: -60, y: getter.lowerBound - 2, width: 120, height: span + 2)),
                       with: .linearGradient(
                        Gradient(stops: [
                            .init(color: Color(white: 0.88), location: 0),
                            .init(color: Color(white: 0.62).opacity(0.95), location: 0.45),
                            .init(color: Color(white: 0.40).opacity(0), location: 1),
                        ]),
                        startPoint: CGPoint(x: 0, y: getter.lowerBound), endPoint: CGPoint(x: 0, y: getter.upperBound)))
        }

        // Reflection down the left flank.
        let reflTop = g.profile.last!.y - 2
        let reflBottom = g.glassBottom - 10
        var refl = Path()
        let steps = 12
        for i in 0...steps {
            let y = reflTop + (reflBottom - reflTop) * CGFloat(i) / CGFloat(steps)
            let pt = CGPoint(x: -halfWidth(g, at: y) + 5, y: y)
            if i == 0 { refl.move(to: pt) } else { refl.addLine(to: pt) }
        }
        inner.stroke(refl, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.20), .white.opacity(0.02)]),
            startPoint: CGPoint(x: 0, y: reflTop), endPoint: CGPoint(x: 0, y: reflBottom)),
                     style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

        ctx.stroke(env, with: .color(.white.opacity(0.5)), lineWidth: 1.0)

        // Exhaust tip, where the glass was sealed off.
        let tip = Path(roundedRect: CGRect(x: -2.6, y: g.top - 6, width: 5.2, height: 7.5), cornerRadius: 2.6)
        ctx.fill(tip, with: .color(.white.opacity(0.12)))
        ctx.stroke(tip, with: .color(.white.opacity(0.5)), lineWidth: 0.9)
    }

    static func drawPlate(_ plate: TubeGeometry.Plate, in ctx: inout GraphicsContext) {
        let r = plate.rect
        let metal = Gradient(colors: [Color(white: 0.20), Color(white: 0.36), Color(white: 0.24), Color(white: 0.16)])
        if plate.fins > 0 {
            for side in [r.minX - plate.fins, r.maxX] {
                let fin = Path(CGRect(x: side, y: r.minY + 4, width: plate.fins, height: r.height - 8))
                ctx.fill(fin, with: .color(Color(white: 0.30)))
                ctx.stroke(fin, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
            }
        }
        let body = Path(roundedRect: r, cornerRadius: 1.2)
        ctx.fill(body, with: .linearGradient(metal, startPoint: CGPoint(x: r.minX, y: 0), endPoint: CGPoint(x: r.maxX, y: 0)))
        if plate.mesh {
            var weave = ctx
            weave.clip(to: body)
            var p = Path()
            var x = r.minX - r.height
            while x < r.maxX {
                p.move(to: CGPoint(x: x, y: r.maxY)); p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x + r.height, y: r.maxY))
                x += 3.2
            }
            weave.stroke(p, with: .color(.white.opacity(0.13)), lineWidth: 0.45)
        }
        for rib in plate.ribs {
            var p = Path()
            p.move(to: CGPoint(x: rib, y: r.minY + 2)); p.addLine(to: CGPoint(x: rib, y: r.maxY - 2))
            ctx.stroke(p, with: .color(.black.opacity(0.45)), lineWidth: 1.0)
            var hi = Path()
            hi.move(to: CGPoint(x: rib + 0.9, y: r.minY + 2)); hi.addLine(to: CGPoint(x: rib + 0.9, y: r.maxY - 2))
            ctx.stroke(hi, with: .color(.white.opacity(0.14)), lineWidth: 0.6)
        }
        ctx.stroke(body, with: .color(.white.opacity(0.22)), lineWidth: 0.6)
    }

    static func drawPins(_ g: TubeGeometry, in ctx: inout GraphicsContext) {
        for x in g.pins {
            let pin = Path(roundedRect: CGRect(x: x - g.pinWidth / 2, y: g.pinTop - 2,
                                               width: g.pinWidth, height: g.pinBottom - g.pinTop + 2),
                           cornerRadius: g.pinWidth / 2)
            ctx.fill(pin, with: .linearGradient(
                Gradient(colors: [Color(white: 0.45), Color(white: 0.85), Color(white: 0.50)]),
                startPoint: CGPoint(x: x - g.pinWidth / 2, y: 0), endPoint: CGPoint(x: x + g.pinWidth / 2, y: 0)))
        }
    }

    static func drawBase(_ g: TubeGeometry, in ctx: inout GraphicsContext) {
        guard case let .bakelite(top, bottom, topHalf, bottomHalf, key) = g.base else { return }
        if key {
            // The octal locating key, a moulded stub between the pins.
            let stub = Path(roundedRect: CGRect(x: -2.8, y: bottom - 2, width: 5.6, height: 9), cornerRadius: 1.5)
            ctx.fill(stub, with: .color(Color(red: 0.16, green: 0.12, blue: 0.10)))
        }
        var p = Path()
        let r: CGFloat = 3.5
        p.move(to: CGPoint(x: -topHalf, y: top))
        p.addLine(to: CGPoint(x: topHalf, y: top))
        p.addLine(to: CGPoint(x: bottomHalf, y: bottom - r))
        p.addQuadCurve(to: CGPoint(x: bottomHalf - r, y: bottom), control: CGPoint(x: bottomHalf, y: bottom))
        p.addLine(to: CGPoint(x: -bottomHalf + r, y: bottom))
        p.addQuadCurve(to: CGPoint(x: -bottomHalf, y: bottom - r), control: CGPoint(x: -bottomHalf, y: bottom))
        p.closeSubpath()
        ctx.fill(p, with: .linearGradient(
            Gradient(colors: [Color(red: 0.09, green: 0.07, blue: 0.06),
                              Color(red: 0.25, green: 0.19, blue: 0.15),
                              Color(red: 0.11, green: 0.08, blue: 0.07)]),
            startPoint: CGPoint(x: -topHalf, y: 0), endPoint: CGPoint(x: topHalf, y: 0)))
        ctx.stroke(p, with: .color(.white.opacity(0.14)), lineWidth: 0.7)
        var seam = Path()
        seam.move(to: CGPoint(x: -topHalf + 1, y: top + 1.2))
        seam.addLine(to: CGPoint(x: topHalf - 1, y: top + 1.2))
        ctx.stroke(seam, with: .color(.white.opacity(0.18)), lineWidth: 0.6)
    }

    static func drawCan(_ g: TubeGeometry, _ env: Path, in ctx: inout GraphicsContext) {
        let w = g.widestHalf
        let steel = Gradient(stops: [
            .init(color: Color(white: 0.30), location: 0),
            .init(color: Color(white: 0.66), location: 0.28),
            .init(color: Color(white: 0.48), location: 0.6),
            .init(color: Color(white: 0.26), location: 1),
        ])
        if let ring = g.ring {
            let band = Path(roundedRect: CGRect(x: -w - 3, y: ring.lowerBound, width: (w + 3) * 2,
                                                height: ring.upperBound - ring.lowerBound), cornerRadius: 2)
            ctx.fill(band, with: .linearGradient(steel, startPoint: CGPoint(x: -w - 3, y: 0), endPoint: CGPoint(x: w + 3, y: 0)))
        }
        ctx.fill(env, with: .linearGradient(steel, startPoint: CGPoint(x: -w, y: 0), endPoint: CGPoint(x: w, y: 0)))
        if let ring = g.ring {
            let band = Path(roundedRect: CGRect(x: -w - 3, y: ring.lowerBound, width: (w + 3) * 2,
                                                height: ring.upperBound - ring.lowerBound), cornerRadius: 2)
            ctx.fill(band, with: .linearGradient(steel, startPoint: CGPoint(x: -w - 3, y: 0), endPoint: CGPoint(x: w + 3, y: 0)))
            ctx.stroke(band, with: .color(.black.opacity(0.35)), lineWidth: 0.6)
        }
        ctx.stroke(env, with: .color(.white.opacity(0.25)), lineWidth: 0.8)
        // The sealing cap on the crown.
        let cap = Path(roundedRect: CGRect(x: -7, y: g.top - 3, width: 14, height: 4), cornerRadius: 1.5)
        ctx.fill(cap, with: .color(Color(white: 0.55)))
        ctx.stroke(cap, with: .color(.black.opacity(0.3)), lineWidth: 0.5)
    }

    // MARK: Glow

    /// The heater glow, or with `bloom` the extra flare laid over it when the
    /// stage is driven hard.
    static func drawGlow(_ g: TubeGeometry, in ctx: inout GraphicsContext, size: CGSize, bloom: Bool) {
        place(&ctx, size)
        let env = envelope(g)
        let color = g.filament != nil ? coreColor : heaterColor

        if !g.metal && !bloom {
            // A faint warm cast through the whole envelope.
            ctx.fill(env, with: .color(heaterColor.opacity(0.05)))
        }

        for glow in g.glows {
            let r = bloom ? glow.radius * 1.7 : glow.radius
            let halo = Path(ellipseIn: CGRect(x: glow.at.x - r, y: glow.at.y - r, width: r * 2, height: r * 2))
            ctx.fill(halo, with: .radialGradient(
                Gradient(stops: [
                    .init(color: color.opacity((bloom ? 0.35 : 0.55) * (g.metal ? 0.45 : 1)), location: 0),
                    .init(color: heaterColor.opacity(bloom ? 0.12 : 0.2), location: 0.45),
                    .init(color: heaterColor.opacity(0), location: 1),
                ]),
                center: glow.at, startRadius: 0, endRadius: r))
            guard !bloom, g.filament == nil, !g.metal else { continue }
            // The visible end of the heater: a hot streak with a soft edge.
            let streak = Path(roundedRect: CGRect(x: glow.at.x - 1.1, y: glow.at.y - 2.6, width: 2.2, height: 5.2),
                              cornerRadius: 1.1)
            var soft = ctx
            soft.addFilter(.blur(radius: 1.6))
            soft.fill(streak, with: .color(heaterColor))
            ctx.fill(streak, with: .color(coreColor))
        }

        if let fil = g.filament {
            var p = Path()
            p.addLines(fil)
            var soft = ctx
            soft.addFilter(.blur(radius: bloom ? 4 : 2))
            soft.stroke(p, with: .color(heaterColor), style: StrokeStyle(lineWidth: bloom ? 3 : 2.2, lineJoin: .round))
            if !bloom {
                ctx.stroke(p, with: .color(Color(red: 1, green: 0.9, blue: 0.7)),
                           style: StrokeStyle(lineWidth: 1.0, lineJoin: .round))
            }
        }
    }
}
