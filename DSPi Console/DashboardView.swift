import SwiftUI

private func formatTrimmed(_ value: Double, decimals: Int, signed: Bool = false) -> String {
    let fmt = signed ? "%+.\(decimals)f" : "%.\(decimals)f"
    let full = String(format: fmt, value)
    let parts = full.split(separator: ".", maxSplits: 1)
    guard parts.count == 2 else { return full }
    let trimmed = String(parts[1]).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    if trimmed.isEmpty { return "\(parts[0]).0" }
    return "\(parts[0]).\(trimmed)"
}

// MARK: - Dashboard Overview (Stereo Pairs)

struct DashboardOverview: View {
    @ObservedObject var vm: DSPViewModel
    @ObservedObject private var settings = AppSettings.shared
    /// The grid's measured width, for the Auto layout.
    @State private var availableWidth: CGFloat = 0

    private static let spacing: CGFloat = 18
    /// Narrowest a stereo pair's two filter lists stay readable side by side.
    private static let autoMinCardWidth: CGFloat = 440

    /// One card on the dashboard, in display order.
    private enum CardItem: Hashable {
        case input
        case outputPair(Int, Int)
        case output(Int)
    }

    private var cards: [CardItem] {
        var items: [CardItem] = [.input]
        // SPDIF stereo pairs (RP2040: 2 pairs, RP2350: 4 pairs); a pair with
        // one side disabled shows the other side alone.
        let spdifPairs = (vm.numOutputChannels - 1) / 2
        for pairIdx in 0..<spdifPairs {
            let leftIdx = pairIdx * 2
            let rightIdx = leftIdx + 1
            switch (vm.outputEnabled[leftIdx], vm.outputEnabled[rightIdx]) {
            case (true, true):  items.append(.outputPair(leftIdx, rightIdx))
            case (true, false): items.append(.output(leftIdx))
            case (false, true): items.append(.output(rightIdx))
            case (false, false): break
            }
        }
        // PDM (always mono)
        if vm.outputEnabled[vm.pdmOutputIndex] { items.append(.output(vm.pdmOutputIndex)) }
        return items
    }

    /// Cards per row: as many as fit for Auto, otherwise the user's choice.
    /// Never more columns than cards, so a short list fills the width.
    private func columnCount(for count: Int) -> Int {
        let chosen = settings.dashboardCardsPerRow
        let wanted = chosen > 0
            ? chosen
            : Int((availableWidth + Self.spacing) / (Self.autoMinCardWidth + Self.spacing))
        return max(1, min(wanted, count))
    }

    var body: some View {
        VStack(spacing: Self.spacing) {
            // The channels checked in the graph's gear menu, when the
            // dashboard has bars switched on.  Always the full width.
            SpectrumBarStrip(vm: vm, engine: vm.rta)

            let items = cards
            // Every card is a header and ten rows, so a row of the grid lines
            // up without any help.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top),
                                     count: columnCount(for: items.count)),
                      spacing: Self.spacing) {
                ForEach(items, id: \.self) { item in
                    DashboardCardFrame { card(item) }
                }
            }
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { availableWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in availableWidth = width }
            })
        }
        .padding(.horizontal)
        .padding(.top, 4)
        // Faded rather than removed without a device, so the change is a
        // pure crossfade with no relayout; invisible cards are also inert.
        // The stale values underneath never show: `isDeviceReady` only flips
        // once the connect fetches have replaced them.
        .opacity(vm.isDeviceReady ? 1 : 0)
        .allowsHitTesting(vm.isDeviceReady)
        .animation(.easeInOut(duration: 0.3), value: vm.isDeviceReady)
    }
}

// MARK: - Unified Card for Stereo Pairs (L/R side by side)

