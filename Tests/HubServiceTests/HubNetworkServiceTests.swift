import Foundation
import Testing
@testable import HubService

@Suite("Swift network share publication")
@MainActor
struct HubNetworkServiceTests {
  private let serviceKey = "service-key"

  @Test("mutations atomically replace the complete share set")
  func atomicReplacement() async throws {
    let recorder = ReplacementRecorder()
    let publisher = makePublisher(replace: recorder.replace)

    try await publisher.publish(share("s3", port: 9000))
    try await publisher.publish(share("game", port: 25565))
    try await publisher.update(
      "s3",
      port: 9001,
      policy: .set(.hub)
    )
    try await publisher.remove("game")

    #expect(recorder.requests.map { $0.map(\.name) } == [
      ["s3"],
      ["game", "s3"],
      ["game", "s3"],
      ["s3"],
    ])
    #expect(recorder.requests[2].first { $0.name == "s3" }?.target.port == 9001)
    #expect(recorder.requests[2].first { $0.name == "s3" }?.policy == .hub)
    #expect(publisher.declaredShares.map(\.name) == ["s3"])
  }

  @Test("failed replacement rolls back the declaration")
  func rollback() async throws {
    let recorder = ReplacementRecorder()
    let publisher = makePublisher(replace: recorder.replace)
    try await publisher.publish(share("s3", port: 9000))
    publisher.setReplaceHandler { _ in throw TestFailure() }

    await #expect(throws: TestFailure.self) {
      try await publisher.update("s3", port: 9001)
    }

    #expect(publisher.declaredShares.first?.target.port == 9000)
  }

  @Test("reconnect refreshes attestations and reports publications")
  func reconnect() async throws {
    let recorder = ReplacementRecorder()
    let publisher = makePublisher(replace: recorder.replace)
    try await publisher.publish(share("s3", port: 9000))
    var callbackPublications: [NetworkSharePublication] = []
    publisher.onReconnect { callbackPublications = $0 }

    let result = try await publisher.republish()

    #expect(recorder.requests.count == 2)
    #expect(result == callbackPublications)
    #expect(publisher.publication(forShare: "s3") == result.first)
  }

  @Test("Hub response must contain one publication per declared share")
  func rejectsPublicationCountMismatch() async throws {
    let publisher = makePublisher { _ in [] }

    await #expect(throws: HubNetworkError.invalidHubResponse) {
      try await publisher.publish(share("s3", port: 9000))
    }
    #expect(publisher.declaredShares.isEmpty)
    #expect(publisher.publications.isEmpty)
  }

  @Test("expired agent attestations fail closed")
  func rejectsExpiredAttestation() async {
    let publisher = HubNetworkService { share, serviceKey, _ in
      AgentAttestation(
        attestationId: "expired",
        serviceKey: serviceKey,
        key: "agent-key",
        shareName: share.name,
        protocol: share.protocol,
        target: share.target,
        issuedAt: "2020-01-01T00:00:00Z",
        expiresAt: "2020-01-01T00:05:00Z",
        signature: "signature"
      )
    }
    configure(publisher, replace: { _ in [] })

    await #expect(throws: HubNetworkError.attestationExpired) {
      try await publisher.publish(share("s3", port: 9000))
    }
    #expect(publisher.declaredShares.isEmpty)
  }

  @Test("policy can be cleared explicitly")
  func clearsPolicy() async throws {
    let recorder = ReplacementRecorder()
    let publisher = makePublisher(replace: recorder.replace)
    try await publisher.publish(share("s3", port: 9000))

    try await publisher.update(
      "s3",
      policy: .clear
    )

    #expect(publisher.declaredShares.first?.policy == nil)
    #expect(recorder.requests.last?.first?.policy == nil)
  }

  @Test("publication response order matches sorted declaration order")
  func publicationOrderContract() async throws {
    let recorder = ReplacementRecorder()
    let publisher = makePublisher(replace: recorder.replace)
    try await publisher.publish(share("s3", port: 9000))
    publisher.setReplaceHandler { shares in
      #expect(shares.map(\.name) == ["game", "s3"])
      return [
        publication("game-result"),
        publication("s3-result"),
      ]
    }
    try await publisher.publish(share("game", port: 25565))

    #expect(publisher.publication(forShare: "game")?.resourceId == "game-result")
    #expect(publisher.publication(forShare: "s3")?.resourceId == "s3-result")
  }

  @Test("overlapping mutations serialize through rollback")
  func serializesMutations() async throws {
    let blocker = MutationBlocker()
    let publisher = makePublisher(replace: blocker.replace)
    let first = Task {
      try await publisher.publish(share("s3", port: 9000))
    }
    await blocker.waitUntilFirstCall()
    let second = Task {
      try await publisher.publish(share("s3", port: 9001))
    }
    await Task.yield()
    #expect(blocker.callCount == 1)
    blocker.releaseFirst()
    await #expect(throws: TestFailure.self) {
      try await first.value
    }
    _ = try await second.value

    #expect(publisher.declaredShares.first?.target.port == 9001)
    #expect(blocker.callCount == 2)
  }

  private func share(_ name: String, port: UInt16) -> NetworkShare {
    NetworkShare(
      name: name,
      protocol: .tcp,
      target: LocalTarget(port: port)
    )
  }

  private func makePublisher(
    replace: @escaping HubNetworkService.ReplaceHandler
  ) -> HubNetworkService {
    let publisher = HubNetworkService(attestationProvider: attestation)
    configure(publisher, replace: replace)
    return publisher
  }

  private func configure(
    _ publisher: HubNetworkService,
    replace: @escaping HubNetworkService.ReplaceHandler
  ) {
    publisher.configureIdentity(serviceKey: serviceKey, sign: signer)
    publisher.setReplaceHandler(replace)
  }

  private func signer(_ challenge: String) async throws -> String {
    "signature:\(challenge)"
  }

  private func attestation(
    share: NetworkShare,
    serviceKey: String,
    sign: @escaping @Sendable (String) async throws -> String
  ) async throws -> AgentAttestation {
    let issuedAt = Date()
    let expiresAt = issuedAt.addingTimeInterval(5 * 60)
    return AgentAttestation(
      attestationId: "attestation-\(share.name)",
      serviceKey: serviceKey,
      key: "agent-key",
      shareName: share.name,
      protocol: share.protocol,
      target: share.target,
      issuedAt: ISO8601DateFormatter().string(from: issuedAt),
      expiresAt: ISO8601DateFormatter().string(from: expiresAt),
      signature: try await sign("challenge-\(share.name)")
    )
  }

  private func publication(_ resourceId: String) -> NetworkSharePublication {
    NetworkSharePublication(
      resourceId: resourceId,
      authority: "\(resourceId).hub",
      providerId: resourceId,
      protocol: .tcp,
      overlayAddress: "fd00::1",
      port: 9000
    )
  }
}

