import XCTest
import AppKit
@testable import DSPi_Console

final class TubeRenderingTests: XCTestCase {
    private func image(in layer: CALayer) throws -> CGImage {
        let contents = try XCTUnwrap(layer.contents)
        return try XCTUnwrap(CFGetTypeID(contents as CFTypeRef) == CGImage.typeID
            ? (contents as! CGImage) : nil)
    }

    func testPulseUsesSelectedOutputsOnBothPlatforms() {
        for start in [2, 8] {
            var peaks = Array(repeating: Float(1), count: start + 9)
            peaks[start] = 0.25
            peaks[start + 8] = 0.0625
            XCTAssertEqual(TubeAudioPulse.opacity(peaks: peaks, outputStart: start,
                outputCount: 9, outputMask: 1), 128.0 / 255)
            XCTAssertEqual(TubeAudioPulse.opacity(peaks: peaks, outputStart: start,
                outputCount: 9, outputMask: 0x100), 64.0 / 255)
            XCTAssertEqual(TubeAudioPulse.opacity(peaks: peaks, outputStart: start,
                outputCount: 5, outputMask: 0x100), 0)
            XCTAssertEqual(TubeAudioPulse.opacity(peaks: peaks, outputStart: start,
                outputCount: 9, outputMask: 0), 0)
        }
    }

    func testPulseHandlesSilenceShortPacketsAndInvalidPeaks() {
        for peaks: [Float] in [[], [0, 0], [-1, .nan, .infinity]] {
            XCTAssertEqual(TubeAudioPulse.opacity(peaks: peaks, outputStart: 0,
                outputCount: 9, outputMask: 0xFFFF), 0)
        }
        XCTAssertEqual(TubeAudioPulse.opacity(peaks: [2], outputStart: 0,
            outputCount: 9, outputMask: 1), 1)
    }

    @MainActor
    func testEveryFamilyRendersAndReusesItsArtwork() throws {
        let meters = DSPMeterModel()
        let view = TubeIllustrationNSView(frame: NSRect(x: 0, y: 0, width: 168, height: 280))
        for type in [1, 9, 11, 6, 10, 12, 14, 13, 15, 16] {
            view.configure(family: .of(type), lit: true, meters: meters,
                           outputStart: 2, outputCount: 5, outputMask: 3, active: false)
            view.layout()
            let layers = try XCTUnwrap(view.layer?.sublayers)
            XCTAssertEqual(layers.count, 3)
            for layer in layers {
                let image = try image(in: layer)
                XCTAssertEqual(image.width, 336)
                XCTAssertEqual(image.height, 560)
                var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                let hasInk = pixels.withUnsafeMutableBytes { bytes -> Bool in
                    guard let ctx = CGContext(data: bytes.baseAddress, width: image.width,
                        height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 }
                }
                XCTAssertTrue(hasInk, "Tube type \(type) produced a blank layer")
                view.layout()
                XCTAssertTrue(image === (layer.contents as AnyObject?), "Unchanged layout rerasterized artwork")
            }
        }
    }

    @MainActor
    func testAudioChangesOnlyOpacityAndStopsWhileHidden() throws {
        let meters = DSPMeterModel()
        let view = TubeIllustrationNSView(frame: NSRect(x: 0, y: 0, width: 168, height: 280))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        func configure(active: Bool = true, lit: Bool = true, mask: UInt16 = 3) {
            view.configure(family: .novalTriode, lit: lit, meters: meters,
                           outputStart: 2, outputCount: 5, outputMask: mask, active: active)
        }
        func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        window.makeKeyAndOrderFront(nil)
        spin()
        configure()
        view.layout()
        let layers = try XCTUnwrap(view.layer?.sublayers)
        let images = try layers.map { try image(in: $0) }
        let bloom = layers[2]
        var status = meters.status
        status.peaks[2] = 0.25
        meters.status = status
        XCTAssertEqual(bloom.opacity, 128.0 / 255)
        spin()
        // Isolate the next event from compositor completion timing.
        bloom.removeAllAnimations()
        status.cpu0 = 50
        meters.status = status
        XCTAssertNil(bloom.animation(forKey: "opacity"), "An unchanged level restarted the animation")
        for (layer, image) in zip(layers, images) {
            XCTAssertTrue(image === (layer.contents as AnyObject?), "Audio rerasterized artwork")
        }
        for _ in 0..<2 {
            window.orderOut(nil)
            spin()
            status.peaks[2] = 1
            meters.status = status
            XCTAssertEqual(bloom.opacity, 0)
            XCTAssertNil(bloom.animation(forKey: "opacity"))
            window.makeKeyAndOrderFront(nil)
            spin()
            XCTAssertEqual(bloom.opacity, 1, "Reopen did not restore the current level")
        }
        configure(active: false)
        XCTAssertEqual(bloom.opacity, 0)
        configure(lit: false)
        XCTAssertEqual(bloom.opacity, 0)
        configure(mask: 0)
        XCTAssertEqual(bloom.opacity, 0)
        configure(mask: 2)
        XCTAssertEqual(bloom.opacity, 0, "Deselected output leaked into the pulse")
        configure()
        XCTAssertEqual(bloom.opacity, 1)
        view.stopFollowingAudio()
        status.peaks[2] = 0.5
        meters.status = status
        XCTAssertEqual(bloom.opacity, 0)
    }
}
