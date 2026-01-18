//
//  AutoEQManager.swift
//  DSPi Console
//
//  Manages AutoEQ headphone profiles with embedded local database.
//

import Foundation
import SwiftUI

// MARK: - Data Models

struct EmbeddedFilter: Codable, Hashable {
    let type: String
    let freq: Double
    let q: Double
    let gain: Double
}

struct HeadphoneEntry: Codable, Identifiable, Hashable {
    let id: String
    let manufacturer: String
    let model: String
    let source: String
    let formFactor: String
    let preamp: Double
    let filters: [EmbeddedFilter]

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

struct AutoEQDatabase: Codable {
    let version: Int
    let generatedAt: String
    let entryCount: Int
    let entries: [HeadphoneEntry]
}

// MARK: - Manager

class AutoEQManager: ObservableObject {
    static let shared = AutoEQManager()

    @Published var entries: [HeadphoneEntry] = []
    @Published var favoriteProfiles: [HeadphoneEntry] = []
    @Published var isLoading = false
    @Published var isUpdating = false
    @Published var errorMessage: String?
    @Published var databaseDate: String?

    // Progress tracking for rebuild
    @Published var rebuildProgress: Double = 0
    @Published var rebuildStatus: String = ""
    @Published var isRebuilding = false

    private let appSupportDirectory: URL
    private let userDatabaseURL: URL
    private let favoritesKey = "AutoEQ.FavoriteProfiles"

    // Source configuration
    private static let sourceInfo: [(folder: String, name: String, priority: Int)] = [
        ("oratory1990", "oratory1990", 1),
        ("crinacle", "crinacle", 2),
        ("Rtings", "rtings", 3),
        ("Innerfidelity", "innerfidelity", 3),
        ("Headphone.com Legacy", "headphone.com", 4)
    ]

    init() {
        // Setup Application Support directory for user updates
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportDirectory = appSupport.appendingPathComponent("com.weeblabs.DSPi-Console", isDirectory: true)
        userDatabaseURL = appSupportDirectory.appendingPathComponent("autoeq_database.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)

        // Load database
        loadDatabase()

        // Load favorites
        loadFavorites()
    }

    // MARK: - Database Loading

    private func loadDatabase() {
        // Try user-updated database first, then fall back to bundle
        let databaseURL: URL

        if FileManager.default.fileExists(atPath: userDatabaseURL.path) {
            databaseURL = userDatabaseURL
        } else if let bundleURL = Bundle.main.url(forResource: "autoeq_database", withExtension: "json") {
            databaseURL = bundleURL
        } else {
            errorMessage = "AutoEQ database not found"
            return
        }

        do {
            let data = try Data(contentsOf: databaseURL)
            let database = try JSONDecoder().decode(AutoEQDatabase.self, from: data)
            entries = database.entries
            databaseDate = formatDatabaseDate(database.generatedAt)
        } catch {
            errorMessage = "Failed to load database: \(error.localizedDescription)"
        }
    }

    private func formatDatabaseDate(_ isoDate: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .none
            return displayFormatter.string(from: date)
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoDate) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .none
            return displayFormatter.string(from: date)
        }
        return isoDate
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

    // MARK: - Apply Profile

    func applyProfile(_ entry: HeadphoneEntry) {
        let vm = AppState.shared.viewModel

        // Set preamp
        vm.setPreamp(Float(entry.preamp))

        // Apply filters to both Master channels
        let masterChannels = [Channel.masterLeft.rawValue, Channel.masterRight.rawValue]
        let maxBands = Channel.masterLeft.bandCount // 10

        for ch in masterChannels {
            // Apply filters (up to maxBands)
            for (i, filter) in entry.filters.prefix(maxBands).enumerated() {
                let filterType = FilterType.from(string: filter.type)
                let params = FilterParams(
                    type: filterType,
                    freq: Float(filter.freq),
                    q: Float(filter.q),
                    gain: Float(filter.gain)
                )
                vm.setFilter(ch: ch, band: i, p: params)
            }

            // Clear remaining bands
            for i in entry.filters.count..<maxBands {
                vm.setFilter(ch: ch, band: i, p: FilterParams(type: .flat, freq: 1000, q: 0.707, gain: 0))
            }
        }
    }

    // MARK: - Favorite Profiles

    func isFavorite(_ entry: HeadphoneEntry) -> Bool {
        favoriteProfiles.contains { $0.id == entry.id }
    }

    func toggleFavorite(_ entry: HeadphoneEntry) {
        if isFavorite(entry) {
            favoriteProfiles.removeAll { $0.id == entry.id }
        } else {
            favoriteProfiles.append(entry)
        }
        saveFavorites()
    }