@MainActor
private final class ReplacementRecorder {
  var requests: [[WireNetworkShare]] = []

  func replace(_ shares: [WireNetworkShare]) async throws -> [NetworkSharePublication] {
    requests.append(shares)
    return shares.map {
      NetworkSharePublication(
        resourceId: "resource-\($0.name)",
        authority: "\($0.name).hub",
        providerId: "provider-\($0.name)",
        protocol: $0.protocol,
        overlayAddress: "fd00::1",
        port: $0.target.port
      )
    }
  }
}

private struct TestFailure: Error {}

@MainActor
private final class MutationBlocker {
  private(set) var callCount = 0
  private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstRelease: CheckedContinuation<Void, Never>?

  func waitUntilFirstCall() async {
    if callCount > 0 {
      return
    }
    await withCheckedContinuation { firstCallWaiters.append($0) }
  }

  func releaseFirst() {
    firstRelease?.resume()
    firstRelease = nil
  }

  func replace(_ shares: [WireNetworkShare]) async throws -> [NetworkSharePublication] {
    callCount += 1
    if callCount == 1 {
      firstCallWaiters.forEach { $0.resume() }
      firstCallWaiters.removeAll()
      await withCheckedContinuation { firstRelease = $0 }
      throw TestFailure()
    }
    return shares.map {
      NetworkSharePublication(
        resourceId: "resource-\($0.name)",
        authority: "\($0.name).hub",
        providerId: "provider-\($0.name)",
        protocol: $0.protocol,
        overlayAddress: "fd00::1",
        port: $0.target.port
      )
    }
  }
}
