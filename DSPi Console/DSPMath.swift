import Foundation

enum FilterType: Int, CaseIterable, Identifiable {
    case flat = 0
    case peaking = 1
    case lowShelf = 2
    case highShelf = 3
    case lowPass = 4
    case highPass = 5
    
    var id: Int { rawValue }
    
    var name: String {
        switch self {
        case .flat: return "Off"
        case .peaking: return "Peaking"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .lowPass: return "Low Pass"
        case .highPass: return "High Pass"
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
}

class DSPMath {
    static let sampleRate: Float = 48000.0
    
    /// Calculates the complex frequency response H(z) magnitude in dB for a specific frequency
    static func responseAt(freq: Float, filters: [FilterParams]) -> Float {
        var magSquaredTotal: Float = 1.0
        
        for f in filters where f.type != .flat && f.active {
            let coeffs = calculateCoefficients(p: f)
            let w = 2.0 * Float.pi * freq / sampleRate
            
            // Evaluate Transfer Function |H(e^jw)|
            // H(z) = (b0 + b1*z^-1 + b2*z^-2) / (1 + a1*z^-1 + a2*z^-2)
            // z = e^jw = cos(w) + j*sin(w)
            
            let cos_w = cos(w)
            let cos_2w = cos(2.0 * w)
            let sin_w = sin(w)
            let sin_2w = sin(2.0 * w)
            
            // Numerator (Real and Imaginary parts)
            let num_r = coeffs.b0 + coeffs.b1 * cos_w + coeffs.b2 * cos_2w
            let num_i = -(coeffs.b1 * sin_w + coeffs.b2 * sin_2w)
            
            // Denominator (a0 is normalized to 1)
            let den_r = 1.0 + coeffs.a1 * cos_w + coeffs.a2 * cos_2w
            let den_i = -(coeffs.a1 * sin_w + coeffs.a2 * sin_2w)
            
            let num_mag_sq = num_r*num_r + num_i*num_i
            let den_mag_sq = den_r*den_r + den_i*den_i
            
            if den_mag_sq > 1e-9 {
                magSquaredTotal *= (num_mag_sq / den_mag_sq)
            }
        }
        
        return 10.0 * log10(magSquaredTotal)
    }
    
    // Direct port of your C firmware logic
    struct Coeffs {
        let b0, b1, b2, a1, a2: Float
    }
    
    static func calculateCoefficients(p: FilterParams) -> Coeffs {
        if p.type == .flat { return Coeffs(b0:1, b1:0, b2:0, a1:0, a2:0) }
        
        let omega = 2.0 * Float.pi * p.freq / sampleRate
        let sn = sin(omega)
        let cs = cos(omega)
        let alpha = sn / (2.0 * p.q)
        let A = pow(10.0, p.gain / 40.0)
        
        var b0: Float = 1, b1: Float = 0, b2: Float = 0
        var a0: Float = 1, a1: Float = 0, a2: Float = 0
        
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
        default: break
        }
        
        return Coeffs(b0: b0/a0, b1: b1/a0, b2: b2/a0, a1: a1/a0, a2: a2/a0)
    }
}