    func addToFavorites(_ entry: HeadphoneEntry) {
        guard !isFavorite(entry) else { return }
        favoriteProfiles.append(entry)
        saveFavorites()
    }

    func removeFromFavorites(_ entry: HeadphoneEntry) {
        favoriteProfiles.removeAll { $0.id == entry.id }
        saveFavorites()
    }

    private func saveFavorites() {
        let ids = favoriteProfiles.map { $0.id }
        UserDefaults.standard.set(ids, forKey: favoritesKey)
    }

    private func loadFavorites() {
        guard let ids = UserDefaults.standard.stringArray(forKey: favoritesKey) else { return }

        // Look up entries by ID
        favoriteProfiles = ids.compactMap { id in
            entries.first { $0.id == id }
        }
    }

    func clearFavorites() {
        favoriteProfiles = []
        UserDefaults.standard.removeObject(forKey: favoritesKey)
    }

    // MARK: - Database Update

    func checkForUpdates() async -> (available: Bool, message: String) {
        // We'll generate a fresh database by running the Python script
        // For now, we provide a way to manually update via downloading
        // a pre-generated database or regenerating locally

        // Check if user has a custom database
        let hasUserDatabase = FileManager.default.fileExists(atPath: userDatabaseURL.path)

        if hasUserDatabase {
            return (true, "You have a custom database installed. You can regenerate it using the Python script.")
        } else {
            return (true, "Using bundled database. Run the update script to get the latest profiles.")
        }
    }

    func updateDatabase(from url: URL) async throws {
        await MainActor.run {
            isUpdating = true
            errorMessage = nil
        }

        defer {
            Task { @MainActor in
                isUpdating = false
            }
        }

        // Download the database
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AutoEQError.downloadFailed
        }

        // Validate it's valid JSON
        let database = try JSONDecoder().decode(AutoEQDatabase.self, from: data)

        // Save to user directory
        try data.write(to: userDatabaseURL)

        // Reload
        await MainActor.run {
            entries = database.entries
            databaseDate = formatDatabaseDate(database.generatedAt)

            // Refresh recent profiles with new entries
            loadFavorites()
        }
    }

    func updateDatabaseFromFile(_ fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)
        let database = try JSONDecoder().decode(AutoEQDatabase.self, from: data)

        // Save to user directory
        try data.write(to: userDatabaseURL)

        // Update state
        entries = database.entries
        databaseDate = formatDatabaseDate(database.generatedAt)

