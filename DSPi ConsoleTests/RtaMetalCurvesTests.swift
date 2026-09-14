import XCTest
import SwiftUI
import MetalKit
@testable import DSPi_Console

final class RtaMetalCurvesTests: XCTestCase {
    private func panel(glow: Bool = false, minFreq: Double = 10, tap: UInt8 = RTA_TAP_OUTPUT,
                       fallTau: TimeInterval = 0) -> RtaMetalCurvePanel {
        let config = RtaDisplayConfiguration(tap: RTA_TAP_OUTPUT, centres: [10, 100, 1000],
            sampleRateHz: 48000, fftOrder: 10, bassBands: 3, firstResolvedBand: 0, levelZero: 243)
        let bands = RtaBandFrame(channel: 0, nBands: 3, ageMs: 0,
                                 avg: [143, 143, 143], peak: [163, 163, 163])
        return RtaMetalCurvePanel(tap: tap, configuration: config,
            channels: [RtaMetalCurveChannel(channel: 0, color: SIMD4(1, 0, 0, 1), bands: bands, bins: nil)],
            minFreq: minFreq, maxFreq: 1000, scale: RtaScale(floorDB: -100, ceilingDB: 0),
            fallTau: fallTau, showPeak: true, glow: glow, opacity: 1)
    }

    @MainActor
    func testDetachedAndInactiveViewDoesNotAnimate() {
        let view = RtaMetalCurveView()
        view.update(panel: panel(), active: true)
        XCTAssertTrue(view.isPaused)
        XCTAssertEqual(view.preferredFramesPerSecond, 60)
        view.update(panel: panel(), active: false)
        XCTAssertTrue(view.isPaused)
        view.stop()
        XCTAssertNil(view.delegate)
    }

    func testShaderABIAndPipeline() throws {
        XCTAssertEqual(MemoryLayout<RtaCurveUniforms>.stride, 64)
        XCTAssertEqual(MemoryLayout<RtaCurveUniforms>.alignment, 16)
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        XCTAssertNotNil(RtaMetalCurveResources.shared, "Curve shaders must compile and link")
    }

