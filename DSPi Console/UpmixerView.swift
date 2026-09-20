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
            let view = UpmixerView(vm: vm, upmix: vm.upmix).onboardingHint("upmixer")

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 720),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window?.title = "Stereo Upmixer"
            let hosting = NSHostingView(rootView: view)
            // The window's size limits are set here, not derived from the
            // tree: left at its defaults the hosting view re-measures the
            // whole tree for them on every display cycle, which is most of
            // what a meter reading or a drag used to cost in this window.
            hosting.sizingOptions = []
            window?.contentView = hosting
            window?.isReleasedWhenClosed = false
            window?.delegate = self
            window?.contentMinSize = NSSize(width: 400, height: 400)
            window?.contentMaxSize = NSSize(width: 400, height: 1200)
        }

        // Pull a fresh config so the panel reflects the device (bulk fetch also
        // keeps it current, but this covers opening without a reconnect).
        vm.upmix.statusPolling = true
        DispatchQueue.global(qos: .userInitiated).async { vm.fetchUpmixConfig() }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        vm?.upmix.statusPolling = false
        isVisible = false
    }
}

extension UpmixerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        vm?.upmix.statusPolling = false
        isVisible = false
    }
}

// MARK: - Stereo Upmixer View

struct UpmixerView: View {
    @ObservedObject var vm: DSPViewModel
    /// Observed separately from `vm` so a slider drag invalidates this
    /// window and nothing else; see ToolParameters.swift.
    @ObservedObject var upmix: UpmixParameters

    /// The whole feature ships in wire format V25 on RP2350; hide the interactive
    /// body on older firmware / RP2040 and show an upgrade note instead.
    private var supported: Bool { vm.firmwareSupportsUpmixer }

    /// Surround conditioning controls only matter when the surround engine runs.
    private var surroundOn: Bool { upmix.surroundMode != UPMIX_SURROUND_MODE_OFF }

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

                        // An engine that is off has nothing to configure, so its
                        // whole block goes with it - header, divider and all.
                        if !centreOff {
                            Divider().padding(.horizontal, 16)

                            centreSection
                                .padding(.horizontal, 16)
                        }

