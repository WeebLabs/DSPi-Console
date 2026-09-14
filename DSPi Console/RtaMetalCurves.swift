import SwiftUI
import MetalKit
import MetalPerformanceShaders

struct RtaMetalCurveChannel {
    let channel: Int
    let color: SIMD4<Float>
    let bands: RtaBandFrame?
    let bins: RtaBinFrame?
}

/// Immutable measurement inputs arrive at USB cadence. MetalKit owns the draw
/// loop; interpolation no longer causes a SwiftUI update or builds a Path.
struct RtaMetalCurvePanel {
    let tap: UInt8
    let configuration: RtaDisplayConfiguration
    let channels: [RtaMetalCurveChannel]
    let minFreq: Double
    let maxFreq: Double
    let scale: RtaScale
    let fallTau: TimeInterval
    let showPeak: Bool
    let glow: Bool
    let opacity: Double
}

struct RtaCurveUniforms {
    var viewport: SIMD4<Float>
    var color: SIMD4<Float>
    var style: SIMD4<Float>
    var gradient: SIMD4<Float> = SIMD4(0.34, 0.02, 0, 0)
}

final class RtaMetalCurveResources {
    static let shared = RtaMetalCurveResources()
    let device: MTLDevice
    let queue: MTLCommandQueue
    let fill: MTLRenderPipelineState
    let stroke: MTLRenderPipelineState
    let composite: MTLRenderPipelineState

    private init?() {
        guard let shared = RtaMetalBarResources.shared else { return nil }
        device = shared.device
        queue = shared.queue
        do {
            let library = try device.makeLibrary(source: RtaCurveShaders.source, options: nil)
            func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: vertex)
                d.fragmentFunction = library.makeFunction(name: fragment)
                let c = d.colorAttachments[0]!
                c.pixelFormat = .bgra8Unorm
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try shared.device.makeRenderPipelineState(descriptor: d)
            }
            fill = try pipeline("rtaCurveFill", "rtaCurveFillColor")
            stroke = try pipeline("rtaCurveStroke", "rtaCurveStrokeColor")
            composite = try pipeline("rtaCurveQuad", "rtaCurveComposite")
        } catch {
            NSLog("Spectrum Metal unavailable; using Canvas: %@", String(describing: error))
            return nil
        }
    }
}

struct RtaMetalCurves: NSViewRepresentable {
    let panel: RtaMetalCurvePanel
    let active: Bool

    func makeNSView(context: Context) -> RtaMetalCurveView {
        let view = RtaMetalCurveView()
        view.update(panel: panel, active: active)
        return view
    }
    func updateNSView(_ view: RtaMetalCurveView, context: Context) { view.update(panel: panel, active: active) }
    static func dismantleNSView(_ view: RtaMetalCurveView, coordinator: ()) { view.stop() }
}

/// Same lifecycle as the bar surface, including on-demand redraw with smoothing
/// off and stopping immediately when detached, hidden, minimised or occluded.
final class RtaMetalCurveView: MTKView {
    private var renderer: RtaMetalCurveRenderer?
    private var requestedActive = true
    private var animating = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let resources = RtaMetalCurveResources.shared
        super.init(frame: .zero, device: resources?.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        preferredFramesPerSecond = 60
        isPaused = true
        enableSetNeedsDisplay = true
        wantsLayer = true
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        if let resources { renderer = RtaMetalCurveRenderer(resources: resources) }
        delegate = renderer
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(panel: RtaMetalCurvePanel, active: Bool) {
        renderer?.update(panel)
        requestedActive = active
        animating = panel.fallTau > 0
        updateVisibility()
        needsDisplay = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in self?.updateVisibility() })
            }
        }
        updateVisibility()
    }
    override func viewDidHide() { super.viewDidHide(); updateVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateVisibility() }
    private func updateVisibility() {
        let visible = requestedActive && window?.occlusionState.contains(.visible) == true
            && window?.isMiniaturized == false && !isHiddenOrHasHiddenAncestor
        renderer?.active = visible
        if enableSetNeedsDisplay != !animating { enableSetNeedsDisplay = !animating }
        if isPaused != (!visible || !animating) { isPaused = !visible || !animating }
        if visible { needsDisplay = true }
    }
    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
    func stop() {
        requestedActive = false
        isPaused = true
        renderer?.active = false
        removeObservers()
        delegate = nil
    }
    deinit { removeObservers() }
}

