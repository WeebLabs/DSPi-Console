import SwiftUI

/// Only the engine properties that affect the picture. Renderers capture this
/// value instead of observing telemetry or reading a live engine inside Canvas.
struct RtaDisplayConfiguration: Equatable {
    var tap: UInt8
    var centres: [Double]
    var sampleRateHz: UInt32
    var fftOrder: Int
    var bassBands: Int
    var firstResolvedBand: Int
    var levelZero: Double

    func levelDB(_ value: UInt8) -> Double {
        (Double(value) - levelZero) * RTA_LEVEL_STEP_DB
    }
}

extension RtaDisplayConfiguration {
    init(engine: RtaEngine) {
        tap = engine.snapshot.tap
        centres = engine.bandCentresHz
        sampleRateHz = engine.snapshot.status.sampleRateHz
        fftOrder = Int(engine.options.fftOrder)
        bassBands = Int(engine.caps.bassBands)
        firstResolvedBand = engine.snapshot.status.firstResolvedBand
        levelZero = engine.caps.levelZero == 0
            ? Double(RTA_LEVEL_ZERO_DBFS) : Double(engine.caps.levelZero)
    }

}

extension RtaBandFrame {
    /// Sequence and age changes carry telemetry, but do not change the drawing.
    /// Retain the never-published sentinel, which does affect its visibility.
    var displayFrame: RtaBandFrame {
        var copy = self
        copy.seq = 0
        copy.ageMs = hasData ? 0 : 0xFFFF
        return copy
    }
}

extension RtaBinFrame {
    var displayFrame: RtaBinFrame {
        var copy = self
        copy.seq = 0
        return copy
    }
}

/// One bounded cache per drawing surface. All geometry is in logical screen
/// points, matching the existing renderer's column resolution.
final class RtaRenderCache {
    private struct BandKey: Equatable {
        let configuration: RtaDisplayConfiguration
        let count: Int
    }
    private var bandKey: BandKey?
    private var bands: [Int] = []

    func visibleBands(configuration: RtaDisplayConfiguration, count: Int) -> [Int] {
        let key = BandKey(configuration: configuration, count: count)
        if key == bandKey { return bands }
        let rate = configuration.sampleRateHz > 0 ? Double(configuration.sampleRateHz) : 48000
        bands = (0..<count).filter {
            $0 >= configuration.firstResolvedBand && rtaBandIsPopulated(
                band: $0, sampleRateHz: rate, fftOrder: configuration.fftOrder,
                bassBands: configuration.bassBands)
        }
        bandKey = key
        return bands
    }

    private struct AxisKey: Equatable {
        let centres: [Double]
        let minFreq: Double
        let maxFreq: Double
        let width: CGFloat
    }
    private var axisKey: AxisKey?
    private var bandX: [CGFloat] = []

    func bandPositions(centres: [Double], minFreq: Double, maxFreq: Double,
                       width: CGFloat) -> [CGFloat] {
        let key = AxisKey(centres: centres, minFreq: minFreq, maxFreq: maxFreq, width: width)
        if key == axisKey { return bandX }
        guard minFreq > 0, maxFreq > minFreq else {
            axisKey = key
            bandX = Array(repeating: 0, count: centres.count)
            return bandX
        }
        let lo = log10(minFreq), span = log10(maxFreq) - lo
        bandX = centres.map { CGFloat((log10(max($0, 1)) - lo) / span) * width }
        axisKey = key
        return bandX
    }

    struct BinGeometry: Equatable {
        let count: Int
        let sampleRateHz: UInt32
        let minFreq: Double
        let maxFreq: Double
        let width: CGFloat
    }
    struct BinProjection: Equatable {
        var firstColumn: Int = 0
        var levels: [Double] = []
    }
    private var binGeometry: BinGeometry?
    private var binColumns: [(bin: Int, column: Int)] = []
    private var sourceLevels: [Double]?
    private var projection = BinProjection()

