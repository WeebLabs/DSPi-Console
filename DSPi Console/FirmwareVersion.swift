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
    /// 0 = final release, 1...255 = beta N, or `earlyBeta` for a beta built
    /// before the ordinal existed.  Betas of a patch share that patch number,
    /// so this is the only field telling two of them apart.
    let beta: Int

    /// A beta that could not say which one it is.  1.1.6 beta 1 and beta 2
    /// predate the ordinal on the wire, so they answer the platform request as
    /// plain 1.1.6.  Sorts below every numbered beta, since whichever it was,
    /// it came before the first build that reports its number.
    static let earlyBeta = -1

    /// The first release whose every build, betas included, reports the beta
    /// ordinal: it arrived part way through the 1.1.6 betas.  A reply without
    /// it that claims this version or later can only be one of those early
    /// betas, never a final release.
    static let firstWithOrdinal = (major: 1, minor: 1, patch: 6)

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
        switch beta {
        case 0:         return "\(major).\(minor).\(patch)"
        case Self.earlyBeta: return "\(major).\(minor).\(patch) early beta"
        default:        return "\(major).\(minor).\(patch) beta \(beta)"
        }
    }

    /// Tag spelling, for anything that has to match a GitHub tag or a `.uf2`
    /// filename rather than read as prose.  nil for an early beta, which names
    /// no single tag.
    var tagSuffix: String? {
        switch beta {
        case 0:         return "\(major).\(minor).\(patch)"
        case Self.earlyBeta: return nil
        default:        return "\(major).\(minor).\(patch)-beta\(beta)"
        }
    }

    /// Sort key for the ordinal.  Final is encoded as 0 but outranks every beta
    /// of its patch, so it cannot be compared as the plain number it is.  Watch
    /// the default argument: `FirmwareVersion(1, 1, 7)` means 1.1.7 final, which
    /// sorts *above* 1.1.7 beta 3, not below it.  `earlyBeta` (-1) needs no
    /// case of its own: it already sorts below beta 1.
    private var betaRank: Int { beta == 0 ? 256 : beta }

    static func < (a: FirmwareVersion, b: FirmwareVersion) -> Bool {
        (a.major, a.minor, a.patch, a.betaRank) < (b.major, b.minor, b.patch, b.betaRank)
    }
}

extension FirmwareVersion {
    /// Decodes a REQ_GET_PLATFORM reply into its platform byte and version.
    ///
    /// The request asks for 7 bytes.  Bytes 4-5 are full-width minor and patch,
    /// because the legacy byte 2 packs them into a nibble each and so caps both
    /// at 15; byte 6 is the beta ordinal.  Older firmware answers short with 6
    /// or 4 bytes, so fall back to the nibbles, never mixing the two decodes.
    ///
    /// A short reply is a final release only below `firstWithOrdinal`.  At or
    /// above it the ordinal has always been sent, except by the betas that came
    /// before it, so a short reply there is one of those.  Returns nil for a
    /// reply too short to hold a version.
    static func fromPlatformReply(_ bytes: [UInt8]) -> (platform: UInt8, version: FirmwareVersion)? {
        guard bytes.count >= 4 else { return nil }
        let major = Int(bytes[1])
        let minor = bytes.count >= 6 ? Int(bytes[4]) : Int(bytes[2] >> 4)
        let patch = bytes.count >= 6 ? Int(bytes[5]) : Int(bytes[2] & 0x0F)
        let beta: Int
        if bytes.count >= 7 {
            beta = Int(bytes[6])
        } else if (major, minor, patch) >= (firstWithOrdinal.major, firstWithOrdinal.minor, firstWithOrdinal.patch) {
            beta = earlyBeta
        } else {
            beta = 0
        }
        return (bytes[0], FirmwareVersion(major, minor, patch, beta))
    }

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
