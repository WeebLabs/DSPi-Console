//
//  LinkClientProtocol.swift
//  DSPi Console
//
//  What a DSPi Link client connection offers the rest of the app: one hub,
//  one WebSocket, the protocol's session lifecycle, and the command,
//  notification and poll channels.  NetworkTransport builds on this; the
//  concrete LinkClient (WebSocket over URLSession) implements it.  Fixed here
//  so the two can be written and tested independently.  See spec sections
//  5, 7 and 8.
//

import Foundation
import Combine

enum LinkClientState: Equatable {
    case disconnected
    case connecting
    /// The hub answered hello and wants authentication.  `needsPairing` is
    /// true when the client holds no token for this hub (or the hub rejected
    /// it), so the UI must ask for a PIN.
    case awaitingAuth(needsPairing: Bool)
    case ready
    /// The hub closed the session with a protocol close code (4001 auth
    /// timeout, 4002 revoked, 4003 shutting down) or the socket failed.
    case failed(String)
}

enum LinkClientError: Error, Equatable {
    case notConnected
    case unauthenticated
    case rejected(code: String, message: String?)   // an `err` reply
    case timeout
    case protocolError(String)
}

/// One connection to one hub.  All callbacks and publishers deliver on the
/// main thread.  Requests may be issued from any thread.
protocol LinkClientProtocol: AnyObject {
    var state: LinkClientState { get }
    var statePublisher: AnyPublisher<LinkClientState, Never> { get }

    /// From the hub's hello, once received.
    var hubInfo: LinkHubInfo? { get }
    var capabilities: [String] { get }
    var limits: LinkLimits? { get }

    /// From the auth ok: this connection's session id (0 until ready) and role.
    var sessionID: LinkSessionID { get }
    var role: LinkRole? { get }

    /// The hub's device inventory, kept current from device.added/changed/
    /// removed events after the initial device.list.
    var devices: [LinkDeviceInfo] { get }
    var devicesPublisher: AnyPublisher<[LinkDeviceInfo], Never> { get }

    /// Open the socket, send hello, and authenticate with `token` if given.
    /// With no token, or a rejected one, the state settles on
    /// `.awaitingAuth(needsPairing: true)` and the caller pairs.
    func connect(to url: URL, clientName: String, token: String?)

    /// Pair with the PIN the hub is showing.  On success the returned token
    /// is what to store for next time, and the state becomes `.ready`.
    func pair(pin: String, clientName: String, role: LinkRole,
              completion: @escaping (Result<String, LinkClientError>) -> Void)

    func disconnect()

    /// Tunnel one vendor command.  The tag is assigned by the client; the
    /// caller's `tag` field is ignored.
    func command(_ request: LinkCmdRequest, completion: @escaping (LinkCmdResponse) -> Void)

    func snapshot(handle: UInt8,
                  completion: @escaping (Result<LinkSnapshotBody, LinkClientError>) -> Void)

    func subscribePolls(handle: UInt8, polls: [LinkPollSpec],
                        completion: @escaping (Result<[LinkPollGrant], LinkClientError>) -> Void)
    func unsubscribePolls(handle: UInt8, slots: [Int])

    func acquireLock(handle: UInt8, reason: String?, timeoutMs: Int?,
                     completion: @escaping (Result<Void, LinkClientError>) -> Void)
    func releaseLock(handle: UInt8)

    /// Data-plane pushes from the hub.
    var onNotify: ((LinkNotifyFrame) -> Void)? { get set }
    var onPoll: ((LinkPollFrame) -> Void)? { get set }
    var onResync: ((LinkResyncFrame) -> Void)? { get set }
}
