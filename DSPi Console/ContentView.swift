import SwiftUI

// MARK: - Sidebar Selection

enum SidebarSelection: Hashable {
    case overview
    case channel(Channel)
    case output(Int)  // Matrix output index 0-8
}

// MARK: - Main Layout

struct ContentView: View {
    @ObservedObject var vm: DSPViewModel
    @State private var selection: SidebarSelection = .overview
    @State private var renamingOutput: Int? = nil
    @State private var renameText = ""
    @State private var localPreamp: Float = 0
    @State private var isDraggingPreamp = false

    private func commitRename() {
        guard let idx = renamingOutput else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            vm.outputNames[idx] = trimmed
        }
        renamingOutput = nil
    }

    private func startRename(_ index: Int) {
        if renamingOutput != nil { commitRename() }
        renameText = vm.outputNames[index]
        renamingOutput = index
    }

    var body: some View {
        HSplitView {
            // SIDEBAR
            List {
                Section(header: Text("INPUTS")) {
                    ForEach(Channel.allCases.filter { !$0.isOutput }, id: \.self) { ch in
                        ChannelRow(channel: ch, isSelected: selection == .channel(ch),
                                  meters: vm.meters)
                            .onTapGesture {
                                if renamingOutput != nil { commitRename(); return }
                                if selection == .channel(ch) {
                                    selection = .overview
                                    vm.updateSelection(to: nil)
                                } else {
                                    selection = .channel(ch)
                                    vm.updateSelection(to: ch)
                                }
                            }
                    }
                }

                Section(header: Text("OUTPUTS")) {
                    ForEach(MatrixOutput.visible(for: vm.platformName).filter { vm.outputEnabled[$0.index] }, id: \.index) { out in
                        OutputRow(output: out, isSelected: selection == .output(out.index),
                                  name: vm.outputNames[out.index],
                                  isMuted: vm.isOutputInactive(out.index),
                                  meters: vm.meters,
                                  isRenaming: renamingOutput == out.index,
                                  renameText: $renameText,
                                  onCommitRename: { commitRename() })
                            .onTapGesture {
                                if renamingOutput != nil { commitRename(); return }
                                if selection == .output(out.index) {
                                    selection = .overview
                                    vm.updateSelection(to: nil)
                                } else {
                                    selection = .output(out.index)
                                    vm.updateSelectionToOutput(out.index)
                                }
                            }
                            .onRightClick { startRename(out.index) }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()

                    // Global Controls
                    VStack(alignment: .leading, spacing: 12) {
                        Text("GLOBAL").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)

                        VStack(spacing: 4) {
                            HStack {
                                Text("Preamp").font(.caption2).foregroundColor(.secondary)
                                Spacer()
                                ValueField(label: "dB", value: localPreamp, width: 60) {
                                    localPreamp = $0
                                    vm.setPreamp($0)
                                }
                            }
                            Slider(value: $localPreamp, in: -60...10) { editing in
                                isDraggingPreamp = editing
                                if !editing { vm.setPreamp(localPreamp) }
                            }
                            .controlSize(.small)
                            .onChange(of: localPreamp) { val in
                                if isDraggingPreamp { vm.sendPreampToDevice(val) }
                            }
                            .onAppear { localPreamp = vm.preampDB }
                            .onChange(of: vm.preampDB) { val in if !isDraggingPreamp { localPreamp = val } }
                            .onRightClick { localPreamp = 0; vm.setPreamp(0) }
                        }

                        Button(action: { vm.setBypass(!vm.bypass) }) {
                            Text("Bypass Master EQ")
                                .font(.caption).fontWeight(.medium)
                                .foregroundColor(vm.bypass ? .white : .secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(vm.bypass ? Color(red: 0.4, green: 0.12, blue: 0.12) : Color.white.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding()
                    // ADDED GESTURE HERE FOR SIDEBAR CONTROLS
                    .onTapGesture {
                        if renamingOutput != nil { commitRename() }
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }

                    Divider()

                    // System Status — CPU load only (meters are inline in sidebar rows)
                    CpuSection(meters: vm.meters)
                    .padding()
                }
                .background(.ultraThinMaterial)
            }
            .frame(minWidth: 220, maxWidth: 260)
            // ADDED GESTURE FOR THE REST OF THE SIDEBAR
            .onTapGesture {
                if renamingOutput != nil { commitRename() }
                NSApp.keyWindow?.makeFirstResponder(nil)
            }

            // MAIN CONTENT
            VStack(alignment: .leading, spacing: 20) {
                // Graph
                VStack(alignment: .leading, spacing: 0) {
                    // Combined header: Filters title + connection status
                    HStack {
                        Text("Filter Response").font(.headline)

                        Spacer()

                        if vm.isDeviceConnected {
                            HStack(spacing: 6) {
                                Circle().fill(.green).frame(width: 6, height: 6)
                                Text("Connected").font(.caption).foregroundColor(.secondary)
                            }
                        } else {
                            HStack(spacing: 6) {
                                Circle().fill(.red).frame(width: 6, height: 6)
                                Text(vm.usb.errorMessage ?? "Disconnected").font(.caption).foregroundColor(.red)
                            }
                        }

                        Button(action: { vm.usb.connect(); vm.fetchAll() }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 8)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                    BodePlotView(vm: vm).frame(height: 250).padding(.horizontal)
                    GraphLegend(vm: vm).padding(.horizontal).padding(.top, 8)
                }

                // Right Panel Content (Dynamic)
                VStack {
                    switch selection {
                    case .channel(let channel):
                        VStack(spacing: 16) {
                            FilterListView(
                                bands: vm.channelData[channel.rawValue] ?? [],
                                channelId: channel.rawValue,
                                onUpdate: { band, params in
                                    vm.setFilter(ch: channel.rawValue, band: band, p: params)
                                },
                                onClear: (channel == .masterLeft || channel == .masterRight) ? { vm.clearAllMaster() } : nil
                            )
                        }

                    case .output(let idx):
                        let eqChannel = idx + 2
                        VStack(spacing: 16) {
                            ChannelSettingsView(
                                gainDB: Binding(
                                    get: { vm.outputGainDB[idx] },
                                    set: { vm.setOutputGain(output: idx, db: $0) }
                                ),
                                delayMS: Binding(
                                    get: { vm.outputDelayMS[idx] },
                                    set: { vm.setOutputDelay(output: idx, ms: $0) }
                                ),
                                isMuted: Binding(
                                    get: { vm.outputMuted[idx] },
                                    set: { vm.setOutputMute(output: idx, muted: $0) }
                                ),
                                onGainDrag: { vm.sendOutputGainToDevice(output: idx, db: $0) },
                                onDelayDrag: { vm.sendOutputDelayToDevice(output: idx, ms: $0) }
                            )
                            .padding(.horizontal)

                            FilterListView(
                                bands: vm.channelData[eqChannel] ?? [],
                                channelId: eqChannel,
                                onUpdate: { band, params in
                                    vm.setFilter(ch: eqChannel, band: band, p: params)
                                },
                                onClear: nil
                            )
                        }

                    case .overview:
                        ScrollView {
                            DashboardOverview(vm: vm)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(NSColor.windowBackgroundColor.blended(withFraction: 0.2, of: .black) ?? .windowBackgroundColor))
            .onTapGesture {
                if renamingOutput != nil { commitRename() }
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .navigationTitle("DSPi Console")
        .frame(maxHeight:900)
        .onChange(of: vm.outputEnabled) { _ in
            // If the selected output was disabled, fall back to overview
            if case .output(let idx) = selection, !vm.outputEnabled[idx] {
                selection = .overview
                vm.updateSelection(to: nil)
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                if let window = NSApp.keyWindow {
                    window.isMovableByWindowBackground = true
                    window.setContentSize(NSSize(width: 950, height: 813))
                    window.styleMask.remove(.resizable)
                }
            }
        }
    }

}

// MARK: - Preview Support

extension DSPViewModel {
    /// Creates a preview-safe view model with mock data (no USB connection)
    static var preview: DSPViewModel {
        let vm = DSPViewModel(usb: USBDevice())
        vm.isDeviceConnected = true
        vm.preampDB = -3.0
        vm.meters.status = SystemStatus(peaks: [0.6, 0.55, 0.4, 0.35, 0.25], cpu0: 42, cpu1: 38)

        // Add some sample filter data for Master L
        vm.channelData[Channel.masterLeft.rawValue] = [
            FilterParams(type: .peaking, freq: 100, q: 0.7, gain: -5.0),
            FilterParams(type: .peaking, freq: 400, q: 1.0, gain: 3.0),
            FilterParams(type: .highShelf, freq: 8000, q: 0.7, gain: -2.0),
            FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams()
        ]

        // Add some sample filter data for Master R
        vm.channelData[Channel.masterRight.rawValue] = [
            FilterParams(type: .peaking, freq: 100, q: 0.7, gain: -5.0),
            FilterParams(type: .peaking, freq: 400, q: 1.0, gain: 3.0),
            FilterParams(type: .highShelf, freq: 8000, q: 0.7, gain: -2.0),
            FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams(), FilterParams()
        ]

        return vm
    }
}

#Preview("Dashboard") {
    ContentView(vm: .preview)
    .frame(height: 790)
}

#Preview("Channel Selected") {
    ContentView(vm: .preview)
    .frame(width: 1000, height: 780)
}
