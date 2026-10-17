import SwiftUI

/// Hosts a SwiftUI subtree in its own `NSHostingView`, so that updates inside
/// it cannot invalidate the layout of the window around it.
///
/// SwiftUI offers no way to stop a layout invalidation propagating up a stack:
/// a change to any leaf re-runs the placement of every ancestor stack, and in
/// the tool windows that is the whole window (about 47 ms - see
/// `ParameterRow`). The one boundary it cannot see through is a platform view.
/// So a graph that must follow a slider live gets its own hosting view: a
/// change inside re-lays out the graph's small tree only, and the outer window
/// sees a fixed-height platform view whose inputs did not change.
///
/// The height is measured once from the content's ideal size and never
/// invalidated, and `sizingOptions` is empty, so nothing in here can start an
/// Auto Layout pass or a SwiftUI re-layout outside. The outer tree updates the
/// content only when it re-renders itself, which a drag no longer causes.
struct LiveGraphHost<Content: View>: NSViewRepresentable {
    let content: Content
    /// False: the height is the content's ideal height, measured once. True:
    /// no intrinsic height at all, so the frame the outer view puts around the
    /// host decides, as it did for the graph before it was hosted.
    var flexibleHeight = false

    init(flexibleHeight: Bool = false, @ViewBuilder content: () -> Content) {
        self.flexibleHeight = flexibleHeight
        self.content = content()
    }

    func makeNSView(context: Context) -> LiveGraphHostView<Content> {
        LiveGraphHostView(rootView: content, flexibleHeight: flexibleHeight)
    }

    func updateNSView(_ view: LiveGraphHostView<Content>, context: Context) {
        view.hosting.rootView = content
    }
}

final class LiveGraphHostView<Content: View>: NSView {
    let hosting: NSHostingView<Content>
    private let frozenHeight: CGFloat

    init(rootView: Content, flexibleHeight: Bool) {
        hosting = NSHostingView(rootView: rootView)
        // Measure with the default sizing options, which report the ideal
        // size, then switch them off for good.
        frozenHeight = flexibleHeight ? NSView.noIntrinsicMetric : ceil(hosting.fittingSize.height)
        hosting.sizingOptions = []
        super.init(frame: .zero)
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: frozenHeight)
    }
    override func invalidateIntrinsicContentSize() {}
}

/// Live overrides for a graph while one of its parameters is being dragged:
/// the dragged value by key, empty between drags. Observed only by the graph
/// pane inside its `LiveGraphHost`; the window holds it in `@State` as a plain
/// reference so it does not observe it. The pane resolves each parameter as
/// override-or-committed, and clears the overrides when the committed values
/// change, which is the commit on release arriving - by then the two agree, so
/// nothing visibly moves.
final class GraphLive<Key: Hashable>: ObservableObject {
    @Published private(set) var overrides: [Key: Float] = [:]

    func set(_ key: Key, _ value: Float) { overrides[key] = value }
    func clear() { if !overrides.isEmpty { overrides = [:] } }
    subscript(_ key: Key, or base: Float) -> Float { overrides[key] ?? base }
}
