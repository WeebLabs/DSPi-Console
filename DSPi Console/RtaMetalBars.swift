import SwiftUI
import MetalKit
import Combine

/// One channel's bars, described by where their numbers come from.  SwiftUI
/// hands these over only when the layout or a setting changes; the draw loop
/// reads each new frame from the engine itself, so a frame costs no view update.
struct RtaMetalBarSource: Equatable {
    let tap: UInt8
    let channel: Int
    let color: SIMD4<Float>
    let scale: RtaScale
    /// The smoothing preference.  The time constant also depends on the
    /// engine's live refresh interval, so it is worked out when resolving.
    let smoothing: Double
    let showPeakHold: Bool
    let rect: CGRect
}

/// Resolves sources into panels against the engine's render state, and only
/// when the engine reports the picture changed.  Sources arrive from SwiftUI on
/// main; panels are resolved on the render thread.
final class RtaMetalBarFeed {
    private weak var engine: RtaEngine?
    private let lock = NSLock()
    private var sources: [RtaMetalBarSource] = []
    private var sourcesChanged = true
    // Render thread only.
    private var resolvedVersion: UInt64?
    private let cache = RtaRenderCache()

    init(engine: RtaEngine) { self.engine = engine }

    var animating: Bool {
        lock.lock(); defer { lock.unlock() }
        return sources.contains { $0.smoothing > 0 }
    }

    func setSources(_ new: [RtaMetalBarSource]) {
        lock.lock(); defer { lock.unlock() }
        guard new != sources else { return }
        sources = new
        sourcesChanged = true
    }

    /// Whether `panelsIfChanged` would return panels.  Render thread.
    func hasChanges() -> Bool {
        guard let engine else { return false }
        lock.lock(); let changed = sourcesChanged; lock.unlock()
        return changed || engine.renderVersion != resolvedVersion
    }

    /// New panels, or nil when nothing has changed since the last call.
    /// Render thread.
    func panelsIfChanged() -> [RtaMetalBarPanel]? {
        guard let engine else { return nil }
        lock.lock()
        let sources = self.sources
        let changed = sourcesChanged
        sourcesChanged = false
        lock.unlock()
        let state = engine.renderState
        guard changed || state.version != resolvedVersion else { return nil }
        resolvedVersion = state.version
        return sources.map { source in
            RtaMetalBarPanel(configuration: state.configuration, tap: source.tap, channel: source.channel,
                             frame: state.frame(channel: source.channel, tap: source.tap),
                             color: source.color, scale: source.scale,
                             fallTau: rtaFallTau(refreshInterval: state.refreshInterval, amount: source.smoothing),
                             showPeakHold: source.showPeakHold, rect: source.rect, cache: cache)
        }
    }
}

/// An immutable channel snapshot: resolved from a source by the draw loop, or
/// supplied directly by tests and benchmarks.
struct RtaMetalBarPanel {
    let identity: Int
    let rect: CGRect
    let levels: [Double]
    let peaks: [Double]
    let visible: [Int]
    let color: SIMD4<Float>
    let floorDB: Double
    let ceilingDB: Double
    let fallTau: TimeInterval
    let showPeakHold: Bool

    static func rgba(_ color: Color) -> SIMD4<Float> {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return SIMD4(Float(rgb.redComponent), Float(rgb.greenComponent),
                     Float(rgb.blueComponent), Float(rgb.alphaComponent))
    }
}

/// The CPU/GPU ABI deliberately uses only float4s (64 bytes, alignment 16).
struct RtaBarInstance {
    var rect: SIMD4<Float>
    var clip: SIMD4<Float>
    var color: SIMD4<Float>
    var style: SIMD4<Float>
}

/// Shared by every bar surface; shaders and pipeline compile/load once.
final class RtaMetalBarResources {
    static let shared = RtaMetalBarResources()
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: RtaBarShaders.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "rtaBarVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "rtaBarFragment")
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            self.device = device
            self.queue = queue
        } catch {
            NSLog("RTA Metal unavailable; using Canvas: %@", String(describing: error))
            return nil
        }
    }
}

struct RtaMetalBars: NSViewRepresentable {
    let engine: RtaEngine
    let sources: [RtaMetalBarSource]
    var active = true

    func makeNSView(context: Context) -> RtaMetalBarView {
        let view = RtaMetalBarView()
        view.update(sources: sources, engine: engine, active: active)
        return view
    }

    func updateNSView(_ view: RtaMetalBarView, context: Context) {
        view.update(sources: sources, engine: engine, active: active)
    }

    static func dismantleNSView(_ view: RtaMetalBarView, coordinator: ()) {
        view.stop()
    }
}

