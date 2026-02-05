import SwiftUI
import Combine

// MARK: - ISO 226 Data

struct IsoData {
    let f: Float
    let af: Float
    let lu: Float
    let tf: Float
}

private let isoTable: [IsoData] = [
    IsoData(f: 20, af: 0.532, lu: -31.6, tf: 78.5),
    IsoData(f: 25, af: 0.506, lu: -27.2, tf: 68.7),
    IsoData(f: 31.5, af: 0.480, lu: -23.0, tf: 59.5),
    IsoData(f: 40, af: 0.455, lu: -19.1, tf: 51.1),
    IsoData(f: 50, af: 0.432, lu: -15.9, tf: 44.0),
    IsoData(f: 63, af: 0.409, lu: -13.0, tf: 37.5),
    IsoData(f: 80, af: 0.387, lu: -10.3, tf: 31.5),
    IsoData(f: 100, af: 0.367, lu: -8.1, tf: 26.5),
    IsoData(f: 125, af: 0.349, lu: -6.2, tf: 22.1),
    IsoData(f: 160, af: 0.330, lu: -4.5, tf: 17.9),
    IsoData(f: 200, af: 0.315, lu: -3.1, tf: 14.4),
    IsoData(f: 250, af: 0.301, lu: -2.0, tf: 11.4),
    IsoData(f: 315, af: 0.288, lu: -1.1, tf: 8.6),
    IsoData(f: 400, af: 0.276, lu: -0.4, tf: 6.2),
    IsoData(f: 500, af: 0.267, lu: 0.0, tf: 4.4),
    IsoData(f: 630, af: 0.259, lu: 0.3, tf: 3.0),
    IsoData(f: 800, af: 0.253, lu: 0.5, tf: 2.2),
    IsoData(f: 1000, af: 0.250, lu: 0.0, tf: 2.4),
    IsoData(f: 1250, af: 0.246, lu: -2.7, tf: 3.5),
    IsoData(f: 1600, af: 0.244, lu: -4.1, tf: 1.7),
    IsoData(f: 2000, af: 0.243, lu: -1.0, tf: -1.3),
    IsoData(f: 2500, af: 0.243, lu: 1.7, tf: -4.2),
    IsoData(f: 3150, af: 0.243, lu: 2.5, tf: -6.0),
    IsoData(f: 4000, af: 0.242, lu: 1.2, tf: -5.4),
    IsoData(f: 5000, af: 0.242, lu: -2.1, tf: -1.5),
    IsoData(f: 6300, af: 0.245, lu: -7.1, tf: 6.0),
    IsoData(f: 8000, af: 0.254, lu: -11.2, tf: 12.6),
    IsoData(f: 10000, af: 0.271, lu: -10.7, tf: 13.9),
    IsoData(f: 12500, af: 0.301, lu: -3.1, tf: 12.3),
    IsoData(f: 16000, af: 0.310, lu: -2.0, tf: 17.0)
]

// MARK: - Loudness Window Controller

class LoudnessWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false

    func show(vm: DSPViewModel) {
        if window == nil {
            let view = LoudnessView(vm: vm)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Loudness Compensation"
            window?.contentView = NSHostingView(rootView: view)
            window?.isReleasedWhenClosed = false
            window?.delegate = self
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }
}

extension LoudnessWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}

// MARK: - ISO 226:2003 Computation (for visualization only)

private func iso226SPL(tf: Float, af: Float, lu: Float, phon: Float) -> Float {
    // Threshold term: (0.4 * 10^((Tf+Lu)/10 - 9))^af
    let B = 0.4 * powf(10.0, (tf + lu) / 10.0 - 9.0)
    let threshold = powf(B, af)
    // Af = phon-dependent term + threshold
    var Af = 4.47e-3 * (powf(10.0, 0.025 * phon) - 1.15) + threshold
    if Af < 1e-10 { Af = 1e-10 }
    return (10.0 / af) * log10f(Af) - lu + 94.0
}

