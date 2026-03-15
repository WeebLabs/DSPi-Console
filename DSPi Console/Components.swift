import SwiftUI

// MARK: - Right Click Handler

/// Invisible overlay that intercepts right-clicks while passing left-clicks through
struct RightClickHandler: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> RightClickNSView {
        let view = RightClickNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: RightClickNSView, context: Context) {
        nsView.action = action
    }

    class RightClickNSView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent, event.type == .rightMouseDown {
                return self
            }
            return nil
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            return true
        }
    }
}

extension View {
    func onRightClick(perform action: @escaping () -> Void) -> some View {
        self.overlay(RightClickHandler(action: action))
    }
    func onOptionClick(perform action: @escaping () -> Void) -> some View {
        self.overlay(OptionClickHandler(action: action))
    }
}

// MARK: - Option Click Handler

/// Invisible overlay that intercepts option-clicks while passing other clicks through
struct OptionClickHandler: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> OptionClickNSView {
        let view = OptionClickNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: OptionClickNSView, context: Context) {
        nsView.action = action
    }

    class OptionClickNSView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            if let event = NSApp.currentEvent, event.type == .leftMouseDown,
               event.modifierFlags.contains(.option) {
                return self
            }
            return nil
        }

        override func mouseDown(with event: NSEvent) {
            action?()
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            return true
        }
    }
}

// MARK: - Meter Components

struct HorizontalMeterBar: View {
    var level: Float        // 0.0 to 1.0
    var color: Color
    var isMuted: Bool = false
    var isClipping: Bool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let clipZoneWidth: CGFloat = 3
            let meterWidth = w - clipZoneWidth

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: CGFloat(max(0, min(1, level))) * meterWidth)
                    .animation(.linear(duration: 0.06), value: level)

                if isClipping {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red)
                        .frame(width: clipZoneWidth)
                        .offset(x: meterWidth)
                }
            }
        }
        .frame(height: 6)
        .opacity(isMuted ? 0.4 : 1.0)
    }
}

struct CpuMeter: View {
    var core: Int
    var load: Int
    var body: some View {
        HStack(spacing: 4) {
            Text("C\(core):").font(.caption2).foregroundColor(.secondary)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.3))
                RoundedRectangle(cornerRadius: 2).fill(load > 90 ? Color.red : Color.blue)
                    .frame(width: CGFloat(load) * 0.4) // Max 40px width
            }
            .frame(width: 40, height: 6)
            Text("\(load)%").font(.caption2).monospacedDigit()
        }
    }
}

struct CpuSection: View {
    @ObservedObject var meters: DSPMeterModel
    var body: some View {
        HStack {
            CpuMeter(core: 0, load: meters.status.cpu0)
            Spacer()
            CpuMeter(core: 1, load: meters.status.cpu1)
        }
    }
}

struct MuteableLabel: View {
    let text: String
    let isMuted: Bool
    var width: CGFloat = 8
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Text(text)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .opacity(isMuted ? 0.3 : 1.0)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .leading)
        .help(isMuted ? "Click to unmute" : "Click to mute")
    }
}

// MARK: - Sidebar Rows

struct ChannelRow: View {
    let channel: Channel
    let isSelected: Bool
    let name: String
    @ObservedObject var meters: DSPMeterModel
    let isRenaming: Bool
    @Binding var renameText: String
    let onCommitRename: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(width: 3).padding(.vertical, 4)
            } else {
                Rectangle().fill(Color.clear).frame(width: 3).padding(.vertical, 4)
            }

            if isRenaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isFocused)
                    .onSubmit { onCommitRename() }
                    .padding(.leading, 8)
                    .frame(width: 80, alignment: .leading)
            } else {
                Text(name)
                    .font(.body)
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.9))
                    .padding(.leading, 8)
                    .frame(width: 80, alignment: .leading)
            }

            HorizontalMeterBar(
                level: meters.status.peaks[channel.rawValue],
                color: channel.color,
                isClipping: (meters.status.clipLatched & (1 << UInt16(channel.rawValue))) != 0
            )
            .padding(.horizontal, 4)

            Text(channel.descriptor)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(channel.color)
                .frame(minWidth: 28)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(channel.color.opacity(0.15)))
                .overlay(Capsule().stroke(channel.color.opacity(0.4), lineWidth: 1))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 8)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .background(isSelected ? Color.primary.opacity(0.05) : Color.clear)
        .onChange(of: isRenaming) { renaming in
            if renaming {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isFocused = true
                }
            }
        }
        .onChange(of: isFocused) { focused in
            if !focused && isRenaming { onCommitRename() }
        }
    }
}

struct OutputRow: View {
    let output: MatrixOutput
    let isSelected: Bool
    let name: String
    let isMuted: Bool
    @ObservedObject var meters: DSPMeterModel
    let isRenaming: Bool
    @Binding var renameText: String
    let onCommitRename: () -> Void
    @FocusState private var isFocused: Bool

    private var chIdx: Int { output.index + 2 }

