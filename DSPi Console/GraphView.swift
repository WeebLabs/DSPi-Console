import SwiftUI
import Accelerate

// MARK: - Graph Animation Support

struct AnimatableVector: VectorArithmetic {
    var values: [Double]

    static var zero = AnimatableVector(values: [])

    var magnitudeSquared: Double {
        guard !values.isEmpty else { return 0 }
        var result: Double = 0
        vDSP_dotprD(values, 1, values, 1, &result, vDSP_Length(values.count))
        return result
    }

    static func - (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        let lc = lhs.values.count, rc = rhs.values.count
        let count = max(lc, rc)
        guard count > 0 else { return .zero }
        var result = [Double](repeating: 0, count: count)
        if lc == rc {
            vDSP_vsubD(rhs.values, 1, lhs.values, 1, &result, 1, vDSP_Length(count))
        } else {
            for i in 0..<count {
                result[i] = (i < lc ? lhs.values[i] : 0) - (i < rc ? rhs.values[i] : 0)
            }
        }
        return AnimatableVector(values: result)
    }

    static func + (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        let lc = lhs.values.count, rc = rhs.values.count
        let count = max(lc, rc)
        guard count > 0 else { return .zero }
        var result = [Double](repeating: 0, count: count)
        if lc == rc {
            vDSP_vaddD(lhs.values, 1, rhs.values, 1, &result, 1, vDSP_Length(count))
        } else {
            for i in 0..<count {
                result[i] = (i < lc ? lhs.values[i] : 0) + (i < rc ? rhs.values[i] : 0)
            }
        }
        return AnimatableVector(values: result)
    }

    mutating func scale(by rhs: Double) {
        guard !values.isEmpty else { return }
        var scalar = rhs
        vDSP_vsmulD(values, 1, &scalar, &values, 1, vDSP_Length(values.count))
    }
}

struct BodeLineShape: Shape {
    var magnitudes: [Double] // 201 points (log-spaced 10Hz-20kHz)
    var dbTop: Float = 25.0
    var dbBottom: Float = -25.0
    var minFreq: Float = 20.0
    var maxFreq: Float = 20000.0

    var animatableData: AnimatableVector {
        get { AnimatableVector(values: magnitudes) }
        set { magnitudes = newValue.values }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !magnitudes.isEmpty else { return path }

        let width = rect.width
        let height = rect.height
        let dbSpan = dbTop - dbBottom

        // Data frequency range (always 10Hz-20kHz, 201 log-spaced points)
        let dataLogMin = log10(Float(10.0))
        let dataLogMax = log10(Float(20000.0))
        let viewLogMin = log10(minFreq)
        let viewLogMax = log10(maxFreq)
        let viewLogSpan = viewLogMax - viewLogMin

        let count = magnitudes.count
        for i in 0..<count {
            // Frequency of this data point
            let dataLog = dataLogMin + Float(i) / Float(count - 1) * (dataLogMax - dataLogMin)
            // Map to view x position
            let x = CGFloat((dataLog - viewLogMin) / viewLogSpan) * width
            // Map dB to y position
            let db = Float(magnitudes[i])
            let normalized = (db - dbBottom) / dbSpan
            let y = height - CGFloat(normalized) * height

            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        return path
    }
}

// MARK: - Graph View

struct BodePlotView: View {
    @ObservedObject var vm: DSPViewModel
    var isPopOut: Bool = false
    @Binding var visibilityOverride: [Int: Bool]
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var graphWindowController: GraphWindowController
    @State private var isHovered = false

    init(vm: DSPViewModel, isPopOut: Bool = false, visibilityOverride: Binding<[Int: Bool]> = .constant([:])) {
        self.vm = vm
        self.isPopOut = isPopOut
        self._visibilityOverride = visibilityOverride
    }

    var minFreq: Float { Float(settings.graphMinFreq) }
    var maxFreq: Float { Float(settings.graphMaxFreq) }
    var dbTop: Float { Float(settings.graphDBCenter + settings.graphDBRange / 2.0) }
    var dbBottom: Float { Float(settings.graphDBCenter - settings.graphDBRange / 2.0) }

