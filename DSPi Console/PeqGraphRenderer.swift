import AppKit
import MetalKit
import MetalPerformanceShaders

// GPU drawing for the on-graph PEQ editor.  Nothing here runs unless the
// picture changed: the view draws on demand, and the response table is only
// recomputed when a band, the axes or the width change.  Hover and selection
// animations run the display link just for their few hundred milliseconds.

struct PeqResponseParams {
    var columns: UInt32
    var curves: UInt32
    var combinedRow: UInt32
    var pad: UInt32 = 0
    var logMin: Float
    var logSpan: Float
    var piOverFs: Float
    var pad2: Float = 0
}

struct PeqCurveRange {
    var start: UInt32
    var count: UInt32
    var offsetDB: Float
    var combined: UInt32
}

struct PeqDrawUniforms {
    var viewport: SIMD4<Float>
    var color: SIMD4<Float> = .zero
    var style: SIMD4<Float> = .zero
    var map: SIMD4<Float> = .zero
    var fill: SIMD4<Float> = .zero
}

struct PeqNodeInstance {
    var center: SIMD2<Float>
    var radius: Float
    var pad: Float = 0
    var color: SIMD4<Float>
    /// Opacity in z; the rest is unused.
    var state: SIMD4<Float>
}

final class PeqGraphResources {
    static let shared = PeqGraphResources()
    let device: MTLDevice
    let queue: MTLCommandQueue
    let response: MTLComputePipelineState
    let stroke: MTLRenderPipelineState
    let lobe: MTLRenderPipelineState
    let composite: MTLRenderPipelineState
    let node: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: PeqGraphShaders.source, options: nil)
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
                return try device.makeRenderPipelineState(descriptor: d)
            }
            guard let kernel = library.makeFunction(name: "peqResponse") else { return nil }
            response = try device.makeComputePipelineState(function: kernel)
            stroke = try pipeline("peqStroke", "peqStrokeColor")
            lobe = try pipeline("peqLobeQuad", "peqLobe")
            composite = try pipeline("peqQuad", "peqComposite")
            node = try pipeline("peqNode", "peqNodeColor")
        } catch {
            NSLog("PEQ graph Metal unavailable: %@", String(describing: error))
            return nil
        }
    }
}

/// What the renderer draws, set by the editor.  Changing `response` is the
/// only thing that reruns the response kernel.
struct PeqGraphPicture {
    struct Response: Equatable {
        /// One entry per band row; nil rows are empty slots.
        var bands: [FilterParams?] = []
        /// Crossover bands, fixed during a PEQ edit.
        var statics: [FilterParams] = []
        var offsetDB: Float = 0
        /// Master EQ bypass: the combined curve is flat.
        var flat = false
    }
    struct BandStyle {
        var row: Int
        var color: SIMD4<Float>
        var lineOpacity: Float
        var fillOpacity: Float
        /// The dB range the band's lobe can reach, which bounds its fill.
        var reach: ClosedRange<Double>
    }
    var geometry = PeqGraphGeometry(size: .zero, minFreq: 20, maxFreq: 20000, dbTop: 25, dbBottom: -25)
    var response = Response()
    var bandStyles: [BandStyle] = []
    var curveColor = SIMD4<Float>(1, 1, 1, 1)
    var lineWidth: Float = 2
    var glow = true
    var nodes: [PeqNodeInstance] = []
}

/// Transparent, on-demand Metal surface.  Never takes mouse events; the
/// editor view above it does.
final class PeqGraphMetalView: MTKView {
    let renderer: PeqGraphRenderer
    /// Advances animations before a frame; returns true while any are still
    /// running, which keeps the display link going.
    var onFrame: ((CFTimeInterval) -> Bool)?
    private var animating = false
    private var observers: [NSObjectProtocol] = []