struct StereoDashboardCard: View {
    let title: String
    let left: Channel
    let right: Channel
    let showDelay: Bool
    @ObservedObject var vm: DSPViewModel
    @Environment(\.dashboardGearVisible) private var gearVisible

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack {
                    Circle().fill(left.color).frame(width: 6, height: 6)
                    Text(vm.channelNames[left.rawValue]).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                    Spacer()
                    if showDelay {
                        Text("Delay: \(vm.channelDelays[left.rawValue] ?? 0.0, specifier: "%.0f")ms")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                // Color of the left table header
                .background(Color.white.opacity(0.01))

                Divider()

                HStack {
                    Circle().fill(right.color).frame(width: 6, height: 6)
                    Text(vm.channelNames[right.rawValue]).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                    Spacer()
                    if showDelay {
                        Text("Delay: \(vm.channelDelays[right.rawValue] ?? 0.0, specifier: "%.0f")ms")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .padding(.trailing, gearVisible ? dashboardGearSlot : 0)
                .frame(maxWidth: .infinity)
                // Color the right table header
                .background(Color.white.opacity(0.01))
            }
            .frame(height: 32)

            Divider().overlay(Color.gray.opacity(0.1))

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(0..<left.bandCount, id: \.self) { band in
                        if let params = vm.channelData[left.rawValue]?[band] {
                            DashboardRow(band: band + 1, params: params, color: left.color)
                                .background(band % 2 == 0 ? Color.white.opacity(0.03) : Color.clear)
                        }
                    }
                }

                Divider()

                VStack(spacing: 0) {
                    ForEach(0..<right.bandCount, id: \.self) { band in
                        if let params = vm.channelData[right.rawValue]?[band] {
                            DashboardRow(band: band + 1, params: params, color: right.color)
                                .background(band % 2 == 0 ? Color.white.opacity(0.03) : Color.clear)
                        }
                    }
                }
            }
            .frame(height: CGFloat(left.bandCount) * 24)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: left.color.opacity(0.3), location: 0.4),
                            .init(color: right.color.opacity(0.3), location: 0.6)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Single Card for Mono Channel

struct MonoDashboardCard: View {
    let channel: Channel
    @ObservedObject var vm: DSPViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(channel.color).frame(width: 6, height: 6)
                Text(vm.channelNames[channel.rawValue]).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                Spacer()
                Text("Delay: \(vm.channelDelays[channel.rawValue] ?? 0.0, specifier: "%.0f")ms")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(8)
            // Color of the table header
            .background(Color.white.opacity(0.01))
            .frame(height: 32)

            Divider().overlay(Color.gray.opacity(0.2))

            VStack(spacing: 0) {
                ForEach(0..<channel.bandCount, id: \.self) { band in
                    if let params = vm.channelData[channel.rawValue]?[band] {
                        DashboardRow(band: band + 1, params: params, color: channel.color)
                            .background(band % 2 == 0 ? Color.white.opacity(0.03) : Color.clear)
                    }
                }
            }
            .frame(height: CGFloat(channel.bandCount) * 24)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(channel.color.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Stereo Card for L/R Matrix Output Pair

struct StereoOutputDashboardCard: View {
    let leftIndex: Int
    let rightIndex: Int
    @ObservedObject var vm: DSPViewModel
    @Environment(\.dashboardGearVisible) private var gearVisible

    private var left: MatrixOutput { MatrixOutput.all[leftIndex] }
    private var right: MatrixOutput { MatrixOutput.all[rightIndex] }
    private var leftEqCh: Int { vm.eqChannel(forOutput: leftIndex) }
    private var rightEqCh: Int { vm.eqChannel(forOutput: rightIndex) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack {
                    Circle().fill(left.color).frame(width: 6, height: 6)
                    Text(vm.channelNames[leftEqCh]).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                    Spacer()
                    Text("Delay: \(vm.outputDelayMS[leftIndex], specifier: "%.0f")ms")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.01))

                Divider()

                HStack {
                    Circle().fill(right.color).frame(width: 6, height: 6)
                    Text(vm.channelNames[rightEqCh]).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                    Spacer()
                    Text("Delay: \(vm.outputDelayMS[rightIndex], specifier: "%.0f")ms")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .padding(.trailing, gearVisible ? dashboardGearSlot : 0)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.01))
            }
            .frame(height: 32)