    // Phase axis scales with the vertical (dB) zoom, centered at 0°:
    // ±180° at the default 50 dB range, proportionally tighter/wider otherwise.
    var phaseTop: Float { Float(180.0 * settings.graphDBRange / 50.0) }
    var phaseBottom: Float { -phaseTop }

    // Grid Helper
    func xPos(_ freq: Float, width: CGFloat) -> CGFloat {
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let logVal = log10(freq)
        return CGFloat((logVal - logMin) / (logMax - logMin)) * width
    }

    func yPos(_ db: Float, height: CGFloat) -> CGFloat {
        let normalized = (db - dbBottom) / (dbTop - dbBottom)
        return height - (CGFloat(normalized) * height)
    }

    // Color for a given EQ channel index
    func colorForEQChannel(_ eqCh: Int) -> Color {
        if eqCh < vm.chOut1 {
            return MatrixInput.color(for: eqCh)   // input channel
        } else {
            let outIdx = eqCh - vm.chOut1
            return MatrixOutput.all.indices.contains(outIdx) ? MatrixOutput.all[outIdx].color : .accentColor
        }
    }

    struct ChannelEntry {
        let eqCh: Int
        let color: Color
        let isActive: Bool
    }

    // Whether this instance uses independent visibility
    private var useOverride: Bool {
        isPopOut && !settings.popoutGraphFollowsSelection && !visibilityOverride.isEmpty
    }

    // Group visible channels by identical magnitudes
    func groupedChannels() -> [[Double]: [ChannelEntry]] {
        var groups: [[Double]: [ChannelEntry]] = [:]
        let activeEq = vm.activeEqChannel
        let followsSelection = !isPopOut || settings.popoutGraphFollowsSelection
        for eqCh in 0..<vm.numChannels {
            let visible: Bool
            if useOverride {
                visible = visibilityOverride[eqCh] ?? false
            } else {
                visible = vm.channelVisibility[eqCh] == true
            }
            if visible {
                var mags = vm.cachedMagnitudes[eqCh] ?? Array(repeating: 0.0, count: 201)
                // Apply output gain as constant offset (output channels only)
                if eqCh >= vm.chOut1 {
                    let gain = Double(vm.outputGainDB[eqCh - vm.chOut1])
                    if gain != 0 { mags = mags.map { $0 + gain } }
                }
                let isActive = !followsSelection || activeEq == nil || eqCh == activeEq
                let entry = ChannelEntry(eqCh: eqCh, color: colorForEQChannel(eqCh), isActive: isActive)
                if groups[mags] != nil {
                    groups[mags]!.append(entry)
                } else {
                    groups[mags] = [entry]
                }
            }
        }
        return groups
    }

    var body: some View {
        let groups = groupedChannels()

        ZStack {
            // Static Grid & Labels
            Canvas { context, size in
                let minF = minFreq
                let maxF = maxFreq
                let dTop = dbTop
                let dBot = dbBottom
                let dbSpan = dTop - dBot

                // Frequency gridlines
                if settings.showFrequencyGrid {
                    let majorFreqs: [Float] = [100, 1000, 10000]
                    let minorFreqs: [Float] = [20, 30, 40, 50, 60, 70, 80, 90,
                                               200, 300, 400, 500, 600, 700, 800, 900,
                                               2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000,
                                               20000]
                    let majorPath = Path { path in
                        for f in majorFreqs where f >= minF && f <= maxF {
                            let x = xPos(f, width: size.width)
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: size.height))
                        }
                    }
                    context.stroke(majorPath, with: .color(.white.opacity(0.15)))

                    let minorPath = Path { path in
                        for f in minorFreqs where f >= minF && f <= maxF && !majorFreqs.contains(f) {
                            let x = xPos(f, width: size.width)
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: size.height))
                        }
                    }
                    context.stroke(minorPath, with: .color(.white.opacity(0.06)))
                }

