import SwiftUI

// MARK: - Stereo Upmixer Window Controller

/// Hosts the upmixer panel in its own window and toggles `upmixStatusPolling` so
/// the shared poll timer fetches UpmixStatus telemetry only while the window is
/// visible (upmixer_spec.md §6.3).
class UpmixerWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    private weak var vm: DSPViewModel?
    @Published var isVisible: Bool = false

    func show(vm: DSPViewModel) {
        self.vm = vm
        if window == nil {
            let view = UpmixerView(vm: vm)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 720),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Stereo Upmixer"
            window?.contentView = NSHostingView(rootView: view)
            window?.isReleasedWhenClosed = false
            window?.delegate = self
            window?.contentMinSize = NSSize(width: 400, height: 400)
            window?.contentMaxSize = NSSize(width: 400, height: 1200)
        }

        // Pull a fresh config so the panel reflects the device (bulk fetch also
        // keeps it current, but this covers opening without a reconnect).
        vm.upmixStatusPolling = true
        DispatchQueue.global(qos: .userInitiated).async { vm.fetchUpmixConfig() }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        vm?.upmixStatusPolling = false
        isVisible = false
    }
}

extension UpmixerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        vm?.upmixStatusPolling = false
        isVisible = false
    }
}

// MARK: - Stereo Upmixer View

struct UpmixerView: View {
    @ObservedObject var vm: DSPViewModel

    /// The whole feature ships in wire format V25 on RP2350; hide the interactive
    /// body on older firmware / RP2040 and show an upgrade note instead.
    private var supported: Bool { vm.firmwareSupportsUpmixer }

    /// Surround conditioning controls only matter when the surround engine runs.
    private var surroundOn: Bool { vm.upmixSurroundMode != UPMIX_SURROUND_MODE_OFF }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            Divider()

