import Foundation

enum FilterType: Int, CaseIterable, Identifiable {
    // PEQ types.  Raw values MUST match the firmware FilterType enum (config.h)
    // exactly - they are sent verbatim as the type byte in REQ_SET_EQ_PARAM and
    // persisted in flash.  The value space is partitioned (firmware "FilterType
    // value-space contract"): 0..7 core PEQ, 8..10 first-order PEQ, 11..31
    // reserved for future PEQ, 32..63 crossover.
    case flat = 0
    case peaking = 1
    case lowShelf = 2
    case highShelf = 3
    case lowPass = 4
    case highPass = 5
    case notch = 6
    case allPass = 7            // 2nd-order RBJ all-pass

    // First-order PEQ types (wire format V13/V14).  Genuine 1st-order sections
    // (b2 = a2 = 0).  All-pass: flat magnitude, phase 0 -> -180 (-90 at fc),
    // freq only.  Shelves: gentle 6 dB/oct, monotonic (no Q), freq + gain.
    case allPass1 = 8          // 1st-order all-pass (wire V13+)
    case lowShelf1 = 9         // 1st-order low shelf  (wire V14+)
    case highShelf1 = 10       // 1st-order high shelf (wire V14+)

    // 11..31 reserved for future PEQ types.

    // Crossover types (32..63, wire format V13+).  Each value encodes
    // (family, order, LP/HP).  Renumbered from the old 8..39 range on
    // 2026-06-17 to open a contiguous PEQ block below FILTER_XOVER_FIRST=32.
    case lr2_lp = 32
    case lr2_hp = 33
    case lr4_lp = 34
    case lr4_hp = 35
    case lr6_lp = 36
    case lr6_hp = 37
    case lr8_lp = 38
    case lr8_hp = 39
    case bw1_lp = 40
    case bw1_hp = 41
    case bw2_lp = 42
    case bw2_hp = 43
    case bw3_lp = 44
    case bw3_hp = 45
    case bw4_lp = 46
    case bw4_hp = 47
    case bw5_lp = 48
    case bw5_hp = 49
    case bw6_lp = 50
    case bw6_hp = 51
    case bw7_lp = 52
    case bw7_hp = 53
    case bw8_lp = 54
    case bw8_hp = 55
    case bes2_lp = 56
    case bes2_hp = 57
    case bes4_lp = 58
    case bes4_hp = 59
    case bes6_lp = 60
    case bes6_hp = 61
    case bes8_lp = 62
    case bes8_hp = 63

    var id: Int { rawValue }

    /// True if this is a crossover filter type (LR / BW / BES family).
    /// Mirrors the firmware FILTER_XOVER_FIRST..FILTER_XOVER_LAST range.
    var isCrossover: Bool { rawValue >= 32 && rawValue <= 63 }

    /// True if this is one of the first-order PEQ sections (all-pass / shelves).
    var isFirstOrderPEQ: Bool {
        switch self {
        case .allPass1, .lowShelf1, .highShelf1: return true
        default: return false
        }
    }

    /// Order/phase label for the shelf & all-pass variants - used as the
    /// submenu child title on the PEQ type picker, where the shape name is the
    /// parent menu (e.g. "Low Shelf" ▸ "6 dB/oct" / "12 dB/oct").  Spells out
    /// "/oct" here since the submenu has room; the compact selected-face label
    /// (FilterType.name) drops it.  nil for shapes with no order choice.
    var orderLabel: String? {
        switch self {
        case .lowShelf1, .highShelf1: return "6 dB/oct"
        case .lowShelf, .highShelf:   return "12 dB/oct"
        case .allPass1:               return "180°"
        case .allPass:                return "360°"
        default:                      return nil
        }
    }

