import AppKit
import Metal
import QuartzCore

/// The one thread every spectrum surface draws on.
///
/// MTKView draws from the main run loop, so anything that holds the main
/// thread - SwiftUI building a window that has just opened, say - froze the
/// spectrum with it.  The surfaces instead attach their display links to this
/// thread's run loop and present from here, the arrangement Apple's "Creating a
/// custom Metal view" sample uses when it renders off the main thread.
final class RtaRenderThread: Thread {
    static let shared: RtaRenderThread = {
        let thread = RtaRenderThread()
        thread.name = "DSPi Console RTA render"
        thread.qualityOfService = .userInteractive
        thread.start()
        thread.ready.wait()
        return thread
    }()

    private let ready = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A run loop with no source returns at once; the port keeps it alive
        // between display links.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while true {
            autoreleasepool { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
    }

    /// Run `block` on the render thread.  `RunLoop` may only be touched from
    /// its own thread, so a display link is added, paused or invalidated here.
    func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }
}

/// What a surface draws.  Both calls arrive on the render thread.
protocol RtaMetalSurfaceDelegate: AnyObject {
    /// Whether a frame drawn now would differ from the last one.  Asked only
    /// while nothing animates, so an idle surface takes no drawable.
    func surfaceHasChanges(_ surface: RtaMetalSurface) -> Bool
    /// Encode and present one frame into `drawable`, `size` points at `scale`.
    func draw(in surface: RtaMetalSurface, drawable: CAMetalDrawable, size: CGSize, scale: CGFloat)
}

/// A CAMetalLayer view drawn from `RtaRenderThread`.  It stops drawing when
/// detached, hidden, occluded or minimised; while nothing animates it draws
/// only when its delegate reports a change or the main thread asks.
class RtaMetalSurface: NSView {
    /// The display link's ceiling, as on MTKView.
    var preferredFramesPerSecond = 60 {
        didSet {
            guard let link else { return }
            let range = frameRateRange
            RtaRenderThread.shared.perform { link.preferredFrameRateRange = range }
        }
    }

    private var frameRateRange: CAFrameRateRange {
        let fps = Float(preferredFramesPerSecond)
        return CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
    }
    /// True while the display link is not delivering frames.  Main thread.
    private(set) var isPaused = true

    /// Guards everything below that the render thread reads.
    private let stateLock = NSLock()
    private weak var delegateStorage: RtaMetalSurfaceDelegate?
    private var rendering = false
    private var animatingStorage = false
    private var dirty = true
    private var size: CGSize = .zero
    private var scale: CGFloat = 1
    /// Held across a frame on the render thread and across a drawable resize
    /// on main, so a frame never draws into a layer changing size under it.
    private let drawLock = NSLock()

    private var link: CADisplayLink?
    private var requestedActive = true
    private var observers: [NSObjectProtocol] = []

    var delegate: RtaMetalSurfaceDelegate? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return delegateStorage }
        set { stateLock.lock(); delegateStorage = newValue; stateLock.unlock() }
    }

    /// Keep the display link running for interpolation; otherwise draw only on
    /// changes.  Main thread.
    var animating: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return animatingStorage }
        set { stateLock.lock(); animatingStorage = newValue; stateLock.unlock() }
    }

    /// Created here and handed to AppKit, so the render thread never asks the
    /// view for its layer.
    let metalLayer = CAMetalLayer()

    init(device: MTLDevice?) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let layer = metalLayer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Draw on the next display frame even if the delegate reports no change.
    func requestRedraw() {
        stateLock.lock(); dirty = true; stateLock.unlock()
    }

    /// Whether the owner wants frames at all; visibility is folded in here.
    func setActive(_ active: Bool) {
        requestedActive = active
        updateVisibility()
    }

    // MARK: Geometry

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = bounds.size
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        stateLock.lock()
        let changed = size != self.size || scale != self.scale
        self.size = size
        self.scale = scale
        if changed { dirty = true }
        stateLock.unlock()
        guard changed else { return }
        drawLock.lock()
        metalLayer.contentsScale = scale
        if pixels.width >= 1, pixels.height >= 1 { metalLayer.drawableSize = pixels }
        drawLock.unlock()
    }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in self?.updateVisibility() })
            }
            if link == nil { attachLink() }
            updateDrawableSize()
        } else {
            detachLink()
        }
        updateVisibility()
    }

    override func viewDidHide() { super.viewDidHide(); updateVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateVisibility() }

    private func updateVisibility() {
        let visible = requestedActive && window?.occlusionState.contains(.visible) == true
            && window?.isMiniaturized == false && !isHiddenOrHasHiddenAncestor
        stateLock.lock()
        rendering = visible
        if visible { dirty = true }
        stateLock.unlock()
        setLinkPaused(!visible || link == nil)
    }

    /// The link fires at the display rate even when no frame is due: the check
    /// is a lock and a version compare, and it lets data that arrives while
    /// main is busy reach the screen without main's help.
    private func setLinkPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        guard let link else { return }
        RtaRenderThread.shared.perform { link.isPaused = paused }
    }

    private func attachLink() {
        let link = displayLink(target: RtaSurfaceLinkTarget(self), selector: #selector(RtaSurfaceLinkTarget.tick(_:)))
        link.isPaused = true
        link.preferredFrameRateRange = frameRateRange
        self.link = link
        isPaused = true
        RtaRenderThread.shared.perform { link.add(to: .current, forMode: .default) }
    }

    private func detachLink() {
        guard let link else { return }
        self.link = nil
        isPaused = true
        RtaRenderThread.shared.perform { link.invalidate() }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Tear down for good: SwiftUI is dismantling the view.
    func stop() {
        requestedActive = false
        removeObservers()
        detachLink()
        stateLock.lock()
        rendering = false
        delegateStorage = nil
        stateLock.unlock()
    }

    deinit {
        removeObservers()
        if let link { RtaRenderThread.shared.perform { link.invalidate() } }
    }

    // MARK: Render thread

    fileprivate func renderTick() {
        stateLock.lock()
        let delegate = delegateStorage
        let due = rendering && delegate != nil
        let animating = animatingStorage
        let wasDirty = dirty
        let size = size, scale = scale
        if due { dirty = false }
        stateLock.unlock()
        guard due, let delegate, size.width >= 1, size.height >= 1 else { return }
        guard animating || wasDirty || delegate.surfaceHasChanges(self) else { return }

        drawLock.lock()
        defer { drawLock.unlock() }
        guard let drawable = metalLayer.nextDrawable() else {
            // Try again next frame rather than drop a change.
            requestRedraw()
            return
        }
        delegate.draw(in: self, drawable: drawable, size: size, scale: scale)
    }
}

/// The display link retains its target; this keeps it from retaining the view.
private final class RtaSurfaceLinkTarget: NSObject {
    private weak var surface: RtaMetalSurface?
    init(_ surface: RtaMetalSurface) { self.surface = surface }
    @objc func tick(_ link: CADisplayLink) {
        autoreleasepool { surface?.renderTick() }
    }
}
