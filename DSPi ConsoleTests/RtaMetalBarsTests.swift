import XCTest
import Metal
import AppKit
@testable import DSPi_Console

final class RtaMetalBarsTests: XCTestCase {
    @MainActor
    func testDetachedViewDoesNotRunAFrameLoop() {
        let view = RtaMetalBarView()
        view.update(panels: [], active: true)
        XCTAssertTrue(view.isPaused)
        XCTAssertEqual(view.preferredFramesPerSecond, 60)
        view.stop()
        XCTAssertNil(view.delegate)
    }

    func testOlderTimestampCannotAdvanceTheNextFrameTwice() {
        let start = Date(timeIntervalSince1970: 0)
        let actual = RtaBarSmoother(), reference = RtaBarSmoother()
        func step(_ smoother: RtaBarSmoother, _ time: Double) -> [Double] {
            smoother.step(now: start.addingTimeInterval(time), target: time == 0 ? [-60] : [-20],
                          identity: 1, riseTau: 0.08, fallTau: 0.2)
        }
        for smoother in [actual, reference] { _ = step(smoother, 0); _ = step(smoother, 0.02) }
        _ = step(actual, 0.01)
        XCTAssertEqual(step(actual, 0.04)[0], step(reference, 0.04)[0], accuracy: 1e-12)
    }

    private func instances(peaks: Bool = true, capacity: Int = 20) -> [RtaBarInstance] {
        let panel = RtaMetalBarPanel(identity: 0, rect: CGRect(x: 10, y: 20, width: 100, height: 60),
            levels: [-120, -60, 0], peaks: [-120, -30, 6], visible: [0, 1, 2],
            color: SIMD4(1, 0, 0, 1), floorDB: -120, ceilingDB: 0,
            fallTau: 0.1, showPeakHold: peaks)
        let memory = UnsafeMutablePointer<RtaBarInstance>.allocate(capacity: max(capacity, 1))
        defer { memory.deallocate() }
        var count = 0
        RtaMetalBarRenderer.writeInstances(panel: panel, levels: panel.levels, peaks: panel.peaks,
                                          into: memory, count: &count, capacity: capacity)
        return Array(UnsafeBufferPointer(start: memory, count: count))
    }

    func testGeometryPreservesDBScaleGradientAndPeakClamp() {
        let bars = instances()
        XCTAssertEqual(bars.count, 4) // silence has neither bar nor peak
        XCTAssertEqual(bars[0].rect.y, 50) // -60 dB is halfway from 20 to 80
        XCTAssertEqual(bars[0].rect.w, 30)
        XCTAssertEqual(bars[0].style.y, 0.95)
        XCTAssertEqual(bars[0].style.z, 0.45)
        XCTAssertEqual(bars[1].rect.y, 34) // -30 dB peak, minus 1-point cap offset
        XCTAssertEqual(bars[1].rect.w, 1.5)
        XCTAssertEqual(bars[2].rect.y, 20)
        XCTAssertEqual(bars[2].rect.w, 60)
        XCTAssertEqual(bars[3].rect.y, 20) // over-range peak clamps to the top
        XCTAssertEqual(bars[0].clip, SIMD4(10, 20, 110, 80))
    }

    func testHiddenPeaksAndBufferCapacity() {
        XCTAssertEqual(instances(peaks: false).count, 2)
        XCTAssertEqual(instances(capacity: 1).count, 1)
        XCTAssertTrue(instances(capacity: 0).isEmpty)
    }

    func testStripPlotsAlignWithGridAcrossRowsAndSingleChannel() {
        XCTAssertEqual(rtaBarStripPlot(index: 0, count: 1, columns: 1, width: 300),
                       CGRect(x: 10, y: 26, width: 280, height: 84))
        XCTAssertEqual(rtaBarStripPlot(index: 2, count: 5, columns: 3, width: 344),
                       CGRect(x: 234, y: 26, width: 100, height: 60))
        XCTAssertEqual(rtaBarStripPlot(index: 3, count: 5, columns: 3, width: 344),
                       CGRect(x: 10, y: 122, width: 100, height: 60))
    }

    func testShaderABIAndPipeline() throws {
        XCTAssertEqual(MemoryLayout<RtaBarInstance>.stride, 64)
        XCTAssertEqual(MemoryLayout<RtaBarInstance>.alignment, 16)
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        XCTAssertNotNil(RtaMetalBarResources.shared, "The RTA shaders must compile and link")
    }

    func testGPUProducesTransparentBackgroundGradientAndRoundedCorners() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let resources = try XCTUnwrap(RtaMetalBarResources.shared)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(resources.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        var instance = RtaBarInstance(rect: SIMD4(10, 10, 30, 40), clip: SIMD4(0, 0, 64, 64),
                                      color: SIMD4(1, 0, 0, 1), style: SIMD4(6, 0.95, 0.45, 0))
        let buffer = try XCTUnwrap(resources.device.makeBuffer(bytes: &instance,
            length: MemoryLayout<RtaBarInstance>.stride, options: .storageModeShared))
        let command = try XCTUnwrap(resources.queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        var size = SIMD2<Float>(64, 64)
        encoder.setRenderPipelineState(resources.pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: 64 * 4,
                             from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
        }
        func alpha(_ x: Int, _ y: Int) -> Int { Int(bytes[(y * 64 + x) * 4 + 3]) }
        XCTAssertEqual(alpha(2, 2), 0)
        XCTAssertEqual(alpha(10, 10), 0) // cut away by the rounded corner
        XCTAssertGreaterThan(alpha(25, 12), 220)
        XCTAssertLessThan(alpha(25, 47), 135)
        XCTAssertGreaterThan(alpha(25, 47), 110)
        // Premultiplied red output: red equals alpha, other channels are zero.
        XCTAssertEqual(bytes[(25 * 64 + 25) * 4 + 2], bytes[(25 * 64 + 25) * 4 + 3])
        XCTAssertEqual(bytes[(25 * 64 + 25) * 4], 0)
    }
}
