//
//  LinkRole.swift
//  DSPi Console
//
//  Authorization roles a DSPi Link hub grants to a paired client.  See
//  Documentation/dspi_link_protocol_spec.md section 6.3.  The raw values are
//  the strings that travel on the wire (`"role": "control"`), so they must
//  not be renamed.
//

import Foundation

/// What a session is allowed to do.  Ordered from least to most privileged;
/// `CaseIterable` order is the order the client-management UI lists them in.
enum LinkRole: String, Codable, CaseIterable {
    /// Read-direction commands, poll subscriptions, notifications.
    case viewer
    /// Everything a viewer may do, plus *control* SETs (EQ, routing, volumes,
    /// presets, DSP features).
    case control
    /// Everything, including *config* (pins, input sources, flash writes of
    /// device-level config, firmware install, hub and client management).
    case admin
}
