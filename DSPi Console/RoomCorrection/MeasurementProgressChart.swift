import Foundation
import SwiftUI

/// What one speaker's measurements look like so far.
///
/// Per speaker, not per position: a speaker's positions only average with that
/// same speaker's, since averaging across transducers in different places says
/// nothing about either of them.
struct SpeakerAccumulation: Identifiable, Equatable {
    let speakerIndex: Int
    /// Every usable position for this speaker, smoothed for display.
    let positions: [[Double]]
    /// Power-domain spatial average, nil until there are at least two.
    let average: [Double]?
    /// Median absolute deviation across positions, nil below three.
    let spread: [Double]?

    var id: Int { speakerIndex }
    var positionCount: Int { positions.count }

    /// Below two an average is the single measurement relabelled; below three
    /// the spread is just the gap between two traces that are already drawn.
    static let averageFromPositions = 2
    static let spreadFromPositions = 3

    var statusLine: String {
        switch positionCount {
        case 0: return "No usable measurement yet."
        case 1: return "One position. The average appears from the second."
        case 2: return "Two positions, averaged. The spread between them appears "
                     + "from the third."
        default:
            return "\(positionCount) positions, averaged. The shaded band is how much "
                 + "they disagree - it narrowing is the average settling."
        }
    }
}

/// Builds the per-speaker view of a session's measurements.
///
/// Pure over a snapshot of positions, so the accumulation rules - which
/// measurements count, when an average starts to mean anything - can be tested
/// without a session, a device or a room.
enum MeasurementProgress {

    /// One entry per speaker that has at least one usable measurement.
    ///
    /// Speakers with nothing usable are omitted rather than shown empty: an
    /// axis with no data invites the reading that the speaker measured flat.
    static func accumulate(positions: [MeasurementSession.Position],
                           speakers: [Int],
                           grid: RoomCorrectionCore.Grid,
                           smoothing: RoomCorrectionCore.Smoothing = .variable,
                           transitionHz: Double = 200) -> [SpeakerAccumulation] {
        speakers.sorted().compactMap { speaker in
            // Only enabled positions, and only measurements the analysis could
            // use. A failed sweep contributes nothing, so counting it would
            // tell the user they are further along than they are.
            let curves = positions
                .filter(\.enabled)
                .compactMap { position -> [Double]? in
                    guard let measurement = position.measurements
                        .first(where: { $0.speakerIndex == speaker }),
                          measurement.verdict.isUsable,
                          measurement.magnitudesDb.count == grid.pointCount
                    else { return nil }
                    return measurement.magnitudesDb
                }
            guard !curves.isEmpty else { return nil }

            // Statistics come from the unsmoothed measurements, exactly as the
            // fit will see them; smoothing is applied to what is drawn.
            let statistics = try? RoomCorrectionCore.spatialStatistics(positions: curves,
                                                                       grid: grid)
            let smoothedPositions = curves.map { curve in
                (try? RoomCorrectionCore.smooth(curve, grid: grid, using: smoothing,
                                                transitionHz: transitionHz)) ?? curve
            }

            var average: [Double]?
            if curves.count >= SpeakerAccumulation.averageFromPositions,
               let raw = statistics?.average {
                average = (try? RoomCorrectionCore.smooth(raw, grid: grid, using: smoothing,
                                                          transitionHz: transitionHz)) ?? raw
            }

            var spread: [Double]?
            if curves.count >= SpeakerAccumulation.spreadFromPositions,
               let raw = statistics?.spread {
                spread = (try? RoomCorrectionCore.smooth(raw, grid: grid, using: smoothing,
                                                         transitionHz: transitionHz)) ?? raw
            }

            return SpeakerAccumulation(speakerIndex: speaker,
                                       positions: smoothedPositions,
                                       average: average,
                                       spread: spread)
        }
    }
}


// MARK: - Chart

/// One speaker's measurements piling up.
///
/// Always present from the first visit to the step, populated from the first
/// capture: a chart that appears later would reflow the page underneath the
/// user at the exact moment they are reading it.
struct MeasurementProgressPlot: View {
    let accumulation: SpeakerAccumulation?
    let frequencies: [Double]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let axis = FrequencyAxis(frequencies: frequencies)
            let scale = FrequencyPlotScale(fitting: plotted, minimumHalfRange: 9)

            ZStack {
                FrequencyPlotBackground(axis: axis, scale: scale)

                if let accumulation {
                    // The spread band first, so the traces read on top of it.
                    if let average = accumulation.average, let spread = accumulation.spread,
                       average.count == frequencies.count, spread.count == frequencies.count {
                        axis.band(lower: zip(average, spread).map(-),
                                  upper: zip(average, spread).map(+),
                                  scale: scale, in: size)
                            .fill(Color.accentColor.opacity(0.24))
                    }

                    // Individual positions, faint: an outlier should be visible
                    // as a stray trace rather than silently dragging the mean.
                    ForEach(Array(accumulation.positions.enumerated()), id: \.offset) { _, curve in
                        axis.path(curve, scale: scale, in: size)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    }

                    if let average = accumulation.average {
                        axis.path(average, scale: scale, in: size)
                            .stroke(Color.accentColor, lineWidth: 2)
                    } else if let only = accumulation.positions.first {
                        // A single position is drawn solid: calling it an
                        // average would be the same curve under a better name.
                        axis.path(only, scale: scale, in: size)
                            .stroke(Color.secondary, lineWidth: 1.5)
                    }
                }
            }
        }
    }

    /// Everything that will be drawn, for fitting the scale.
    private var plotted: [Double] {
        guard let accumulation else { return [] }
        return accumulation.positions.flatMap { $0 } + (accumulation.average ?? [])
    }
}
