import XCTest
import SwiftUI
@testable import DSPi_Console

final class RtaRenderingTests: XCTestCase {
    private var configuration: RtaDisplayConfiguration {
        .init(tap: RTA_TAP_OUTPUT, centres: [10, 20, 50, 100, 200, 500, 1000],
              sampleRateHz: 48000, fftOrder: 10, bassBands: 3,
              firstResolvedBand: 0, levelZero: Double(RTA_LEVEL_ZERO_DBFS))
    }

    func testDisplayFramesIgnoreAgeAndSequenceButKeepDataValidity() {
        let a = RtaBandFrame(channel: 2, seq: 1, nBands: 3, ageMs: 10, avg: [1, 2, 3], peak: [4, 5, 6])
        var b = a
        b.seq = 2
        b.ageMs = 100
        XCTAssertEqual(a.displayFrame, b.displayFrame)
        b.ageMs = 0xFFFF
        XCTAssertNotEqual(a.displayFrame, b.displayFrame)
        b = a
        b.avg[1] += 1
        XCTAssertNotEqual(a.displayFrame, b.displayFrame)
    }

    func testPreparedFrequencySmoothingMatchesExistingAlgorithmAcrossResetAndWrap() {
        var average = RtaBinAverage()
        let start = Date(timeIntervalSince1970: 0)
        for step in 0..<8 {
            if step == 4 { average.reset() }
            let frame = RtaBinFrame(channel: UInt8(step / 3), seq: UInt8((253 + step) % 255),
                                    fftOrder: 10, sampleRateHz: 48000,
                                    bins: (0..<512).map { UInt8(($0 * 7 + step * 13) % 200) })
            let levels = average.add(frame, tap: step < 6 ? RTA_TAP_OUTPUT : RTA_TAP_INPUT,
                                     at: start.addingTimeInterval(Double(step) * 0.06), avgMs: 300,
                                     levelDB: configuration.levelDB)
            XCTAssertEqual(average.smoothedLevels, rtaSmoothBins(levels, octaves: rtaBinSmoothingOctaves))
        }
    }

    func testProjectionRetainsNarrowPeakAndInterpolatesEmptyColumns() {
        let cache = RtaRenderCache()
        // Bin spacing is 1 Hz. On this log axis bins 1, 2 and 4 land at 0, 50, 100.
        let geometry = RtaRenderCache.BinGeometry(count: 8, sampleRateHz: 16,
                                                minFreq: 1, maxFreq: 4, width: 100)
        var levels = [Double](repeating: -100, count: 8)
        levels[1] = -60
        levels[2] = -20
        let result = cache.projectBins(levels, geometry: geometry)
        XCTAssertEqual(result.firstColumn, 0)
        XCTAssertEqual(result.levels[0], -60)
        XCTAssertEqual(result.levels[25], -40, accuracy: 1e-9)
        XCTAssertEqual(result.levels[50], -20)
        XCTAssertEqual(result, cache.projectBins(levels, geometry: geometry))
        levels[2] = -10
        XCTAssertEqual(cache.projectBins(levels, geometry: geometry).levels[50], -10)

        let narrow = RtaRenderCache.BinGeometry(count: 8, sampleRateHz: 16,
                                               minFreq: 1, maxFreq: 4, width: 2)
        XCTAssertEqual(cache.projectBins(levels, geometry: narrow).levels, [-60, -10])
    }

    func testProjectionInvalidatesForRateRangeAndSizeWithUnchangedLevels() {
        let cache = RtaRenderCache()
        let levels = (0..<512).map { Double($0 % 37) - 80 }
        for count in [512, 128] {
            for rate: UInt32 in [48000, 96000] {
                for width: CGFloat in [52, 760, 1000.5] {
                    for lo in [10.0, 1000.0] {
                        let geometry = RtaRenderCache.BinGeometry(count: count, sampleRateHz: rate,
                            minFreq: lo, maxFreq: 20000, width: width)
                        let actual = cache.projectBins(levels, geometry: geometry)
                        // A fresh surface must agree with the reused surface after every change.
                        XCTAssertEqual(actual, RtaRenderCache().projectBins(levels, geometry: geometry))
                    }
                }
            }
        }
    }

    func testBandGeometryInvalidatesForConfigurationAndResize() {
        let cache = RtaRenderCache()
        var config = configuration
        XCTAssertEqual(cache.visibleBands(configuration: config, count: 10).prefix(3), [0, 1, 2])
        config.firstResolvedBand = 5
        XCTAssertTrue(cache.visibleBands(configuration: config, count: 10).allSatisfy { $0 >= 5 })
        config.sampleRateHz = 96000
        config.fftOrder = 8
        XCTAssertEqual(cache.visibleBands(configuration: config, count: 20),
                       RtaRenderCache().visibleBands(configuration: config, count: 20))
        let a = cache.bandPositions(centres: [10, 100, 1000], minFreq: 10, maxFreq: 1000, width: 100)
        XCTAssertEqual(a, [0, 50, 100])
        XCTAssertEqual(cache.bandPositions(centres: [10, 100, 1000], minFreq: 10, maxFreq: 1000, width: 200),
                       [0, 100, 200])
    }

    func testCachedBandSamplingPreservesLineAndUpdatesHeightsAndClipping() {
        let cache = RtaRenderCache()
        let plot = CGRect(x: 10, y: 0, width: 100, height: 100)
        let points = [CGPoint(x: 10, y: 20), CGPoint(x: 60, y: 50), CGPoint(x: 110, y: 80)]
        for shift: CGFloat in [0, 10, 70] {
            let moved = points.map { CGPoint(x: $0.x, y: $0.y + shift) }
            let samples = cache.sampleBands(moved, plot: plot, columns: 100)
            for c in 0..<100 {
                XCTAssertEqual(samples[c]!, min(100, 20 + CGFloat(c) * 0.6 + shift), accuracy: 1e-9)
            }
        }
        XCTAssertTrue(cache.sampleBands([], plot: plot, columns: 100).allSatisfy { $0 == nil })
        XCTAssertNotNil(cache.sampleBands(points, plot: plot, columns: 100)[50])
    }

    func testSixtyFPSPreservesSmoothingTimeConstant() {
        XCTAssertEqual(rtaFrameInterval, 1.0 / 60.0)
        let start = Date(timeIntervalSince1970: 0)
        func interpolate(fps: Int, target: Double) -> Double {
            let smoother = RtaBarSmoother()
            _ = smoother.step(now: start, target: [-40], identity: 0, riseTau: 0.08, fallTau: 0.2)
            var value = [-40.0]
            for frame in 1...fps {
                value = smoother.step(now: start.addingTimeInterval(Double(frame) / Double(fps)),
                                      target: [target], identity: 0, riseTau: 0.08, fallTau: 0.2)
            }
            return value[0]
        }
        for target in [-10.0, -80.0] {
            XCTAssertEqual(interpolate(fps: 30, target: target), interpolate(fps: 60, target: target), accuracy: 1e-9)
        }
    }
}