/// Flatten exactly the same clamped cubic Beziers as smoothPath, within a
/// fraction of a physical pixel. This preserves the band/peak contours without
/// asking SwiftUI/CoreGraphics to tessellate and stroke them every frame.
enum RtaCurveGeometry {
    /// A physical-pixel height table lets the GPU fill a curve with two
    /// triangles, avoiding thousands of tall, subpixel-width fill triangles.
    static func fillSamples(_ points: [SIMD2<Float>], width: CGFloat, backingScale: CGFloat) -> [SIMD2<Float>] {
        guard points.count > 1 else { return [] }
        let start = max(0, points[0].x), end = min(Float(width), points[points.count - 1].x)
        guard end > start else { return [] }
        let intervals = max(1, Int(ceil(Double(end - start) * Double(max(1, backingScale)))))
        let step = (end - start) / Float(intervals)
        var samples: [SIMD2<Float>] = []
        samples.reserveCapacity(intervals + 1)
        var segment = 0
        for column in 0...intervals {
            let x = start + Float(column) * step
            while segment < points.count - 2, points[segment + 1].x < x { segment += 1 }
            let a = points[segment], b = points[segment + 1]
            let t = min(1, max(0, (x - a.x) / max(b.x - a.x, 1e-6)))
            samples.append(SIMD2(x, a.y + (b.y - a.y) * t))
        }
        return samples
    }

    static func flatten(_ points: [CGPoint], dense: Bool, plot: CGRect,
                        backingScale: CGFloat) -> [SIMD2<Float>] {
        guard points.count > 1, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        if dense { return points.map { SIMD2(Float($0.x), Float($0.y)) } }
        var out = [SIMD2(Float(points[0].x), Float(points[0].y))]
        out.reserveCapacity(points.count * 8)
        let tolerance = 0.15 / max(backingScale, 1)
        func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(dx * dx + dy * dy, 1e-12)))
            return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
        }
        func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        func emit(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, depth: Int) {
            if depth >= 12 || max(distance(b, a, d), distance(c, a, d)) <= tolerance {
                out.append(SIMD2(Float(d.x), Float(d.y)))
                return
            }
            let ab = middle(a, b), bc = middle(b, c), cd = middle(c, d)
            let abc = middle(ab, bc), bcd = middle(bc, cd), mid = middle(abc, bcd)
            emit(a, ab, abc, mid, depth: depth + 1)
            emit(mid, bcd, cd, d, depth: depth + 1)
        }
        func clamp(_ y: CGFloat) -> CGFloat { min(max(y, plot.minY), plot.maxY) }
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: clamp(p1.y + (p2.y - p0.y) / 6))
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: clamp(p2.y - (p3.y - p1.y) / 6))
            emit(p1, c1, c2, p2, depth: 0)
        }
        return out
    }
}

final class RtaMetalCurveRenderer: NSObject, MTKViewDelegate {
    private let resources: RtaMetalCurveResources
    private var panel: RtaMetalCurvePanel?
    private var filters: [Int: RtaCurveSmoothing] = [:]
    private var lastWidth: CGFloat = 0
    private var slots: [MTLBuffer?] = [nil, nil, nil]
    private let slotLock = NSLock()
    private var busy = [false, false, false]
    private var glowSource: MTLTexture?
    private var glowResult: MTLTexture?
    private var blur: MPSImageGaussianBlur?
    private var blurScale: CGFloat = 0
    var active = true

    init(resources: RtaMetalCurveResources) { self.resources = resources; super.init() }

