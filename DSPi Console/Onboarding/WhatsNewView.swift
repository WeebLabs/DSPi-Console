import SwiftUI

// MARK: - Release notes

/// One release's notes, as carried in `WhatsNew.json`.
struct ReleaseNotes: Decodable, Identifiable {
    let version: String
    let headline: String
    let items: [String]

    var id: String { version }
    var parsedVersion: FirmwareVersion? { FirmwareVersion(version) }
}

enum WhatsNew {
    /// Version whose notes the user has already read.  Separate from
    /// onboarding's own `lastSeenVersion`: release notes are not onboarding,
    /// and dismissing one must not silence the other.
    static let lastShownKey = "whatsNew.lastShownVersion"

    static func load(from bundle: Bundle = .main) -> [ReleaseNotes] {
        guard let url = bundle.url(forResource: "WhatsNew", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode([ReleaseNotes].self, from: data)
        else { return [] }
        // Newest first regardless of the file's order, so a mis-ordered entry
        // cannot bury the release the user just installed.
        return notes.sorted { ($0.parsedVersion ?? FirmwareVersion(0, 0, 0)) > ($1.parsedVersion ?? FirmwareVersion(0, 0, 0)) }
    }

    /// Notes the user has not read yet, bounded at both ends.
    ///
    /// Empty on a brand-new install: someone seeing the app for the first time
    /// has nothing to catch up on, and a list of changes from a version they
    /// never ran is noise rather than news.
    ///
    /// Also capped at the installed version.  The file is written while a
    /// release is still being built, so it routinely describes a version this
    /// build is not yet; announcing those would promise features that are not
    /// there.
    static func unread(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> [ReleaseNotes] {
        guard let shownRaw = defaults.string(forKey: lastShownKey),
              let shown = FirmwareVersion(shownRaw),
              let current = FirmwareVersion.expected else { return [] }
        return load(from: bundle).filter { release in
            guard let version = release.parsedVersion else { return false }
            return version > shown && version <= current
        }
    }

    /// Records that the current version's notes need not be shown again.
    /// Also called on a new install, so the user starts caught up.
    static func markCurrentAsRead(defaults: UserDefaults = .standard) {
        guard let current = FirmwareVersion.expected else { return }
        defaults.set(current.description, forKey: lastShownKey)
    }
}

// MARK: - Window Controller

class WhatsNewWindowController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible: Bool = false

    func show() {
        if window == nil {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window?.title = "What's New"
            window?.isReleasedWhenClosed = false
            window?.delegate = self
        }
        window?.contentView = NSHostingView(rootView: WhatsNewView(
            onClose: { [weak self] in self?.hide() }))
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
        WhatsNew.markCurrentAsRead()
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }
}

extension WhatsNewWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { isVisible = false }
}

// MARK: - View

struct WhatsNewView: View {
    let onClose: () -> Void
    private let releases = WhatsNew.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(releases) { release in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(release.headline).font(.headline)
                                Spacer()
                                Text(release.version)
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\u{2022}").foregroundColor(.secondary)
                                    Text(item)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    if releases.isEmpty {
                        Text("No release notes are available in this build.")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460, height: 420)
    }
}