                // dB gridlines
                if settings.showDBGrid {
                    let step: Float = dbSpan <= 12 ? 1 : (dbSpan <= 30 ? 3 : (dbSpan <= 60 ? 5 : 10))
                    let startDB = (dBot / step).rounded(.up) * step
                    let dbPath = Path { path in
                        var db = startDB
                        while db <= dTop {
                            if abs(db) > 0.01 { // skip 0dB, drawn separately
                                let y = yPos(db, height: size.height)
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: size.width, y: y))
                            }
                            db += step
                        }
                    }
                    context.stroke(dbPath, with: .color(.white.opacity(0.1)))

                    // 0dB reference line
                    if dBot <= 0 && dTop >= 0 {
                        let zeroY = yPos(0, height: size.height)
                        var zeroPath = Path()
                        zeroPath.move(to: CGPoint(x: 0, y: zeroY))
                        zeroPath.addLine(to: CGPoint(x: size.width, y: zeroY))
                        context.stroke(zeroPath, with: .color(.white.opacity(0.3)), lineWidth: 1)
                    }
                }

            }

            // Animated Lines - grouped by identical curves
            ForEach(Array(groups.keys), id: \.self) { mags in
                let entries = groups[mags] ?? []
                let lineWidth = settings.graphLineWidth
                let anyActive = entries.contains { $0.isActive }
                let dashPattern: [CGFloat] = anyActive ? [] : [6, 4]
                let style = StrokeStyle(lineWidth: lineWidth, dash: dashPattern)
                if entries.count == 1 {
                    // Single channel
                    ZStack {
                        if settings.showGraphGlow && anyActive {
                            BodeLineShape(magnitudes: mags, dbTop: dbTop, dbBottom: dbBottom, minFreq: minFreq, maxFreq: maxFreq)
                                .stroke(entries[0].color.opacity(0.3), lineWidth: lineWidth * 4)
                                .blur(radius: 6)
                            BodeLineShape(magnitudes: mags, dbTop: dbTop, dbBottom: dbBottom, minFreq: minFreq, maxFreq: maxFreq)
                                .stroke(entries[0].color.opacity(0.6), lineWidth: lineWidth * 2)
                                .blur(radius: 3)
                        }
                        BodeLineShape(magnitudes: mags, dbTop: dbTop, dbBottom: dbBottom, minFreq: minFreq, maxFreq: maxFreq)
                            .stroke(entries[0].color, style: style)
                    }
                    .animation(.spring(response: 0.2, dampingFraction: 0.8), value: mags)
                } else {
                    // Multiple overlapping channels - gradient
                    let colors = entries.map { $0.color }
                    let gradient = LinearGradient(
                        stops: gradientStops(for: colors),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    ZStack {
                        if settings.showGraphGlow && anyActive {
                            BodeLineShape(magnitudes: mags, dbTop: dbTop, dbBottom: dbBottom, minFreq: minFreq, maxFreq: maxFreq)
                                .stroke(gradient, lineWidth: lineWidth * 5)
                                .blur(radius: 8)
                                .opacity(0.07)
                            BodeLineShape(magnitudes: mags, dbTop: dbTop, dbBottom: dbBottom, minFreq: minFreq, maxFreq: maxFreq)
                                .stroke(gradient, lineWidth: lineWidth * 2.5)
                                .blur(radius: 5)
                                .opacity(0.07)
                        }
                        BodeLineShape(magnitudes: mags, dbTop: dbTop, dbBottom: dbBottom, minFreq: minFreq, maxFreq: maxFreq)
                            .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth * 1.25, dash: dashPattern))
                    }
                    .animation(.spring(response: 0.2, dampingFraction: 0.8), value: mags)
                }
            }

            // Phase response of the selected channel - dotted, light-gray,
            // mapped to a -180...+180 degree axis (labeled on the right).
            if settings.showPhase,
               let activeCh = vm.activeEqChannel,
               let phases = (settings.phaseUnwrapped ? vm.cachedPhasesUnwrapped[activeCh] : vm.cachedPhases[activeCh]),
               (useOverride ? (visibilityOverride[activeCh] ?? false) : (vm.channelVisibility[activeCh] == true)) {
                let lw = settings.graphLineWidth
                BodeLineShape(magnitudes: phases, dbTop: phaseTop, dbBottom: phaseBottom, minFreq: minFreq, maxFreq: maxFreq)
                    .stroke(Color(white: 0.93),
                            style: StrokeStyle(lineWidth: lw * 0.9, lineCap: .round, dash: [0.1, lw * 3]))
                    .animation(.spring(response: 0.2, dampingFraction: 0.8), value: phases)
            }
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .clipped()
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .overlay(
            Canvas { context, size in
                let minF = minFreq
                let maxF = maxFreq
                let dTop = dbTop
                let dBot = dbBottom
                let dbSpan = dTop - dBot

                if settings.showFrequencyLabels {
                    let labelFreqs: [(Float, String)] = [
                        (20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"),
                        (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k"), (20000, "20k")
                    ]
                    for (f, label) in labelFreqs where f >= minF && f <= maxF {
                        let x = xPos(f, width: size.width)
                        let text = Text(label).font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.4))
                        context.draw(context.resolve(text), at: CGPoint(x: x, y: size.height - 2), anchor: .bottom)
                    }
                }

                if settings.showDBLabels {
                    let step: Float = dbSpan <= 12 ? 1 : (dbSpan <= 30 ? 3 : (dbSpan <= 60 ? 5 : 10))
                    let startDB = (dBot / step).rounded(.up) * step
                    var db = startDB
                    while db <= dTop {
                        let y = yPos(db, height: size.height)
                        let label = db >= 0 ? String(format: "+%g", db) : String(format: "%g", db)
                        let text = Text(label).font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.4))
                        context.draw(context.resolve(text), at: CGPoint(x: 4, y: y), anchor: .leading)
                        db += step
                    }
                }

                // Phase axis labels (right side), in degrees - scaled with the
                // vertical zoom to match the phase curve's axis.
                if settings.showPhase {
                    let pTop = phaseTop
                    let phaseTicks: [Float] = [pTop, pTop / 2, 0, -pTop / 2, -pTop]
                    for p in phaseTicks {
                        let normalized = (p - phaseBottom) / (phaseTop - phaseBottom)
                        let y = size.height - CGFloat(normalized) * size.height
                        let label = p == 0 ? "0°" : String(format: "%+d°", Int(p.rounded()))
                        let text = Text(label).font(.system(size: 9, weight: .medium)).foregroundColor(Color(white: 0.93).opacity(0.55))
                        context.draw(context.resolve(text), at: CGPoint(x: size.width - 4, y: y), anchor: .trailing)
                    }
                }
            }
            .allowsHitTesting(false)
        )
        .overlay(
            GraphVerticalZoomHandler(settings: settings)
        )
        .overlay(alignment: .topTrailing) {
            if isHovered && !graphWindowController.isVisible {
                Button(action: {
                    graphWindowController.show(vm: vm)
                }) {
                    Image(systemName: "arrow.down.backward.and.arrow.up.forward")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(6)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    // Create smooth gradient stops for overlapping channels
    func gradientStops(for colors: [Color]) -> [Gradient.Stop] {
        guard !colors.isEmpty else { return [] }
        guard colors.count > 1 else {
            return [.init(color: colors[0], location: 0.0),
                    .init(color: colors[0], location: 1.0)]
        }

        var stops: [Gradient.Stop] = []
        let count = colors.count
        let transitionWidth: Double = count == 2 ? 0.4 : (count == 3 ? 0.25 : 0.15)
        let segmentWidth = 1.0 / Double(count)

        for (index, color) in colors.enumerated() {
            let segmentCenter = (Double(index) + 0.5) * segmentWidth
            let solidStart = segmentCenter - (segmentWidth - transitionWidth) / 2
            let solidEnd = segmentCenter + (segmentWidth - transitionWidth) / 2
            let clampedStart = max(0.0, solidStart)
            let clampedEnd = min(1.0, solidEnd)

            if index == 0 {
                stops.append(.init(color: color, location: 0.0))
            }
            stops.append(.init(color: color, location: clampedStart))
            stops.append(.init(color: color, location: clampedEnd))
            if index == count - 1 {
                stops.append(.init(color: color, location: 1.0))
            }
        }

        return stops.sorted { $0.location < $1.location }
    }
}

// MARK: - Graph Resize Handle

struct GraphResizeHandle: View {
    var body: some View {
        GraphResizeHandleRepresentable()
            .frame(height: 20)
            .padding(.horizontal)
    }
}

struct GraphResizeHandleRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> GraphResizeNSView {
        GraphResizeNSView()
    }

    func updateNSView(_ nsView: GraphResizeNSView, context: Context) {}
}

class GraphResizeNSView: NSView {
    private var dragStartHeight: Double = 0
    private var dragStartY: CGFloat = 0
    private var isDragging = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragStartY = NSEvent.mouseLocation.y
        dragStartHeight = AppSettings.shared.graphHeight
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let currentY = NSEvent.mouseLocation.y
        let delta = Double(currentY - dragStartY)
        let newHeight = dragStartHeight - delta
        AppSettings.shared.graphHeight = min(max(newHeight, 200), 350)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }
}

