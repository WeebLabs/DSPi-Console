import SwiftUI

// Presentation pieces shared by the Firmware Update window and the Getting
// Started wizard.  Both drive the same FirmwareInstaller, and both must render
// its states in the same visual language: a spinner always means the app or
// the hardware is doing the work; a still icon means the next move is the
// user's, and the card body says exactly what that move is.

// MARK: - Card chrome

/// The rounded panel every status and summary card sits on.
struct SetupCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
    }
}

extension View {
    func setupCard() -> some View { modifier(SetupCardBackground()) }
}

// MARK: - Labelled value row

/// One "LABEL   value" line.  The fixed label column keeps values aligned
/// across stacked rows however long the labels get.
struct LabeledValueRow: View {
    let label: String
    let value: String
    var secondary = false
    var labelWidth: CGFloat = 120

    var body: some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(secondary ? .secondary : .primary)
        }
    }
}

// MARK: - State card

/// One centred state: an icon or spinner, a short title, and one or two
/// sentences of explanation.
struct InstallStateCard: View {
    let icon: String
    let tint: Color
    var spinning = false
    var iconSize: CGFloat = 28
    let title: String
    let message: String

    /// Optional control belonging to this state, drawn inside the card.  A
    /// button that acts on what the card describes reads as part of it; the
    /// same button floating underneath reads as belonging to the page.
    var accessory: AnyView? = nil

    var body: some View {
        VStack(spacing: 10) {
            if spinning {
                ProgressView()
                    .controlSize(.regular)
                    .frame(height: iconSize)
            } else {
                Image(systemName: icon)
                    .font(.system(size: iconSize))
                    .foregroundColor(tint)
                    .frame(height: iconSize)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
            if let accessory {
                accessory.padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
        .setupCard()
    }
}

// MARK: - Writing card

/// The write in progress: who is being written, what is being written, how far
/// along it is, and a line saying the alarming-looking ending - the drive
/// vanishing - is the normal one.
struct InstallWritingCard: View {
    let fraction: Double
    let boardName: String?
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Writing firmware")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            ProgressView(value: fraction)

            VStack(alignment: .leading, spacing: 4) {
                if let boardName {
                    LabeledValueRow(label: "Board", value: boardName)
                }
                LabeledValueRow(label: "Firmware", value: version)
            }
            .padding(.top, 2)

            Spacer(minLength: 0)

            Label("Near the end the board restarts itself and its drive disappears. That is normal - do not unplug it.",
                  systemImage: "info.circle")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .setupCard()
    }
}

// MARK: - Step strip

/// A row of labelled dots showing where a linear process is.  Steps before
/// `current` get a checkmark; the final step turns green when reached.
struct StepDotStrip: View {
    let labels: [String]
    let current: Int
    /// A failure keeps the strip on screen but takes the emphasis off it; the
    /// status card is telling the real story.
    var dimmed = false
    /// Fixed width so the labels sit centred under their dots and the
    /// connectors between dots stay equal, whatever the labels say.
    var dotWidth: CGFloat = 52

    var body: some View {
        HStack(spacing: 0) {
            ForEach(labels.indices, id: \.self) { index in
                if index != 0 {
                    Rectangle()
                        .fill(connectorColor(into: index))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 4)
                }
                stepDot(index)
            }
        }
        .padding(.horizontal, 8)
        .opacity(dimmed ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.2), value: current)
    }

    private var lastIndex: Int { labels.count - 1 }

    private func stepDot(_ index: Int) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(fillColor(index))
                    .frame(width: 14, height: 14)
                if index < current || (index == lastIndex && current == lastIndex) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            Text(labels[index])
                .font(.system(size: 9, weight: index == current ? .bold : .regular))
                .foregroundColor(index == current ? .primary : .secondary)
        }
        .frame(width: dotWidth)
    }

    private func fillColor(_ index: Int) -> Color {
        if index < current { return .accentColor }
        if index == current { return current == lastIndex ? .green : .accentColor }
        return Color.secondary.opacity(0.25)
    }

    private func connectorColor(into index: Int) -> Color {
        index <= current ? Color.accentColor.opacity(0.6)
                         : Color.secondary.opacity(0.2)
    }
}

// MARK: - BOOTSEL hint

/// What BOOTSEL is and how to use it, for anyone who may need to put a board
/// into bootloader mode by hand.
struct BootselHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "button.programmable")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text("Hold the BOOTSEL button on your Pico-compatible device while plugging it into your computer.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Failure severity

extension FirmwareInstallError {
    /// Detection-side stumbles - no board yet, a drive that has not mounted -
    /// are ordinary and should read that way; a failure after bytes have moved
    /// deserves the warning triangle.
    var isMundane: Bool {
        switch self {
        case .noBoardFound, .volumeNotMounted, .multipleBoards: return true
        default: return false
        }
    }
}

/// A failure card dressed to match its severity.
func installFailureCard(_ error: FirmwareInstallError) -> InstallStateCard {
    InstallStateCard(
        icon: error.isMundane ? "questionmark.circle" : "exclamationmark.triangle.fill",
        tint: .orange,
        title: error.isMundane ? "Not quite ready" : "The update did not complete",
        message: error.message)
}
