import SwiftUI

/// AppKit owns pointer tracking and thumb drawing. Only the value delivered to
/// the surrounding SwiftUI/USB model is rate limited; the thumb follows every
/// input event and the exact release value is always committed immediately.
struct CustomSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var disabled = false

    var body: some View {
        NativeParameterSlider(value: $value, range: range)
            .disabled(disabled)
            .frame(height: 16)
    }
}

private struct NativeParameterSlider: NSViewRepresentable {
    @Binding var value: Float
    let range: ClosedRange<Float>

    func makeNSView(context: Context) -> ParameterSlider {
        ParameterSlider(frame: .zero)
    }

    func updateNSView(_ slider: ParameterSlider, context: Context) {
        slider.configure(value: value, range: range, enabled: context.environment.isEnabled) {
            value = $0
        }
    }

    static func dismantleNSView(_ slider: ParameterSlider, coordinator: ()) {
        slider.delivery.cancel()
        slider.delivery.onValue = nil
    }
}

final class ParameterSlider: NSSlider {
    let delivery = SliderValueDelivery()
    private(set) var isTrackingMouse = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        sliderType = .linear
        controlSize = .small
        isContinuous = true
        target = self
        action = #selector(valueChanged)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(value: Float, range: ClosedRange<Float>, enabled: Bool,
                   onValue: @escaping (Float) -> Void) {
        delivery.onValue = onValue
        if minValue != Double(range.lowerBound) { minValue = Double(range.lowerBound) }
        if maxValue != Double(range.upperBound) { maxValue = Double(range.upperBound) }
        isEnabled = enabled
        // A throttled model echo must never pull the native thumb backwards.
        // Outside a drag, presets, typed values and device changes take effect.
        if !isTrackingMouse {
            if floatValue != value { floatValue = value }
            delivery.synchronize(to: floatValue)
        } else if !enabled {
            delivery.cancel()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        delivery.synchronize(to: floatValue)
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        if isEnabled { delivery.finish(floatValue) }
        else { delivery.cancel() }
    }

    @objc private func valueChanged() {
        guard isEnabled else { return }
        if isTrackingMouse { delivery.submit(floatValue) }
        else { delivery.finish(floatValue) } // Keyboard and accessibility edits.
    }
}

/// At most 30 live model/USB updates per second, with one pending value rather
/// than a backlog. The timer runs in tracking mode as well as the normal loop.
/// It exists only while dragging, and is cancelled on release or dismantling.
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
