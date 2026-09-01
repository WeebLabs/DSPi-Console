import SwiftUI

// MARK: - Anchors

/// Where every coach-mark target is on screen.
///
/// Anchors rather than coordinates: the overlay reads the real layout, so it
/// survives window resizing, a collapsed sidebar, a different font size and
/// any future rearrangement without a single hardcoded number.  A view opts in
/// with `.onboardingAnchor("basics.graph")` and never learns anything else
/// about onboarding.
struct OnboardingAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        // Last writer wins.  A key claimed by two views at once would
        // otherwise resolve by traversal order, which is not something a
        // caller can reason about; ids are expected to be unique instead.
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this view as the coach mark `id` points at.
    func onboardingAnchor(_ id: String) -> some View {
        anchorPreference(key: OnboardingAnchors.self, value: .bounds) { [id: $0] }
    }
}

// MARK: - Tour host

/// Runs the basics tour over the live interface.
///
/// Attached at the root of every window the tour visits, where it can see that
/// window's anchors and cover all of it.  The spotlight is a real hole: the
/// highlighted control stays clickable, so the step that asks the user to add
/// a filter, or to connect an input to an output, is one they can actually
/// carry out without leaving the tour.  Everything else is covered, which
/// keeps a half-finished tour from turning into aimless clicking.
///
/// `host` says which window this copy is in.  Only the window the current step
/// belongs to lights anything up; the main window stays dimmed and inert while
/// the tour is off in a tool window, so the next click goes where the tour is
/// rather than into a console nobody is looking at.  A tool window shows the
/// spotlight alone - `CoachMarkPanelController` puts the card beside it.
struct BasicsTourOverlay: ViewModifier {
    @ObservedObject var onboarding: OnboardingCoordinator
    let host: OnboardingHost

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(OnboardingAnchors.self) { anchors in
            GeometryReader { proxy in
                if let step = onboarding.basicsTourStep {
                    if step.host == host {
                        CoachMarkStage(
                            step: step,
                            index: onboarding.basicsTourIndex,
                            total: onboarding.basicsTourSteps.count,
                            // A step whose target is not on screen (a collapsed
                            // sidebar, a control the device hides) still gets
                            // said - it simply loses its spotlight rather than
                            // stalling the tour.
                            target: step.anchor
                                .flatMap { anchors[$0] }
                                .map { proxy[$0] },
                            container: proxy.size,
                            // A tool window is sized to its own content and has
                            // no room to spare, so its card is a panel beside
                            // the window rather than an overlay on top of the
                            // thing being described.
                            showsCard: host == .mainWindow,
                            onBack: onboarding.basicsTourBack,
                            onNext: onboarding.basicsTourNext,
                            onSkip: onboarding.endBasicsTour)
                    } else if host == .mainWindow {
                        // The tour has stepped into a tool window.  The console
                        // keeps its dimming, without a spotlight or a card, so
                        // it is plainly out of play until the tour comes back.
                        Color.black.opacity(0.55)
                            .contentShape(Rectangle())
                            .onTapGesture { }
                            .gesture(DragGesture(minimumDistance: 0))
                    }
                }
            }
            // The overlay sits over its window for the whole life of that
            // window.  Idle it must be completely inert, or a mistake here
            // costs the user every click in the app.
            .allowsHitTesting(isActive)
        }
    }

    /// Live only while this window has something to show: the current step, or
    /// the console's dimming while the tour is elsewhere.
    private var isActive: Bool {
        guard let step = onboarding.basicsTourStep else { return false }
        return step.host == host || host == .mainWindow
    }
}

extension View {
    func basicsTour(_ onboarding: OnboardingCoordinator,
                    host: OnboardingHost = .mainWindow) -> some View {
        modifier(BasicsTourOverlay(onboarding: onboarding, host: host))
    }
}

// MARK: - The card

/// What a step says, and the ways out of the tour.
///
/// Split out from the spotlight because the two do not always live in the same
/// place: a step hosted in a tool window keeps its spotlight inside that window
/// and puts this card in a panel beside it, since a window sized to its own
/// content has no spare room to put a card in.
struct CoachMarkCard: View {
    let step: OnboardingStep
    let index: Int
    let total: Int
    var width: CGFloat = 340
    let onBack: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Step \(index + 1) of \(total)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            Text(step.title)
                .font(.system(size: 15, weight: .semibold))