        // Refresh recent profiles
        loadFavorites()
    }

    func resetToBuiltInDatabase() throws {
        // Remove user database
        if FileManager.default.fileExists(atPath: userDatabaseURL.path) {
            try FileManager.default.removeItem(at: userDatabaseURL)
        }

        // Reload from bundle
        loadDatabase()
        loadFavorites()
    }

    var hasUserDatabase: Bool {
        FileManager.default.fileExists(atPath: userDatabaseURL.path)
    }

    // MARK: - Rebuild Database from GitHub

    func rebuildDatabase() async throws {
        await MainActor.run {
            isRebuilding = true
            rebuildProgress = 0
            rebuildStatus = "Connecting to GitHub..."
            errorMessage = nil
        }

        defer {
            Task { @MainActor in
                isRebuilding = false
            }
        }

        var allEntries: [String: (entry: HeadphoneEntry, priority: Int)] = [:]
        var totalProfiles = 0
        var processedProfiles = 0

        // Phase 1: Discover all headphone folders
        await MainActor.run {
            rebuildStatus = "Discovering profiles..."
        }

        var profilesToDownload: [(source: String, sourceName: String, priority: Int, target: String, headphone: String, url: URL)] = []

        for sourceInfo in Self.sourceInfo {
            let sourceFolder = sourceInfo.folder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sourceInfo.folder

            // Get target folders for this source
            guard let targets = try? await fetchGitHubDirectory(path: "results/\(sourceFolder)") else {
                continue
            }

            for target in targets {
                guard target.type == "dir" else { continue }

                let targetPath = "results/\(sourceFolder)/\(target.name)"

                // Get headphone folders
                guard let headphones = try? await fetchGitHubDirectory(path: targetPath) else {
                    continue
                }

                for headphone in headphones {
                    guard headphone.type == "dir" else { continue }

                    // Build raw URL for ParametricEQ.txt
                    let fileName = "\(headphone.name) ParametricEQ.txt"
                    let encodedSource = sourceInfo.folder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sourceInfo.folder
                    let encodedTarget = target.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target.name
                    let encodedFolder = headphone.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? headphone.name
                    let encodedFile = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName

                    let urlString = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/\(encodedSource)/\(encodedTarget)/\(encodedFolder)/\(encodedFile)"

                    if let url = URL(string: urlString) {
                        profilesToDownload.append((
                            source: sourceInfo.folder,
                            sourceName: sourceInfo.name,
                            priority: sourceInfo.priority,
                            target: target.name,
                            headphone: headphone.name,
                            url: url
                        ))
                    }
                }
            }

            await MainActor.run {
                rebuildStatus = "Found \(profilesToDownload.count) profiles..."
            }
        }

        totalProfiles = profilesToDownload.count

        await MainActor.run {
            rebuildStatus = "Downloading 0 / \(totalProfiles) profiles..."
        }

        // Phase 2: Download and parse profiles in batches
        let batchSize = 20
        for batchStart in stride(from: 0, to: profilesToDownload.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, profilesToDownload.count)
            let batch = profilesToDownload[batchStart..<batchEnd]

            await withTaskGroup(of: (String, HeadphoneEntry?, Int)?.self) { group in
                for profile in batch {
                    group.addTask {
                        guard let content = try? await self.downloadProfile(from: profile.url) else {
                            return nil
                        }

                        guard let parsed = self.parseProfile(content) else {
                            return nil
                        }

                        let (manufacturer, model) = self.parseHeadphoneName(profile.headphone)
                        let formFactor = self.detectFormFactor(profile.target)

                        let entry = HeadphoneEntry(
                            id: "\(profile.sourceName)/\(profile.headphone)",
                            manufacturer: manufacturer,
                            model: model,
                            source: profile.sourceName,
                            formFactor: formFactor,
                            preamp: parsed.preamp,
                            filters: parsed.filters
                        )

                        let key = "\(manufacturer.lowercased())/\(model.lowercased())"
                        return (key, entry, profile.priority)
                    }
                }

                for await result in group {
                    if let (key, entry, priority) = result, let entry = entry {
                        if let existing = allEntries[key] {
                            if priority < existing.priority {
                                allEntries[key] = (entry, priority)
                            }
                        } else {
                            allEntries[key] = (entry, priority)
                        }
                    }
                    processedProfiles += 1
                }
            }

            await MainActor.run {
                rebuildProgress = Double(processedProfiles) / Double(totalProfiles)
                rebuildStatus = "Downloading \(processedProfiles) / \(totalProfiles) profiles..."
            }
        }

        // Phase 3: Build and save database
        await MainActor.run {
            rebuildStatus = "Building database..."
        }

        let sortedEntries = allEntries.values
            .map { $0.entry }
            .sorted { ($0.manufacturer.lowercased(), $0.model.lowercased()) < ($1.manufacturer.lowercased(), $1.model.lowercased()) }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let database = AutoEQDatabase(
            version: 1,
            generatedAt: formatter.string(from: Date()),
            entryCount: sortedEntries.count,
            entries: sortedEntries
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(database)
        try data.write(to: userDatabaseURL)

        await MainActor.run {
            entries = sortedEntries
            databaseDate = formatDatabaseDate(database.generatedAt)
            rebuildProgress = 1.0
            rebuildStatus = "Complete! \(sortedEntries.count) profiles."
            loadFavorites()
        }
    }

    // MARK: - GitHub API Helpers

    private struct GitHubItem: Codable {
        let name: String
        let type: String
    }

    private func fetchGitHubDirectory(path: String) async throws -> [GitHubItem] {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "https://api.github.com/repos/jaakkopasanen/AutoEq/contents/\(encodedPath)") else {
            throw AutoEQError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AutoEQError.downloadFailed
        }

        return try JSONDecoder().decode([GitHubItem].self, from: data)
    }

    private func downloadProfile(from url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AutoEQError.downloadFailed
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw AutoEQError.invalidContent
        }

        return content
    }

    // MARK: - Parsing Helpers

    private static let filterTypes: [String: String] = [
        "PK": "peaking", "PEQ": "peaking",
        "LSC": "lowShelf", "LSB": "lowShelf", "LS": "lowShelf",
        "HSC": "highShelf", "HSB": "highShelf", "HS": "highShelf",
        "LP": "lowPass", "LPQ": "lowPass",
        "HP": "highPass", "HPQ": "highPass"
    ]

    private func parseProfile(_ content: String) -> (preamp: Double, filters: [EmbeddedFilter])? {
        var preamp: Double = 0
        var filters: [EmbeddedFilter] = []

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Parse preamp
            if trimmed.lowercased().hasPrefix("preamp:") {
                if let match = trimmed.range(of: #"-?\d+\.?\d*"#, options: .regularExpression) {
                    preamp = Double(trimmed[match]) ?? 0
                }
                continue
            }

            // Parse filter lines
            guard trimmed.contains("Filter") && trimmed.contains(":") else { continue }

            let upperLine = trimmed.uppercased()
            guard upperLine.contains(" ON ") else { continue }

            // Detect filter type
            var filterType: String?
            for (code, ftype) in Self.filterTypes {
                if upperLine.contains(" \(code) ") {
                    filterType = ftype
                    break
                }
            }

            guard let type = filterType else { continue }

            // Extract frequency
            var freq: Double = 1000
            if let fcRange = trimmed.range(of: "Fc", options: .caseInsensitive) {
                let afterFc = trimmed[fcRange.upperBound...]
                let components = afterFc.split(whereSeparator: { $0.isWhitespace })
                if let freqStr = components.first, let freqVal = Double(freqStr) {
                    freq = freqVal
                }
            }

            // Extract gain
            var gain: Double = 0
            if let gainRange = trimmed.range(of: "Gain", options: .caseInsensitive) {
                let afterGain = trimmed[gainRange.upperBound...]
                let components = afterGain.split(whereSeparator: { $0.isWhitespace })
                if let gainStr = components.first, let gainVal = Double(gainStr) {
                    gain = gainVal
                }
            }

            // Extract Q
            var q: Double = 0.707
            if let qMatch = trimmed.range(of: #"\sQ\s+([\d.]+)"#, options: .regularExpression) {
                let qPart = trimmed[qMatch]
                let components = qPart.split(whereSeparator: { $0.isWhitespace })
                if components.count >= 2, let qVal = Double(components[1]) {
                    q = qVal
                }
            }

            filters.append(EmbeddedFilter(type: type, freq: freq, q: q, gain: gain))
        }

        return filters.isEmpty ? nil : (preamp, filters)
    }

    private func detectFormFactor(_ target: String) -> String {
        let lower = target.lowercased()
        if lower.contains("in-ear") || lower.contains("in_ear") || lower.contains("iem") {
            return "in-ear"
        } else if lower.contains("earbud") {
            return "earbud"
        }
        return "over-ear"
    }

    private static let knownManufacturers = [
        "AKG", "Audio-Technica", "Audeze", "Bang & Olufsen", "Beats", "Beyerdynamic",
        "Bose", "Campfire Audio", "Dan Clark Audio", "Denon", "FiiO", "Final",
        "Focal", "Grado", "HarmonicDyne", "HIFIMAN", "JBL", "Koss", "Massdrop",
        "Meze", "Moondrop", "Philips", "Pioneer", "Sennheiser", "Shure", "Sony",
        "SteelSeries", "STAX", "Tin HiFi", "V-MODA", "ZMF", "64 Audio", "7Hz",
        "Anker", "Apple", "AFUL", "BLON", "CCA", "Dunu", "Empire Ears", "Etymotic",
        "FatFreq", "Hidizs", "HiBy", "iBasso", "JVC", "KZ", "Letshuoer", "Linsoul",
        "Noble Audio", "QKZ", "Samsung", "See Audio", "Simgot", "SoftEars",
        "Tangzu", "Thieaudio", "Tinhifi", "Tripowin", "TRN", "Truthear",
        "Unique Melody", "Westone", "Yanyin", "BGVP", "CCZ"
    ]

    private func parseHeadphoneName(_ folderName: String) -> (manufacturer: String, model: String) {
        for mfr in Self.knownManufacturers {
            if folderName.lowercased().hasPrefix(mfr.lowercased()) {
                if folderName.lowercased().hasPrefix(mfr.lowercased() + " ") || folderName.lowercased() == mfr.lowercased() {
                    let model = String(folderName.dropFirst(mfr.count)).trimmingCharacters(in: .whitespaces)
                    return (mfr, model.isEmpty ? folderName : model)
                }
            }
        }

        let parts = folderName.split(separator: " ", maxSplits: 1)
        if parts.count == 2 {
            return (String(parts[0]), String(parts[1]))
        }
        return (folderName, "")
    }
}

// MARK: - FilterType Extension

extension FilterType {
    static func from(string: String) -> FilterType {
        switch string {
        case "peaking": return .peaking
        case "lowShelf": return .lowShelf
        case "highShelf": return .highShelf
        case "lowPass": return .lowPass
        case "highPass": return .highPass
        default: return .flat
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
        case .invalidURL: return "Invalid URL"
        case .downloadFailed: return "Failed to download database"
        case .invalidContent: return "Invalid database content"
        case .parseFailed: return "Failed to parse database"
        }
    }
}
