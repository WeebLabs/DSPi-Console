import Foundation

/// A firmware version as three plain numbers plus a pre-release ordinal.
///
/// Console and firmware ship as a matched pair carrying the same version, so
/// the app's own `MARKETING_VERSION` is also the version it expects a connected
/// device to report.  See CLAUDE.md > Releases, and the firmware repo's
/// `Documentation/Features/firmware_versioning_spec.md` for the wire encoding.
struct FirmwareVersion: Comparable, Hashable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// 0 = final release, 1...255 = beta N.  Betas of a patch share that patch
    /// number, so this is the only field telling two of them apart.
    let beta: Int

    init(_ major: Int, _ minor: Int, _ patch: Int, _ beta: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.beta = beta
    }

    /// Parses "1.1.7" and "1.1.6-beta2" (the tag spelling, which is also what
    /// `MARKETING_VERSION` carries during a beta run).  A missing patch reads
    /// as 0 ("1.2" becomes 1.2.0) and an unrecognised suffix as a final
    /// release, which is what builds predating the ordinal were.  Returns nil
    /// when there is no leading number at all.
    init?(_ string: String) {
        let numeric = string.prefix { $0.isNumber || $0 == "." }
        let fields = numeric.split(separator: ".").map { Int($0) }
        guard let first = fields.first, let major = first else { return nil }
        self.major = major
        self.minor = fields.count > 1 ? (fields[1] ?? 0) : 0
        self.patch = fields.count > 2 ? (fields[2] ?? 0) : 0
        let suffix = string.dropFirst(numeric.count).lowercased()
        let trimmed = suffix.drop { $0 == "-" || $0 == "." || $0 == " " }
        self.beta = trimmed.hasPrefix("beta")
            ? (Int(trimmed.dropFirst(4).prefix { $0.isNumber }) ?? 0) : 0
    }

    var description: String {
        beta == 0 ? "\(major).\(minor).\(patch)"
                  : "\(major).\(minor).\(patch) beta \(beta)"
    }

    /// Tag spelling, for anything that has to match a GitHub tag or a `.uf2`
    /// filename rather than read as prose.
    var tagSuffix: String {
        beta == 0 ? "\(major).\(minor).\(patch)"
                  : "\(major).\(minor).\(patch)-beta\(beta)"
    }

    /// Sort key for the ordinal.  Final is encoded as 0 but outranks every beta
    /// of its patch, so it cannot be compared as the plain number it is.  Watch
    /// the default argument: `FirmwareVersion(1, 1, 7)` means 1.1.7 final, which
    /// sorts *above* 1.1.7 beta 3, not below it.
    private var betaRank: Int { beta == 0 ? 256 : beta }

    static func < (a: FirmwareVersion, b: FirmwareVersion) -> Bool {
        (a.major, a.minor, a.patch, a.betaRank) < (b.major, b.minor, b.patch, b.betaRank)
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
