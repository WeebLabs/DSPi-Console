//
//  LinkClientFake.swift
//  DSPi ConsoleTests
//
//  A scriptable LinkClientProtocol for transport tests: no socket, canned
//  answers, recorded requests, and state/device publishers the test drives.
//

import Foundation
import Combine
@testable import DSPi_Console

final class LinkClientFake: LinkClientProtocol {
    private let stateSubject = CurrentValueSubject<LinkClientState, Never>(.disconnected)
    private let devicesSubject = CurrentValueSubject<[LinkDeviceInfo], Never>([])

    var state: LinkClientState { stateSubject.value }
    var statePublisher: AnyPublisher<LinkClientState, Never> { stateSubject.eraseToAnyPublisher() }
    var hubInfo: LinkHubInfo?
    var capabilities: [String] = ["cmd", "notify", "poll"]
    var limits: LinkLimits?
    var sessionID: LinkSessionID = 0
    var role: LinkRole?
    var devices: [LinkDeviceInfo] { devicesSubject.value }
    var devicesPublisher: AnyPublisher<[LinkDeviceInfo], Never> { devicesSubject.eraseToAnyPublisher() }

    var onNotify: ((LinkNotifyFrame) -> Void)?
    var onPoll: ((LinkPollFrame) -> Void)?
    var onResync: ((LinkResyncFrame) -> Void)?

    // Script
    var connectCalls: [(URL, String?)] = []
    var pairCalls: [String] = []
    var pairResult: Result<String, LinkClientError> = .success("tok-abc")
    var commands: [LinkCmdRequest] = []
    var responder: ((LinkCmdRequest) -> LinkCmdResponse) = { req in
        LinkCmdResponse(tag: req.tag, status: .ok, payload: req.direction == .get ? Data([1, 2, 3, 4]) : Data())
    }
    var snapshotBody: LinkSnapshotBody?
    var disconnectCalls = 0

    // Test-side drivers
    func setState(_ s: LinkClientState) { stateSubject.send(s) }
    func setDevices(_ d: [LinkDeviceInfo]) { devicesSubject.send(d) }

    func connect(to url: URL, clientName: String, token: String?) {
        connectCalls.append((url, token))
    }
    func pair(pin: String, clientName: String, role: LinkRole,
              completion: @escaping (Result<String, LinkClientError>) -> Void) {
        pairCalls.append(pin)
        if case .success = pairResult { sessionID = 7; self.role = role; stateSubject.send(.ready) }
        completion(pairResult)
    }
    func disconnect() { disconnectCalls += 1; stateSubject.send(.disconnected) }
    func command(_ request: LinkCmdRequest, completion: @escaping (LinkCmdResponse) -> Void) {
        commands.append(request)
        let r = responder(request)
        DispatchQueue.main.async { completion(r) }
    }
    func snapshot(handle: UInt8, completion: @escaping (Result<LinkSnapshotBody, LinkClientError>) -> Void) {
        let body = snapshotBody
        DispatchQueue.main.async { completion(body.map { .success($0) } ?? .failure(.rejected(code: "no_device", message: nil))) }
    }
    func subscribePolls(handle: UInt8, polls: [LinkPollSpec],
                        completion: @escaping (Result<[LinkPollGrant], LinkClientError>) -> Void) {
        completion(.success(polls.map { LinkPollGrant(slot: $0.slot, hz: $0.hz) }))
    }
    func unsubscribePolls(handle: UInt8, slots: [Int]) {}
    func acquireLock(handle: UInt8, reason: String?, timeoutMs: Int?,
                     completion: @escaping (Result<Void, LinkClientError>) -> Void) { completion(.success(())) }
    func releaseLock(handle: UInt8) {}
}
