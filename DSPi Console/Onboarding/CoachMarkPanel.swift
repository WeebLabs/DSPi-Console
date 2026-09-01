import AppKit
import SwiftUI

/// The tour's card for a step hosted in a tool window, shown in a panel beside
/// that window.
///
/// Tool windows are sized to their own content: the Matrix Mixer's window is
/// exactly its grid, so a card drawn inside it lands on top of the thing the
/// step is describing, and reserving room for one means growing the window by
/// a third of its height for the duration of two steps.  Neither is acceptable
/// on the one screen the tour exists to explain.  A child panel beside the
/// window costs the window nothing, travels with it, and leaves the spotlight
/// where it belongs.
final class CoachMarkPanelController {
    static let shared = CoachMarkPanelController()

    private var panel: NSPanel?
    private weak var parent: NSWindow?
    private var parentObservers: [NSObjectProtocol] = []
    private var escapeMonitor: Any?

    private init() {}

    /// Puts the card beside `window`, creating it if need be.  Safe to call on
    /// every step: the content follows the coordinator, and only the size and
    /// position are refreshed here.
    func show(beside window: NSWindow) {
        let panel = panel ?? makePanel()
        self.panel = panel

        if parent !== window {
            detachFromParent()
            parent = window
            window.addChildWindow(panel, ordered: .above)
            // A tool window can be resized or refitted under the card - the
            // matrix grid grows and shrinks with the input count - and a child
            // window follows its parent's origin but knows nothing about its
            // size.
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                parentObservers.append(
                    NotificationCenter.default.addObserver(forName: name, object: window,
                                                           queue: .main) { [weak self] _ in
                        self?.reposition()
                    })
            }
        }

        installEscapeMonitor()

        // Sized after SwiftUI has laid the new step's copy out: the card is as
        // tall as its message, which changes from step to step.
        DispatchQueue.main.async { [weak self] in
            guard let self, let hosting = panel.contentView else { return }
            hosting.layoutSubtreeIfNeeded()
            let size = hosting.fittingSize
            guard size.width > 0, size.height > 0 else { return }
            panel.setContentSize(size)
            self.reposition()
            panel.orderFront(nil)
        }
    }

    /// Takes the card away.  Cheap and idempotent, so callers can hand it every
    /// state change without checking first.
    func hide() {
        guard panel != nil else { return }
        detachFromParent()
        removeEscapeMonitor()
        panel?.orderOut(nil)
    }

    // MARK: Panel

    private func makePanel() -> NSPanel {
        let panel = CardPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The tour outlives a click elsewhere in the app, and a panel that hid
        // itself on deactivation would take the only Next button with it.
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = FirstMouseHostingView(rootView: CoachMarkPanelCard())
        return panel
    }

    private func reposition() {
        guard let panel, let parent else { return }
        let screen = parent.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? parent.frame
        panel.setFrameOrigin(Self.placement(cardSize: panel.frame.size,
                                            beside: parent.frame,
                                            in: screen))
    }

    /// Beside the window it belongs to: to its right where the screen allows,
    /// to its left otherwise, and below it when neither side fits.
    ///
    /// Pure, and in AppKit's coordinates (y upwards), so the one thing that
    /// must never happen - the card landing on top of the window it is
    /// describing, which is what putting it inside the window did - can be
    /// tested without a screen.
    static func placement(cardSize: CGSize, beside host: CGRect, in screen: CGRect) -> CGPoint {
        let gap: CGFloat = 14
        let edge: CGFloat = 8

        var origin = CGPoint(x: host.maxX + gap, y: host.midY - cardSize.height / 2)
        if origin.x + cardSize.width > screen.maxX - edge {
            origin.x = host.minX - gap - cardSize.width
        }
        if origin.x < screen.minX + edge {
            origin.x = host.midX - cardSize.width / 2
            origin.y = host.minY - gap - cardSize.height
        }
        origin.x = min(max(origin.x, screen.minX + edge), max(screen.minX + edge, screen.maxX - cardSize.width - edge))
        origin.y = min(max(origin.y, screen.minY + edge), max(screen.minY + edge, screen.maxY - cardSize.height - edge))
        return origin
    }

    private func detachFromParent() {
        parentObservers.forEach(NotificationCenter.default.removeObserver)
        parentObservers = []
        if let panel, let parent, parent.childWindows?.contains(panel) == true {
            parent.removeChildWindow(panel)
        }
        parent = nil
    }

    // MARK: Escape

    /// Esc leaves the tour wherever the tour is.
    ///
    /// The card's own `.cancelAction` shortcut only fires while its window is
    /// key, and this panel deliberately never takes key away from the window
    /// the user is being shown; a local monitor keeps the promise without it.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }   // Escape
            // A rename in progress owns Esc first: cancelling the edit is what
            // the key means there, and the tour is not going anywhere.
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            OnboardingCoordinator.shared.endBasicsTour()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}

/// Clicks act on the first press rather than being spent bringing the panel
/// forward.  The card is a palette beside the window the user is working in,
/// and Next has to work without a click to focus it first.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) { super.init(rootView: rootView) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Borderless windows refuse key by default, which is what is wanted here: the
/// window being explained keeps focus, so a crosspoint can be clicked without
/// first clicking past the card.
private final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// The panel's content, which follows the tour rather than being handed a step,
/// so a step change needs no work from the controller beyond a resize.
private struct CoachMarkPanelCard: View {
    @ObservedObject private var onboarding = OnboardingCoordinator.shared

    var body: some View {
        if let step = onboarding.basicsTourStep {
            CoachMarkCard(step: step,
                          index: onboarding.basicsTourIndex,
                          total: onboarding.basicsTourSteps.count,
                          onBack: onboarding.basicsTourBack,
                          onNext: onboarding.basicsTourNext,
                          onSkip: onboarding.endBasicsTour)
        }
    }
}