    var body: some View {
        HStack(spacing: 0) {
            if isSelected {
                Rectangle().fill(Color.accentColor).frame(width: 3).padding(.vertical, 4)
            } else {
                Rectangle().fill(Color.clear).frame(width: 3).padding(.vertical, 4)
            }

            if isRenaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isFocused)
                    .onSubmit { onCommitRename() }
                    .padding(.leading, 8)
                    .frame(width: 80, alignment: .leading)
            } else {
                Text(name)
                    .font(.body)
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.9))
                    .padding(.leading, 8)
                    .frame(width: 80, alignment: .leading)
            }

            HorizontalMeterBar(
                level: meters.status.peaks[chIdx],
                color: output.color,
                isMuted: isMuted,
                isClipping: (meters.status.clipLatched & (1 << UInt16(chIdx))) != 0
            )
            .padding(.horizontal, 4)

            Text(output.descriptor)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(output.color)
                .frame(minWidth: 28)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(output.color.opacity(0.15)))
                .overlay(Capsule().stroke(output.color.opacity(0.4), lineWidth: 1))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 8)
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .background(isSelected ? Color.primary.opacity(0.05) : Color.clear)
        .onChange(of: isRenaming) { renaming in
            if renaming {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isFocused = true
                }
            }
        }
        .onChange(of: isFocused) { focused in
            if !focused && isRenaming { onCommitRename() }
        }
    }
}

// MARK: - Channel Settings

struct ChannelSettingsView: View {
    @Binding var gainDB: Float
    @Binding var delayMS: Float
    @Binding var isMuted: Bool
    var onGainDrag: ((Float) -> Void)? = nil
    var onDelayDrag: ((Float) -> Void)? = nil

    @State private var localGain: Float = 0
    @State private var localDelay: Float = 0
    @State private var isDraggingGain = false
    @State private var isDraggingDelay = false

    var body: some View {
        HStack(spacing: 0) {
            // GAIN
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Gain", systemImage: "speaker.wave.2.fill")
                        .font(.caption).fontWeight(.bold).foregroundColor(.secondary)
                    ValueField(label: "dB", value: localGain, width: 60) {
                        localGain = $0
                        gainDB = $0
                    }
                }
                .frame(width: 80, alignment: .leading)

                Slider(value: $localGain, in: -60...10) { editing in
                    isDraggingGain = editing
                    if !editing { gainDB = localGain }
                }
                .onChange(of: localGain) { val in
                    if isDraggingGain { onGainDrag?(val) }
                }
                .onAppear { localGain = gainDB }
                .onChange(of: gainDB) { val in if !isDraggingGain { localGain = val } }
                .onRightClick { localGain = 0; gainDB = 0 }
            }
            .padding(12)
            .frame(maxWidth: .infinity)

            Divider()

            // DELAY
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Delay", systemImage: "clock.arrow.circlepath")
                        .font(.caption).fontWeight(.bold).foregroundColor(.secondary)
                    ValueField(label: "ms", value: localDelay, width: 60) {
                        localDelay = $0
                        delayMS = $0
                    }
                }
                .frame(width: 80, alignment: .leading)

                Slider(value: $localDelay, in: 0...85) { editing in
                    isDraggingDelay = editing
                    if !editing { delayMS = localDelay }
                }
                .onChange(of: localDelay) { val in
                    if isDraggingDelay { onDelayDrag?(val) }
                }
                .onAppear { localDelay = delayMS }
                .onChange(of: delayMS) { val in if !isDraggingDelay { localDelay = val } }
                .onRightClick { localDelay = 0; delayMS = 0 }
            }
            .padding(12)
            .frame(maxWidth: .infinity)

            Divider()

            // MUTE
            Toggle(isOn: $isMuted) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.title2)
                    .foregroundColor(isMuted ? .red : .secondary)
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .frame(width: 60)
            .background(isMuted ? Color.red.opacity(0.1) : Color.clear)
        }
        .frame(height: 60)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Filter List

struct FilterListView: View {
    let bands: [FilterParams]
    let channelId: Int
    let onUpdate: (Int, FilterParams) -> Void
    var onClear: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text("#").font(.caption).fontWeight(.bold).foregroundColor(.secondary).frame(width: 24, alignment: .leading)
                Text("TYPE").font(.caption).fontWeight(.bold).foregroundColor(.secondary).frame(width: 100, alignment: .leading)
                Text("FREQ").font(.caption).fontWeight(.bold).foregroundColor(.secondary).frame(width: 104, alignment: .center)
                Text("GAIN").font(.caption).fontWeight(.bold).foregroundColor(.secondary).frame(width: 84, alignment: .center)
                Text("WIDTH").font(.caption).fontWeight(.bold).foregroundColor(.secondary).frame(width: 74, alignment: .center)
                Spacer()
                if let onClear = onClear {
                    Button("Clear All", role: .destructive, action: onClear)
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(0..<bands.count, id: \.self) { index in
                        FilterRowView(
                            index: index,
                            params: bands[index],
                            onChange: { onUpdate(index, $0) }
                        )
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2), lineWidth: 1))
        .padding(.horizontal)
        .padding(.bottom)
    }
}

