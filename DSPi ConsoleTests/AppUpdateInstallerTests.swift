import CryptoKit
import XCTest
@testable import DSPi_Console

/// The in-place updater: signature check, unpack and validation of a real
/// (ad-hoc signed) bundle, and the helper script's bundle swap.
final class AppUpdateInstallerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppUpdateInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func asset(_ name: String) -> AppUpdateChecker.Asset {
        AppUpdateChecker.Asset(name: name, url: URL(string: "https://example.invalid/\(name)")!)
    }

    // MARK: Assets and signatures

    func testSignedZipNeedsAMatchingSignatureAsset() {
        let url = URL(string: "https://github.com/WeebLabs/DSPi-Console/releases/tag/v1.1.7")!
        let signed = AppUpdateChecker.Release(tagName: "v1.1.7", htmlURL: url, draft: false,
                                              assets: [asset("DSPi.Console.v1.1.7.zip.sig"), asset("DSPi.Console.v1.1.7.zip")])
        XCTAssertEqual(AppUpdateInstaller.signedZip(in: signed)?.zip.name, "DSPi.Console.v1.1.7.zip")
        XCTAssertEqual(AppUpdateInstaller.signedZip(in: signed)?.signature.name, "DSPi.Console.v1.1.7.zip.sig")

        let unsigned = AppUpdateChecker.Release(tagName: "v1.1.6-beta4", htmlURL: url, draft: false,
                                                assets: [asset("DSPi.Console.v1.1.6-beta4.zip")])
        XCTAssertNil(AppUpdateInstaller.signedZip(in: unsigned))
    }

    func testEmbeddedPublicKeyIsAnEd25519Key() {
        XCTAssertNotNil(try? Curve25519.Signing.PublicKey(rawRepresentation: AppUpdateInstaller.publicKey))
    }

    func testSignatureAcceptsOnlyTheSignedBytesAndKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("release zip".utf8)
        let signature = try key.signature(for: data).base64EncodedString() + "\n"
        let publicKey = key.publicKey.rawRepresentation

        XCTAssertTrue(AppUpdateInstaller.signatureIsValid(data, signatureText: signature, publicKey: publicKey))
        XCTAssertFalse(AppUpdateInstaller.signatureIsValid(data + Data([0]), signatureText: signature, publicKey: publicKey))
        XCTAssertFalse(AppUpdateInstaller.signatureIsValid(data, signatureText: signature,
                                                           publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        XCTAssertFalse(AppUpdateInstaller.signatureIsValid(data, signatureText: "not base64", publicKey: publicKey))
        // The real key must not accept a signature from some other key.
        XCTAssertFalse(AppUpdateInstaller.signatureIsValid(data, signatureText: signature))
    }

    // MARK: Unpack and validate

    /// Builds an ad-hoc signed bundle like a release, zipped the way GitHub
    /// release zips are, and returns the zip.
    private func makeReleaseZip(identifier: String = "WeebLabs.DSPi-Console", version: String = "1.1.7",
                                tamper: Bool = false) throws -> URL {
        let build = dir.appendingPathComponent(UUID().uuidString)
        let app = build.appendingPathComponent("DSPi Console.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "DSPi Console",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: contents.appendingPathComponent("MacOS/DSPi Console"))
        try Data("firmware".utf8).write(to: contents.appendingPathComponent("Resources/firmware.uf2"))
        XCTAssertEqual(AppUpdateInstaller.run("/usr/bin/codesign", ["--force", "--deep", "-s", "-", app.path]), 0)
        if tamper {
            try Data("other firmware".utf8).write(to: contents.appendingPathComponent("Resources/firmware.uf2"))
        }
        let zip = build.appendingPathComponent("release.zip")
        XCTAssertEqual(AppUpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path]), 0)
        return zip
    }

    func testUnpacksAndAcceptsAMatchingSignedApp() throws {
        let app = try AppUpdateInstaller.unpack(try makeReleaseZip(), into: dir.appendingPathComponent("unpacked"))
        XCTAssertEqual(app.lastPathComponent, "DSPi Console.app")
        XCTAssertNoThrow(try AppUpdateInstaller.validate(app, bundleIdentifier: "WeebLabs.DSPi-Console",
                                                         version: FirmwareVersion(1, 1, 7)))
    }

    func testRejectsAnotherAppOrAnotherVersion() throws {
        let app = try AppUpdateInstaller.unpack(try makeReleaseZip(identifier: "com.example.Other"),
                                                into: dir.appendingPathComponent("unpacked"))
        XCTAssertThrowsError(try AppUpdateInstaller.validate(app, bundleIdentifier: "WeebLabs.DSPi-Console",
                                                             version: FirmwareVersion(1, 1, 7)))
        let app2 = try AppUpdateInstaller.unpack(try makeReleaseZip(version: "1.1.7-beta1"),
                                                 into: dir.appendingPathComponent("unpacked2"))
        XCTAssertThrowsError(try AppUpdateInstaller.validate(app2, bundleIdentifier: "WeebLabs.DSPi-Console",
                                                             version: FirmwareVersion(1, 1, 7)))
    }

    func testRejectsABundleModifiedAfterSigning() throws {
        let app = try AppUpdateInstaller.unpack(try makeReleaseZip(tamper: true), into: dir.appendingPathComponent("unpacked"))
        XCTAssertThrowsError(try AppUpdateInstaller.validate(app, bundleIdentifier: "WeebLabs.DSPi-Console",
                                                             version: FirmwareVersion(1, 1, 7))) { error in
            guard case AppUpdateInstaller.Failure.invalidCodeSignature = error else {
                return XCTFail("expected invalidCodeSignature, got \(error)")
            }
        }
    }

    // MARK: Helper script

    /// Runs the helper to completion against a process that exits shortly,
    /// so the wait loop is exercised too.  Relaunch is never requested here.
    private func runHelper(app: URL, staged: URL, work: URL) throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.5"]
        try sleeper.run()

        let script = dir.appendingPathComponent("install.sh")
        try AppUpdateInstaller.helperScript.write(to: script, atomically: true, encoding: .utf8)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [script.path, String(sleeper.processIdentifier), app.path, staged.path, work.path]
        try helper.run()
        helper.waitUntilExit()
        XCTAssertFalse(sleeper.isRunning, "helper must wait for the app to exit")
    }

    private func makeBundle(_ url: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: url.appendingPathComponent("marker"))
    }

    private func marker(_ app: URL) -> String? {
        (try? Data(contentsOf: app.appendingPathComponent("marker"))).map { String(decoding: $0, as: UTF8.self) }
    }

    func testHelperSwapsTheBundleAfterExitAndCleansUp() throws {
        let app = dir.appendingPathComponent("Applications/DSPi Console.app")
        let work = dir.appendingPathComponent("work")
        let staged = work.appendingPathComponent("unpacked/DSPi Console.app")
        try makeBundle(app, marker: "old")
        try makeBundle(staged, marker: "new")

        try runHelper(app: app, staged: staged, work: work)
        XCTAssertEqual(marker(app), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testHelperRestoresTheOldBundleWhenTheSwapFails() throws {
        let app = dir.appendingPathComponent("Applications/DSPi Console.app")
        let work = dir.appendingPathComponent("work")
        try makeBundle(app, marker: "old")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        try runHelper(app: app, staged: work.appendingPathComponent("missing.app"), work: work)
        XCTAssertEqual(marker(app), "old")
    }

    func testCannotReplaceFromAReadOnlyLocation() throws {
        let parent = dir.appendingPathComponent("ro")
        let app = parent.appendingPathComponent("DSPi Console.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertTrue(AppUpdateInstaller.canReplace(app))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        XCTAssertFalse(AppUpdateInstaller.canReplace(app))
    }
}