    /// Maximum in each occupied column, then linear interpolation across gaps.
    /// Geometry is rebuilt only for a resize or a frequency/FFT change; levels
    /// only for new data. Temporal interpolation remains a display-frame job.
    func projectBins(_ levels: [Double], geometry: BinGeometry) -> BinProjection {
        let columns = max(Int(geometry.width.rounded()), 2)
        if geometry != binGeometry {
            binGeometry = geometry
            sourceLevels = nil
            binColumns.removeAll(keepingCapacity: true)
            if geometry.count > 1, geometry.minFreq > 0,
               geometry.maxFreq > geometry.minFreq {
                let lo = log10(geometry.minFreq)
                let span = log10(geometry.maxFreq) - lo
                for k in 1..<geometry.count {
                    let hz = Double(k) * Double(geometry.sampleRateHz) / Double(2 * geometry.count)
                    guard hz >= geometry.minFreq, hz <= geometry.maxFreq else { continue }
                    let x = CGFloat((log10(max(hz, 1)) - lo) / span) * geometry.width
                    let c = min(max(Int(x.rounded()), 0), columns - 1)
                    binColumns.append((k, c))
                }
            }
        }
        if levels == sourceLevels { return projection }
        sourceLevels = levels
        var target = [Double](repeating: -.infinity, count: columns)
        for (k, c) in binColumns where k < levels.count {
            target[c] = max(target[c], levels[k])
        }
        guard let first = target.firstIndex(where: { $0.isFinite }),
              let last = target.lastIndex(where: { $0.isFinite }), last > first else {
            projection = BinProjection()
            return projection
        }
        var previous = first
        for c in (first + 1)...last where target[c].isFinite {
            let gap = c - previous
            if gap > 1 {
                let a = target[previous], b = target[c]
                for g in 1..<gap { target[previous + g] = a + (b - a) * Double(g) / Double(gap) }
            }
            previous = c
        }
        projection = BinProjection(firstColumn: first, levels: Array(target[first...last]))
        return projection
    }

    private struct SamplingKey: Equatable {
        let positions: [CGFloat]
        let origin: CGFloat
        let columns: Int
    }
    private struct Sample {
        let column: Int, segment: Int
        let a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat
    }
    private var samplingKey: SamplingKey?
    private var samples: [Sample] = []

    /// Cache the Hermite basis for the band curve: x positions do not animate.
    func sampleBands(_ points: [CGPoint], plot: CGRect, columns: Int) -> [CGFloat?] {
        let key = SamplingKey(positions: points.map(\.x), origin: plot.minX, columns: columns)
        if key != samplingKey {
            samplingKey = key
            samples.removeAll(keepingCapacity: true)
            if points.count > 1 {
                var seg = 0
                for column in 0..<columns {
                    let x = plot.minX + CGFloat(column)
                    guard x >= points[0].x, x <= points[points.count - 1].x else { continue }
                    while seg < points.count - 2, x > points[seg + 1].x { seg += 1 }
                    let h = points[seg + 1].x - points[seg].x
                    guard h > 0 else {
                        samples.append(Sample(column: column, segment: seg, a: 1, b: 0, c: 0, d: 0))
                        continue
                    }
                    let t = (x - points[seg].x) / h, t2 = t * t, t3 = t2 * t
                    samples.append(Sample(column: column, segment: seg,
                                          a: 2 * t3 - 3 * t2 + 1, b: (t3 - 2 * t2 + t) * h,
                                          c: -2 * t3 + 3 * t2, d: (t3 - t2) * h))
                }
            }
        }
        let slopes: [CGFloat] = points.indices.map { i in
            let a = points[max(i - 1, 0)], b = points[min(i + 1, points.count - 1)]
            return b.x > a.x ? (b.y - a.y) / (b.x - a.x) : 0
        }
        var out = [CGFloat?](repeating: nil, count: columns)
        for s in samples {
            let i = s.segment
            let y = s.a * points[i].y + s.b * slopes[i]
                + s.c * points[i + 1].y + s.d * slopes[i + 1]
            out[s.column] = min(max(y, plot.minY), plot.maxY)
        }
        return out
    }
}