    var name: String {
        switch self {
        case .flat: return "Off"
        case .peaking: return "Peaking"
        case .lowShelf: return "Low Shelf (12dB)"
        case .highShelf: return "High Shelf (12dB)"
        case .lowPass: return "High Cut"
        case .highPass: return "Low Cut"
        case .notch: return "Notch"
        case .allPass: return "All Pass (360°)"
        case .allPass1: return "All Pass (180°)"
        case .lowShelf1: return "Low Shelf (6dB)"
        case .highShelf1: return "High Shelf (6dB)"
        case .lr2_lp: return "LR2 Low Pass"
        case .lr2_hp: return "LR2 High Pass"
        case .lr4_lp: return "LR4 Low Pass"
        case .lr4_hp: return "LR4 High Pass"
        case .lr6_lp: return "LR6 Low Pass"
        case .lr6_hp: return "LR6 High Pass"
        case .lr8_lp: return "LR8 Low Pass"
        case .lr8_hp: return "LR8 High Pass"
        case .bw1_lp: return "BW1 Low Pass"
        case .bw1_hp: return "BW1 High Pass"
        case .bw2_lp: return "BW2 Low Pass"
        case .bw2_hp: return "BW2 High Pass"
        case .bw3_lp: return "BW3 Low Pass"
        case .bw3_hp: return "BW3 High Pass"
        case .bw4_lp: return "BW4 Low Pass"
        case .bw4_hp: return "BW4 High Pass"
        case .bw5_lp: return "BW5 Low Pass"
        case .bw5_hp: return "BW5 High Pass"
        case .bw6_lp: return "BW6 Low Pass"
        case .bw6_hp: return "BW6 High Pass"
        case .bw7_lp: return "BW7 Low Pass"
        case .bw7_hp: return "BW7 High Pass"
        case .bw8_lp: return "BW8 Low Pass"
        case .bw8_hp: return "BW8 High Pass"
        case .bes2_lp: return "BES2 Low Pass"
        case .bes2_hp: return "BES2 High Pass"
        case .bes4_lp: return "BES4 Low Pass"
        case .bes4_hp: return "BES4 High Pass"
        case .bes6_lp: return "BES6 Low Pass"
        case .bes6_hp: return "BES6 High Pass"
        case .bes8_lp: return "BES8 Low Pass"
        case .bes8_hp: return "BES8 High Pass"
        }
    }

    /// Short label suitable for compact UI ("LR4 LP").
    var shortLabel: String {
        switch self {
        case .flat: return "—"
        case .peaking: return "PK"
        case .lowShelf: return "LS"
        case .highShelf: return "HS"
        case .lowPass: return "LP"
        case .highPass: return "HP"
        case .notch: return "NT"
        case .allPass: return "AP"
        case .allPass1: return "AP1"
        case .lowShelf1: return "LS1"
        case .highShelf1: return "HS1"
        case .lr2_lp: return "LR2 LP"
        case .lr2_hp: return "LR2 HP"
        case .lr4_lp: return "LR4 LP"
        case .lr4_hp: return "LR4 HP"
        case .lr6_lp: return "LR6 LP"
        case .lr6_hp: return "LR6 HP"
        case .lr8_lp: return "LR8 LP"
        case .lr8_hp: return "LR8 HP"
        case .bw1_lp: return "BW1 LP"
        case .bw1_hp: return "BW1 HP"
        case .bw2_lp: return "BW2 LP"
        case .bw2_hp: return "BW2 HP"
        case .bw3_lp: return "BW3 LP"
        case .bw3_hp: return "BW3 HP"
        case .bw4_lp: return "BW4 LP"
        case .bw4_hp: return "BW4 HP"
        case .bw5_lp: return "BW5 LP"
        case .bw5_hp: return "BW5 HP"
        case .bw6_lp: return "BW6 LP"
        case .bw6_hp: return "BW6 HP"
        case .bw7_lp: return "BW7 LP"
        case .bw7_hp: return "BW7 HP"
        case .bw8_lp: return "BW8 LP"
        case .bw8_hp: return "BW8 HP"
        case .bes2_lp: return "BES2 LP"
        case .bes2_hp: return "BES2 HP"
        case .bes4_lp: return "BES4 LP"
        case .bes4_hp: return "BES4 HP"
        case .bes6_lp: return "BES6 LP"
        case .bes6_hp: return "BES6 HP"
        case .bes8_lp: return "BES8 LP"
        case .bes8_hp: return "BES8 HP"
        }
    }

    /// Crossover family decomposition.  Returns nil for PEQ types.
    var crossoverFamily: CrossoverFamily? {
        switch self {
        case .lr2_lp, .lr2_hp, .lr4_lp, .lr4_hp, .lr6_lp, .lr6_hp, .lr8_lp, .lr8_hp: return .linkwitzRiley
        case .bw1_lp, .bw1_hp, .bw2_lp, .bw2_hp, .bw3_lp, .bw3_hp, .bw4_lp, .bw4_hp,
             .bw5_lp, .bw5_hp, .bw6_lp, .bw6_hp, .bw7_lp, .bw7_hp, .bw8_lp, .bw8_hp:
            return .butterworth
        case .bes2_lp, .bes2_hp, .bes4_lp, .bes4_hp, .bes6_lp, .bes6_hp, .bes8_lp, .bes8_hp:
            return .bessel
        default: return nil
        }
    }