    init(resources: PeqGraphResources) {
        renderer = PeqGraphRenderer(resources: resources)
        super.init(frame: .zero, device: resources.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        preferredFramesPerSecond = 120
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        wantsLayer = true
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        delegate = renderer
        renderer.view = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Draw once on the next display cycle.
    func redraw() {
        guard !animating else { return }
        needsDisplay = true
    }

    /// Run the display link until `onFrame` reports it has settled.
    func animate() {
        guard !animating else { return }
        // Nobody can watch an animation in a hidden window: finish it now
        // and draw the end state once.
        guard isVisibleOnScreen else { _ = onFrame?(.infinity); needsDisplay = true; return }
        animating = true
        enableSetNeedsDisplay = false
        isPaused = false
    }

    fileprivate func frameWillDraw(_ now: CFTimeInterval) {
        let still = onFrame?(now) ?? false
        if animating, !still {
            animating = false
            isPaused = true
            enableSetNeedsDisplay = true
        }
    }

    private var isVisibleOnScreen: Bool {
        guard let window else { return false }
        return window.occlusionState.contains(.visible) && !window.isMiniaturized && !isHiddenOrHasHiddenAncestor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let window else { stopAnimating(); return }
        // An occluded or minimised window stops the loop; showing it again
        // draws one fresh frame.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                if self.isVisibleOnScreen { self.needsDisplay = true } else { self.stopAnimating() }
            })
        needsDisplay = true
    }
    override func viewDidHide() { super.viewDidHide(); stopAnimating() }
    override func viewDidUnhide() { super.viewDidUnhide(); needsDisplay = true }