private func loudnessCompensationDB(
    tf: Float, af: Float, lu: Float,
    refSPL: Float, effectivePhon: Float, intensity: Float
) -> Float {
    if effectivePhon >= refSPL { return 0 }
    let splRef = iso226SPL(tf: tf, af: af, lu: lu, phon: refSPL)
    let splEff = iso226SPL(tf: tf, af: af, lu: lu, phon: effectivePhon)
    let flat = effectivePhon - refSPL
    let freq = splEff - splRef
    return (freq - flat) * (intensity / 100.0)
}

// MARK: - Loudness View

struct LoudnessView: View {
    @ObservedObject var vm: DSPViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Visualization
                    compensationGraph
                        .padding(.top, 16)
                        .padding(.horizontal, 16)

                    Divider().padding(.horizontal, 16)

                    // Parameters
                    parameterSection
                        .padding(.horizontal, 16)
                }
            }
        }
        .frame(width: 380, height: 480)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "ear.fill")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Loudness Compensation")
                    .font(.system(size: 14, weight: .semibold))
                Text("ISO 226:2003 Fletcher-Munson")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { vm.loudnessEnabled },
                set: { vm.setLoudness($0) }
            ))
            .toggleStyle(.switch)
            .disabled(!vm.isDeviceConnected)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }



    // MARK: - Compensation Graph

    private var compensationGraph: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COMPENSATION CURVE")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))

                // Grid + curve
                CompensationCurveView(
                    refSPL: vm.loudnessRefSPL,
                    intensity: vm.loudnessIntensity,
                    isEnabled: vm.loudnessEnabled
                )
                .padding(8)
            }
            .frame(height: 140)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
    }

    // MARK: - Parameter Section

    private var parameterSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PARAMETERS")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            // Reference SPL
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Reference SPL")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    ValueField(
                        label: "dB",
                        value: vm.loudnessRefSPL,
                        width: 60
                    ) { vm.setLoudnessRef($0) }
                }
                
                CustomSlider(
                    value: Binding(
                        get: { vm.loudnessRefSPL },
                        set: { vm.setLoudnessRef($0) }
                    ),
                    range: 40...100
                )
                .disabled(!vm.isDeviceConnected)

                Text("SPL at 1 kHz when USB volume is 0 dB. Lower = more compensation per dB of volume reduction.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Intensity
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Intensity")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    ValueField(
                        label: "%",
                        value: vm.loudnessIntensity,
                        width: 60
                    ) { vm.setLoudnessIntensity($0) }
                }
                
                CustomSlider(
                    value: Binding(
                        get: { vm.loudnessIntensity },
                        set: { vm.setLoudnessIntensity($0) }
                    ),
                    range: 0...200
                )
                .disabled(!vm.isDeviceConnected)

                Text("Scales the ISO 226 compensation. 100% = standard curve. 0% = bypassed. >100% = exaggerated.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Custom Slider

struct CustomSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var disabled: Bool = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 3)
                
                // Active Track
                RoundedRectangle(cornerRadius: 2)
                    .fill(disabled ? Color.gray.opacity(0.3) : Color.accentColor)
                    .frame(width: max(0, min(geometry.size.width, geometry.size.width * CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)))), height: 3)
                
                // Thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
                    .offset(x: max(0, min(geometry.size.width - 12, geometry.size.width * CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)) - 6)))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                if !disabled {
                                    let percent = min(max(0, gesture.location.x / geometry.size.width), 1)
                                    let newValue = range.lowerBound + Float(percent) * (range.upperBound - range.lowerBound)
                                    value = newValue
                                }
                            }
                    )
            }
            .frame(height: 12)
        }
        .frame(height: 12)
        .opacity(disabled ? 0.5 : 1.0)
    }
}

// MARK: - Info Row

private struct InfoRow: View {
    let volume: String
    let description: String