/// A single surface for an entire strip, drawn off the main thread; see
/// `RtaMetalSurface`.  With interpolation off it draws only on data/size changes.
final class RtaMetalBarView: RtaMetalSurface {
    private var renderer: RtaMetalBarRenderer?
    private var feed: RtaMetalBarFeed?

    init() {
        let resources = RtaMetalBarResources.shared
        super.init(device: resources?.device)
        if let resources { renderer = RtaMetalBarRenderer(resources: resources) }
        delegate = renderer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Fixed panels, for tests and benchmarks.
    func update(panels: [RtaMetalBarPanel], active: Bool) {
        renderer?.update(panels)
        animating = panels.contains { $0.fallTau > 0 }
        setActive(active)
        requestRedraw()
    }

    /// Live bars: the render thread resolves `sources` against the engine.
    func update(sources: [RtaMetalBarSource], engine: RtaEngine, active: Bool) {
        if feed == nil {
            let feed = RtaMetalBarFeed(engine: engine)
            self.feed = feed
            renderer?.feed = feed
        }
        feed?.setSources(sources)
        animating = feed?.animating ?? false
        setActive(active)
    }
}

final class RtaMetalBarRenderer: NSObject, RtaMetalSurfaceDelegate {
    private let resources: RtaMetalBarResources
    // Render thread only, apart from tests driving it directly.
    private var panels: [RtaMetalBarPanel] = []
    /// Fixed panels handed over from main, adopted at the next frame.
    private let pendingLock = NSLock()
    private var pending: [RtaMetalBarPanel]?
    private struct Filters {
        let bars = RtaBarSmoother()
        let caps = RtaBarSmoother()
    }
    private var filters: [Int: Filters] = [:]
    // Each slot is leased until its command buffer completes. Never overwrite
    // memory the GPU is reading, and never block the main thread waiting for it.
    private let slots: [MTLBuffer]
    private let slotLock = NSLock()
    private var busy = [false, false, false]
    private static let capacity = 16 * 37 * 2

    init?(resources: RtaMetalBarResources) {
        let slots = (0..<3).compactMap { _ in resources.device.makeBuffer(
            length: Self.capacity * MemoryLayout<RtaBarInstance>.stride, options: .storageModeShared) }
        guard slots.count == 3 else { return nil }
        self.resources = resources
        self.slots = slots
        super.init()
    }

    /// Fixed panels, for tests and benchmarks.  Any thread.
    func update(_ panels: [RtaMetalBarPanel]) {
        pendingLock.lock(); pending = panels; pendingLock.unlock()
    }

    private func adopt(_ panels: [RtaMetalBarPanel]) {
        self.panels = panels
        let identities = Set(panels.map(\.identity))
        filters = filters.filter { identities.contains($0.key) }
        for panel in panels where filters[panel.identity] == nil { filters[panel.identity] = Filters() }
    }

    private func acquireSlot() -> Int? {
        slotLock.lock(); defer { slotLock.unlock() }
        guard let slot = busy.firstIndex(of: false) else { return nil }
        busy[slot] = true
        return slot
    }

    private func releaseSlot(_ slot: Int) {
        slotLock.lock(); defer { slotLock.unlock() }
        busy[slot] = false
    }

    /// Set for live bars; nil when panels are supplied directly.  Set once on
    /// main before the surface first draws.
    var feed: RtaMetalBarFeed?

    func surfaceHasChanges(_ surface: RtaMetalSurface) -> Bool {
        pendingLock.lock(); let fixed = pending != nil; pendingLock.unlock()
        return fixed || feed?.hasChanges() == true
    }

