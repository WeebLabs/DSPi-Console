//
//  AutoEQManager.swift
//  DSPi Console
//
//  Manages AutoEQ headphone profiles: index, caching, and application.
//

import Foundation
import SwiftUI

// MARK: - Data Models

struct HeadphoneEntry: Codable, Identifiable, Hashable {
    let id: String
    let manufacturer: String
    let model: String
    let source: String
    let formFactor: String
    let profileURL: String

    var displayName: String {
        if model.isEmpty {
            return manufacturer
        }
        return "\(manufacturer) \(model)"
    }

    var sourceDisplayName: String {
        switch source {
        case "oratory1990": return "oratory1990"
        case "crinacle": return "Crinacle"
        case "rtings": return "Rtings"
        case "innerfidelity": return "InnerFidelity"
        case "headphone.com": return "Headphone.com"
        default: return source
        }
    }

    var formFactorIcon: String {
        switch formFactor {
        case "over-ear": return "headphones"
        case "in-ear": return "earbuds"
        case "earbud": return "earbuds"
        default: return "headphones"
        }
    }
}

// MARK: - Manager

class AutoEQManager: ObservableObject {
    static let shared = AutoEQManager()

    @Published var entries: [HeadphoneEntry] = []
    @Published var recentProfiles: [HeadphoneEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let cacheDirectory: URL
    private let recentKey = "AutoEQ.RecentProfiles"
    private let maxRecent = 10

    init() {
        // Setup cache directory
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = caches.appendingPathComponent("com.weeblabs.DSPi-Console/autoeq", isDirectory: true)

        // Create cache directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Load index
        loadIndex()

        // Load recent profiles
        loadRecent()
    }

    // MARK: - Index

    private func loadIndex() {
        guard let url = Bundle.main.url(forResource: "headphone_index", withExtension: "json") else {
            errorMessage = "Headphone index not found in bundle"
            return
        }

        do {
            let data = try Data(contentsOf: url)
            entries = try JSONDecoder().decode([HeadphoneEntry].self, from: data)
        } catch {
            errorMessage = "Failed to load headphone index: \(error.localizedDescription)"
        }
    }

    // MARK: - Search

    func search(query: String) -> [HeadphoneEntry] {
        if query.isEmpty {
            return entries
        }

        let lowercased = query.lowercased()
        return entries.filter { entry in
            entry.manufacturer.lowercased().contains(lowercased) ||
            entry.model.lowercased().contains(lowercased) ||
            entry.displayName.lowercased().contains(lowercased)
        }
    }

    // MARK: - Profile Loading

    func loadProfile(for entry: HeadphoneEntry) async throws -> AutoEQProfile {
        // Check cache first
        let cacheFile = cacheFileURL(for: entry)
        if let cachedContent = try? String(contentsOf: cacheFile, encoding: .utf8),
           let profile = AutoEQParser.parse(cachedContent) {
            return profile
        }

        // Download from GitHub
        guard let url = URL(string: entry.profileURL) else {
            throw AutoEQError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AutoEQError.downloadFailed
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw AutoEQError.invalidContent
        }

        // Save to cache
        try? content.write(to: cacheFile, atomically: true, encoding: .utf8)

        // Parse
        guard let profile = AutoEQParser.parse(content) else {
            throw AutoEQError.parseFailed
        }

        return profile
    }

    private func cacheFileURL(for entry: HeadphoneEntry) -> URL {
        let sanitized = entry.id
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return cacheDirectory.appendingPathComponent("\(sanitized).txt")
    }

    // MARK: - Apply Profile

    func applyProfile(_ profile: AutoEQProfile, entry: HeadphoneEntry) {
        let vm = AppState.shared.viewModel

        // Set preamp
        vm.setPreamp(profile.preamp)

        // Apply filters to both Master channels
        let masterChannels = [Channel.masterLeft.rawValue, Channel.masterRight.rawValue]
        let maxBands = Channel.masterLeft.bandCount // 10

        for ch in masterChannels {
            // Apply filters (up to maxBands)
            for (i, filter) in profile.filters.prefix(maxBands).enumerated() {
                vm.setFilter(ch: ch, band: i, p: filter)
            }

            // Clear remaining bands
            for i in profile.filters.count..<maxBands {
                vm.setFilter(ch: ch, band: i, p: FilterParams(type: .flat, freq: 1000, q: 0.707, gain: 0))
            }
        }

        // Add to recent
        addToRecent(entry)
    }

    // MARK: - Recent Profiles

    func addToRecent(_ entry: HeadphoneEntry) {
        // Remove if already present
        recentProfiles.removeAll { $0.id == entry.id }

        // Add to front
        recentProfiles.insert(entry, at: 0)

        // Trim to max
        if recentProfiles.count > maxRecent {
            recentProfiles = Array(recentProfiles.prefix(maxRecent))
        }

        // Persist
        saveRecent()
    }

    private func saveRecent() {
        let ids = recentProfiles.map { $0.id }
        UserDefaults.standard.set(ids, forKey: recentKey)
    }

    private func loadRecent() {
        guard let ids = UserDefaults.standard.stringArray(forKey: recentKey) else { return }

        // Look up entries by ID
        recentProfiles = ids.compactMap { id in
            entries.first { $0.id == id }
        }
    }

    func clearRecent() {
        recentProfiles = []
        UserDefaults.standard.removeObject(forKey: recentKey)
    }

    func applyRecent(_ entry: HeadphoneEntry) async {
        do {
            let profile = try await loadProfile(for: entry)
            await MainActor.run {
                applyProfile(profile, entry: entry)
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to load profile: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Errors

enum AutoEQError: LocalizedError {
    case invalidURL
    case downloadFailed
    case invalidContent
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid profile URL"
        case .downloadFailed: return "Failed to download profile"
        case .invalidContent: return "Invalid profile content"
        case .parseFailed: return "Failed to parse profile"
        }
    }
}