    /// True for low-pass crossover types; nil for non-crossover.
    var crossoverIsLowPass: Bool? {
        guard isCrossover else { return nil }
        return rawValue % 2 == 0
    }

    /// Order (1..8) for crossover types; 0 for non-crossover.
    var crossoverOrder: Int {
        switch self {
        case .lr2_lp, .lr2_hp: return 2
        case .lr4_lp, .lr4_hp: return 4
        case .lr6_lp, .lr6_hp: return 6
        case .lr8_lp, .lr8_hp: return 8
        case .bw1_lp, .bw1_hp: return 1
        case .bw2_lp, .bw2_hp: return 2
        case .bw3_lp, .bw3_hp: return 3
        case .bw4_lp, .bw4_hp: return 4
        case .bw5_lp, .bw5_hp: return 5
        case .bw6_lp, .bw6_hp: return 6
        case .bw7_lp, .bw7_hp: return 7
        case .bw8_lp, .bw8_hp: return 8
        case .bes2_lp, .bes2_hp: return 2
        case .bes4_lp, .bes4_hp: return 4
        case .bes6_lp, .bes6_hp: return 6
        case .bes8_lp, .bes8_hp: return 8
        default: return 0
        }
    }

    /// Theoretical attenuation slope, dB/octave (= 6 × order).
    var slopeDBPerOctave: Int { crossoverOrder * 6 }
}

enum CrossoverFamily: Int, CaseIterable, Identifiable {
    case linkwitzRiley
    case butterworth
    case bessel

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .linkwitzRiley: return "Linkwitz-Riley"
        case .butterworth: return "Butterworth"
        case .bessel: return "Bessel"
        }
    }

    var shortName: String {
        switch self {
        case .linkwitzRiley: return "LR"
        case .butterworth: return "BW"
        case .bessel: return "BES"
        }
    }

    /// Brief description of the family's character for tooltips.
    var description: String {
        switch self {
        case .linkwitzRiley: return "Allpass sum at fc. The de-facto crossover standard."
        case .butterworth: return "Maximally flat passband. Standard analog filter."
        case .bessel: return "Approximately linear phase. Smooth group delay."
        }
    }

    /// Available orders for this family.
    var availableOrders: [Int] {
        switch self {
        case .linkwitzRiley: return [2, 4, 6, 8]
        case .butterworth: return [1, 2, 3, 4, 5, 6, 7, 8]
        case .bessel: return [2, 4, 6, 8]
        }
    }

    /// Resolve to a concrete FilterType from order + low/high pass.
    func filterType(order: Int, lowPass: Bool) -> FilterType? {
        switch (self, order, lowPass) {
        case (.linkwitzRiley, 2, true):  return .lr2_lp
        case (.linkwitzRiley, 2, false): return .lr2_hp
        case (.linkwitzRiley, 4, true):  return .lr4_lp
        case (.linkwitzRiley, 4, false): return .lr4_hp
        case (.linkwitzRiley, 6, true):  return .lr6_lp
        case (.linkwitzRiley, 6, false): return .lr6_hp
        case (.linkwitzRiley, 8, true):  return .lr8_lp
        case (.linkwitzRiley, 8, false): return .lr8_hp
        case (.butterworth, 1, true):    return .bw1_lp
        case (.butterworth, 1, false):   return .bw1_hp
        case (.butterworth, 2, true):    return .bw2_lp
        case (.butterworth, 2, false):   return .bw2_hp
        case (.butterworth, 3, true):    return .bw3_lp
        case (.butterworth, 3, false):   return .bw3_hp
        case (.butterworth, 4, true):    return .bw4_lp
        case (.butterworth, 4, false):   return .bw4_hp
        case (.butterworth, 5, true):    return .bw5_lp
        case (.butterworth, 5, false):   return .bw5_hp
        case (.butterworth, 6, true):    return .bw6_lp
        case (.butterworth, 6, false):   return .bw6_hp
        case (.butterworth, 7, true):    return .bw7_lp
        case (.butterworth, 7, false):   return .bw7_hp
        case (.butterworth, 8, true):    return .bw8_lp
        case (.butterworth, 8, false):   return .bw8_hp
        case (.bessel, 2, true):         return .bes2_lp
        case (.bessel, 2, false):        return .bes2_hp
        case (.bessel, 4, true):         return .bes4_lp
        case (.bessel, 4, false):        return .bes4_hp
        case (.bessel, 6, true):         return .bes6_lp
        case (.bessel, 6, false):        return .bes6_hp
        case (.bessel, 8, true):         return .bes8_lp
        case (.bessel, 8, false):        return .bes8_hp
        default: return nil
        }
    }
}