                        if surroundOn {
                            Divider().padding(.horizontal, 16)

                            surroundSection
                                .padding(.horizontal, 16)
                        }

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
    /// meters for correlation and the derived-channel steering gains. In its
    /// own hosting view: the telemetry is polled at 16 Hz while the window is
    /// open, and on the window's own tree each reading re-laid out everything
    /// (11 ms). Only the pane observes it; the rows it does not need are kept
    /// at zero opacity rather than removed, so its height never changes.
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STATUS")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            LiveGraphHost {
                UpmixStatusPane(isConnected: vm.isDeviceConnected, centreOff: centreOff,
                                surroundOn: surroundOn, telemetry: upmix.telemetry)
            }
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
                    get: { upmix.centerMode },
                    set: { vm.setUpmixCenterMode($0) }
                )) {
                    // Off is wire value 2, but sits first here to line up with the
                    // Surround row below - the enum order is not the UI order.
                    Text("Off").tag(UPMIX_CENTER_MODE_OFF)
                    Text("Sinner").tag(UPMIX_CENTER_MODE_PASSIVE)
                    Text("Logician").tag(UPMIX_CENTER_MODE_ADAPTIVE)
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
                    get: { upmix.surroundMode },
                    set: { vm.setUpmixSurroundMode($0) }
                )) {
                    Text("Off").tag(UPMIX_SURROUND_MODE_OFF)
                    Text("Sinner").tag(UPMIX_SURROUND_MODE_PASSIVE)
                    Text("Logician").tag(UPMIX_SURROUND_MODE_ADAPTIVE)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!vm.isDeviceConnected)
            }

            Text("Logician centre gates extraction on running L/R correlation; Logician surround uses a Pro Logic II-style matrix decoder. Sinner modes are fixed (C = 0.7071(L+R), surround = L-R) - a Hafler-style passive matrix like the one in the Schiit Syn.")
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
            // The engine-off case never reaches here: the body drops this whole
            // section, since none of it has any effect with the centre off.
            paramRow(
                title: "Strength", unit: "%",
                value: upmix.strengthPct, range: 0...100, maxDecimals: 0, scrollStep: 1,
                liveIndex: UPMIX_PARAM_STRENGTH,
                help: "Centre extraction strength; scales both the C output and how much centre energy is removed from L/R. In Sinner mode this is the fixed centre gain.",
                set: { vm.setUpmixStrength($0) }
            )
            Divider()
            paramRow(
                title: "Centre Width", unit: "%",
                value: upmix.centerWidthPct, range: 0...100, maxDecimals: 0, scrollStep: 1,
                liveIndex: UPMIX_PARAM_CENTER_WIDTH,
                help: "How much extracted centre stays in L/R. 0 = full removal (discrete centre); 100 = L/R untouched (expect combing if a real centre speaker plays).",
                set: { vm.setUpmixCenterWidth($0) }
            )
            Divider()
            // Presence works in both centre modes, so it stays with Strength/Width.
            paramRow(
                title: "Presence", unit: "dB",
                value: upmix.presenceDB, range: -12...12, maxDecimals: 1, scrollStep: 0.5,
                liveIndex: UPMIX_PARAM_PRESENCE,
                help: "Voice presence bell at 3 kHz (Q 0.6). Positive brings voices forward, negative pushes them back (Syn-style). Stored in 0.5 dB steps.",
                set: { vm.setUpmixPresence($0) }
            )

            // Threshold / Attack / Release / Detector HPF drive the Logician steering
            // only, so they are hidden entirely in Sinner (passive) mode.
            if centreAdaptive {
                Divider()
                paramRow(
                    title: "Correlation Threshold", unit: "%",
                    value: upmix.thresholdPct, range: 0...95, maxDecimals: 0, scrollStep: 1,
                    liveIndex: UPMIX_PARAM_THRESHOLD,
                    help: "Correlation gate. Below this, nothing is extracted; above it, extraction scales up to full. Raise to extract only strongly-correlated content.",
                    set: { vm.setUpmixThreshold($0) }
                )
                Divider()
                paramRow(
                    title: "Attack", unit: "ms",
                    value: upmix.attackMs, range: 1...500, maxDecimals: 0, scrollStep: 1,
                    liveIndex: UPMIX_PARAM_ATTACK,
                    help: "Centre gain rise time (Logician mode).",
                    set: { vm.setUpmixAttack($0) }
                )
                Divider()
                paramRow(
                    title: "Release", unit: "ms",
                    value: upmix.releaseMs, range: 5...2000, maxDecimals: 0, scrollStep: 5,
                    liveIndex: UPMIX_PARAM_RELEASE,
                    help: "Centre gain fall time (Logician mode).",
                    set: { vm.setUpmixRelease($0) }
                )
                Divider()
                paramRow(
                    title: "Detector HPF", unit: "Hz",
                    value: upmix.detectorHpfHz, range: 20...1000, maxDecimals: 0, scrollStep: 5,
                    liveIndex: UPMIX_PARAM_DET_HPF,
                    help: "Detector bass-cut corner. Content below this is ignored by the steering detector (the audio itself is not filtered) so bass does not pump the centre.",
                    set: { vm.setUpmixDetectorHpf($0) }
                )
            }
        }
    }

    /// Logician centre engine: the steering controls (threshold/ballistics/detector)
    /// only apply here.
    private var centreAdaptive: Bool { upmix.centerMode == UPMIX_CENTER_MODE_ADAPTIVE }

    /// Centre engine off (V27+): no C output at all, L/R bit-exact.
    private var centreOff: Bool { upmix.centerMode == UPMIX_CENTER_MODE_OFF }

    // MARK: - Surround parameters

    private var surroundSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SURROUND")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            // The conditioning chain applies in both Sinner and Logician surround.
            // The engine-off case never reaches here - the body drops the whole
            // section rather than leaving a header over an explanation.
            paramRow(
                title: "Delay", unit: "ms",
                value: upmix.surroundDelayMs, range: 0...20, maxDecimals: 1, scrollStep: 0.5,
                liveIndex: UPMIX_PARAM_SUR_DELAY,
                help: "Haas delay on Ls/Rs (precedence effect). Rule of thumb ~1 ms per foot of listener distance.",
                set: { vm.setUpmixSurroundDelay($0) }
            )
            Divider()
            paramRow(
                title: "Band-limit HPF", unit: "Hz",
                value: upmix.surroundHpfHz, range: 20...2000, maxDecimals: 0, scrollStep: 5,
                liveIndex: UPMIX_PARAM_SUR_HPF,
                help: "Surround high-pass; keeps rumble out of the rears.",
                set: { vm.setUpmixSurroundHpf($0) }
            )
            Divider()
            paramRow(
                title: "Band-limit LPF", unit: "Hz",
                value: upmix.surroundLpfHz, range: 1000...20000, maxDecimals: 0, scrollStep: 100,
                liveIndex: UPMIX_PARAM_SUR_LPF,
                help: "Surround low-pass. 7 kHz is the classic surround voicing; raise for full-band rears.",
                set: { vm.setUpmixSurroundLpf($0) }
            )
            Divider()
            paramRow(
                title: "Decorrelation", unit: "%",
                value: upmix.decorrPct, range: 0...100, maxDecimals: 0, scrollStep: 1,
                liveIndex: UPMIX_PARAM_DECORR,
                help: "Schroeder allpass decorrelator amount. 0 disables decorrelation.",
                set: { vm.setUpmixDecorr($0) }
            )
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
        liveIndex: UInt16,
        help: String,
        set: @escaping (Float) -> Void
    ) -> some View {
        ParameterRow(
            title: title,
            unit: unit,
            value: value,
            range: range,
            scrollStep: scrollStep,
            maxDecimals: maxDecimals,
            fieldWidth: 64,
            isEnabled: vm.isDeviceConnected,
            caption: help,
            live: { vm.sendUpmixParamToDevice(liveIndex, min(max($0, range.lowerBound), range.upperBound)) },
            set: { set(min(max($0, range.lowerBound), range.upperBound)) }
        )
    }
}