    func draw(in surface: RtaMetalSurface, drawable: CAMetalDrawable, size: CGSize, scale: CGFloat) {
        pendingLock.lock(); let fixed = pending; pending = nil; pendingLock.unlock()
        if let fixed { adopt(fixed) }
        if let fresh = feed?.panelsIfChanged() { adopt(fresh) }
        guard let slot = acquireSlot() else { surface.requestRedraw(); return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let command = resources.queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
            releaseSlot(slot)
            return
        }

        #if RTA_RENDER_BENCHMARK
        RtaBarBenchmarkMetrics.frame()
        #endif

        // CACurrentMediaTime is monotonic. Date here is just the existing
        // smoother's scalar time carrier, never the adjustable wall clock.
        let now = Date(timeIntervalSinceReferenceDate: CACurrentMediaTime())
        let buffer = slots[slot]
        let instances = buffer.contents().bindMemory(to: RtaBarInstance.self, capacity: Self.capacity)
        var count = 0
        for panel in panels {
            guard let filter = filters[panel.identity], !panel.visible.isEmpty,
                  panel.rect.width > 0, panel.rect.height > 2 else { continue }
            let avg = panel.fallTau > 0 ? filter.bars.step(
                now: now, target: panel.levels, identity: panel.identity,
                riseTau: panel.fallTau * 0.4, fallTau: panel.fallTau) : panel.levels
            let peaks: [Double]
            if panel.showPeakHold {
                peaks = panel.fallTau > 0 ? filter.caps.step(
                    now: now, target: panel.peaks, identity: panel.identity,
                    riseTau: 0, fallTau: panel.fallTau) : panel.peaks
            } else { peaks = [] }
            Self.writeInstances(panel: panel, levels: avg, peaks: peaks,
                                into: instances, count: &count, capacity: Self.capacity)
        }
        var viewport = SIMD2<Float>(Float(size.width), Float(size.height))
        encoder.setRenderPipelineState(resources.pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        if count > 0 {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        }
        encoder.endEncoding()
        command.addCompletedHandler { [self] command in
            #if RTA_RENDER_BENCHMARK
            RtaBarBenchmarkMetrics.gpu(seconds: command.gpuEndTime - command.gpuStartTime)
            #endif
            releaseSlot(slot)
        }
        command.present(drawable)
        command.commit()
    }

    /// Pure geometry preparation, also exercised without a Metal device.
    static func writeInstances(panel: RtaMetalBarPanel, levels: [Double], peaks: [Double],
                               into out: UnsafeMutablePointer<RtaBarInstance>, count: inout Int,
                               capacity: Int) {
        guard !panel.visible.isEmpty, panel.ceilingDB > panel.floorDB else { return }
        let plot = panel.rect
        let slot = plot.width / CGFloat(panel.visible.count)
        let gap = min(2.0, max(0.5, slot * 0.18))
        let width = max(1, slot - gap)
        let floorDB = panel.floorDB, rangeDB = panel.ceilingDB - panel.floorDB
        let minX = plot.minX, minY = plot.minY, maxY = plot.maxY, plotHeight = plot.height
        let clipX0 = Float(plot.minX), clipY0 = Float(plot.minY)
        let clipX1 = Float(plot.maxX), clipY1 = Float(plot.maxY)
        let red = panel.color.x, green = panel.color.y, blue = panel.color.z, alpha = panel.color.w
        let barWidth = Float(width), corner = Float(min(1.5, width / 3))
        let showPeaks = panel.showPeakHold

        // Runs for every band of every panel on every frame, so it writes the
        // instance floats directly and compares explicitly: unoptimised builds
        // do not specialise the SIMD initialisers, enumerated() or min/max.
        // The comparisons mirror the standard library's, so the values match.
        // RtaBarInstance is four float4s: rect, clip, color, style.
        let f = UnsafeMutableRawPointer(out).assumingMemoryBound(to: Float.self)
        func norm(_ db: Double) -> Double {
            guard db.isFinite else { return 0 }
            let v = (db - floorDB) / rangeDB
            let w = v >= 0 ? v : 0
            return w < 1 ? w : 1
        }
        panel.visible.withUnsafeBufferPointer { visible in
            levels.withUnsafeBufferPointer { lv in
                peaks.withUnsafeBufferPointer { pk in
                    var pos = 0
                    while pos < visible.count {
                        let band = visible[pos]
                        let x = minX + CGFloat(pos) * slot + gap / 2
                        pos += 1
                        guard band >= 0, band < lv.count else { continue }
                        let level = norm(lv[band])
                        if level > 0.001, count < capacity {
                            let height = plotHeight * level
                            let o = count * 16
                            f[o] = Float(x); f[o + 1] = Float(maxY - height)
                            f[o + 2] = barWidth; f[o + 3] = Float(height)
                            f[o + 4] = clipX0; f[o + 5] = clipY0; f[o + 6] = clipX1; f[o + 7] = clipY1
                            f[o + 8] = red; f[o + 9] = green; f[o + 10] = blue; f[o + 11] = alpha
                            f[o + 12] = corner; f[o + 13] = 0.95; f[o + 14] = 0.45; f[o + 15] = 0
                            count += 1
                        }
                        if showPeaks, band < pk.count {
                            let peak = norm(pk[band])
                            if peak > 0.001, count < capacity {
                                let top = maxY - plotHeight * peak - 1
                                let y = top >= minY ? top : minY
                                let o = count * 16
                                f[o] = Float(x); f[o + 1] = Float(y); f[o + 2] = barWidth; f[o + 3] = 1.5
                                f[o + 4] = clipX0; f[o + 5] = clipY0; f[o + 6] = clipX1; f[o + 7] = clipY1
                                f[o + 8] = red; f[o + 9] = green; f[o + 10] = blue; f[o + 11] = alpha
                                f[o + 12] = 0; f[o + 13] = 0.9; f[o + 14] = 0.9; f[o + 15] = 0
                                count += 1
                            }
                        }
                    }
                }
            }
        }
    }
}