    func update(_ panel: RtaMetalCurvePanel) {
        precondition(Thread.isMainThread)
        if self.panel?.configuration != panel.configuration || self.panel?.minFreq != panel.minFreq
            || self.panel?.maxFreq != panel.maxFreq { filters.removeAll() }
        let channels = Set(panel.channels.map(\.channel))
        filters = filters.filter { channels.contains($0.key) }
        self.panel = panel
    }
    private func acquireSlot() -> Int? {
        slotLock.lock(); defer { slotLock.unlock() }
        guard let i = busy.firstIndex(of: false) else { return nil }
        busy[i] = true
        return i
    }
    private func releaseSlot(_ i: Int) {
        slotLock.lock(); defer { slotLock.unlock() }
        busy[i] = false
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        precondition(Thread.isMainThread)
        guard active, view.bounds.width > 4, view.bounds.height > 4,
              let drawable = view.currentDrawable, let command = resources.queue.makeCommandBuffer() else { return }
        let scale = CGFloat(drawable.texture.width) / view.bounds.width
        guard encode(command: command, target: drawable.texture, size: view.bounds.size, backingScale: scale,
                     now: Date(timeIntervalSinceReferenceDate: CACurrentMediaTime())) else { return }
        #if RTA_CURVE_BENCHMARK
        RtaCurveBenchmarkMetrics.frame()
        command.addCompletedHandler { RtaCurveBenchmarkMetrics.gpu($0.gpuEndTime - $0.gpuStartTime) }
        #endif
        command.present(drawable)
        command.commit()
    }

    private struct Trace {
        let color: SIMD4<Float>
        let average: Range<Int>
        let fill: Range<Int>
        let peak: Range<Int>
        let start: Float
    }

