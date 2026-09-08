//
//  LinkRole.swift
//  DSPi Console
//
//  The role a DSPi Link session was granted.  Kept in its own file because
//  both the control-plane messages and the authorization policy need it and
//  neither owns it.  See Documentation/dspi_link_protocol_spec.md section 6.3.
//

import Foundation

/// What a session is allowed to do.  Roles are cumulative: `control` is
/// `viewer` plus the control class, `admin` is everything.
enum LinkRole: String, Codable, CaseIterable {
    case viewer
    case control
    case admin
}
