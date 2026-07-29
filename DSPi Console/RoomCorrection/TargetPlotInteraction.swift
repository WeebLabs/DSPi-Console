import AppKit
import SwiftUI

/// Something on the target plot that can be grabbed.
enum TargetPlotHandle: Equatable {
    case lowCurtain
    case highCurtain
    case bassShelf
    case trebleShelf
    case anchor(UUID)

    var isCurtain: Bool { self == .lowCurtain || self == .highCurtain }
}

/// Works out what the pointer is over.
///
/// Pulled out of the view because the rules here are real behaviour rather than
/// layout - which handle wins when two overlap, how close counts as a hit - and
/// a view's private method cannot be tested.
struct TargetPlotHitTester {
    /// Handles that occupy a point on the plot.
    let points: [(handle: TargetPlotHandle, position: CGPoint)]
    /// Handles that are full-height lines, so only the x distance matters.
    let verticals: [(handle: TargetPlotHandle, x: CGFloat)]
    var grabRadius: CGFloat = 11

    /// Points win over curtains where they overlap.
    ///
    /// A point is a small target the user placed deliberately; a curtain is a
    /// full-height line that stays easy to grab anywhere else along its length.
    /// Losing a point under a curtain would make it unreachable.
    func handle(at location: CGPoint) -> TargetPlotHandle? {
        var best: (handle: TargetPlotHandle, distance: CGFloat)?
        for entry in points {
            let distance = hypot(location.x - entry.position.x,
                                 location.y - entry.position.y)
            guard distance <= grabRadius else { continue }
            if best == nil || distance < best!.distance {
                best = (entry.handle, distance)
            }
        }
        if let best { return best.handle }

        for entry in verticals where abs(location.x - entry.x) <= grabRadius {
            return entry.handle
        }
        return nil
    }
}

/// Reports right-clicks without swallowing anything else.
///
/// SwiftUI has no right-click gesture, and putting a `contextMenu` on each
/// point would need the points to be hit-testable - which would break the
/// single drag gesture the rest of the plot relies on. This only claims the
/// event when it is actually a secondary click, so left-clicks and drags pass
/// straight through to SwiftUI underneath.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        CatchingView(onRightClick: onRightClick)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatchingView)?.onRightClick = onRightClick
    }

    final class CatchingView: NSView {
        var onRightClick: (CGPoint) -> Void

        init(onRightClick: @escaping (CGPoint) -> Void) {
            self.onRightClick = onRightClick
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        /// Top-left origin, matching SwiftUI, so callers need no conversion.
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            case .leftMouseDown where event.modifierFlags.contains(.control):
                // Control-click is a secondary click on macOS.
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick(convert(event.locationInWindow, from: nil))
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                onRightClick(convert(event.locationInWindow, from: nil))
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}