struct FilterParams: Equatable, Identifiable {
    let id = UUID()
    var type: FilterType = .flat
    var freq: Float = 1000.0
    var q: Float = 0.707
    var gain: Float = 0.0
    var active: Bool = true // UI Toggle for graph visibility calculation only
    /// User-controlled per-band bypass flag (firmware 1.1.4+).  When true the
    /// band is skipped in the audio path and drawn flat in the graph.
    /// Distinct from `active` (UI-only) and from master-EQ bypass.
    var bypass: Bool = false

    static func == (lhs: FilterParams, rhs: FilterParams) -> Bool {
        lhs.type == rhs.type && lhs.freq == rhs.freq &&
        lhs.q == rhs.q && lhs.gain == rhs.gain && lhs.active == rhs.active &&
        lhs.bypass == rhs.bypass
    }
}

class DSPMath {
    static let sampleRate: Double = 48000.0

    /// Calculates the complex frequency response H(z) magnitude in dB for a specific frequency
    /// Uses Double precision to avoid numerical artifacts with high-Q filters at low frequencies
    static func responseAt(freq: Float, filters: [FilterParams]) -> Float {
        var magSquaredTotal: Double = 1.0
        let freqD = Double(freq)

        for f in filters where f.type != .flat && f.active && !f.bypass {
            // Crossover types cascade multiple biquad sections.
            let sections: [Coeffs]
            if f.type.isCrossover {
                sections = crossoverSections(p: f)
            } else {
                sections = [calculateCoefficients(p: f)]
            }
            for coeffs in sections {
                let mag = magnitudeSquared(coeffs: coeffs, freq: freqD)
                magSquaredTotal *= mag
            }
        }

        return Float(10.0 * log10(magSquaredTotal))
    }

    private static func magnitudeSquared(coeffs: Coeffs, freq: Double) -> Double {
        let w = 2.0 * Double.pi * freq / sampleRate
        let cos_w = cos(w)
        let cos_2w = cos(2.0 * w)
        let sin_w = sin(w)
        let sin_2w = sin(2.0 * w)
        let num_r = coeffs.b0 + coeffs.b1 * cos_w + coeffs.b2 * cos_2w
        let num_i = -(coeffs.b1 * sin_w + coeffs.b2 * sin_2w)
        let den_r = 1.0 + coeffs.a1 * cos_w + coeffs.a2 * cos_2w
        let den_i = -(coeffs.a1 * sin_w + coeffs.a2 * sin_2w)
        let num_mag_sq = num_r*num_r + num_i*num_i
        let den_mag_sq = den_r*den_r + den_i*den_i
        if den_mag_sq > 1e-15 {
            return num_mag_sq / den_mag_sq
        }
        return 1.0
    }

    // Coefficients in Double precision for accurate frequency response calculation
    struct Coeffs {
        let b0, b1, b2, a1, a2: Double
    }

