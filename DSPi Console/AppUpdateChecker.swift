import AppKit
import Foundation
import SwiftUI

/// Tells the user when a newer DSPi Console has been published on GitHub, and
/// installs it when the release carries a signed zip and this copy of the app
/// can be replaced.  Otherwise it points at the release page.
@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()

    static let releasesURL = URL(string: "https://api.github.com/repos/WeebLabs/DSPi-Console/releases?per_page=30")!
    static let automaticKey = "checkForUpdatesAutomatically"
    /// Developer override for the release list, for exercising the installer
    /// against a local feed.  Safe to honour: an install still needs a zip
    /// signed with the release key.
    private static let feedOverrideKey = "updateFeedURLOverride"
    private static let skippedTagKey = "updateCheckSkippedTag"
    private static let lastCheckedKey = "updateCheckLastChecked"
    /// Automatic checks repeat this often while the app stays open.
    private static let interval: TimeInterval = 24 * 60 * 60

    struct Asset: Decodable, Equatable {
        let name: String
        let url: URL

        enum CodingKeys: String, CodingKey {
            case name
            case url = "browser_download_url"
        }
    }

    struct Release: Decodable, Equatable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool
        var assets: [Asset] = []

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft, assets
        }

        init(tagName: String, htmlURL: URL, draft: Bool, assets: [Asset] = []) {
            self.tagName = tagName
            self.htmlURL = htmlURL
            self.draft = draft
            self.assets = assets
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try c.decode(String.self, forKey: .tagName)
            htmlURL = try c.decode(URL.self, forKey: .htmlURL)
            draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
            assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        }

        /// Tags are spelled "v1.1.6-beta4", the same scheme as MARKETING_VERSION.
        var version: FirmwareVersion? {
            FirmwareVersion(tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName)
        }
    }

    enum InstallState: Equatable {
        case idle
        case downloading(Double)
        case verifying
        /// The helper is waiting for the app to exit, after the user cancelled
        /// the quit the installer asked for.
        case waitingForQuit
        case failed(String)
    }

    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?
    /// The newest release above the running version, from the last check.
    @Published private(set) var available: Release?
    @Published private(set) var installState: InstallState = .idle

    private var timer: Timer?
    private var downloadTask: URLSessionTask?
    private var installTask: Task<Void, Never>?
    private var progressPanel: NSPanel?
    /// Work directory of a started helper; holds the relaunch marker.
    private var pendingWork: URL?

    private init() {
        lastChecked = UserDefaults.standard.object(forKey: Self.lastCheckedKey) as? Date
    }

    /// The running app's version.  Console and firmware share one version
    /// scheme, so `FirmwareVersion.expected` is also the app's own version.
    var currentVersion: FirmwareVersion? { FirmwareVersion.expected }

    /// Picks the newest release worth offering over `current`.  Someone on a
    /// final release is only offered finals; someone already on a beta is
    /// offered newer betas too.  Judged from the tag, because the beta
    /// releases are not flagged as pre-releases on GitHub.
    nonisolated static func newestUpdate(in releases: [Release], over current: FirmwareVersion) -> Release? {
        releases
            .filter { !$0.draft }
            .compactMap { release in release.version.map { (release, $0) } }
            .filter { current.beta != 0 || $0.1.beta == 0 }
            .filter { $0.1 > current }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// Whether `release` can be installed in place right now.
    func canInstall(_ release: Release) -> Bool {
        AppUpdateInstaller.signedZip(in: release) != nil
            && AppUpdateInstaller.canReplace(Bundle.main.bundleURL)
    }

    var isInstalling: Bool {
        switch installState {
        case .downloading, .verifying, .waitingForQuit: return true
        case .idle, .failed: return false
        }
    }

    // MARK: - Checking

    /// Starts the launch check and the daily repeat, if the user allows them.
    func startAutomaticChecks() {
        UserDefaults.standard.register(defaults: [Self.automaticKey: true])
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in await AppUpdateChecker.shared.checkAutomatically() }
        }
        // Let launch settle (What's New, device connect) before any alert.
        Task {
            try? await Task.sleep(for: .seconds(5))
            await checkAutomatically()
        }
    }

    private func checkAutomatically() async {
        guard UserDefaults.standard.bool(forKey: Self.automaticKey), !isInstalling else { return }
        guard let release = try? await check(),
              release.tagName != UserDefaults.standard.string(forKey: Self.skippedTagKey)
        else { return }
        presentUpdate(release)
    }

    /// The "Check for Updates..." path: always answers, including when there
    /// is nothing new or the check failed, and ignores a skipped version.
    func checkInteractively() {
        guard !isInstalling else {
            progressPanel?.makeKeyAndOrderFront(nil)
            return
        }
        Task {
            do {
                if let release = try await check() {
                    presentUpdate(release)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "DSPi Console is up to date"
                    alert.informativeText = "Version \(currentVersion?.description ?? GeneralSettingsTab.appVersion) is the newest version available."
                    alert.runModal()
                }
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// Fetches the release list and records the result.  Returns the release
    /// to offer, or nil when the running version is already the newest.
    @discardableResult
    func check() async throws -> Release? {
        guard !isChecking else { return available }
        guard let current = currentVersion else { return nil }
        isChecking = true
        defer { isChecking = false }

        let feed = UserDefaults.standard.string(forKey: Self.feedOverrideKey).flatMap(URL.init(string:))
            ?? Self.releasesURL
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        let releases = try JSONDecoder().decode([Release].self, from: data)

        available = Self.newestUpdate(in: releases, over: current)
        lastChecked = Date()
        UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckedKey)
        return available
    }

    private func presentUpdate(_ release: Release) {
        let name = release.version?.description ?? release.tagName
        let signed = AppUpdateInstaller.signedZip(in: release) != nil
        let replaceable = AppUpdateInstaller.canReplace(Bundle.main.bundleURL)
        let installable = signed && replaceable

        let alert = NSAlert()
        alert.messageText = "DSPi Console \(name) is available"
        var text = "You have version \(currentVersion?.description ?? GeneralSettingsTab.appVersion). "
            + "The new version includes matching DSPi firmware, which it will offer to install when your device is connected."
        if signed && !replaceable {
            text += "\n\nTo let DSPi Console update itself, move it to the Applications folder with Finder."
        }
        alert.informativeText = text
        alert.addButton(withTitle: installable ? "Install and Relaunch" : "View Release")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        if installable {
            alert.accessoryView = releaseNotesLink(release.htmlURL)
        }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if installable {
                install(release)
            } else {
                NSWorkspace.shared.open(release.htmlURL)
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.tagName, forKey: Self.skippedTagKey)
        default:
            break
        }
    }

    private func releaseNotesLink(_ url: URL) -> NSView {
        let link = NSTextField(labelWithAttributedString: NSAttributedString(
            string: "View release notes",
            attributes: [.link: url, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]))
        // Links in a label only respond when it is selectable.
        link.isSelectable = true
        link.allowsEditingTextAttributes = true
        link.sizeToFit()
        return link
    }

    // MARK: - Installing

    func install(_ release: Release) {
        guard !isInstalling,
              let version = release.version,
              let assets = AppUpdateInstaller.signedZip(in: release),
              let bundleID = Bundle.main.bundleIdentifier
        else { return }
        let app = Bundle.main.bundleURL
        installState = .downloading(0)
        showProgressPanel()

        installTask = Task {
            var work: URL?
            do {
                guard AppUpdateInstaller.canReplace(app) else { throw AppUpdateInstaller.Failure.notWritable }
                // Same volume as the app, so the final swap is a rename.
                let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                      appropriateFor: app, create: true)
                work = dir
                let zip = dir.appendingPathComponent(assets.zip.name)
                let sig = dir.appendingPathComponent(assets.signature.name)
                try await AppUpdateInstaller.download(assets.signature.url, to: sig) { _ in }
                try await AppUpdateInstaller.download(assets.zip.url, to: zip, started: { task in
                    Task { @MainActor in AppUpdateChecker.shared.downloadTask = task }
                }, progress: { fraction in
                    Task { @MainActor in
                        if case .downloading = AppUpdateChecker.shared.installState {
                            AppUpdateChecker.shared.installState = .downloading(fraction)
                        }
                    }
                })
                downloadTask = nil
                try Task.checkCancellation()

                installState = .verifying
                let staged = try await Task.detached {
                    let data = try Data(contentsOf: zip, options: .mappedIfSafe)
                    let signature = try String(contentsOf: sig, encoding: .utf8)
                    guard AppUpdateInstaller.signatureIsValid(data, signatureText: signature) else {
                        throw AppUpdateInstaller.Failure.badSignature
                    }
                    let unpacked = try AppUpdateInstaller.unpack(zip, into: dir.appendingPathComponent("unpacked"))
                    try AppUpdateInstaller.validate(unpacked, bundleIdentifier: bundleID, version: version)
                    // Belt and braces: an app carrying the quarantine flag
                    // would be translocated and assessed by Gatekeeper.
                    AppUpdateInstaller.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", unpacked.path])
                    return unpacked
                }.value
                try Task.checkCancellation()

                try AppUpdateInstaller.launchHelper(pid: ProcessInfo.processInfo.processIdentifier,
                                                    app: app, staged: staged, work: dir, relaunch: true)
                pendingWork = dir
                installState = .waitingForQuit
                NSApp.terminate(nil)
            } catch {
                downloadTask = nil
                if let work { try? FileManager.default.removeItem(at: work) }
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    installState = .idle
                    closeProgressPanel()
                } else {
                    installState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelInstall() {
        guard case .downloading = installState else { return }
        installTask?.cancel()
        downloadTask?.cancel()
    }

    /// Called when the user cancels the quit the installer asked for.  The
    /// helper keeps waiting and installs on the next quit, but should not
    /// reopen the app after an ordinary quit.
    func quitCancelled() {
        guard installState == .waitingForQuit, let work = pendingWork else { return }
        try? FileManager.default.removeItem(at: work.appendingPathComponent(AppUpdateInstaller.relaunchMarker))
        closeProgressPanel()
    }

    private func showProgressPanel() {
        if progressPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                                styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = "Software Update"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: UpdateProgressView(checker: self))
            progressPanel = panel
        }
        progressPanel?.center()
        progressPanel?.makeKeyAndOrderFront(nil)
    }

    func closeProgressPanel() {
        progressPanel?.orderOut(nil)
        if case .failed = installState { installState = .idle }
    }
}

/// Contents of the install progress panel.
private struct UpdateProgressView: View {
    @ObservedObject var checker: AppUpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch checker.installState {
            case .downloading(let fraction):
                Text("Downloading update...")
                ProgressView(value: fraction)
                buttons { Button("Cancel") { checker.cancelInstall() } }
            case .verifying, .idle:
                Text("Verifying update...")
                ProgressView().progressViewStyle(.linear)
                buttons { EmptyView() }
            case .waitingForQuit:
                Text("The update will be installed when DSPi Console quits.")
                buttons { Button("Close") { checker.closeProgressPanel() } }
            case .failed(let message):
                Text("The update couldn't be installed.").font(.headline)
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                buttons { Button("Close") { checker.closeProgressPanel() } }
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Spacer()
            content()
        }
    }
}