            if supported {
                ScrollView {
                    VStack(spacing: 20) {
                        statusSection
                            .padding(.top, 16)
                            .padding(.horizontal, 16)

                        Divider().padding(.horizontal, 16)

                        enginesSection
                            .padding(.horizontal, 16)

                        Divider().padding(.horizontal, 16)

                        centreSection
                            .padding(.horizontal, 16)

                        Divider().padding(.horizontal, 16)

                        surroundSection
                            .padding(.horizontal, 16)

                        Divider().padding(.horizontal, 16)

                        routingNote
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                }
            } else {
                unsupportedNote
            }
        }
        .frame(minWidth: 400, maxWidth: 400)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.split.2x2")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Stereo Upmixer")
                    .font(.system(size: 14, weight: .semibold))
                Text("Derive Centre and Surround from stereo")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { vm.upmixEnabled },
                set: { vm.setUpmixEnabled($0) }
            ))
            .toggleStyle(.switch)
            .disabled(!vm.isDeviceConnected || !supported)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var unsupportedNote: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("Requires an RP2350 device with firmware wire format V25 or newer.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("The upmixer runs on stereo input at 48 kHz or below.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status / telemetry

    /// A one-line banner explaining why the upmixer is not running, plus live
    /// meters for correlation and the derived-channel steering gains.
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STATUS")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(vm.upmixActive ? .primary : .secondary)
                Spacer()
            }

            if vm.upmixActive {
                telemetryGauge(label: "Correlation", value: (vm.upmixCorr + 1) / 2,
                               display: String(format: "%+.2f", vm.upmixCorr), color: .accentColor)
                telemetryGauge(label: "Centre gain", value: vm.upmixCenterGain,
                               display: String(format: "%.0f%%", vm.upmixCenterGain * 100), color: .green)
                if surroundOn {
                    telemetryGauge(label: "Ls gain", value: vm.upmixLsGain,
                                   display: String(format: "%.0f%%", vm.upmixLsGain * 100), color: .purple)
                    telemetryGauge(label: "Rs gain", value: vm.upmixRsGain,
                                   display: String(format: "%.0f%%", vm.upmixRsGain * 100), color: .pink)
                }
            }
        }
    }

    private var statusText: String {
        if !vm.isDeviceConnected { return "No device connected" }
        if vm.upmixActive { return "Active - processing audio" }
        switch vm.upmixParkedReason {
        case UPMIX_PARKED_DISABLED:      return "Idle: upmixer disabled"
        case UPMIX_PARKED_NOT_STEREO:    return "Idle: input is not stereo"
        case UPMIX_PARKED_RATE_TOO_HIGH: return "Idle: sample rate above 48 kHz"
        default:                         return "Idle"
        }
    }

    private var statusColor: Color {
        if !vm.isDeviceConnected { return .secondary }
        return vm.upmixActive ? .green : .orange
    }

    private func telemetryGauge(label: String, value: Float, display: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 76, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: max(0, min(1, CGFloat(value))) * geo.size.width)
                        // Glide between the ~16.7 Hz telemetry samples instead of
                        // snapping, matching the main window's HorizontalMeterBar.
                        .animation(.linear(duration: 0.06), value: value)
                }
            }
            .frame(height: 6)
            Text(display)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: - Engines

    private var enginesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ENGINES")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            HStack {
                Text("Centre")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: Binding(
                    get: { vm.upmixCenterMode },
                    set: { vm.setUpmixCenterMode($0) }
                )) {
                    Text("Sinner").tag(UPMIX_CENTER_MODE_PASSIVE)
                    Text("Logic").tag(UPMIX_CENTER_MODE_ADAPTIVE)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!vm.isDeviceConnected)
            }

            HStack {
                Text("Surround")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: Binding(
                    get: { vm.upmixSurroundMode },
                    set: { vm.setUpmixSurroundMode($0) }
                )) {
                    Text("Off").tag(UPMIX_SURROUND_MODE_OFF)
                    Text("Sinner").tag(UPMIX_SURROUND_MODE_PASSIVE)
                    Text("Logic").tag(UPMIX_SURROUND_MODE_ADAPTIVE)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!vm.isDeviceConnected)
            }

            Text("Logic centre gates extraction on running L/R correlation; Logic surround uses a Pro Logic II-style matrix decoder. Sinner modes are fixed (C = 0.7071(L+R), surround = L-R) - a Hafler-style passive matrix like the one in the Schiit Syn.")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Centre parameters

    private var centreSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CENTRE")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            // Strength and Width are the passive engine's working controls, so
            // they stay active in both modes (spec §4 per-mode applicability).
            paramRow(
                title: "Strength", unit: "%",
                value: vm.upmixStrengthPct, range: 0...100, maxDecimals: 0, scrollStep: 1,
                help: "Centre extraction strength; scales both the C output and how much centre energy is removed from L/R. In Sinner mode this is the fixed centre gain.",
                set: { vm.setUpmixStrength($0) }
            )
            Divider()
            paramRow(
                title: "Centre Width", unit: "%",
                value: vm.upmixCenterWidthPct, range: 0...100, maxDecimals: 0, scrollStep: 1,
                help: "How much extracted centre stays in L/R. 0 = full removal (discrete centre); 100 = L/R untouched (expect combing if a real centre speaker plays).",
                set: { vm.setUpmixCenterWidth($0) }
            )
            Divider()
            // Presence works in both centre modes, so it stays with Strength/Width.
            paramRow(
                title: "Presence", unit: "dB",
                value: vm.upmixPresenceDB, range: -12...12, maxDecimals: 1, scrollStep: 0.5,
                help: "Voice presence bell at 3 kHz (Q 0.6). Positive brings voices forward, negative pushes them back (Syn-style). Stored in 0.5 dB steps.",
                set: { vm.setUpmixPresence($0) }
            )

            // Threshold / Attack / Release / Detector HPF drive the Logic steering
            // only, so they are hidden entirely in Sinner (passive) mode.
            if centreAdaptive {
                Divider()
                paramRow(
                    title: "Correlation Threshold", unit: "%",
                    value: vm.upmixThresholdPct, range: 0...95, maxDecimals: 0, scrollStep: 1,
                    help: "Correlation gate. Below this, nothing is extracted; above it, extraction scales up to full. Raise to extract only strongly-correlated content.",
                    set: { vm.setUpmixThreshold($0) }
                )
                Divider()
                paramRow(
                    title: "Attack", unit: "ms",
                    value: vm.upmixAttackMs, range: 1...500, maxDecimals: 0, scrollStep: 1,
                    help: "Centre gain rise time (Logic mode).",
                    set: { vm.setUpmixAttack($0) }
                )
                Divider()
                paramRow(
                    title: "Release", unit: "ms",
                    value: vm.upmixReleaseMs, range: 5...2000, maxDecimals: 0, scrollStep: 5,
                    help: "Centre gain fall time (Logic mode).",
                    set: { vm.setUpmixRelease($0) }
                )
                Divider()
                paramRow(
                    title: "Detector HPF", unit: "Hz",
                    value: vm.upmixDetectorHpfHz, range: 20...1000, maxDecimals: 0, scrollStep: 5,
                    help: "Detector bass-cut corner. Content below this is ignored by the steering detector (the audio itself is not filtered) so bass does not pump the centre.",
                    set: { vm.setUpmixDetectorHpf($0) }
                )
            }
        }
    }

    /// Logic centre engine: the steering controls (threshold/ballistics/detector)
    /// only apply here.
    private var centreAdaptive: Bool { vm.upmixCenterMode == UPMIX_CENTER_MODE_ADAPTIVE }

    // MARK: - Surround parameters

    private var surroundSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SURROUND")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            // The conditioning chain applies in both Sinner and Logic surround;
            // when the engine is Off no rears are produced, so hide the controls
            // and show only a short explanation in their place.
            if surroundOn {
                paramRow(
                    title: "Delay", unit: "ms",
                    value: vm.upmixSurroundDelayMs, range: 0...20, maxDecimals: 1, scrollStep: 0.5,
                    help: "Haas delay on Ls/Rs (precedence effect). Rule of thumb ~1 ms per foot of listener distance.",
                    set: { vm.setUpmixSurroundDelay($0) }
                )
                Divider()
                paramRow(
                    title: "Band-limit HPF", unit: "Hz",
                    value: vm.upmixSurroundHpfHz, range: 20...2000, maxDecimals: 0, scrollStep: 5,
                    help: "Surround high-pass; keeps rumble out of the rears.",
                    set: { vm.setUpmixSurroundHpf($0) }
                )
                Divider()
                paramRow(
                    title: "Band-limit LPF", unit: "Hz",
                    value: vm.upmixSurroundLpfHz, range: 1000...20000, maxDecimals: 0, scrollStep: 100,
                    help: "Surround low-pass. 7 kHz is the classic surround voicing; raise for full-band rears.",
                    set: { vm.setUpmixSurroundLpf($0) }
                )
                Divider()
                paramRow(
                    title: "Decorrelation", unit: "%",
                    value: vm.upmixDecorrPct, range: 0...100, maxDecimals: 0, scrollStep: 1,
                    help: "Schroeder allpass decorrelator amount. 0 disables decorrelation.",
                    set: { vm.setUpmixDecorr($0) }
                )
            } else {
                Text("Surround engine is off - rows Ls/Rs are not produced.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Routing note

    private var routingNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ROUTING")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            Text("The derived channels appear as matrix source rows: row 2 = Centre, row 3 = Left Surround, row 4 = Right Surround. Open the Matrix Mixer to route them to your output slots (a centre crosspoint gain of -3 dB is a safe start, since the centre row can reach +3 dBFS).")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shared parameter row

    /// One labelled ValueField + CustomSlider + caption.  The commit closure
    /// clamps to the documented range so app state matches the firmware's silent
    /// clamping without a read-back (mirrors PsychoacousticBassView).
    private func paramRow(
        title: String,
        unit: String,
        value: Float,
        range: ClosedRange<Float>,
        maxDecimals: Int,
        scrollStep: Float,
        help: String,
        set: @escaping (Float) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                ValueField(
                    label: unit,
                    value: value,
                    width: 64,
                    scrollStep: scrollStep,
                    maxDecimals: maxDecimals
                ) { set(min(max($0, range.lowerBound), range.upperBound)) }
            }

            CustomSlider(
                value: Binding(get: { value }, set: { set($0) }),
                range: range
            )
            .disabled(!vm.isDeviceConnected)

            Text(help)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