    static func calculateCoefficients(p: FilterParams) -> Coeffs {
        if p.type == .flat { return Coeffs(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0) }

        let freq = Double(p.freq)
        let q = Double(p.q)
        let gain = Double(p.gain)

        let omega = 2.0 * Double.pi * freq / sampleRate
        let sn = sin(omega)
        let cs = cos(omega)
        let alpha = sn / (2.0 * q)
        let A = pow(10.0, gain / 40.0)

        var b0: Double = 1, b1: Double = 0, b2: Double = 0
        var a0: Double = 1, a1: Double = 0, a2: Double = 0

        switch p.type {
        case .lowPass:
            b0 = (1 - cs)/2; b1 = 1 - cs; b2 = (1 - cs)/2
            a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cs)/2; b1 = -(1 + cs); b2 = (1 + cs)/2
            a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha
        case .peaking:
            b0 = 1 + alpha * A; b1 = -2 * cs; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cs; a2 = 1 - alpha / A
        case .lowShelf:
            b0 = A * ((A + 1) - (A - 1) * cs + 2 * sqrt(A) * alpha)
            b1 = 2 * A * ((A - 1) - (A + 1) * cs)
            b2 = A * ((A + 1) - (A - 1) * cs - 2 * sqrt(A) * alpha)
            a0 = (A + 1) + (A - 1) * cs + 2 * sqrt(A) * alpha
            a1 = -2 * ((A - 1) + (A + 1) * cs)
            a2 = (A + 1) + (A - 1) * cs - 2 * sqrt(A) * alpha
        case .highShelf:
            b0 = A * ((A + 1) + (A - 1) * cs + 2 * sqrt(A) * alpha)
            b1 = -2 * A * ((A - 1) + (A + 1) * cs)
            b2 = A * ((A + 1) + (A - 1) * cs - 2 * sqrt(A) * alpha)
            a0 = (A + 1) - (A - 1) * cs + 2 * sqrt(A) * alpha
            a1 = 2 * ((A - 1) - (A + 1) * cs)
            a2 = (A + 1) - (A - 1) * cs - 2 * sqrt(A) * alpha
        case .notch:
            b0 = 1; b1 = -2 * cs; b2 = 1.0
            a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha
        case .allPass:
            b0 = 1 - alpha; b1 = -2 * cs; b2 = 1 + alpha
            a0 = 1 + alpha; a1 = -2 * cs; a2 = 1 - alpha
        case .allPass1:
            // First-order all-pass (degenerate biquad, b2 = a2 = 0): flat
            // magnitude, phase 0 -> -180 (-90 at fc).  freq only; Q/gain unused.
            // ap = (tan(pi*fc/Fs) - 1) / (tan(pi*fc/Fs) + 1)
            let ta = tan(omega / 2.0)
            let ap = (ta - 1.0) / (ta + 1.0)
            b0 = ap; b1 = 1.0; b2 = 0
            a0 = 1.0; a1 = ap; a2 = 0
        case .lowShelf1:
            // First-order low shelf (degenerate biquad): DC gain A^2, unity at
            // Nyquist.  Q unused.  Matches firmware FILTER_LOWSHELF1.
            b0 = (A * sn) + 1 + cs; b1 = (A * sn) - 1 - cs; b2 = 0
            a0 = (sn / A) + 1 + cs; a1 = (sn / A) - 1 - cs; a2 = 0
        case .highShelf1:
            // First-order high shelf (degenerate biquad): unity at DC, gain A^2
            // at Nyquist.  Q unused.  Matches firmware FILTER_HIGHSHELF1.
            b0 = sn + A + (A * cs); b1 = sn - A - (A * cs); b2 = 0
            a0 = sn + (1 / A) + (cs / A); a1 = sn - (1 / A) - (cs / A); a2 = 0
        default: break
        }

