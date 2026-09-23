import XCTest
import AppKit
import Metal
import SwiftUI
@testable import DSPi_Console

/// Renders the on-graph editor to PNG files for a visual review: the GPU
/// picture over a replica of the graph's grid, with the AppKit parameter
/// display on top.  Runs only when asked, e.g.
///   TEST_RUNNER_PEQ_SNAPSHOT_DIR=/tmp/peq xcodebuild test -only-testing:...
final class PeqGraphSnapshotTests: XCTestCase {

    @MainActor
    func testWriteSnapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["PEQ_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_PEQ_SNAPSHOT_DIR to write snapshots")
        }
        guard let resources = PeqGraphResources.shared else { throw XCTSkip("No Metal device") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var bands = Array(repeating: FilterParams(), count: 10)
        bands[0] = FilterParams(type: .highPass, freq: 32, q: 0.9, gain: 0)
        bands[1] = FilterParams(type: .lowShelf, freq: 110, q: 0.707, gain: 4.5)
        bands[2] = FilterParams(type: .peaking, freq: 380, q: 2.2, gain: -6.5)
        bands[3] = FilterParams(type: .peaking, freq: 1800, q: 1.1, gain: 5)
        bands[4] = FilterParams(type: .notch, freq: 4200, q: 6, gain: 0)
        bands[5] = FilterParams(type: .highShelf, freq: 9000, q: 0.707, gain: -3.5)
        var bypassed = FilterParams(type: .peaking, freq: 90, q: 4, gain: -8)
        bypassed.bypass = true
        bands[6] = bypassed

        let size = CGSize(width: 900, height: 280)
        let host = SnapshotHost()
        let view = PeqGraphEditorView(host: host)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 80, y: 80), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var config = PeqGraphEditorConfig()
        config.channel = 0
        config.bands = bands
        config.minFreq = 15
        config.maxFreq = 20000
        config.dbTop = 15
        config.dbBottom = -15
        config.curveColor = SIMD4(0.35, 0.78, 1.0, 1)
        config.availableTypes = FilterType.allCases.filter { !$0.isCrossover }
        config.bypassSupported = true
        view.apply(config)
        view.layoutSubtreeIfNeeded()
        let g = PeqGraphGeometry(size: size, minFreq: 15, maxFreq: 20000, dbTop: 15, dbBottom: -15)

        func shoot(_ name: String) throws {
            view.settleForTesting()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            view.settleForTesting()
            view.displayIfNeeded()
            let renderer = try XCTUnwrap(view.rendererForTesting)
            try write(renderer: renderer, resources: resources, view: view, geometry: g,
                      to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }

        // Idle: every band drawn thin, nothing emphasised.
        view.hoverForTesting(CGPoint(x: -100, y: -100))
        try shoot("1-idle")

        // A selected bell with its parameter display, another band hovered.
        host.peqSelection.selected = [3]
        view.hoverForTesting(CGPoint(x: g.x(1800), y: g.y(5)))
        try shoot("2-selected-hud")

        // Hovering empty graph: the ghost of the band a click would create.
        host.peqSelection.selected = []
        view.hoverForTesting(CGPoint(x: g.x(650), y: g.y(8)))
        try shoot("3-ghost")

        // Multiple selection: both lobes filled, both rings.
        host.peqSelection.selected = [1, 2, 5]
        view.hoverForTesting(CGPoint(x: g.x(380), y: g.y(-6.5)))
        try shoot("4-multi")
    }

    /// The band list's bypass controls in band colours: enabled on the top
    /// row, bypassed below, an empty band at the end of each.
    @MainActor
    func testWriteBypassControls() throws {
        guard let dir = ProcessInfo.processInfo.environment["PEQ_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_PEQ_SNAPSHOT_DIR to write snapshots")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let strip = VStack(spacing: 6) {
            ForEach([true, false], id: \.self) { active in
                HStack(spacing: 10) {
                    ForEach(0..<10, id: \.self) { band in
                        BypassCheckbox(isActive: active, isEnabled: true, color: PeqBandPalette.color(band), onToggle: {})
                    }
                    BypassCheckbox(isActive: false, isEnabled: false, onToggle: {})
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .background(Color(NSColor.windowBackgroundColor))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: strip)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.cgImage)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("5-bypass-controls.png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private final class SnapshotHost: PeqGraphEditorHost {
        let peqSelection = PeqGraphSelection()
        let peqLive = PeqLiveReadouts()
        func commitGraphBands(ch: Int, _ changes: [(band: Int, params: FilterParams)]) {}
        func sendGraphBandsToDevice(ch: Int, _ changes: [(band: Int, params: FilterParams)]) {}
        func setGraphBandBypass(ch: Int, band: Int, bypass: Bool) {}
    }

    private func write(renderer: PeqGraphRenderer, resources: PeqGraphResources, view: NSView,
                       geometry g: PeqGraphGeometry, to url: URL) throws {
        let scale: CGFloat = 2
        let w = Int(g.size.width * scale), h = Int(g.size.height * scale)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .managed
        let texture = try XCTUnwrap(resources.device.makeTexture(descriptor: d))
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        XCTAssertTrue(renderer.encode(command: command, target: texture, backingScale: scale))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.synchronize(resource: texture)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: info))
        // Graph background and grid, as BodePlotView draws them.
        // The card colour over the window, as the page composites it.
        let window = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .black
        let card = NSColor.controlBackgroundColor.usingColorSpace(.sRGB) ?? .black
        ctx.setFillColor(window.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(card.withAlphaComponent(0.6).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        func vline(_ f: Double, _ a: CGFloat) {
            ctx.setStrokeColor(CGColor(gray: 1, alpha: a))
            ctx.stroke(CGRect(x: g.x(f), y: 0, width: 0, height: g.size.height), width: 1)
        }
        for decade in [10.0, 100, 1000, 10000] {
            for k in 1...9 { let f = decade * Double(k); if f >= g.minFreq, f <= g.maxFreq { vline(f, k == 1 ? 0.15 : 0.06) } }
        }
        for db in stride(from: -15.0, through: 15, by: 3) {
            ctx.setStrokeColor(CGColor(gray: 1, alpha: db == 0 ? 0.3 : 0.1))
            ctx.stroke(CGRect(x: 0, y: g.y(db), width: g.size.width, height: 0), width: 1)
        }
        // The GPU picture.
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let metalImage = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                               space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                               decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: g.size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(metalImage, in: CGRect(origin: .zero, size: g.size))
        ctx.restoreGState()
        // AppKit overlays (parameter display, axis label).
        for sub in view.subviews where !(sub is PeqGraphMetalView) && !sub.isHidden {
            guard let rep = sub.bitmapImageRepForCachingDisplay(in: sub.bounds) else { continue }
            sub.cacheDisplay(in: sub.bounds, to: rep)
            guard let image = rep.cgImage else { continue }
            ctx.saveGState()
            ctx.setAlpha(sub.alphaValue)
            ctx.translateBy(x: sub.frame.minX, y: sub.frame.maxY)
            ctx.scaleBy(x: 1, y: -1)
            let path = CGPath(roundedRect: CGRect(origin: .zero, size: sub.frame.size), cornerWidth: 9, cornerHeight: 9, transform: nil)
            if sub is PeqBandHUD {
                ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: CGColor(gray: 0, alpha: 0.45))
                ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 0.94))
                ctx.addPath(path); ctx.fillPath()
                ctx.setShadow(offset: .zero, blur: 0)
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.11))
                ctx.addPath(path); ctx.strokePath()
            }
            ctx.draw(image, in: CGRect(origin: .zero, size: sub.frame.size))
            ctx.restoreGState()
        }
        let out = try XCTUnwrap(ctx.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, out, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