    func stopAnimating() {
        guard animating else { return }
        animating = false
        isPaused = true
        enableSetNeedsDisplay = true
        _ = onFrame?(.infinity)
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

final class PeqGraphRenderer: NSObject, MTKViewDelegate {
    static let bandRows = 12
    static var staticRow: Int { bandRows }
    static var combinedRow: Int { bandRows + 1 }
    static var rowCount: Int { bandRows + 2 }

    private let resources: PeqGraphResources
    weak var view: PeqGraphMetalView?
    var picture = PeqGraphPicture()

    private var table: MTLBuffer?
    private var tableColumns = 0
    private var computedResponse: PeqGraphPicture.Response?
    private var computedGeometry: PeqGraphGeometry?
    private var glowSource: MTLTexture?
    private var glowResult: MTLTexture?
    private var blur: MPSImageGaussianBlur?
    private var blurSigma: Float = 0

    #if DEBUG
    /// Counters for tests: how often each stage actually ran.
    private(set) var frames = 0
    private(set) var responsePasses = 0
    #endif

    init(resources: PeqGraphResources) {
        self.resources = resources
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        (view as? PeqGraphMetalView)?.frameWillDraw(CACurrentMediaTime())
        guard view.bounds.width > 4, view.bounds.height > 4,
              let drawable = view.currentDrawable,
              let command = resources.queue.makeCommandBuffer() else { return }
        let scale = CGFloat(drawable.texture.width) / view.bounds.width
        guard encode(command: command, target: drawable.texture, backingScale: scale) else { return }
        command.present(drawable)
        command.commit()
    }

    /// Encodes one frame into `target`.  Also used offscreen by tests.
    func encode(command: MTLCommandBuffer, target: MTLTexture, backingScale: CGFloat) -> Bool {
        let g = picture.geometry
        guard g.size.width > 4, g.size.height > 4 else { return false }
        #if DEBUG
        frames += 1
        #endif
        let columns = min(max(Int((g.size.width * backingScale).rounded()), 2), 8192)
        if !encodeResponse(command: command, columns: columns) { return false }
        guard let table else { return false }

        let scale = Float(max(backingScale, 1))
        func uniforms(row: Int) -> PeqDrawUniforms {
            PeqDrawUniforms(viewport: SIMD4(Float(g.size.width), Float(g.size.height), scale, Float(columns)),
                            map: SIMD4(Float(g.dbTop), Float(g.dbSpan), Float(g.y(0)), Float(row)))
        }
        func stroke(_ e: MTLRenderCommandEncoder, row: Int, color: SIMD4<Float>, width: Float,
                    opacity: Float, fadeNearZero: Float = 0, pixelScale: Float? = nil) {
            guard opacity > 0.001 else { return }
            var u = uniforms(row: row)
            if let pixelScale { u.viewport.z = pixelScale }
            u.color = color
            u.style = SIMD4(width, opacity, fadeNearZero, 0)
            e.setRenderPipelineState(resources.stroke)
            e.setVertexBuffer(table, offset: 0, index: 0)
            e.setVertexBytes(&u, length: MemoryLayout<PeqDrawUniforms>.stride, index: 1)
            e.setFragmentBytes(&u, length: MemoryLayout<PeqDrawUniforms>.stride, index: 1)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: columns * 2)
        }

        // Glow: the combined curve stroked wide into a half-resolution
        // texture and blurred there, a quarter of the pixels a full-size
        // blur would touch.
        let glow = picture.glow && prepareGlow(width: target.width / 2, height: target.height / 2, scale: scale / 2)
        if glow, let source = glowSource, let result = glowResult, let blur,
           let e = command.makeRenderCommandEncoder(descriptor: pass(source, clear: true)) {
            stroke(e, row: Self.combinedRow, color: picture.curveColor, width: picture.lineWidth * 2.5,
                   opacity: 0.7, pixelScale: scale / 2)
            e.endEncoding()
            blur.encode(commandBuffer: command, sourceTexture: source, destinationTexture: result)
        }

        guard let e = command.makeRenderCommandEncoder(descriptor: pass(target, clear: true)) else { return false }

        // Every band's lobe, faint and fading to nothing at 0 dB; hovering or
        // selecting a band brightens it and adds its outline.
        for band in picture.bandStyles where band.fillOpacity > 0.001 {
            var u = uniforms(row: band.row)
            u.color = band.color
            let top = max(g.y(band.reach.upperBound) - 2, 0)
            let bottom = min(g.y(band.reach.lowerBound) + 2, g.size.height)
            guard bottom - top > 0.5 else { continue }
            u.fill = SIMD4(band.fillOpacity, 0, Float(top), Float(bottom))
            e.setRenderPipelineState(resources.lobe)
            e.setFragmentBuffer(table, offset: 0, index: 0)
            e.setVertexBytes(&u, length: MemoryLayout<PeqDrawUniforms>.stride, index: 1)
            e.setFragmentBytes(&u, length: MemoryLayout<PeqDrawUniforms>.stride, index: 1)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        for band in picture.bandStyles {
            stroke(e, row: band.row, color: band.color, width: 1.25, opacity: band.lineOpacity, fadeNearZero: 10)
        }
        if glow, let result = glowResult {
            var u = uniforms(row: 0)
            u.style = SIMD4(0, 0.85, 0, 0)
            e.setRenderPipelineState(resources.composite)
            e.setVertexBytes(&u, length: MemoryLayout<PeqDrawUniforms>.stride, index: 1)
            e.setFragmentBytes(&u, length: MemoryLayout<PeqDrawUniforms>.stride, index: 1)
            e.setFragmentTexture(result, index: 0)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        stroke(e, row: Self.combinedRow, color: picture.curveColor, width: picture.lineWidth, opacity: 1)

        if !picture.nodes.isEmpty {
            var u = uniforms(row: 0)
            var nodes = picture.nodes
            e.setRenderPipelineState(resources.node)
            e.setVertexBytes(&nodes, length: MemoryLayout<PeqNodeInstance>.stride * nodes.count, index: 0)
            e.setFragmentBytes(&nodes, length: MemoryLayout<PeqNodeInstance>.stride * nodes.count, index: 0)
            e.setVertexBytes(&u, length: MemoryLayout<PeqDrawUniforms>.stride, index: 1)
            e.setFragmentBytes(&u, length: MemoryLayout<PeqDrawUniforms>.stride, index: 1)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: nodes.count)
        }
        e.endEncoding()
        return true
    }

    /// Reruns the response kernel only when the bands, axes or width changed.
    private func encodeResponse(command: MTLCommandBuffer, columns: Int) -> Bool {
        let g = picture.geometry
        let axesChanged = computedGeometry.map {
            $0.minFreq != g.minFreq || $0.maxFreq != g.maxFreq
        } ?? true
        if table != nil, columns == tableColumns, !axesChanged, computedResponse == picture.response { return true }

        let length = Self.rowCount * columns * MemoryLayout<Float>.stride
        if table == nil || columns != tableColumns {
            table = resources.device.makeBuffer(length: length, options: .storageModePrivate)
            tableColumns = columns
        }
        guard let table, encodeKernel(command: command, into: table, columns: columns) else { return false }
        computedResponse = picture.response
        computedGeometry = g
        #if DEBUG
        responsePasses += 1
        #endif
        return true
    }

    private func encodeKernel(command: MTLCommandBuffer, into table: MTLBuffer, columns: Int) -> Bool {
        let g = picture.geometry

        var sections: [PeqPhiSection] = []
        var ranges: [PeqCurveRange] = []
        func add(_ bands: [FilterParams], offset: Float, combined: Bool) {
            let start = sections.count
            for p in bands { sections += PeqPhiSection.sections(for: p) }
            ranges.append(PeqCurveRange(start: UInt32(start), count: UInt32(sections.count - start),
                                        offsetDB: offset, combined: combined ? 1 : 0))
        }
        let r = picture.response
        for row in 0..<Self.bandRows {
            // A bypassed band still draws its own dimmed shape, but stays out
            // of the combined curve.
            let band: FilterParams? = row < r.bands.count ? r.bands[row] : nil
            var shape: [FilterParams] = []
            var audible = false
            if var p = band {
                audible = !p.bypass && !r.flat
                p.bypass = false
                shape = [p]
            }
            add(shape, offset: 0, combined: audible)
        }
        add(r.statics, offset: r.offsetDB, combined: true)
        if sections.isEmpty { sections.append(PeqPhiSection(DSPMath.Coeffs(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0))) }

        var params = PeqResponseParams(
            columns: UInt32(columns), curves: UInt32(ranges.count), combinedRow: UInt32(Self.combinedRow),
            logMin: Float(log10(max(g.minFreq, 1))),
            logSpan: Float(log10(max(g.maxFreq, 2)) - log10(max(g.minFreq, 1))),
            piOverFs: Float(Double.pi / DSPMath.sampleRate))
        guard let e = command.makeComputeCommandEncoder() else { return false }
        e.setComputePipelineState(resources.response)
        e.setBytes(&params, length: MemoryLayout<PeqResponseParams>.stride, index: 0)
        e.setBytes(&sections, length: MemoryLayout<PeqPhiSection>.stride * sections.count, index: 1)
        e.setBytes(&ranges, length: MemoryLayout<PeqCurveRange>.stride * ranges.count, index: 2)
        e.setBuffer(table, offset: 0, index: 3)
        let width = resources.response.threadExecutionWidth
        e.dispatchThreadgroups(MTLSize(width: (columns + width - 1) / width, height: 1, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        e.endEncoding()
        return true
    }

    #if DEBUG
    /// Runs the response kernel into readable memory, for tests: rows of
    /// `columns` dB values in the table's row order.
    func evaluateForTesting(columns: Int) -> [Float]? {
        let length = Self.rowCount * columns * MemoryLayout<Float>.stride
        guard let buffer = resources.device.makeBuffer(length: length, options: .storageModeShared),
              let command = resources.queue.makeCommandBuffer(),
              encodeKernel(command: command, into: buffer, columns: columns) else { return nil }
        command.commit()
        command.waitUntilCompleted()
        let p = buffer.contents().assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: p, count: Self.rowCount * columns))
    }
    #endif

    private func pass(_ texture: MTLTexture, clear: Bool) -> MTLRenderPassDescriptor {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = texture
        d.colorAttachments[0].loadAction = clear ? .clear : .load
        d.colorAttachments[0].storeAction = .store
        d.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        return d
    }

    private func prepareGlow(width: Int, height: Int, scale: Float) -> Bool {
        guard width > 0, height > 0 else { return false }
        if glowSource?.width != width || glowSource?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.storageMode = .private
            d.usage = [.renderTarget, .shaderRead, .shaderWrite]
            glowSource = resources.device.makeTexture(descriptor: d)
            glowResult = resources.device.makeTexture(descriptor: d)
        }
        let sigma = 3.5 * scale
        if blur == nil || blurSigma != sigma {
            blur = MPSImageGaussianBlur(device: resources.device, sigma: sigma)
            blur?.edgeMode = .zero
            blurSigma = sigma
        }
        return glowSource != nil && glowResult != nil
    }
}