// MARK: - Status Pane

/// The status banner and telemetry gauges. Lives in a `LiveGraphHost` and is
/// the only view that observes `UpmixTelemetry`, so a reading costs the layout
/// of this pane alone.
private struct UpmixStatusPane: View {
    let isConnected: Bool
    let centreOff: Bool
    let surroundOn: Bool
    @ObservedObject var telemetry: UpmixTelemetry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(telemetry.active ? .primary : .secondary)
                Spacer()
            }

            telemetryGauge(label: "Correlation", value: (telemetry.corr + 1) / 2,
                           display: String(format: "%+.2f", telemetry.corr), color: .accentColor)
                .opacity(telemetry.active ? 1 : 0)
            telemetryGauge(label: "Centre gain", value: telemetry.centerGain,
                           display: String(format: "%.0f%%", telemetry.centerGain * 100), color: .green)
                .opacity(telemetry.active && !centreOff ? 1 : 0)
            telemetryGauge(label: "Ls gain", value: telemetry.lsGain,
                           display: String(format: "%.0f%%", telemetry.lsGain * 100), color: .purple)
                .opacity(telemetry.active && surroundOn ? 1 : 0)
            telemetryGauge(label: "Rs gain", value: telemetry.rsGain,
                           display: String(format: "%.0f%%", telemetry.rsGain * 100), color: .pink)
                .opacity(telemetry.active && surroundOn ? 1 : 0)
        }
    }

    private var statusText: String {
        if !isConnected { return "No device connected" }
        if telemetry.active { return "Active - processing audio" }
        switch telemetry.parkedReason {
        case UPMIX_PARKED_DISABLED:      return "Idle: upmixer disabled"
        case UPMIX_PARKED_NOT_STEREO:    return "Idle: input is not stereo"
        case UPMIX_PARKED_RATE_TOO_HIGH: return "Idle: sample rate above 48 kHz"
        default:                         return "Idle"
        }
    }

    private var statusColor: Color {
        if !isConnected { return .secondary }
        return telemetry.active ? .green : .orange
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

}