// MARK: - Vertical Zoom Handler

struct GraphVerticalZoomHandler: NSViewRepresentable {
    let settings: AppSettings
    private let zoneWidth: CGFloat = 40

    func makeNSView(context: Context) -> VerticalZoomNSView {
        let view = VerticalZoomNSView()
        view.settings = settings
        view.zoneWidth = zoneWidth
        return view
    }

    func updateNSView(_ nsView: VerticalZoomNSView, context: Context) {
        nsView.settings = settings
    }
}

class VerticalZoomNSView: NSView {
    var settings: AppSettings?
    var zoneWidth: CGFloat = 40

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard location.x <= zoneWidth, let settings = settings else {
            super.scrollWheel(with: event)
            return
        }

        let delta = Double(event.scrollingDeltaY)
        let sensitivity = event.hasPreciseScrollingDeltas ? 0.3 : 3.0
        let newRange = settings.graphDBRange - delta * sensitivity
        settings.graphDBRange = min(max(newRange, 10), 100)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if local.x <= zoneWidth {
            return self
        }
        return nil
    }
}

// MARK: - Graph Legend

struct GraphLegend: View {
    @ObservedObject var vm: DSPViewModel
    @Binding var visibilityOverride: [Int: Bool]

    init(vm: DSPViewModel, visibilityOverride: Binding<[Int: Bool]> = .constant([:])) {
        self.vm = vm
        self._visibilityOverride = visibilityOverride
    }

