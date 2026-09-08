//
//  LinkPolicy.swift
//  DSPi Console
//
//  The hub's command authorization table: every vendor bRequest with the
//  transfer directions the firmware accepts for it and the class that decides
//  which roles may issue it.  The table itself lives in
//  Link/policy/commands.json so that hubs and clients in other languages can
//  embed the same copy rather than hand-transcribing it (spec section 9.3).
//
//  Rule 7 of spec section 10: a bRequest the table does not list is treated as
//  config, which is admin-only.  A new firmware command is therefore locked
//  down until somebody classifies it, never quietly exposed to viewers.
//

import Foundation

/// How much authority a command needs.  See spec section 6.3.
enum LinkCommandClass: String, Codable {
    /// Returns state and mutates nothing.  A write-as-read command (a GET
    /// transfer that changes the device) is never `read`.
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
    /// IN, bmRequestType 0xC1.  Also the direction of the write-as-read
    /// commands, which mutate despite reading.
    case get
}

/// One row of the table.
struct LinkCommandEntry: Codable, Equatable {
    let code: UInt8
    /// The firmware's REQ_ name without the prefix, for logs and UI.
    let name: String
    /// Directions the firmware accepts for this code.  Anything else STALLs.
    let dirs: [LinkCommandDirection]
    let commandClass: LinkCommandClass
    let note: String?

    private enum CodingKeys: String, CodingKey {
        case code, name, dirs, note
        case commandClass = "class"
    }
}

/// The parsed table plus the two questions a hub asks of it.
struct LinkPolicy {
    /// Spec version the table was taken from, recorded so a hub can report it.
    let specVersion: String
    let generated: String
    let entries: [LinkCommandEntry]

    /// code -> entry, so classify() does not scan the array per command.
    private let byCode: [UInt8: LinkCommandEntry]

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
        byCode = Dictionary(doc.commands.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
    }

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
    static let bundled: LinkPolicy? = try? LinkPolicy()

    // MARK: - Queries

    func entry(for code: UInt8) -> LinkCommandEntry? { byCode[code] }

    /// Fails safe: an unlisted code, or a direction the firmware does not
    /// accept for a listed code, is config and therefore admin only.
    func classify(code: UInt8, direction: LinkCommandDirection) -> LinkCommandClass {
        guard let entry = byCode[code], entry.dirs.contains(direction) else { return .config }
        return entry.commandClass
    }

    func isAllowed(role: LinkRole, code: UInt8, direction: LinkCommandDirection) -> Bool {
        role.permits(classify(code: code, direction: direction))
    }

    /// Every (code, direction) pair in the table this role may not use, for
    /// the `policy.denied` array in `hello` so clients can grey out controls
    /// without replicating the classification.  Codes absent from the table
    /// are not listed: the client cannot enumerate them either, and they are
    /// already denied by the fail-safe rule.
    func denied(for role: LinkRole) -> [(code: UInt8, direction: LinkCommandDirection)] {
        entries
            .sorted { $0.code < $1.code }
            .flatMap { entry in
                entry.dirs.compactMap { dir in
                    role.permits(entry.commandClass) ? nil : (code: entry.code, direction: dir)
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