    private final class CountingDelegate: NSObject, MTKViewDelegate {
        let forward: MTKViewDelegate?
        var draws = 0
        init(_ forward: MTKViewDelegate?) { self.forward = forward }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            forward?.mtkView(view, drawableSizeWillChange: size)
        }
        func draw(in view: MTKView) { draws += 1; forward?.draw(in: view) }
    }

    @MainActor
    func testDrawLoopPausesAndResumesWithoutNewMeasurements() throws {
        guard RtaMetalCurveResources.shared != nil else { throw XCTSkip("No Metal device") }
        let view = RtaMetalCurveView()
        let counter = CountingDelegate(view.delegate)
        view.delegate = counter
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { view.stop(); window.orderOut(nil) }
        func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        let animated = panel(fallTau: 0.1)
        view.update(panel: animated, active: true)
        window.makeKeyAndOrderFront(nil)
        spin(0.4)
        XCTAssertGreaterThan(counter.draws, 0)
        view.update(panel: animated, active: false)
        spin(0.1)
        let paused = counter.draws
        spin(0.2)
        XCTAssertEqual(counter.draws, paused)
        view.update(panel: animated, active: true)
        spin(0.3)
        XCTAssertGreaterThan(counter.draws, paused)
        window.orderOut(nil)
        spin(0.1)
        let hidden = counter.draws
        spin(0.2)
        XCTAssertEqual(counter.draws, hidden)
        window.makeKeyAndOrderFront(nil)
        spin(0.3)
        XCTAssertGreaterThan(counter.draws, hidden)
        view.update(panel: panel(), active: true)
        spin(0.2)
        let stationary = counter.draws
        spin(0.2)
        XCTAssertTrue(view.isPaused)
        XCTAssertEqual(counter.draws, stationary, "Smoothing off should redraw only on changes")
    }

    func testFlatteningKeepsFFTPointsAndClampsBandCurve() {
        let plot = CGRect(x: 0, y: 0, width: 100, height: 100)
        let points = [CGPoint(x: 0, y: 100), CGPoint(x: 40, y: 0), CGPoint(x: 100, y: 100)]
        XCTAssertEqual(RtaCurveGeometry.flatten(points, dense: true, plot: plot, backingScale: 2),
                       points.map { SIMD2(Float($0.x), Float($0.y)) })
        let curve = RtaCurveGeometry.flatten(points, dense: false, plot: plot, backingScale: 2)
        XCTAssertEqual(curve.first, SIMD2(0, 100))
        XCTAssertEqual(curve.last, SIMD2(100, 100))
        XCTAssertTrue(curve.contains(SIMD2(40, 0)))
        XCTAssertGreaterThan(curve.count, 3)
        XCTAssertTrue(curve.allSatisfy { $0.y >= 0 && $0.y <= 100 })
        XCTAssertTrue(zip(curve, curve.dropFirst()).allSatisfy { $0.x <= $1.x })
        XCTAssertEqual(RtaCurveGeometry.flatten([], dense: false, plot: plot, backingScale: 2), [])
    }

    func testFillTableUsesPhysicalPixelsAndPreservesPeakAndClipping() {
        let points: [SIMD2<Float>] = [SIMD2(-10, 60), SIMD2(50, 0), SIMD2(110, 60)]
        let samples = RtaCurveGeometry.fillSamples(points, width: 100, backingScale: 2)
        XCTAssertEqual(samples.count, 201)
        XCTAssertEqual(samples.first, SIMD2(0, 50))
        XCTAssertEqual(samples[100], SIMD2(50, 0))
        XCTAssertEqual(samples.last, SIMD2(100, 50))
        XCTAssertEqual(samples[50].y, 25, accuracy: 1e-5)
        XCTAssertTrue(RtaCurveGeometry.fillSamples([], width: 100, backingScale: 2).isEmpty)
        XCTAssertTrue(RtaCurveGeometry.fillSamples([SIMD2(-10, 10), SIMD2(-1, 20)],
                                                   width: 100, backingScale: 2).isEmpty)
    }

    @MainActor
    private func render(_ panel: RtaMetalCurvePanel, size: Int = 96,
                        renderer: RtaMetalCurveRenderer? = nil) throws -> [UInt8] {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let resources = try XCTUnwrap(RtaMetalCurveResources.shared)
        let renderer = renderer ?? RtaMetalCurveRenderer(resources: resources)
        renderer.update(panel)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let texture = try XCTUnwrap(resources.device.makeTexture(descriptor: d))
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        XCTAssertTrue(renderer.encode(command: command, target: texture, size: CGSize(width: size, height: size),
                                      backingScale: 1, now: Date(timeIntervalSince1970: 0)))
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        return bytes
    }

    @MainActor
    func testGPUFillFadeGlowAndTransparency() throws {
        let plain = try render(panel())
        let glow = try render(panel(glow: true))
        let faded = try render(panel(minFreq: 1))
        func alpha(_ image: [UInt8], _ x: Int, _ y: Int) -> Int { Int(image[(y * 96 + x) * 4 + 3]) }
        XCTAssertEqual(alpha(plain, 50, 10), 0)
        XCTAssertGreaterThan(alpha(plain, 50, 60), alpha(plain, 50, 85))
        XCTAssertLessThanOrEqual(abs(alpha(plain, 50, 72) - 26), 2)
        XCTAssertGreaterThan(alpha(glow, 50, 45), alpha(plain, 50, 45))
        XCTAssertEqual(alpha(faded, 10, 72), 0)
        XCTAssertLessThan(alpha(faded, 35, 72), alpha(faded, 80, 72))
        let pixel: Int = (72 * 96 + 50) * 4
        XCTAssertEqual(plain[pixel + 2], plain[pixel + 3])
    }

    @MainActor
    func testChangingTapAndRemovingChannelsClearsPreviousImage() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let renderer = RtaMetalCurveRenderer(resources: try XCTUnwrap(RtaMetalCurveResources.shared))
        XCTAssertTrue(try render(panel(), renderer: renderer).contains { $0 != 0 })
        XCTAssertTrue(try render(panel(tap: RTA_TAP_INPUT), renderer: renderer).allSatisfy { $0 == 0 })
        XCTAssertTrue(try render(panel(glow: true), size: 128, renderer: renderer).contains { $0 != 0 })
        let p = panel()
        let empty = RtaMetalCurvePanel(tap: p.tap, configuration: p.configuration, channels: [],
            minFreq: p.minFreq, maxFreq: p.maxFreq, scale: p.scale, fallTau: 0, showPeak: true, glow: true, opacity: 1)
        XCTAssertTrue(try render(empty, renderer: renderer).allSatisfy { $0 == 0 })
    }
}
