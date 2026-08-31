import XCTest
@testable import DSPi_Console

/// Tests for which release notes get shown, and to whom.
///
/// Release notes are the one piece of onboarding that must NOT appear on a
/// first run: a list of changes from versions the user never ran is noise
/// dressed as news. The rest is ordering, which matters because a mis-ordered
/// entry would bury the release the user just installed. No device.
final class WhatsNewTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "whatsnew-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// The shipped file has to parse, or the Help menu opens on an empty
    /// window and nothing says why.
    func testBundledNotesLoad() {
        let releases = WhatsNew.load()
        XCTAssertFalse(releases.isEmpty)
        for release in releases {
            XCTAssertNotNil(release.parsedVersion, "\(release.version) is not a version")
            XCTAssertFalse(release.headline.isEmpty)
            XCTAssertFalse(release.items.isEmpty, "\(release.version) has no notes")
        }
    }

    /// Sorted on load rather than trusted from the file, so an entry appended
    /// in the wrong place cannot bury the newest release below older ones.
    func testNotesAreNewestFirst() {
        let versions = WhatsNew.load().compactMap(\.parsedVersion)
        XCTAssertEqual(versions, versions.sorted(by: >))
    }

    /// Every shipped release must have notes by the time it goes out, and the
    /// current build's own entry is the one most likely to be forgotten.
    func testCurrentVersionHasNotes() {
        guard let current = FirmwareVersion.expected else { return }
        let covered = WhatsNew.load().compactMap(\.parsedVersion)
        XCTAssertTrue(covered.contains { $0 >= current },
                      "no release notes cover \(current)")
    }

    /// A first run has nothing to catch up on. Returning notes here would
    /// greet a brand-new user with a changelog for software they have never
    /// seen.
    func testFirstRunHasNothingUnread() {
        XCTAssertTrue(WhatsNew.unread(defaults: defaults).isEmpty)
    }

    /// Someone who last read notes for an older release should see what has
    /// landed since, which is the entire purpose of the sheet.
    func testOlderReaderSeesReleasesUpToTheirOwn() {
        guard let current = FirmwareVersion.expected else { return }
        defaults.set("0.0.1", forKey: WhatsNew.lastShownKey)
        let unread = WhatsNew.unread(defaults: defaults)
        let expected = WhatsNew.load().filter { ($0.parsedVersion ?? FirmwareVersion(0, 0, 0)) <= current }
        XCTAssertEqual(unread.map(\.version), expected.map(\.version))
    }

    /// The notes file is written while a release is still being built, so it
    /// routinely describes a version this build is not yet.  Announcing those
    /// would promise features that are not in the app the user is running.
    func testNotesForAnUnreleasedVersionAreNotShown() {
        guard let current = FirmwareVersion.expected else { return }
        defaults.set("0.0.1", forKey: WhatsNew.lastShownKey)
        for release in WhatsNew.unread(defaults: defaults) {
            XCTAssertLessThanOrEqual(release.parsedVersion ?? FirmwareVersion(0, 0, 0), current,
                                     "\(release.version) has not shipped in this build")
        }
    }

    /// Reading them once is enough; the sheet must not reappear on every
    /// launch until the next release.
    func testMarkingAsReadClearsTheBacklog() {
        defaults.set("1.1.0", forKey: WhatsNew.lastShownKey)
        WhatsNew.markCurrentAsRead(defaults: defaults)
        XCTAssertTrue(WhatsNew.unread(defaults: defaults).isEmpty)
    }

    /// A reader already on the current version has nothing outstanding, even
    /// though notes for that version exist.
    func testCurrentReaderHasNothingUnread() {
        guard let current = FirmwareVersion.expected else { return }
        defaults.set(current.description, forKey: WhatsNew.lastShownKey)
        XCTAssertTrue(WhatsNew.unread(defaults: defaults).isEmpty)
    }
}
