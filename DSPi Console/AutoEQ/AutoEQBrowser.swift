//
//  AutoEQBrowser.swift
//  DSPi Console
//
//  Browse and search AutoEQ headphone profiles.
//

import SwiftUI

struct AutoEQBrowser: View {
    @ObservedObject var manager = AutoEQManager.shared
    @State private var searchText = ""
    @State private var selectedEntryId: String?
    @Environment(\.dismiss) private var dismiss

    var filteredEntries: [HeadphoneEntry] {
        manager.search(query: searchText)
    }

    var selectedEntry: HeadphoneEntry? {
        guard let id = selectedEntryId else { return nil }
        return filteredEntries.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search headphones...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Results list
            if filteredEntries.isEmpty {
                VStack {
                    Spacer()
                    if let error = manager.errorMessage {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundColor(.orange)
                            Text(error)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                    } else if searchText.isEmpty {
                        Text("Loading headphone database...")
                            .foregroundColor(.secondary)
                    } else {
                        Text("No headphones found matching \"\(searchText)\"")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredEntries) { entry in
                            HeadphoneRow(
                                entry: entry,
                                isSelected: selectedEntryId == entry.id,
                                isFavorite: manager.isFavorite(entry),
                                onToggleFavorite: { manager.toggleFavorite(entry) }
                            )
                            .background(selectedEntryId == entry.id ? Color.accentColor : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedEntryId = entry.id
                            }
                        }
                    }
                }
                .background(Color(NSColor.textBackgroundColor))
            }

            Divider()

            // Bottom bar
            HStack {
                if let entry = selectedEntry {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.displayName)
                            .font(.headline)
                        HStack(spacing: 8) {
                            Label(entry.sourceDisplayName, systemImage: "waveform")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Label(entry.formFactor, systemImage: entry.formFactorIcon)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("Select a headphone to apply its EQ profile")
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    applySelected()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedEntry == nil)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 500, minHeight: 400)
        .frame(idealWidth: 600, idealHeight: 500)
    }

    private func applySelected() {
        guard let entry = selectedEntry else { return }
        manager.applyProfile(entry)
        dismiss()
    }
}

struct HeadphoneRow: View {
    let entry: HeadphoneEntry
    let isSelected: Bool
    let isFavorite: Bool
    let onToggleFavorite: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.formFactorIcon)
                .font(.title2)
                .foregroundColor(isSelected ? .white : .accentColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.body)
                    .foregroundColor(isSelected ? .white : .primary)

                HStack(spacing: 8) {
                    Text(entry.sourceDisplayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(sourceColor(entry.source).opacity(isSelected ? 0.3 : 0.15))
                        )
                        .foregroundColor(isSelected ? .white : sourceColor(entry.source))

                    Text(entry.formFactor)
                        .font(.caption)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
            }

            Spacer()

            // Heart button - show on hover or if favorited
            if isHovering || isFavorite {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 14))
                        .foregroundColor(isFavorite ? .red : (isSelected ? .white.opacity(0.7) : .secondary))
                }
                .buttonStyle(.plain)
                .help(isFavorite ? "Remove from favorites" : "Add to favorites")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private func sourceColor(_ source: String) -> Color {
        switch source {
        case "oratory1990": return .orange
        case "crinacle": return .purple
        case "rtings": return .blue
        case "innerfidelity": return .green
        default: return .gray
        }
    }
}

// MARK: - Window Controller

class AutoEQBrowserController: NSObject, ObservableObject {
    private var window: NSWindow?
    @Published var isVisible = false

    func show() {
        if window == nil {
            let browserView = AutoEQBrowser()

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window?.title = "AutoEQ - Browse Profiles"
            window?.contentView = NSHostingView(rootView: browserView)
            window?.isReleasedWhenClosed = false
            window?.delegate = self
            window?.minSize = NSSize(width: 450, height: 350)
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }
}

extension AutoEQBrowserController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}
