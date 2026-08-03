import SwiftUI

/// The single source of truth for every per-channel color in the app.  Sidebar
/// pills, graph curves, matrix rows, dashboard cards and the Settings output
/// assignment list all read from here; nothing else should spell out a channel
/// color literal.
///
/// These values were previously written out three times - in `MatrixInput`,
/// in `MatrixOutput` and again in `Channel.color` - which is how the copies
/// came to disagree (see the note on `Channel.color` about output 2).  The
/// colors themselves are unchanged; only the number of places defining them is.
enum ChannelPalette {

    /// Input channels 0..7 (`MAX_MATRIX_INPUTS`).  Indices 0/1 are the stereo
    /// blue/red, so the 2-input view reads the way it always has.
    static let inputs: [Color] = [
        Color(red: 0.29, green: 0.56, blue: 0.89),  // 0 FL - blue
        Color(red: 0.96, green: 0.45, blue: 0.45),  // 1 FR - red
        Color(red: 0.45, green: 0.78, blue: 0.55),  // 2 FC - green
        Color(red: 0.93, green: 0.70, blue: 0.30),  // 3 LFE - amber
        Color(red: 0.60, green: 0.55, blue: 0.92),  // 4 BL - violet
        Color(red: 0.90, green: 0.55, blue: 0.78),  // 5 BR - pink
        Color(red: 0.40, green: 0.78, blue: 0.82),  // 6 SL - teal
        Color(red: 0.80, green: 0.72, blue: 0.42),  // 7 SR - olive
    ]

    /// Output channels 0..7 - the four S/PDIF or I2S stereo pairs.  The PDM
    /// subwoofer is mono and sits outside this list; see `pdm`.
    static let outputs: [Color] = [
        Color(red: 0.27, green: 0.76, blue: 0.64),  // 0 - teal
        Color(red: 0.35, green: 0.82, blue: 0.50),  // 1 - green
        Color(red: 0.94, green: 0.77, blue: 0.35),  // 2 - amber
        Color(red: 0.95, green: 0.65, blue: 0.30),  // 3 - orange
        Color(red: 0.35, green: 0.55, blue: 0.95),  // 4 - blue
        Color(red: 0.55, green: 0.70, blue: 0.95),  // 5 - light blue
        Color(red: 0.85, green: 0.45, blue: 0.55),  // 6 - rose
        Color(red: 0.95, green: 0.60, blue: 0.65),  // 7 - pink
    ]

    /// The PDM subwoofer output - purple, and a single tone since it has no
    /// stereo partner.
    static let pdm = Color(red: 0.73, green: 0.53, blue: 0.95)

    /// Color for an input channel, falling back to the accent color for an
    /// index outside the 8-channel model.
    static func input(_ index: Int) -> Color {
        inputs.indices.contains(index) ? inputs[index] : .accentColor
    }

    /// Color for an output channel by matrix output index.  The PDM output
    /// (index 8 on RP2350, 4 on RP2040) is passed explicitly via `pdm`;
    /// anything past the eight paired outputs lands on the accent color.
    static func output(_ index: Int) -> Color {
        outputs.indices.contains(index) ? outputs[index] : .accentColor
    }
}