    /// Also used for offscreen GPU regression tests. The caller commits the
    /// command after a successful encode. In-flight CPU buffers are never reused.
    func encode(command: MTLCommandBuffer, target: MTLTexture, size: CGSize,
                backingScale: CGFloat, now: Date) -> Bool {
        precondition(Thread.isMainThread)
        guard size.width > 4, size.height > 4, let panel, let slot = acquireSlot() else { return false }
        var submitted = false
        defer { if !submitted { releaseSlot(slot) } }
        if lastWidth != size.width { filters.removeAll(); lastWidth = size.width }
        let plot = CGRect(origin: .zero, size: size)
        var points: [SIMD2<Float>] = []
        var traces: [Trace] = []
        if panel.tap == panel.configuration.tap {
            for channel in panel.channels {
                let smoothing = filters[channel.channel] ?? RtaCurveSmoothing()
                filters[channel.channel] = smoothing
                let builder = RtaCurveBuilder(configuration: panel.configuration, smoothing: smoothing,
                    minFreq: panel.minFreq, maxFreq: panel.maxFreq, plot: plot, scale: panel.scale,
                    now: panel.fallTau > 0 ? now : nil, tau: panel.fallTau)
                let band = channel.bands.flatMap { $0.hasData ? $0 : nil }
                let bands = band.map { builder.bandPoints($0, peak: false, channel: channel.channel) } ?? []
                let bins = channel.bins.flatMap { Int($0.channel) == channel.channel ? $0 : nil }
                    .map { builder.binPoints($0, channel: channel.channel) } ?? []
                let curve = builder.blend(bands: bands, bins: bins)
                let avg = RtaCurveGeometry.flatten(curve, dense: bins.count > 1, plot: plot, backingScale: backingScale)
                let peakPoints = panel.showPeak ? band.map { builder.bandPoints($0, peak: true, channel: channel.channel) } ?? [] : []
                let peak = RtaCurveGeometry.flatten(peakPoints, dense: false, plot: plot, backingScale: backingScale)
                let first = min(avg.first?.x ?? .infinity, peak.first?.x ?? .infinity)
                guard first.isFinite else { continue }
                let avgRange = points.count..<(points.count + avg.count)
                points.append(contentsOf: avg)
                let peakRange = points.count..<(points.count + peak.count)
                points.append(contentsOf: peak)
                let fill = RtaCurveGeometry.fillSamples(avg, width: size.width, backingScale: backingScale)
                let fillRange = points.count..<(points.count + fill.count)
                points.append(contentsOf: fill)
                traces.append(Trace(color: channel.color, average: avgRange, fill: fillRange, peak: peakRange, start: first))
            }
        }
        let length = max(1, points.count) * MemoryLayout<SIMD2<Float>>.stride
        if (slots[slot]?.length ?? 0) < length {
            slots[slot] = resources.device.makeBuffer(length: max(4096, length * 2), options: .storageModeShared)
        }
        guard let buffer = slots[slot] else { return false }
        points.withUnsafeBytes { if let base = $0.baseAddress, !$0.isEmpty { buffer.contents().copyMemory(from: base, byteCount: $0.count) } }

        func pass(_ texture: MTLTexture, clear: Bool) -> MTLRenderPassDescriptor {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = texture
            d.colorAttachments[0].loadAction = clear ? .clear : .load
            d.colorAttachments[0].storeAction = .store
            d.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            return d
        }
        func uniforms(_ color: SIMD4<Float>, count: Int, width: Float = 1, alpha: Float,
                      fadeStart: Float, fade: Bool = true) -> RtaCurveUniforms {
            RtaCurveUniforms(viewport: SIMD4(Float(size.width), Float(size.height), Float(max(1, backingScale)), Float(count)),
                color: color, style: SIMD4(width, alpha, fadeStart, fade && fadeStart > 1 ? 1 : 0))
        }
        func draw(_ encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState,
                  range: Range<Int>, uniforms: RtaCurveUniforms, fill: Bool = false) {
            guard range.count > 1 else { return }
            var u = uniforms
            if fill {
                u.gradient.z = points[range.lowerBound].x
                u.gradient.w = (points[range.upperBound - 1].x - u.gradient.z) / Float(range.count - 1)
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: range.lowerBound * MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.setFragmentBuffer(buffer, offset: range.lowerBound * MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.setVertexBytes(&u, length: MemoryLayout<RtaCurveUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<RtaCurveUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: fill ? 4 : range.count * 2)
        }
        let groups = Dictionary(grouping: traces) { Int($0.start.rounded()) }
        let opacity = Float(panel.opacity)
        if panel.glow, !traces.isEmpty {
            guard prepareGlow(width: target.width, height: target.height, scale: backingScale) else { return false }
        }
        var firstPass = true
        for key in groups.keys.sorted() {
            let group = groups[key]!
            let start = group.map(\.start).min()!
            if panel.glow, let source = glowSource, let result = glowResult, let blur {
                guard let encoder = command.makeRenderCommandEncoder(descriptor: pass(source, clear: true)) else { return false }
                for t in group {
                    draw(encoder, pipeline: resources.stroke, range: t.average,
                         uniforms: uniforms(t.color, count: t.average.count, width: 2, alpha: 0.35 * opacity, fadeStart: start, fade: false))
                }
                encoder.endEncoding()
                blur.encode(commandBuffer: command, sourceTexture: source, destinationTexture: result)
            }
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass(target, clear: firstPass)) else { return false }
            firstPass = false
            for t in group {
                draw(encoder, pipeline: resources.fill, range: t.fill,
                     uniforms: uniforms(t.color, count: t.fill.count, alpha: opacity, fadeStart: start), fill: true)
            }
            if panel.glow, let result = glowResult {
                var u = uniforms(SIMD4(repeating: 1), count: 0, alpha: 1, fadeStart: start)
                encoder.setRenderPipelineState(resources.composite)
                encoder.setVertexBytes(&u, length: MemoryLayout<RtaCurveUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&u, length: MemoryLayout<RtaCurveUniforms>.stride, index: 1)
                encoder.setFragmentTexture(result, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            for t in group {
                draw(encoder, pipeline: resources.stroke, range: t.average,
                     uniforms: uniforms(t.color, count: t.average.count, alpha: 0.55 * opacity, fadeStart: start))
                draw(encoder, pipeline: resources.stroke, range: t.peak,
                     uniforms: uniforms(t.color, count: t.peak.count, alpha: 0.35 * opacity, fadeStart: start))
            }
            encoder.endEncoding()
        }
        if firstPass { // Always clear old spectra, including mismatched taps and empty selections.
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass(target, clear: true)) else { return false }
            encoder.endEncoding()
        }
        command.addCompletedHandler { [self] _ in releaseSlot(slot) }
        submitted = true
        return true
    }

    private func prepareGlow(width: Int, height: Int, scale: CGFloat) -> Bool {
        if glowSource?.width != width || glowSource?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.storageMode = .private
            d.usage = [.renderTarget, .shaderRead, .shaderWrite]
            glowSource = resources.device.makeTexture(descriptor: d)
            glowResult = resources.device.makeTexture(descriptor: d)
        }
        if blur == nil || blurScale != scale {
            blur = MPSImageGaussianBlur(device: resources.device, sigma: Float(4 * scale))
            blur?.edgeMode = .zero
            blurScale = scale
        }
        return glowSource != nil && glowResult != nil
    }
}
