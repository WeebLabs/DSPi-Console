import SwiftUI

/// The slider the tool windows use: the same native SwiftUI `Slider` as the
/// channel-page gain and volume controls, and nothing more.
///
/// An earlier version wrapped an `NSSlider` and throttled its output through a
/// timer, to protect the view model from a drag's value stream. That treated
/// the symptom. `ParameterRow` now keeps the view model out of the gesture
/// altogether, and once it did, the wrapper was the thing left making drags
/// rough: an `NSSlider` runs AppKit's modal tracking loop, which services
/// timers only between mouse events, so a 30 Hz delivery timer fired late and
/// in bursts during a fast drag. A plain `Slider` bound to local state updates
/// on every event and has no loop to starve, which is why the channel-page
/// sliders were always smooth.
struct CustomSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var disabled = false
    /// Fires true when a drag starts and false when it ends, as SwiftUI's own
    /// `Slider(value:in:onEditingChanged:)` does.
    var onEditingChanged: ((Bool) -> Void)? = nil

    var body: some View {
        Slider(value: $value, in: range) { editing in
            onEditingChanged?(editing)
        }
        .controlSize(.small)
        .disabled(disabled)
        .frame(height: 16)
    }
}

/// Coalesces a drag's value stream for the USB send: at most 30 a second, with
/// one pending value rather than a backlog, so a fast drag cannot queue writes
/// on the serial USB queue ahead of the RTA's synchronous reads. It no longer
/// gates rendering; the thumb and readout follow every event. It exists only
/// while dragging, and is cancelled on release or when the row goes away.
final class SliderValueDelivery {
    var onValue: ((Float) -> Void)?
    private let interval: TimeInterval
    private var timer: Timer?
    private var pending: Float?
    private var lastDelivered: Float?

    init(interval: TimeInterval = 1.0 / 30.0) {
        self.interval = interval
    }

    deinit { timer?.invalidate() }

    func synchronize(to value: Float) {
        cancel()
        lastDelivered = value
    }

    func submit(_ value: Float) {
        pending = value
        guard timer == nil else { return }
        deliverPending()
    }

    func finish(_ value: Float) {
        cancel()
        deliver(value)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        pending = nil
    }

    private func deliverPending() {
        timer = nil
        guard let value = pending else { return }
        pending = nil
        // Install the cooldown before the callback, which may rebuild the view.
        let next = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.deliverPending()
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
        deliver(value)
    }

    private func deliver(_ value: Float) {
        guard value != lastDelivered else { return }
        lastDelivered = value
        onValue?(value)
    }
}

// MARK: - Parameter Row

/// The labelled value-field + slider row the tool windows use.
///
/// It follows the pattern the channel-gain and volume sliders already use, and
/// it exists because the tool windows did not: their sliders bound straight
/// into the view model, so every value delivered during a drag - thirty a
/// second - published a change and re-ran the whole window's body. The RTA
/// graphs draw on the main thread, so that stalled them, and the slider's own
/// tracking loop stuttered for the same reason.
///
/// Here the thumb and the readout run off local state, so a drag re-renders
/// this row and nothing else. `live` sends each value straight to the device
/// without touching the view model; `set` publishes once, on release or on a
/// typed entry. While a drag is in progress the model is ignored as an input,
/// so a late echo cannot pull the thumb backwards.
struct ParameterRow: View {
    let title: String
    /// A second, smaller line under the title.
    var subtitle: String? = nil
    let unit: String
    /// The published value. Read only when no drag is in progress.
    let value: Float
    let range: ClosedRange<Float>
    var scrollStep: Float = 1
    var maxDecimals: Int = 0
    var ends: (String, String)? = nil
    var displayOverride: String? = nil
    /// Width of the numeric field; the windows agree on 60 except the upmixer.
    var fieldWidth: CGFloat = 60
    /// Text to show for a value during a drag instead of the number, or nil
    /// for the number - e.g. "Off" at a band's floor, as `displayOverride`
    /// shows it once the value is committed.
    var formatLive: ((Float) -> String?)? = nil
    var isEnabled: Bool = true
    /// Tooltip text. Windows that show their explanation inline pass the same
    /// string as `caption` instead.
    var help: String = ""
    /// Shown under the slider as secondary text, for the windows that caption
    /// their controls rather than hiding the explanation in a tooltip.
    var caption: String? = nil
    /// Device-only, called for values delivered during a drag - coalesced to
    /// the latest value at most 30 times a second.
    var live: ((Float) -> Void)? = nil
    /// Clamps, publishes and sends. Called once on release, and on typed entry.
    let set: (Float) -> Void