        return Coeffs(b0: b0/a0, b1: b1/a0, b2: b2/a0, a1: a1/a0, a2: a2/a0)
    }

    // MARK: - Crossover Coefficient Synthesis

    /// Builds the cascade of biquad sections that implements a crossover filter
    /// at the given cutoff frequency.  Mirrors the firmware design path: each
    /// section is computed from analog pole locations via the bilinear transform
    /// (matched conventions to firmware `section_emit_1st_order` / `_2nd_order`).
    static func crossoverSections(p: FilterParams) -> [Coeffs] {
        guard let family = p.type.crossoverFamily,
              let isLP = p.type.crossoverIsLowPass else {
            return []
        }
        let order = p.type.crossoverOrder
        let fc = Double(p.freq)
        let fs = sampleRate
        guard fc > 0, fs > 0 else { return [] }

        // Each section's (sigma_n, omega_n) normalised so the prototype LP has
        // its cutoff at omega = 1.  Sections come out as pairs (sigma, omega);
        // sigma == 0 indicates a first-order section using omega only.
        let proto = prototypePoles(family: family, order: order)
        var sections: [Coeffs] = []
        sections.reserveCapacity(proto.count)
        for pole in proto {
            sections.append(designSection(pole: pole, fc: fc, fs: fs, isLP: isLP))
        }
        return sections
    }

    /// A prototype pole pair (sigma, omega).  For first-order sections we use
    /// `omega` alone and ignore `sigma` (encoded as sigma = 0, omega = pole
    /// location).
    private struct ProtoPole {
        let sigma: Double   // real part of the LHP pole (>0)
        let omega: Double   // imaginary part magnitude
        let isFirstOrder: Bool
    }

    /// Returns the analog prototype LP poles for a given family/order,
    /// normalised so the cutoff is at omega = 1 (i.e. -3 dB at omega = 1 for
    /// Butterworth and Bessel; LR uses cascaded BW prototypes).
    private static func prototypePoles(family: CrossoverFamily, order: Int) -> [ProtoPole] {
        switch family {
        case .butterworth:
            return butterworthPoles(order: order)
        case .linkwitzRiley:
            // LR(2N) = BW(N) cascaded with itself.  Use BW(N/2) poles, doubled.
            let halfOrder = order / 2
            let bw = butterworthPoles(order: halfOrder)
            return bw + bw
        case .bessel:
            return besselPoles(order: order)
        }
    }

    /// Butterworth pole locations in the analog s-plane.  Standard formula:
    /// `s_k = exp(j·θ_k)` with `θ_k = (2k+N-1)·π/(2N)` for k=1..N.  We collect
    /// only the upper-half-plane poles (each represents a conjugate pair);
    /// when N is odd, k = (N+1)/2 lands exactly on the negative real axis at
    /// −1, which becomes a first-order section.  Cutoff is at omega = 1.
    ///
    /// For each pair, `sigma = -Re(s)` (always positive, since the poles sit
    /// in the LHP) and `omega = |Im(s)|`.  Geometrically the pole is on the
    /// unit circle at angle `φ` from the negative real axis where
    /// `φ = (N − 2k + 1)·π/(2N)`, so `sigma = cos(φ)` and `omega = sin(φ)`.
    private static func butterworthPoles(order: Int) -> [ProtoPole] {
        guard order > 0 else { return [] }
        var poles: [ProtoPole] = []
        let N = order
        let hasOdd = (N % 2) == 1
        if hasOdd {
            poles.append(ProtoPole(sigma: 1.0, omega: 0.0, isFirstOrder: true))
        }
        // floor(N/2) complex pairs.  For odd N, k = (N+1)/2 → φ = 0 (the real
        // pole) is already in `poles`; we iterate k = 1..floor(N/2) below.
        let pairCount = N / 2
        for k in 1...max(pairCount, 1) where pairCount > 0 {
            // φ from the negative real axis.  At φ=0 the pole is on the real
            // axis; at φ=π/2 it's on the imaginary axis.
            let phi = Double(N - 2*k + 1) * Double.pi / (2.0 * Double(N))
            if phi <= 1e-9 { continue }  // guard against degenerate real-axis case
            let sigma = cos(phi)
            let omega = sin(phi)
            poles.append(ProtoPole(sigma: sigma, omega: omega, isFirstOrder: false))
        }
        return poles
    }

    /// Bessel pole locations, normalised to -3 dB at omega = 1.  Values match
    /// the firmware tables verbatim (config.h / crossover.c), verified against
    /// scipy `signal.bessel(N, 1.0, ..., norm='mag')`.  Pairs are listed as
    /// (sigma, omega) with sigma > 0 (LHP), ordered low-Q first.
    private static func besselPoles(order: Int) -> [ProtoPole] {
        switch order {
        case 2:
            return [
                ProtoPole(sigma: 1.10160, omega: 0.63601, isFirstOrder: false)
            ]
        case 4:
            return [
                ProtoPole(sigma: 1.37007, omega: 0.41025, isFirstOrder: false),
                ProtoPole(sigma: 0.99521, omega: 1.25711, isFirstOrder: false)
            ]
        case 6:
            return [
                ProtoPole(sigma: 1.57149, omega: 0.32090, isFirstOrder: false),
                ProtoPole(sigma: 1.38186, omega: 0.97147, isFirstOrder: false),
                ProtoPole(sigma: 0.93066, omega: 1.66186, isFirstOrder: false)
            ]
        case 8:
            return [
                ProtoPole(sigma: 1.75741, omega: 0.27287, isFirstOrder: false),
                ProtoPole(sigma: 1.63694, omega: 0.82280, isFirstOrder: false),
                ProtoPole(sigma: 1.37384, omega: 1.38836, isFirstOrder: false),
                ProtoPole(sigma: 0.89287, omega: 1.99833, isFirstOrder: false)
            ]
        default:
            return []
        }
    }

    /// Bilinear-transform a single analog section into a digital biquad.
    /// For first-order sections (sigma > 0, omega = 0, isFirstOrder = true)
    /// the result is a one-pole biquad with b2 = a2 = 0.
    private static func designSection(pole: ProtoPole, fc: Double, fs: Double, isLP: Bool) -> Coeffs {
        // Pre-warp the analog cutoff for the bilinear transform.
        let wc = 2.0 * fs * tan(Double.pi * fc / fs)

        if pole.isFirstOrder {
            // Analog 1-pole LP: H(s) = wc / (s + sigma·wc).  HP via s ↔ wc²/s
            // reciprocates the pole; for sigma==1 (BW1) the pole stays at -wc.
            // Bilinear: s = 2fs (1-z⁻¹) / (1+z⁻¹).
            let p = pole.sigma * wc
            let K = 2.0 * fs
            // For LP: H(s) = p / (s + p)
            // For HP: H(s) = s / (s + p)
            if isLP {
                let b0 = p
                let b1 = p
                let a0 = K + p
                let a1 = -(K - p)
                return Coeffs(b0: b0/a0, b1: b1/a0, b2: 0, a1: a1/a0, a2: 0)
            } else {
                let b0 = K
                let b1 = -K
                let a0 = K + p
                let a1 = -(K - p)
                return Coeffs(b0: b0/a0, b1: b1/a0, b2: 0, a1: a1/a0, a2: 0)
            }
        }

        // 2nd-order section design.  The prototype-LP section in unity-DC-gain
        // form is `H(s_n) = r² / (s_n² + 2σ·s_n + r²)` where r² = σ²+ω² is the
        // squared pole magnitude.  After cutoff scaling s_n → s/ωc:
        //   LP: H(s) = r²·ωc² / (s² + 2σ·ωc·s + r²·ωc²)
        //   HP: H(s) = s²     / (s² + 2(σ/r²)·ωc·s + (1/r²)·ωc²)
        // For Butterworth / LR r² = 1, so HP and LP sections share the same
        // denominator coefficients (only the numerator distinguishes them).
        // For Bessel r² ≠ 1, so we must apply the reciprocal scaling on HP and
        // include r² in the LP numerator (otherwise the section would have
        // sub-unity DC gain).
        let r2 = pole.sigma * pole.sigma + pole.omega * pole.omega
        // Pole coordinates after the LP→HP transform (no-op for LP).
        let sigma = isLP ? pole.sigma : pole.sigma / r2
        let omega = isLP ? pole.omega : pole.omega / r2
        let a2_s = sigma * sigma + omega * omega   // == r² for LP, 1/r² for HP
        let a1_s = 2.0 * sigma
        let K = 2.0 * fs
        let wn = wc
        let wn2 = wn * wn
        let K2 = K * K

        // Apply bilinear: s = K·(1-z⁻¹)/(1+z⁻¹).
        // (1 − z⁻¹)² = 1 − 2z⁻¹ + z⁻²
        // (1 − z⁻²)  = 1         − z⁻²
        // (1 + z⁻¹)² = 1 + 2z⁻¹ + z⁻²
        // Denominator (same form for LP and HP, only `sigma` differs):
        //   A(z) = K²(1−z⁻¹)² + a1_s·wn·K·(1−z⁻²) + a2_s·wn²·(1+z⁻¹)²
        let den0 = K2 + a1_s * wn * K + a2_s * wn2
        let den1 = -2.0 * K2 + 2.0 * a2_s * wn2
        let den2 = K2 - a1_s * wn * K + a2_s * wn2

        // Numerator:
        //   LP: r²·wn²·(1+z⁻¹)²  (a2_s == r² for LP, so a2_s·wn² is correct)
        //   HP: K²·(1−z⁻¹)²
        let num0: Double
        let num1: Double
        let num2: Double
        if isLP {
            let g = a2_s * wn2  // = r² · ωc² ; gives unity DC gain across the section
            num0 = g
            num1 = 2.0 * g
            num2 = g
        } else {
            num0 = K2
            num1 = -2.0 * K2
            num2 = K2
        }
        return Coeffs(
            b0: num0 / den0,
            b1: num1 / den0,
            b2: num2 / den0,
            a1: den1 / den0,
            a2: den2 / den0
        )
    }
}