            Text(step.message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                // Esc leaves the tour, which is what the plan promises and
                // what people try first.
                Button("Skip Tour", action: onSkip)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if index > 0 {
                    Button("Back", action: onBack)
                }
                // Next owns the return key, except on a step that asks the
                // user to type into the control it is pointing at: there,
                // committing a frequency would advance the tour instead.
                Button(index == total - 1 ? "Done" : "Next", action: onNext)
                    .keyboardShortcut(step.invitesTyping ? nil : .defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Material.regular)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - One mark

/// The dimming, the hole and the card, for a single step.
private struct CoachMarkStage: View {
    let step: OnboardingStep
    let index: Int
    let total: Int
    let target: CGRect?
    let container: CGSize
    /// False where the card is shown in a panel beside the window instead, so
    /// this window contributes the dimming and the spotlight only.
    let showsCard: Bool
    let onBack: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void

    /// Measured rather than guessed: the card decides whether it sits above or
    /// below the spotlight, and a wrong guess would put it off screen.
    @State private var cardSize: CGSize = .zero

    /// Breathing room around the highlighted control, so the ring reads as a
    /// spotlight rather than a border drawn on the control itself.
    private var hole: CGRect? {
        target
            .map { $0.insetBy(dx: -8, dy: -8) }
            .map { $0.intersection(CGRect(origin: .zero, size: container)) }
            .flatMap { $0.isNull || $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            dimming
            ring
            card
        }
        .frame(width: container.width, height: container.height, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.22), value: index)
    }

    // MARK: Dimming

    /// Four bands rather than one shape with a hole, because the hole has to
    /// be a hole for the mouse as well as for the eye: with nothing drawn over
    /// the highlighted control, clicks reach it without any hit-testing
    /// trickery.  Each band swallows clicks, so the rest of the window is out
    /// of play until the tour ends.
    @ViewBuilder
    private var dimming: some View {
        if let hole {
            let width = container.width
            let height = container.height
            Group {
                band(CGRect(x: 0, y: 0, width: width, height: hole.minY))
                band(CGRect(x: 0, y: hole.maxY, width: width, height: max(0, height - hole.maxY)))
                band(CGRect(x: 0, y: hole.minY, width: hole.minX, height: hole.height))
                band(CGRect(x: hole.maxX, y: hole.minY,
                            width: max(0, width - hole.maxX), height: hole.height))
            }
        } else {
            band(CGRect(origin: .zero, size: container))
        }
    }

    /// Swallows clicks and drags aimed outside the spotlight, so a half-read
    /// tour does not turn into aimless clicking around the console.  The tap
    /// gesture alone leaves drags through - the graph's resize strip is one -
    /// so both are absorbed.
    private func band(_ rect: CGRect) -> some View {
        Color.black.opacity(0.55)
            .frame(width: max(0, rect.width), height: max(0, rect.height))
            .offset(x: rect.minX, y: rect.minY)
            .contentShape(Rectangle())
            .onTapGesture { }
            .gesture(DragGesture(minimumDistance: 0))
    }

    @ViewBuilder
    private var ring: some View {
        if let hole {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 2)
                .frame(width: hole.width, height: hole.height)
                .offset(x: hole.minX, y: hole.minY)
                .allowsHitTesting(false)
        }
    }

    // MARK: Card

    private static let preferredCardWidth: CGFloat = 340
    private static let gap: CGFloat = 14
    private static let margin: CGFloat = 16

    /// Narrowed for a small window.  The tour visits the Matrix Mixer, whose
    /// window is sized to its grid and can be barely wider than the card
    /// itself; a fixed width there would hang off both edges at once.
    private var cardWidth: CGFloat {
        min(Self.preferredCardWidth, max(200, container.width - 2 * Self.margin))
    }

    @ViewBuilder
    private var card: some View {
        if showsCard {
            CoachMarkCard(step: step, index: index, total: total,
                          width: cardWidth,
                          onBack: onBack, onNext: onNext, onSkip: onSkip)
                .background(sizeReader)
                .offset(x: cardOrigin.x, y: cardOrigin.y)
        }
    }

    private var sizeReader: some View {
        GeometryReader { proxy in
            Color.clear.onAppear { cardSize = proxy.size }
                .onChange(of: proxy.size) { _, new in
                    withAnimation(.easeInOut(duration: 0.22)) { cardSize = new }
                }
        }
    }

    /// Beside the spotlight, never on top of it.
    ///
    /// Four candidate positions are tried in turn and the first that fits
    /// inside the window wins.  Below and above read best, but a tall target
    /// leaves room for neither: the sidebar's channel list runs the height of
    /// the window, and clamping a below-placement back into view would drop
    /// the card straight onto the thing it is describing.  The step that asks
    /// the user to operate the highlighted control would then be covering it.
    ///
    /// If nothing fits, the roomiest side wins and the card is clamped there.
    /// That can still overlap, but only when the target leaves no clear space
    /// at all, and it overlaps the least-bad edge.
    private var cardOrigin: CGPoint {
        let height = cardSize.height > 0 ? cardSize.height : 150

        guard let hole else {
            return clamped(CGPoint(x: (container.width - cardWidth) / 2,
                                   y: (container.height - height) / 2), height: height)
        }

        // Lined up with the spotlight where the window allows it, so the eye
        // travels from the card to the thing it describes.
        let alignedX = hole.midX - cardWidth / 2
        let alignedY = hole.midY - height / 2

        let candidates: [(origin: CGPoint, room: CGFloat, fits: Bool)] = [
            (CGPoint(x: alignedX, y: hole.maxY + Self.gap),
             container.height - hole.maxY,
             hole.maxY + Self.gap + height + Self.margin <= container.height),

            (CGPoint(x: alignedX, y: hole.minY - Self.gap - height),
             hole.minY,
             hole.minY - Self.gap - height >= Self.margin),

            (CGPoint(x: hole.maxX + Self.gap, y: alignedY),
             container.width - hole.maxX,
             hole.maxX + Self.gap + cardWidth + Self.margin <= container.width),

            (CGPoint(x: hole.minX - Self.gap - cardWidth, y: alignedY),
             hole.minX,
             hole.minX - Self.gap - cardWidth >= Self.margin),
        ]

        let chosen = candidates.first(where: \.fits)
            ?? candidates.max(by: { $0.room < $1.room })!
        return clamped(chosen.origin, height: height)
    }

    /// Keeps the card inside the window whatever was chosen.  A card the user
    /// cannot read is worse than no tour.
    private func clamped(_ point: CGPoint, height: CGFloat) -> CGPoint {
        CGPoint(x: clamp(point.x, Self.margin, container.width - cardWidth - Self.margin),
                y: clamp(point.y, Self.margin, container.height - height - Self.margin))
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        guard high > low else { return low }
        return min(max(value, low), high)
    }
}