// MARK: - NSViewRepresentable Components

private class PaddedPopUpButtonCell: NSPopUpButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        super.drawTitle(title, withFrame: frame.offsetBy(dx: 0, dy: 1), in: controlView)
    }
}

private class PaddedPopUpButton: NSPopUpButton {
    var trailingPadding: CGFloat = 14
    var onRightClick: (() -> Void)?
    override class var cellClass: AnyClass? {
        get { PaddedPopUpButtonCell.self }
        set {}
    }
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += trailingPadding
        return size
    }
    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick = onRightClick {
            onRightClick()
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

struct BorderlessPopUpButton<T: Hashable>: NSViewRepresentable {
    let items: [T]
    let titleForItem: (T) -> String
    @Binding var selection: T

    var font: NSFont?
    var enabled: Bool = true
    var showsHoverBorder: Bool = true
    var onRightClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = PaddedPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = showsHoverBorder
        button.showsBorderOnlyWhileMouseInside = showsHoverBorder
        button.onRightClick = onRightClick
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        if let font = font { button.font = font }
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        // Update coordinator's reference to current parent (fixes stale binding issue)
        context.coordinator.parent = self

        if let font = font { button.font = font }
        button.isBordered = showsHoverBorder && enabled
        button.showsBorderOnlyWhileMouseInside = showsHoverBorder && enabled
        (button as? PaddedPopUpButton)?.onRightClick = onRightClick
        button.menu?.removeAllItems()
        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem(title: titleForItem(item), action: nil, keyEquivalent: "")
            menuItem.tag = index
            button.menu?.addItem(menuItem)
        }
        if let index = items.firstIndex(of: selection) {
            button.selectItem(withTag: index)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: BorderlessPopUpButton

        init(_ parent: BorderlessPopUpButton) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            if index >= 0 && index < parent.items.count {
                parent.selection = parent.items[index]
            }
            // Resync popup to binding value in case the setter rejected the change
            // (e.g. unsaved changes alert → Cancel)
            if let correctIndex = parent.items.firstIndex(of: parent.selection) {
                sender.selectItem(withTag: correctIndex)
            }
        }
    }
}

// MARK: - Filter Row

struct FilterRowView: View {
    let index: Int
    var params: FilterParams
    var onChange: (FilterParams) -> Void

    var isActive: Bool { params.type != .flat }

    var body: some View {
        HStack(spacing: 12) {
            // Index
            Text("\(index + 1)")
                .font(.system(.body))
                .foregroundColor(isActive ? .primary : .secondary.opacity(0.5))
                .frame(width: 24, alignment: .leading)

            // Type Selector
            BorderlessPopUpButton(
                items: FilterType.allCases,
                titleForItem: { $0.name },
                selection: Binding(
                    get: { params.type },
                    set: { var p = params; p.type = $0; onChange(p) }
                )
            )
            .frame(width: 100, height: 20)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 4)
                    .allowsHitTesting(false)
            }

            // Controls
            if isActive {
                HStack(spacing: 12) {
                    // Freq
                    ValueField(label: "Hz", value: params.freq, width: 80) {
                        var p = params; p.freq = $0; onChange(p)
                    }

                    // Gain
                    if params.type == .peaking || params.type == .lowShelf || params.type == .highShelf {
                        ValueField(label: "dB", value: params.gain, width: 60) {
                            var p = params; p.gain = $0; onChange(p)
                        }
                    } else {
                        Spacer().frame(width: 60 + 24) // Placeholder
                    }

                    // Q
                    ValueField(label: "Q", value: params.q, width: 50) {
                        var p = params; p.q = $0; onChange(p)
                    }
                }
            } else {
                Text("Filter Disabled")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
                    .frame(width: 104, alignment: .center)
            }

            Spacer()
        }
        .frame(height: 24) // Fixed height to prevent jumping
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
        .background(
            ZStack {
                if index % 2 == 0 { Color.white.opacity(0.03) }
            }
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Value Field

struct ValueField: View {
    let label: String
    let value: Float
    let width: CGFloat
    let onCommit: (Float) -> Void
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .trailing) {
                Text(text + " ")
                    .font(.system(.body).monospacedDigit())
                    .opacity(0)
                    .padding(4)

                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(.body).monospacedDigit())
                    .foregroundColor(isFocused ? .accentColor : .primary)
                    .tint(.accentColor)
                    .multilineTextAlignment(.trailing)
                    .padding(4)
                    .frame(width: width) // Enforce fixed width
                    .focused($isFocused)
                    .onSubmit { if let v = Float(text) { onCommit(v) } else { text = String(format: "%.1f", value) } }
                    .onChange(of: isFocused) { focused in if !focused { if let v = Float(text) { onCommit(v) } else { text = String(format: "%.1f", value) } } }
            }
            .fixedSize(horizontal: true, vertical: false)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 20, alignment: .leading)
        }
        .onAppear { text = String(format: "%.1f", value) }
        .onChange(of: value) { newValue in text = String(format: "%.1f", newValue) }
    }
}
