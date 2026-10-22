//
//  Pairing.swift
//  HubUI
//
//  Pairing state and status for "Connect to a Hub" screens (protocol §12).
//

import Foundation
#if canImport(Observation)
import Observation
#endif
import SwiftUI
import HubService

/// Runs `hub/pair` and keeps its state for a view. The hub verifies one code at a time and at least a second each,
/// so `verifying` stays visible and `verifyingSince` tells a view when to explain the wait.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
@Observable
public final class HubPairing {
  public private(set) var state: PairingState = .idle
  public private(set) var verifyingSince: Date?
  public init() { }

  /// - Returns: the result once the hub made this client an owner; `nil` with `state` set to `.failed` otherwise
  @discardableResult
  public func pair(_ client: HubClient, code: String) async -> PairingResult? {
    guard !state.isWorking else { return nil }
    state = .connecting
    verifyingSince = nil
    do {
      let result = try await client.pair(code: code) { [weak self] state in
        self?.state = state
        if state == .verifying { self?.verifyingSince = Date() }
      }
      state = .paired(result)
      return result
    } catch {
      state = .failed(PairingError(error))
      return nil
    }
  }

  public func fail(_ error: PairingError) {
    state = .failed(error)
  }

  public func reset() {
    state = .idle
    verifyingSince = nil
  }
}

/// One line for a pairing state: progress while connecting and verifying (with a note when the hub takes longer than a
/// few seconds, as it queues codes), a check mark when paired, the error in red when it failed.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public struct PairingStatusView: View {
  let state: PairingState
  let verifyingSince: Date?
  public init(state: PairingState, verifyingSince: Date? = nil) {
    self.state = state
    self.verifyingSince = verifyingSince
  }
  public init(_ pairing: HubPairing) {
    self.init(state: pairing.state, verifyingSince: pairing.verifyingSince)
  }
  public var body: some View {
    switch state {
    case .idle:
      EmptyView()
    case .connecting:
      progress("Connecting to the hub…")
    case .verifying:
      TimelineView(.periodic(from: verifyingSince ?? .now, by: 1)) { context in
        let waited = verifyingSince.map { context.date.timeIntervalSince($0) } ?? 0
        progress(waited < 4 ? "Checking the code…" : "Checking the code… the hub checks one code at a time")
      }
    case .paired(let result):
      Label(result.name.map { "Paired with \($0). This device is an owner." } ?? "Paired. This device is an owner.",
            systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .failed(let error):
      Label(error.description, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    }
  }
  @ViewBuilder
  func progress(_ text: String) -> some View {
    HStack(spacing: 6) {
      ProgressView().controlSize(.small)
      Text(text)
    }.foregroundStyle(.secondary)
  }
}
