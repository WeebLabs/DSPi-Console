import Foundation

/// A firmware version as three plain numbers.
///
/// Console and firmware ship as a matched pair carrying the same version, so
/// the app's own `MARKETING_VERSION` is also the version it expects a connected
/// device to report.  See CLAUDE.md > Releases, and the firmware repo's
/// `Documentation/Features/firmware_versioning_spec.md` for the wire encoding.
struct FirmwareVersion: Comparable, Hashable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses "1.1.7".  Tolerates a trailing suffix ("1.1.6-beta2") so builds
    /// predating the point-release policy still compare sensibly, and a missing
    /// patch ("1.2" becomes 1.2.0).  Returns nil when there is no leading
    /// number at all.
    init?(_ string: String) {
        let numeric = string.prefix { $0.isNumber || $0 == "." }
        let fields = numeric.split(separator: ".").map { Int($0) }
        guard let first = fields.first, let major = first else { return nil }
        self.major = major
        self.minor = fields.count > 1 ? (fields[1] ?? 0) : 0
        self.patch = fields.count > 2 ? (fields[2] ?? 0) : 0
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (a: FirmwareVersion, b: FirmwareVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

extension FirmwareVersion {
    /// The firmware version this Console build expects a device to be running,
    /// read from `CFBundleShortVersionString` (driven by `MARKETING_VERSION`).
    ///
    /// Derived rather than hand-maintained on purpose: bumping the app version
    /// is the one step of a release nobody forgets, so hanging the expected
    /// device version off it removes a way for the two to drift apart.  nil
    /// only if the bundle version is unparseable, in which case callers must
    /// treat the expectation as unknown rather than guessing.
    static let expected: FirmwareVersion? =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap(FirmwareVersion.init)
}

/// How a connected device's firmware compares with what this Console expects.
enum FirmwareMatch {
    /// Device is running exactly the expected version.
    case match
    /// Device is behind this Console; the bundled images are an upgrade.
    case deviceOlder
    /// Device is ahead of this Console, e.g. the user reverted to an older
    /// app.  Installing the bundled images would be a downgrade, so the UI
    /// must say so rather than calling it an update.
    case deviceNewer
}