    var body: some View {
        HStack(spacing: 8) {
            Text(volume)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.accentColor)
                .frame(width: 50, alignment: .trailing)
            Text(description)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Compensation Curve Visualization

private struct CompensationCurveView: View {
    let refSPL: Float
    let intensity: Float
    let isEnabled: Bool

    // Fixed visualization volume to show representative curve
    private let visualizationVolumeDB: Float = -40.0
    private let minFreq: CGFloat = 20.0
    private let maxFreq: CGFloat = 20000.0
    
    private func computeCurve() -> [CGPoint] {
        var effectivePhon = refSPL + visualizationVolumeDB
        // Clamping logic
        if effectivePhon < 20 { effectivePhon = 20 }
        if effectivePhon > refSPL { effectivePhon = refSPL }
        
        return isoTable.map { data in
            let gain = loudnessCompensationDB(
                tf: data.tf, af: data.af, lu: data.lu,
                refSPL: refSPL, effectivePhon: effectivePhon,
                intensity: intensity
            )
            return CGPoint(x: CGFloat(data.f), y: CGFloat(gain))
        }
    }
    
    // Logarithmic X mapping
    private func xPos(_ freq: CGFloat, w: CGFloat) -> CGFloat {
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let logVal = log10(freq)
        return CGFloat((logVal - logMin) / (logMax - logMin)) * w
    }

    // Dynamic Linear Y mapping
    private func yPos(_ gain: CGFloat, h: CGFloat, domainMin: CGFloat, domainMax: CGFloat) -> CGFloat {
        let range = domainMax - domainMin
        let normalized = (gain - domainMin) / range
        return h - (normalized * h)
    }

    var body: some View {
        let points = computeCurve()
        
        // Calculate dynamic domain to center the curve
        let gains = points.map { $0.y }
        let minGain = gains.min() ?? 0
        let maxGain = gains.max() ?? 0
        
        // Minimum visual range of 10dB to prevent extreme zoom on flat lines
        let dataRange = maxGain - minGain
        let minVisualRange: CGFloat = 10.0
        let visualRange = max(dataRange, minVisualRange)
        
        // Add 20% padding above and below
        let padding = visualRange * 0.2
        let domainMin = minGain - padding
        let domainMax = maxGain + padding

        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // Grid
                drawGrid(w: w, h: h, domainMin: domainMin, domainMax: domainMax)
                
                // Labels
                drawLabels(w: w, h: h, domainMin: domainMin, domainMax: domainMax)

                if isEnabled {
                    // Draw Curve
                    Path { path in
                        for (i, p) in points.enumerated() {
                            let x = xPos(p.x, w: w)
                            let y = yPos(p.y, h: h, domainMin: domainMin, domainMax: domainMax)
                            
                            if i == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
                    
                    // Info Badge
                    HStack(spacing: 4) {
                        Text("Curve at -40dB")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.8))
                    .cornerRadius(4)
                    .position(x: w - 40, y: 15)
                    
                } else {
                    Text("Disabled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.5))
                        .position(x: w / 2, y: h / 2)
                }
            }
            .clipped()
        }
    }

    private func drawGrid(w: CGFloat, h: CGFloat, domainMin: CGFloat, domainMax: CGFloat) -> some View {
        Path { path in
            // Horizontal lines (Gain) - find "nice" steps
            let range = domainMax - domainMin
            let step: CGFloat = range > 40 ? 10 : 5
            
            // Find first multiple of step greater than domainMin
            let start = ceil(domainMin / step) * step
            
            var current = start
            while current <= domainMax {
                let y = yPos(current, h: h, domainMin: domainMin, domainMax: domainMax)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: w, y: y))
                current += step
            }
            
            // Vertical lines (Frequency)
            // 100, 1k, 10k
            for f in [100.0, 1000.0, 10000.0] {
                let x = xPos(CGFloat(f), w: w)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: h))
            }
        }
        .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
    }
    
    private func drawLabels(w: CGFloat, h: CGFloat, domainMin: CGFloat, domainMax: CGFloat) -> some View {
        ZStack {
            // Frequency Labels
            ForEach([100, 1000, 10000], id: \.self) { f in
                Text(f == 1000 ? "1k" : (f == 10000 ? "10k" : "\(f)"))
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                    .position(x: xPos(CGFloat(f), w: w), y: h - 5)
            }
            
            // Gain Labels
            let range = domainMax - domainMin
            let step: CGFloat = range > 40 ? 10 : 5
            let start = ceil(domainMin / step) * step
            
            // Generate valid steps manually
            let steps = stride(from: start, through: domainMax, by: Double(step)).map { CGFloat($0) }
            
            ForEach(steps, id: \.self) { gain in
                Text("\(Int(gain))")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                    .position(x: 10, y: yPos(gain, h: h, domainMin: domainMin, domainMax: domainMax))
            }
        }
    }
}
