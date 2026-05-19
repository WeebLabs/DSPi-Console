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

    var body: some View {
        VStack(spacing: 18) {
            StereoDashboardCard(
                title: "STEREO INPUT (USB)",
                left: .masterLeft,
                right: .masterRight,
                showDelay: false,
                vm: vm
            )

            // SPDIF stereo pairs (RP2040: 2 pairs, RP2350: 4 pairs)
            let spdifPairs = (vm.numOutputChannels - 1) / 2
            ForEach(0..<spdifPairs, id: \.self) { pairIdx in
                let leftIdx = pairIdx * 2
                let rightIdx = pairIdx * 2 + 1
                let leftEnabled = vm.outputEnabled[leftIdx]
                let rightEnabled = vm.outputEnabled[rightIdx]

                if leftEnabled && rightEnabled {
                    StereoOutputDashboardCard(leftIndex: leftIdx, rightIndex: rightIdx, vm: vm)
                } else if leftEnabled {
                    OutputDashboardCard(outputIndex: leftIdx, vm: vm)
                } else if rightEnabled {
                    OutputDashboardCard(outputIndex: rightIdx, vm: vm)
                }
            }

            // PDM (always mono)
            if vm.outputEnabled[vm.pdmOutputIndex] {
                OutputDashboardCard(outputIndex: vm.pdmOutputIndex, vm: vm)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }
}

// MARK: - Unified Card for Stereo Pairs (L/R side by side)

struct StereoDashboardCard: View {
    let title: String
    let left: Channel
    let right: Channel
    let showDelay: Bool
    @ObservedObject var vm: DSPViewModel

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

    private var left: MatrixOutput { MatrixOutput.all[leftIndex] }
    private var right: MatrixOutput { MatrixOutput.all[rightIndex] }
    private var leftEqCh: Int { leftIndex + 2 }
    private var rightEqCh: Int { rightIndex + 2 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack {
                    Circle().fill(left.color).frame(width: 6, height: 6)
                    Text(vm.channelNames[leftIndex + 2]).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
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
                    Text(vm.channelNames[rightIndex + 2]).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                    Spacer()
                    Text("Delay: \(vm.outputDelayMS[rightIndex], specifier: "%.0f")ms")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(8)
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

    private var output: MatrixOutput {
        MatrixOutput.visible(for: vm.platformName, slotTypes: vm.outputSlotTypes).first(where: { $0.index == outputIndex })
            ?? MatrixOutput.all[outputIndex]
    }
    private var eqChannel: Int { outputIndex + 2 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(output.color).frame(width: 6, height: 6)
                Text(vm.channelNames[outputIndex + 2]).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                Spacer()
                Text("Delay: \(vm.outputDelayMS[outputIndex], specifier: "%.0f")ms")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(8)
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

                    if params.type == .peaking || params.type == .lowShelf || params.type == .highShelf {
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
