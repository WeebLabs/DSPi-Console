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
    /// Bands in the device's latest frames; 0 until one arrives.
    var bandCount: Int = 0

    func levelDB(_ value: UInt8) -> Double {
        (Double(value) - levelZero) * RTA_LEVEL_STEP_DB
    }

    /// Band slots a bar display lays out: the device's count once it has
    /// reported one, the centre table's before that.
    var barCount: Int {
        bandCount > 0 ? min(bandCount, RTA_MAX_BANDS) : max(centres.count, 34)
    }
}

extension RtaDisplayConfiguration {
    init(engine: RtaEngine) {
        let display = engine.display
        tap = display.tap
        centres = engine.bandCentresHz
        sampleRateHz = display.sampleRateHz
        fftOrder = Int(engine.options.fftOrder)
        bassBands = Int(engine.caps.bassBands)
        firstResolvedBand = display.firstResolvedBand
        levelZero = engine.caps.levelZero == 0
            ? Double(RTA_LEVEL_ZERO_DBFS) : Double(engine.caps.levelZero)
        bandCount = display.bandCount
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

    private var columnKey: SamplingKey?
    /// Flat rows of six: column x, segment, and the four Hermite weights.
    private var columnBasis: [Float] = []

    /// The band curve as one point per whole column inside the plot, from the
    /// same Hermite interpolation as `sampleBands`.  The Metal renderer draws
    /// it as the line and reuses it as the fill table.
    ///
    /// Band positions do not move between frames, so the basis is rebuilt only
    /// for a new axis or width and a frame just weighs the new heights.  That
    /// loop runs on raw Float storage because it runs for every curve on every
    /// frame, and unoptimised builds do not specialise the generic accessors.
    func columnSeries(_ points: [CGPoint], plot: CGRect) -> [SIMD2<Float>] {
        let n = points.count
        guard n > 1 else { return [] }
        let columns = max(Int(plot.width.rounded()), 2)
        let key = SamplingKey(positions: points.map(\.x), origin: plot.minX, columns: columns)
        if key != columnKey {
            columnKey = key
            columnBasis.removeAll(keepingCapacity: true)
            var seg = 0
            for column in 0..<columns {
                let x = plot.minX + CGFloat(column)
                guard x >= points[0].x, x <= points[n - 1].x else { continue }
                while seg < n - 2, x > points[seg + 1].x { seg += 1 }
                let h = points[seg + 1].x - points[seg].x
                var weights: (CGFloat, CGFloat, CGFloat, CGFloat) = (1, 0, 0, 0)
                if h > 0 {
                    let t = (x - points[seg].x) / h, t2 = t * t, t3 = t2 * t
                    weights = (2 * t3 - 3 * t2 + 1, (t3 - 2 * t2 + t) * h,
                               -2 * t3 + 3 * t2, (t3 - t2) * h)
                }
                columnBasis.append(contentsOf: [Float(x), Float(seg), Float(weights.0),
                                                Float(weights.1), Float(weights.2), Float(weights.3)])
            }
        }
        let rows = columnBasis.count / 6
        guard rows > 0 else { return [] }

        var heights = [Float](repeating: 0, count: n)
        var slopes = [Float](repeating: 0, count: n)
        for i in 0..<n {
            heights[i] = Float(points[i].y)
            let a = points[max(i - 1, 0)], b = points[min(i + 1, n - 1)]
            slopes[i] = b.x > a.x ? Float((b.y - a.y) / (b.x - a.x)) : 0
        }
        let top = Float(plot.minY), bottom = Float(plot.maxY)

        return [SIMD2<Float>](unsafeUninitializedCapacity: rows) { buffer, initialized in
            // SIMD2<Float> is two Floats: x at 2r, y at 2r + 1.
            let out = UnsafeMutableRawPointer(buffer.baseAddress!).assumingMemoryBound(to: Float.self)
            columnBasis.withUnsafeBufferPointer { basis in
                heights.withUnsafeBufferPointer { y in
                    slopes.withUnsafeBufferPointer { m in
                        var r = 0
                        while r < rows {
                            let o = 6 * r
                            let i = Int(basis[o + 1])
                            var v = basis[o + 2] * y[i] + basis[o + 3] * m[i]
                                + basis[o + 4] * y[i + 1] + basis[o + 5] * m[i + 1]
                            v = top >= v ? top : v
                            v = bottom < v ? bottom : v
                            out[2 * r] = basis[o]
                            out[2 * r + 1] = v
                            r += 1
                        }
                    }
                }
            }
            initialized = rows
        }
    }
}
