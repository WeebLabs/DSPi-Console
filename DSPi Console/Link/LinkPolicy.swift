//
//  LinkPolicy.swift
//  DSPi Console
//
//  The hub's command authorization table: every firmware 1.1.7 command, by
//  its 16-bit command ID `(page << 8) | command`, with a class for each
//  direction it has.  The table lives in Link/policy/commands.json, the same
//  copy every DSPi Link hub and client embeds (spec section 9.3), taken from
//  the DSPi-Link repository's policy/commands.json.
//
//  Classified by command ID, never by bRequest alone: every page reuses the
//  same command numbers.  Rule 7 of spec section 10: a command ID or a
//  direction the table does not list is config, which is admin only, so a new
//  firmware command is locked down until somebody classifies it.
//

import Foundation

/// How much authority a command needs.  See spec section 6.3.
enum LinkCommandClass: String, Codable {
    /// Returns state and mutates nothing.  Every GET of firmware 1.1.7.
    case read
    /// Changes listening state or runs a transient tool: EQ, routing, volume,
    /// presets, DSP features, test signals, the analyser.
    case control
    /// Changes board wiring, persistence mode or device-level flash config,
    /// or takes the device away.  Admin only.
    case config
}

/// The transfer direction of one tunnelled command.  Named for the command
/// layer rather than the frame codec so the codec can keep its own direction
/// enum without a clash.
enum LinkCommandDirection: String, Codable {
    /// OUT, bmRequestType 0x41: payload travels in the data stage.
    case set
    /// IN, bmRequestType 0xC1.
    case get
}

/// One row of the table.
struct LinkCommandEntry: Codable, Equatable {
    /// `(page << 8) | command`.
    let id: UInt16
    /// `PAGE.NAME`, for logs and UI.
    let name: String
    /// The class of each direction the firmware accepts, keyed "get"/"set".
    /// String keys because an enum-keyed dictionary decodes from an array.
    let classes: [String: LinkCommandClass]
    let note: String?

    func commandClass(for direction: LinkCommandDirection) -> LinkCommandClass? {
        classes[direction.rawValue]
    }

    var directions: [LinkCommandDirection] {
        [.get, .set].filter { classes[$0.rawValue] != nil }
    }
}

/// The parsed table plus the questions a hub asks of it.
struct LinkPolicy {
    /// Spec version the table was taken from, recorded so a hub can report it.
    let specVersion: String
    let generated: String
    let entries: [LinkCommandEntry]

    /// id -> entry, so classify() does not scan the array per command.
    private let byID: [UInt16: LinkCommandEntry]

    private struct Document: Codable {
        let spec_version: String
        let generated: String
        let commands: [LinkCommandEntry]
    }

    /// Parse a table.  The `Data` initializer exists so tests can feed a
    /// fixture without going through the bundle.
    init(data: Data) throws {
        let doc = try JSONDecoder().decode(Document.self, from: data)
        specVersion = doc.spec_version
        generated = doc.generated
        entries = doc.commands
        byID = Dictionary(doc.commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// An empty table: every command classifies as config and only admin may
    /// use it.  The last-resort fallback if the bundled JSON is missing, so the
    /// hub always has a non-nil, fail-safe policy rather than permitting all.
    private init() {
        specVersion = "0"
        generated = ""
        entries = []
        byID = [:]
    }

    static let empty = LinkPolicy()

    /// Load the copy bundled with the app.  `Link/policy` is a synchronized
    /// group, so commands.json is copied into the bundle automatically.
    init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "commands", withExtension: "json") else {
            throw LinkPolicyError.resourceMissing
        }
        try self.init(data: Data(contentsOf: url))
    }

    enum LinkPolicyError: Error {
        case resourceMissing
    }

    /// The shared instance, or nil if the resource is missing or malformed.
    /// A hub that cannot load its table must refuse to forward anything
    /// rather than fall back to permitting everything.
    static let bundled: LinkPolicy? = try? LinkPolicy(bundle: .main)

    // MARK: - Queries

    func entry(for id: UInt16) -> LinkCommandEntry? { byID[id] }

    /// Fails safe: an unlisted command ID, or a direction the firmware does not
    /// accept for a listed one, is config and therefore admin only.  Page 0,
    /// where every 1.1.6-style request lands, lists nothing.
    func classify(id: UInt16, direction: LinkCommandDirection) -> LinkCommandClass {
        byID[id]?.commandClass(for: direction) ?? .config
    }

    func isAllowed(role: LinkRole, id: UInt16, direction: LinkCommandDirection) -> Bool {
        role.permits(classify(id: id, direction: direction))
    }

    /// Every (id, direction) pair in the table this role may not use, for the
    /// `policy.denied_ids` array in the auth `ok` (spec 7.3), so clients can
    /// grey out controls without replicating the classification.  IDs absent
    /// from the table are not listed: they are already denied by the
    /// fail-safe rule.
    func denied(for role: LinkRole) -> [(id: UInt16, direction: LinkCommandDirection)] {
        entries
            .sorted { $0.id < $1.id }
            .flatMap { entry in
                entry.directions.compactMap { dir in
                    role.permits(entry.commandClass(for: dir) ?? .config) ? nil : (id: entry.id, direction: dir)
                }
            }
    }
}

extension LinkRole {
    /// Roles are cumulative, so this is a rank comparison rather than a set.
    func permits(_ commandClass: LinkCommandClass) -> Bool {
        switch self {
        case .viewer:  return commandClass == .read
        case .control: return commandClass == .read || commandClass == .control
        case .admin:   return true
        }
    }
}