    private var useOverride: Bool { !visibilityOverride.isEmpty }

    private func legendPill(eqCh: Int, name: String, color: Color) -> some View {
        let isVisible = useOverride ? (visibilityOverride[eqCh] ?? false) : (vm.channelVisibility[eqCh] ?? true)
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.1)) {
                if useOverride {
                    visibilityOverride[eqCh] = !isVisible
                } else {
                    vm.channelVisibility[eqCh] = !isVisible
                }
            }
        }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isVisible ? color : Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(name)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isVisible ? .primary : .secondary)
                    .frame(minWidth: 30)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isVisible ? color.opacity(0.15) : Color.gray.opacity(0.1))
            )
            .overlay(
                Capsule().stroke(
                    isVisible ? color.opacity(0.5) : Color.clear,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        // Wrap pills onto additional rows instead of stretching horizontally,
        // so a high channel count never forces the graph pane (and window)
        // wider.  FlowLayout reports a minimum width of only its widest pill.
        FlowLayout(spacing: 8, lineSpacing: 6) {
            // Active input channels
            ForEach(Array(0..<vm.numMatrixInputs), id: \.self) { ch in
                legendPill(eqCh: ch, name: "IN\(ch + 1)", color: MatrixInput.color(for: ch))
            }

            // Enabled outputs (dynamic)
            ForEach(MatrixOutput.visible(for: vm.platformName, slotTypes: vm.outputSlotTypes).filter { vm.outputEnabled[$0.index] }, id: \.index) { out in
                legendPill(eqCh: vm.eqChannel(forOutput: out.index), name: out.descriptor, color: out.color)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

/// Simple wrapping flow layout: lays subviews left-to-right, wrapping to a new
/// row when the proposed width is exceeded.  Reports a minimum width equal to
/// its widest subview, so it never inflates the enclosing view's minimum size.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }

        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for size in sizes {
            // Start a new row when this subview would overflow the current one.
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + lineSpacing
                maxRowWidth = max(maxRowWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, rowWidth)

        // Report the actual used width (bounded by the proposal) so alignment
        // in the parent stays tight rather than claiming the full proposal.
        let width = maxWidth.isFinite ? min(maxRowWidth, maxWidth) : maxRowWidth
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }

        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            // Wrap to the next row on overflow.
            if x > bounds.minX && x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
