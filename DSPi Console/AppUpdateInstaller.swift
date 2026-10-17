import CryptoKit
import Foundation
import Security

/// Downloads, verifies and installs a DSPi Console release in place.
///
/// No notarization is involved: files this app downloads are not quarantined
/// (LSFileQuarantineEnabled defaults to off), so Gatekeeper does not assess
/// the new copy.  Trust comes from an Ed25519 signature over the release zip
/// instead, made with a key only the release machine holds
/// (Tools/UpdateSigning/update-signing.swift).
///
/// The bundle is swapped by a helper script after this process exits, never
/// while it runs: a quit can be cancelled at the unsaved-preset prompt, and a
/// live app reading resources (bundled firmware included) from a bundle that
/// had already been replaced would mix two versions.
enum AppUpdateInstaller {
    /// Public half of the release signing key.
    static let publicKey = Data(base64Encoded: "1PVzcgAEI2T4cMy+DWeLEQaxdXRywAg+s+MbYNlffWU=")!

    /// Present in the work directory while the helper should reopen the app
    /// once installed.  Removed when the user cancels the quit, so a later
    /// ordinary quit installs without relaunching.
    static let relaunchMarker = "relaunch"

    enum Failure: LocalizedError {
        case notWritable
        case noSignedAsset
        case download
        case badSignature
        case unpack
        case wrongApp(String)
        case invalidCodeSignature
        case helper

        var errorDescription: String? {
            switch self {
            case .notWritable:
                return "DSPi Console can't replace itself where it is.  Move it to the Applications folder with Finder, then try again."
            case .noSignedAsset:
                return "This release has no signed download, so it can't be installed automatically."
            case .download:
                return "The download failed."
            case .badSignature:
                return "The download's signature doesn't match, so it was discarded."
            case .unpack:
                return "The download couldn't be unpacked."
            case .wrongApp(let detail):
                return "The download isn't the expected DSPi Console (\(detail))."
            case .invalidCodeSignature:
                return "The downloaded app's code signature is invalid."
            case .helper:
                return "The installer couldn't be started."
            }
        }
    }

    // MARK: - Checks

    /// The release zip and its detached signature, matched by name.  GitHub
    /// rewrites spaces in asset names to dots, the same way for both files.
    static func signedZip(in release: AppUpdateChecker.Release) -> (zip: AppUpdateChecker.Asset, signature: AppUpdateChecker.Asset)? {
        guard let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let sig = release.assets.first(where: { $0.name == zip.name + ".sig" })
        else { return nil }
        return (zip, sig)
    }

    /// Whether this copy can be swapped out.  Fails for a translocated app
    /// (run from Downloads without being moved in Finder, which macOS runs
    /// from a read-only mount), a disk image, or a folder the user can't write.
    static func canReplace(_ bundle: URL) -> Bool {
        let fm = FileManager.default
        return fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
            && fm.isWritableFile(atPath: bundle.path)
    }

    static func signatureIsValid(_ data: Data, signatureText: String, publicKey: Data = publicKey) -> Bool {
        guard let signature = Data(base64Encoded: signatureText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        else { return false }
        return key.isValidSignature(signature, for: data)
    }

    /// Unpacks with ditto, which keeps the code signature and extended
    /// attributes intact, and returns the one app bundle inside.
    static func unpack(_ zip: URL, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path]) == 0 else { throw Failure.unpack }
        let apps = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1 else { throw Failure.unpack }
        return apps[0]
    }

    /// Checks the unpacked app is this app, at the version the release claims,
    /// with an intact code signature.
    static func validate(_ app: URL, bundleIdentifier: String, version: FirmwareVersion) throws {
        guard let info = Bundle(url: app)?.infoDictionary else { throw Failure.wrongApp("no Info.plist") }
        let identifier = info["CFBundleIdentifier"] as? String ?? "?"
        guard identifier == bundleIdentifier else { throw Failure.wrongApp(identifier) }
        let shortVersion = info["CFBundleShortVersionString"] as? String ?? "?"
        guard FirmwareVersion(shortVersion) == version else { throw Failure.wrongApp("version \(shortVersion)") }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure.invalidCodeSignature
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw Failure.invalidCodeSignature }
    }

    // MARK: - Install

    /// Waits for the app to exit, swaps the bundles, restores the old one if
    /// the swap fails, and reopens the app if the marker is still present.
    static let helperScript = """
    #!/bin/sh
    pid="$1"; app="$2"; new="$3"; work="$4"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    if mv "$app" "$work/previous.app"; then
        mv "$new" "$app" || mv "$work/previous.app" "$app"
    fi
    if [ -e "$work/\(relaunchMarker)" ]; then open "$app"; fi
    rm -rf "$work"
    """

    /// Starts the helper that installs `staged` over `app` once `pid` exits.
    static func launchHelper(pid: Int32, app: URL, staged: URL, work: URL, relaunch: Bool) throws {
        let script = work.appendingPathComponent("install.sh")
        try helperScript.write(to: script, atomically: true, encoding: .utf8)
        if relaunch {
            FileManager.default.createFile(atPath: work.appendingPathComponent(relaunchMarker).path, contents: nil)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(pid), app.path, staged.path, work.path]
        do { try process.run() } catch { throw Failure.helper }
    }

    /// Downloads to `destination`, reporting progress from 0 to 1.  `started`
    /// hands over the task so the caller can cancel it.
    static func download(_ url: URL, to destination: URL,
                         started: (URLSessionTask) -> Void = { _ in },
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                guard let location, error == nil,
                      (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else {
                    continuation.resume(throwing: error ?? Failure.download)
                    return
                }
                do {
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            started(task)
            task.resume()
        }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