            Divider().overlay(Color.gray.opacity(0.1))

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(0..<10, id: \.self) { band in
                        if let params = vm.channelData[leftEqCh]?[band] {
                            DashboardRow(band: band + 1, params: params, color: left.color)
                                .background(band % 2 == 0 ? Color.white.opacity(0.03) : Color.clear)
                        }
                    }
                }

                Divider()

                VStack(spacing: 0) {
                    ForEach(0..<10, id: \.self) { band in
                        if let params = vm.channelData[rightEqCh]?[band] {
                            DashboardRow(band: band + 1, params: params, color: right.color)
                                .background(band % 2 == 0 ? Color.white.opacity(0.03) : Color.clear)
                        }
                    }
                }
            }
            .frame(height: CGFloat(10) * 24)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: left.color.opacity(0.3), location: 0.4),
                            .init(color: right.color.opacity(0.3), location: 0.6)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Single Card for Matrix Output

struct OutputDashboardCard: View {
    let outputIndex: Int
    @ObservedObject var vm: DSPViewModel
    @Environment(\.dashboardGearVisible) private var gearVisible

    private var output: MatrixOutput {
        MatrixOutput.visible(for: vm.platformName, slotTypes: vm.outputSlotTypes).first(where: { $0.index == outputIndex })
            ?? MatrixOutput.all[outputIndex]
    }
    private var eqChannel: Int { vm.eqChannel(forOutput: outputIndex) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(output.color).frame(width: 6, height: 6)
                Text(vm.channelNames[eqChannel]).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                Spacer()
                Text("Delay: \(vm.outputDelayMS[outputIndex], specifier: "%.0f")ms")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .padding(.trailing, gearVisible ? dashboardGearSlot : 0)
            .background(Color.white.opacity(0.01))
            .frame(height: 32)

            Divider().overlay(Color.gray.opacity(0.2))

            VStack(spacing: 0) {
                ForEach(0..<10, id: \.self) { band in
                    if let params = vm.channelData[eqChannel]?[band] {
                        DashboardRow(band: band + 1, params: params, color: output.color)
                            .background(band % 2 == 0 ? Color.white.opacity(0.03) : Color.clear)
                    }
                }
            }
            .frame(height: CGFloat(10) * 24)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(output.color.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Compact Read-Only Row

struct DashboardRow: View {
    let band: Int
    let params: FilterParams
    let color: Color

    var isActive: Bool { params.type != .flat }

    var typeCode: String {
        switch params.type {
        case .flat: return "OFF"
        case .peaking: return "PK"
        case .lowShelf: return "LS"
        case .highShelf: return "HS"
        case .lowPass: return "LP"
        case .highPass: return "HP"
        case .notch: return "NO"
        case .allPass: return "AP"
        default: return params.type.shortLabel
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("\(band)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: 14, alignment: .leading)

            Text(typeCode)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isActive ? color : .secondary.opacity(0.4))
                .frame(width: 28, alignment: .leading)

            Spacer()

            if isActive {
                HStack(spacing: 2) {
                    Text("\(params.freq, specifier: "%.0f")")
                        // Hz value color
                        .foregroundColor(.primary.opacity(0.8))
                    // Hz unit color
                    Text("Hz").foregroundColor(.secondary.opacity(0.7)).font(.system(size: 8))

                    Spacer().frame(width: 4)

                    if params.type.usesGain {
                        Text(formatTrimmed(Double(params.gain), decimals: 2, signed: true))
                            .foregroundColor(.primary.opacity(0.8))
                        Text("dB").foregroundColor(.secondary.opacity(0.7)).font(.system(size: 8))
                    }

                    if params.type == .peaking {
                        Spacer().frame(width: 4)
                        Text(formatTrimmed(Double(params.q), decimals: 3))
                            .foregroundColor(.primary.opacity(0.8))
                        Text("Q").foregroundColor(.secondary.opacity(0.7)).font(.system(size: 8))
                    }
                }
                .font(.system(size: 10, design: .monospaced))
            } else {
                Text("—")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.2))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
    }
}

// MARK: - Layout

/// Opened at the end of each card's right-most header while the hover gear is
/// showing, so the delay readout slides aside instead of sitting under it.
private let dashboardGearSlot: CGFloat = 18

private struct DashboardGearVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the enclosing dashboard card is showing its layout gear.
    var dashboardGearVisible: Bool {
        get { self[DashboardGearVisibleKey.self] }
        set { self[DashboardGearVisibleKey.self] = newValue }
    }
}

extension DashboardOverview {
    @ViewBuilder
    private func card(_ item: CardItem) -> some View {
        switch item {
        case .input:
            StereoDashboardCard(title: "STEREO INPUT (USB)", left: .masterLeft, right: .masterRight,
                                showDelay: false, vm: vm)
        case .outputPair(let left, let right):
            StereoOutputDashboardCard(leftIndex: left, rightIndex: right, vm: vm)
        case .output(let index):
            OutputDashboardCard(outputIndex: index, vm: vm)
        }
    }
}

/// Wraps a dashboard card with the layout gear, shown while the pointer is over
/// that card.  Every card's gear edits the same dashboard-wide setting, so the
/// control is wherever the user already is rather than in a header of its own.
private struct DashboardCardFrame<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var isHovered = false
    @State private var optionsOpen = false

    var body: some View {
        content
            // Animated here rather than at each state change, so the readout
            // also slides back when the popover closes on an outside click.
            .environment(\.dashboardGearVisible, isHovered || optionsOpen)
            .animation(.easeInOut(duration: 0.15), value: isHovered || optionsOpen)
            .overlay(alignment: .topTrailing) {
                Button { optionsOpen.toggle() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(optionsOpen ? .primary : .secondary)
                        .frame(width: 16, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dashboard layout")
                // Faded rather than removed, so the popover keeps its anchor.
                .opacity(isHovered || optionsOpen ? 1 : 0)
                .allowsHitTesting(isHovered || optionsOpen)
                .popover(isPresented: $optionsOpen, arrowEdge: .bottom) {
                    DashboardLayoutPanel()
                }
                // Centred in the 32 pt header, in its reserved slot.
                .padding(.top, 9)
                .padding(.trailing, 6)
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            }
    }
}

/// The dashboard layout popover: Auto, or a fixed number of cards per row.
private struct DashboardLayoutPanel: View {
    @ObservedObject private var settings = AppSettings.shared

    private var chosen: Int { min(max(settings.dashboardCardsPerRow, 0), 3) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DASHBOARD LAYOUT")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            HStack(spacing: 6) {
                ForEach(0...3, id: \.self) { n in tile(n) }
            }
            .padding(.horizontal, 12)
            Text(chosen == 0 ? "Fits as many cards per row as the window allows."
                             : "Up to \(chosen) \(chosen == 1 ? "card" : "cards") per row.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
        .frame(width: 220)
    }

    private func tile(_ n: Int) -> some View {
        let on = chosen == n
        let shape = RoundedRectangle(cornerRadius: 6)
        return Button { settings.dashboardCardsPerRow = n } label: {
            VStack(spacing: 4) {
                if n == 0 {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 13)
                } else {
                    DashboardLayoutGlyph(columns: n)
                }
                Text(n == 0 ? "Auto" : "\(n)")
                    .font(.system(size: 9, weight: on ? .semibold : .regular))
            }
            .foregroundColor(on ? .accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(shape.fill(on ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)))
            .overlay(shape.stroke(on ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(n == 0 ? "Fit cards to the window width" : "\(n) \(n == 1 ? "card" : "cards") per row")
    }
}

/// Two rows of rounded cells in the given number of columns: a picture of a
/// cards-per-row layout, drawn in the current foreground colour.
private struct DashboardLayoutGlyph: View {
    let columns: Int

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 2) {
                    ForEach(0..<columns, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2)
                    }
                }
            }
        }
        .frame(width: 22, height: 13)
    }
}