    /// The published value's local copy, written on appear, on echo while no
    /// drag is running, and once at the end of a drag.
    @State private var localValue: Float = 0
    /// Class held in `@State` so one instance lives as long as the row does.
    @State private var delivery = SliderValueDelivery()
    /// Where a drag keeps its value. A plain class rather than `@State`: the
    /// profile showed that any SwiftUI state change during a drag re-ran the
    /// layout of the whole window (about 47 ms in the Tube Modeller), so the
    /// drag must not touch SwiftUI at all. The thumb is drawn by AppKit, the
    /// readout goes through `LiveValueReadout` to an AppKit label, the value
    /// goes to the device through the coalescer, and SwiftUI hears about it
    /// exactly once, on release.
    @State private var dragValue = DragValueBox()
    @State private var readout = LiveValueReadout()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let subtitle {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 12, weight: .medium))
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                }
                Spacer()
                ValueField(
                    label: unit,
                    value: localValue,
                    width: fieldWidth,
                    scrollStep: scrollStep,
                    maxDecimals: maxDecimals,
                    displayOverride: displayOverride,
                    liveReadout: readout
                ) { typed in
                    // Commit and let the published value echo back into
                    // `localValue`, so a clamped entry shows the clamped value.
                    set(typed)
                }
            }

            CustomSlider(
                value: Binding(
                    get: { dragValue.active ? dragValue.value : localValue },
                    set: { v in
                        // Branch on the box, not on `isDragging`: the @State
                        // flip lands on SwiftUI's next update, and the first
                        // drag event can arrive before it does.
                        if dragValue.active {
                            dragValue.value = v
                            readout.show(v)
                            if let live {
                                delivery.onValue = live
                                delivery.submit(v)
                            }
                        } else {
                            // SwiftUI's slider raises onEditingChanged(true)
                            // only after a drag's first value has arrived, so
                            // this branch also sees the first event of every
                            // drag. Defer one turn: if a drag has begun by
                            // then, it owns the commit on release; otherwise
                            // this was a keyboard step or a click, and it
                            // commits as it always did.
                            dragValue.value = v
                            DispatchQueue.main.async {
                                guard !dragValue.active else { return }
                                localValue = v
                                set(v)
                            }
                        }
                    }),
                range: range,
                onEditingChanged: { editing in
                    if editing {
                        // Nothing here touches SwiftUI state: the grab must not
                        // provoke a layout pass before the first movement.
                        dragValue.value = localValue
                        dragValue.active = true
                        readout.format = { v in
                            formatLive?(v) ?? ValueField.format(v, maxDecimals: maxDecimals,
                                                                stripTrailingZeros: false)
                        }
                        readout.beginLive(showing: localValue)
                    } else {
                        dragValue.active = false
                        readout.endLive()
                        // The commit is the last write, so drop any live value
                        // still waiting on the coalescer before it.
                        delivery.cancel()
                        localValue = dragValue.value
                        set(dragValue.value)
                    }
                }
            )
            .disabled(!isEnabled)
            .onAppear { localValue = value }
            // While a drag is in progress the model is not an input, so a late
            // echo cannot pull the thumb backwards.
            .onChange(of: value) { v in if !dragValue.active { localValue = v } }

            if let ends {
                HStack {
                    Text(ends.0)
                    Spacer()
                    Text(ends.1)
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }

            if let caption {
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(help)
    }
}


/// A drag's value and whether one is running, kept outside SwiftUI state on
/// purpose; see `ParameterRow`. `active` is set synchronously in
/// `onEditingChanged`, so the very first event of a drag already takes the
/// live path even though the matching `@State` has not been applied yet.
final class DragValueBox {
    var value: Float = 0
    var active = false
}
