import SwiftUI

/// Shared geometry and furniture for the frequency plots.
///
/// Extracted once there were three of these: the target curve, the results
/// comparison, and the measurement progress chart all draw dB against log
/// frequency with the same gridlines and labels, and a third hand-rolled copy
/// was three places for the axis mapping to drift apart.
struct FrequencyPlotScale {
    /// dB at the vertical centre of the plot.
    let centre: Double
    /// dB from the centre to the top edge.
    let halfRange: Double

    /// Fits the scale to what is actually drawn.
    ///
    /// A fixed window clips: a warm target with bass lift, or a room with a
    /// 25 dB null, both cover far more than any sensible default. `minimum`
    /// stops a nearly flat curve having its own rounding blown up into drama.
    init(fitting values: [Double], minimumHalfRange: Double = 6, padding: Double = 1.15) {
        let finite = values.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max(), high >= low else {
            self.centre = 0
            self.halfRange = minimumHalfRange
            return
        }
        self.centre = (low + high) / 2
        self.halfRange = Swift.max(minimumHalfRange, (high - low) / 2 * padding)
    }

    init(centre: Double, halfRange: Double) {
        self.centre = centre
        self.halfRange = Swift.max(0.5, halfRange)
    }

    func y(forDb db: Double, in height: CGFloat) -> CGFloat {
        height / 2 - CGFloat((db - centre) / halfRange) * (height / 2)
    }

    /// Clamped to the plot, so a curve running off the scale draws along the
    /// edge rather than escaping its box.
    func clampedY(forDb db: Double, in height: CGFloat) -> CGFloat {
        Swift.min(Swift.max(y(forDb: db, in: height), 0), height)
    }

    /// Round dB gridlines inside the visible range.
    var gridLines: [Double] {
        let step: Double = halfRange > 15 ? 10 : (halfRange > 8 ? 5 : 2)
        var lines: [Double] = [centre]
        var offset = step
        while offset < halfRange {
            lines.append(centre + offset)
            lines.append(centre - offset)
            offset += step
        }
        return lines.sorted()
    }
}

/// Log frequency, because that is how hearing works and how every other tool in
/// this field draws it - a linear axis puts half the picture above 10 kHz,
/// where almost nothing worth correcting happens.
struct FrequencyAxis {
    let frequencies: [Double]

    static let decades: [Double] = [20, 100, 1000, 10000]
    static let labelled: [Double] = [100, 1000, 10000]

    func x(forHz hz: Double, in width: CGFloat) -> CGFloat {
        guard let low = frequencies.first, let high = frequencies.last, high > low else {
            return 0
        }
        let fraction = (log10(hz) - log10(low)) / (log10(high) - log10(low))
        return width * CGFloat(Swift.min(Swift.max(fraction, 0), 1))
    }

    static func label(for hz: Double) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }
}

/// The background, gridlines and axis labels every plot here shares.
struct FrequencyPlotBackground: View {
    let axis: FrequencyAxis
    let scale: FrequencyPlotScale
    var showsDbLabels = true

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.12))

                ForEach(FrequencyAxis.decades, id: \.self) { hz in
                    let x = axis.x(forHz: hz, in: size.width)
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                }

                ForEach(scale.gridLines, id: \.self) { db in
                    let y = scale.y(forDb: db, in: size.height)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    .stroke(Color.primary.opacity(db == scale.centre ? 0.18 : 0.08),
                            lineWidth: 1)
                }

                ForEach(FrequencyAxis.labelled, id: \.self) { hz in
                    Text(FrequencyAxis.label(for: hz))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .position(x: axis.x(forHz: hz, in: size.width) + 12,
                                  y: size.height - 8)
                }

                if showsDbLabels {
                    ForEach(scale.gridLines, id: \.self) { db in
                        Text(String(format: "%+.0f", db - scale.centre))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .position(x: 18, y: scale.y(forDb: db, in: size.height))
                    }
                }
            }
        }
    }
}

extension FrequencyAxis {
    /// One curve as a path, dropping any run that does not match the axis.
    func path(_ values: [Double], scale: FrequencyPlotScale, in size: CGSize) -> Path {
        Path { path in
            guard values.count == frequencies.count else { return }
            for (index, value) in values.enumerated() where value.isFinite {
                let point = CGPoint(x: x(forHz: frequencies[index], in: size.width),
                                    y: scale.clampedY(forDb: value, in: size.height))
                if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    /// A filled band between two curves, for showing spread.
    func band(lower: [Double], upper: [Double],
              scale: FrequencyPlotScale, in size: CGSize) -> Path {
        Path { path in
            guard lower.count == frequencies.count,
                  upper.count == frequencies.count,
                  !frequencies.isEmpty else { return }

            for (index, value) in upper.enumerated() {
                let point = CGPoint(x: x(forHz: frequencies[index], in: size.width),
                                    y: scale.clampedY(forDb: value, in: size.height))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            for (index, value) in lower.enumerated().reversed() {
                path.addLine(to: CGPoint(x: x(forHz: frequencies[index], in: size.width),
                                         y: scale.clampedY(forDb: value, in: size.height)))
            }
            path.closeSubpath()
        }
    }
}
