import XCTest
@testable import DSPi_Console

/// Where the tour's card lands beside a tool window.
///
/// The card used to be drawn inside the window, which put it on top of the
/// grid it was explaining, and the fix after that grew the window by a third of
/// its height to make room. Both were the same mistake: the card taking space
/// from the thing being taught. These are the arithmetic that replaced it. No
/// device, no screen.
final class CoachMarkPanelTests: XCTestCase {

    /// A 15" screen with a matrix window the size the stereo grid produces.
    private let screen = CGRect(x: 0, y: 0, width: 1680, height: 1000)
    private let card = CGSize(width: 340, height: 220)

    private func place(host: CGRect, card: CGSize? = nil) -> CGRect {
        let size = card ?? self.card
        let origin = CoachMarkPanelController.placement(cardSize: size, beside: host, in: screen)
        return CGRect(origin: origin, size: size)
    }

    /// The whole point: the card never covers the window it is describing.
    func testCardNeverOverlapsTheWindow() {
        let hosts = [
            CGRect(x: 600, y: 300, width: 472, height: 410),     // centred
            CGRect(x: 1180, y: 300, width: 472, height: 410),    // hard right
            CGRect(x: 20, y: 300, width: 472, height: 410),      // hard left
            CGRect(x: 40, y: 300, width: 1600, height: 410),     // nearly full width
        ]
        for host in hosts {
            XCTAssertFalse(place(host: host).intersects(host),
                           "the card lands on top of the window at \\(host)")
        }
    }

    /// And it stays where it can be read.
    func testCardStaysOnScreen() {
        let hosts = [
            CGRect(x: 600, y: 300, width: 472, height: 410),
            CGRect(x: 1180, y: 300, width: 472, height: 410),
            CGRect(x: 20, y: 300, width: 472, height: 410),
            CGRect(x: 40, y: 500, width: 1600, height: 410),
        ]
        for host in hosts {
            XCTAssertTrue(screen.contains(place(host: host)),
                          "the card falls off the screen beside the window at \\(host)")
        }
    }

    /// Right first, because that is where a window opened centrally has room
    /// and where the eye goes next.
    func testCardPrefersTheRightHandSide() {
        let host = CGRect(x: 600, y: 300, width: 472, height: 410)
        let placed = place(host: host)
        XCTAssertEqual(placed.minX, host.maxX + 14, accuracy: 0.5)
        XCTAssertEqual(placed.midY, host.midY, accuracy: 0.5)
    }

    /// A window against the right edge pushes the card to its left rather than
    /// off the screen.
    func testCardSwapsSidesWhenTheRightIsFull() {
        let host = CGRect(x: 1250, y: 300, width: 400, height: 410)
        XCTAssertEqual(place(host: host).maxX, host.minX - 14, accuracy: 0.5)
    }

    /// A window too wide for either side sends the card underneath it, which
    /// is the 8-channel matrix on a small display.
    func testCardGoesBelowAWindowThatFillsTheWidth() {
        let host = CGRect(x: 40, y: 400, width: 1600, height: 400)
        let placed = place(host: host)
        XCTAssertLessThanOrEqual(placed.maxY, host.minY)
        XCTAssertEqual(placed.midX, host.midX, accuracy: 0.5)
    }
}
