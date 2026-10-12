import Foundation
import Testing
@testable import HubService

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@Suite("Hub Network signed connection grants")
struct NetworkGrantVerifierTests {
  private let publicKey =
    "MCowBQYDK2VwAyEAA6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="

  @Test("Swift canonical bytes and Ed25519 verification match shared v1 vector")
  func sharedSignatureVector() throws {
    let grant = fixtureGrant()
    let input = try HubNetworkSignedEnvelope.signatureInput(
      for: grant,
      domain: "hub-network/connection-grant/v1"
    )
    #expect(
      SHA256Digest.hexDigest(input)
        == "7b6765fc35a70d978dd44078f50c039cf051ed509723504a45bae1dfdca65f8b"
    )
    #expect(
      try HubNetworkSignedEnvelope.verifyConnectionGrantSignature(
        grant,
        publicKey: publicKey
      )
    )
  }

  @Test("production validation accepts fully bound trusted grant")
  func validatesTrustedBinding() throws {
    let grant = signedProductionGrant()
    try HubNetworkSignedEnvelope.validateConnectionGrant(
      grant,
      binding: binding(for: grant),
      now: timestamp("2026-07-25T00:00:30.000Z")
    )
  }

  @Test("malformed signature and public key report distinct errors")
  func malformedCryptographicInput() {
    let malformedSignature = copy(fixtureGrant(), signature: "not-base64!")
    #expect(throws: HubNetworkGrantValidationError.invalidSignature) {
      try HubNetworkSignedEnvelope.verifyConnectionGrantSignature(
        malformedSignature,
        publicKey: publicKey
      )
    }
    #expect(throws: HubNetworkGrantValidationError.invalidPublicKey) {
      try HubNetworkSignedEnvelope.verifyConnectionGrantSignature(
        fixtureGrant(),
        publicKey: "not-base64!"
      )
    }
  }

  @Test("trust, caller, generation, lifetime, and signature fail closed")
  func rejectsInvalidAuthorization() throws {
    let grant = signedProductionGrant()
    let now = timestamp("2026-07-25T00:00:30.000Z")

    #expect(throws: HubNetworkGrantValidationError.trustRootMismatch) {
      try HubNetworkSignedEnvelope.validateConnectionGrant(
        grant,
        binding: ConnectionGrantBinding(
          trustedHubKey: Data(repeating: 0, count: 44).base64EncodedString(),
          hubNetworkId: grant.hubNetworkId,
          callerKey: grant.callerKey,
          callerWireGuardKey: grant.callerWireGuardKey
        ),
        now: now
      )
    }
    #expect(throws: HubNetworkGrantValidationError.bindingMismatch) {
      try HubNetworkSignedEnvelope.validateConnectionGrant(
        grant,
        binding: ConnectionGrantBinding(
          trustedHubKey: grant.hubKey,
          hubNetworkId: grant.hubNetworkId,
          callerKey: "substituted",
          callerWireGuardKey: grant.callerWireGuardKey
        ),
        now: now
      )
    }
    #expect(throws: HubNetworkGrantValidationError.generationMismatch) {
      try HubNetworkSignedEnvelope.validateConnectionGrant(
        grant,
        binding: binding(for: grant, generation: grant.generation + 1),
        now: now
      )
    }
    #expect(throws: HubNetworkGrantValidationError.bindingMismatch) {
      try HubNetworkSignedEnvelope.validateConnectionGrant(
        grant,
        binding: binding(for: grant, resourceId: "another-resource"),
        now: now
      )
    }
    #expect(throws: HubNetworkGrantValidationError.invalidLifetime) {
      try HubNetworkSignedEnvelope.validateConnectionGrant(
        grant,
        binding: binding(for: grant),
        now: timestamp("2026-07-25T00:02:00.000Z")
      )
    }

    let tampered = copy(grant, destinationPort: grant.destinationPort + 1)
    #expect(throws: HubNetworkGrantValidationError.invalidSignature) {
      try HubNetworkSignedEnvelope.validateConnectionGrant(
        tampered,
        binding: binding(for: tampered),
        now: now
      )
    }
  }

  @Test("gateway grant binds Hub, both peers, capability, and generation")
  func validatesGatewayGrantBindings() throws {
    let grant = signedGatewayGrant()
    let now = timestamp("2026-07-25T00:00:30.000Z")
    let binding = GatewayGrantBinding(
      trustedHubKey: grant.hubKey,
      hubNetworkId: grant.hubNetworkId,
      gatewayKey: grant.gatewayKey,
      gatewayWireGuardKey: grant.gatewayWireGuardKey,
      generation: grant.generation,
      clientKey: grant.clientKey,
      clientWireGuardKey: grant.clientWireGuardKey,
      ipv4: true,
      ipv6: true,
      dns: true
    )
    try HubNetworkSignedEnvelope.validateGatewayGrant(
      grant,
      binding: binding,
      now: now
    )

    #expect(throws: HubNetworkGrantValidationError.bindingMismatch) {
      try HubNetworkSignedEnvelope.validateGatewayGrant(
        grant,
        binding: GatewayGrantBinding(
          trustedHubKey: grant.hubKey,
          hubNetworkId: "another-hub",
          gatewayKey: grant.gatewayKey,
          gatewayWireGuardKey: grant.gatewayWireGuardKey,
          generation: grant.generation
        ),
        now: now
      )
    }
    #expect(throws: HubNetworkGrantValidationError.generationMismatch) {
      try HubNetworkSignedEnvelope.validateGatewayGrant(
        grant,
        binding: GatewayGrantBinding(
          trustedHubKey: grant.hubKey,
          hubNetworkId: grant.hubNetworkId,
          gatewayKey: grant.gatewayKey,
          gatewayWireGuardKey: grant.gatewayWireGuardKey,
          generation: grant.generation + 1
        ),
        now: now
      )
    }

    let tampered = GatewayGrant(
      grantId: grant.grantId,
      hubKey: grant.hubKey,
      hubNetworkId: grant.hubNetworkId,
      clientKey: grant.clientKey,
      clientWireGuardKey: grant.clientWireGuardKey,
      gatewayKey: grant.gatewayKey,
      gatewayWireGuardKey: grant.gatewayWireGuardKey,
      ipv4: false,
      ipv6: grant.ipv6,
      dns: grant.dns,
      generation: grant.generation,
      issuedAt: grant.issuedAt,
      expiresAt: grant.expiresAt,
      signature: grant.signature
    )
    #expect(throws: HubNetworkGrantValidationError.invalidSignature) {
      try HubNetworkSignedEnvelope.validateGatewayGrant(
        tampered,
        binding: GatewayGrantBinding(
          trustedHubKey: grant.hubKey,
          hubNetworkId: grant.hubNetworkId,
          gatewayKey: grant.gatewayKey,
          gatewayWireGuardKey: grant.gatewayWireGuardKey,
          generation: grant.generation
        ),
        now: now
      )
    }
  }

  @Test("ticket and candidate decode shared Go fixture")
  func rendezvousModelsDecodeFixture() throws {
    let fixture = """
      {
        "ticket": {
          "version": 1, "ticketId": "ticket-1", "hubKey": "hub-key",
          "hubNetworkId": "network-1", "key": "agent-key", "nodeId": "node-1",
          "roles": ["rendezvous"], "sessionPurpose": "peer-connect",
          "issuedAt": "2026-07-25T00:00:00.000Z",
          "expiresAt": "2026-07-25T00:01:00.000Z", "signature": "sig"
        },
        "candidate": {
          "version": 1, "candidateId": "candidate-1", "sessionId": "session-1",
          "key": "agent-key", "kind": "server-reflexive",
          "transport": "udp", "address": "198.51.100.4", "port": 51820,
          "priority": 100, "expiresAt": "2026-07-25T00:01:00.000Z"
        }
      }
      """
    struct Fixture: Decodable {
      let ticket: RendezvousTicket
      let candidate: NetworkCandidate
    }
    let value = try JSONDecoder().decode(Fixture.self, from: Data(fixture.utf8))
    #expect(value.ticket.roles == [.rendezvous])
    #expect(value.ticket.sessionPurpose == .peerConnect)
    #expect(value.candidate.kind == .serverReflexive)
    #expect(value.candidate.foundation == nil)
  }

  private func fixtureGrant() -> ConnectionGrant {
    ConnectionGrant(
      grantId: "grant-1",
      hubKey: "hub-key",
      hubNetworkId: "018f0f67-89ab-7def-8123-456789abcdef",
      callerKey: "caller-profile-key",
      callerWireGuardKey: "caller-wg-key",
      callerAddress: "100.96.0.3",
      targetKey: "target-agent-key",
      targetWireGuardKey: "target-wg-key",
      resourceId: "hnr1_vu5lgvuep3ijwvktdc3c7jtlkbq7tpio",
      providerId: "provider-1",
      protocol: .tcp,
      destinationAddress: "100.96.0.2",
      destinationPort: 9001,
      generation: 4,
      issuedAt: "2026-07-25T00:00:00.000Z",
      expiresAt: "2026-07-25T00:01:00.000Z",
      signature:
        "F2b4xfGgSq6+9Ru9lnKc1sWH4OU8vYul+lAsfNzP1HJXGck6mVbdfZuSHwoZEcS7s4Da7Dw/FWiKPgPKZm9SAA=="
    )
  }

  private func signedProductionGrant() -> ConnectionGrant {
    let unsigned = copy(fixtureGrant(), hubKey: publicKey, signature: "")
    let seed = Data((0 ..< 32).map(UInt8.init))
    let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    let input = try! HubNetworkSignedEnvelope.signatureInput(
      for: unsigned,
      domain: "hub-network/connection-grant/v1"
    )
    return copy(unsigned, signature: try! key.signature(for: input).base64EncodedString())
  }

  private func signedGatewayGrant() -> GatewayGrant {
    let seed = Data((0 ..< 32).map(UInt8.init))
    let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    let unsigned = GatewayGrant(
      grantId: "gateway-grant-1",
      hubKey: publicKey,
      hubNetworkId: "network-1",
      clientKey: "client-profile",
      clientWireGuardKey: "client-wg",
      gatewayKey: "gateway-profile",
      gatewayWireGuardKey: "gateway-wg",
      ipv4: true,
      ipv6: true,
      dns: true,
      generation: 7,
      issuedAt: "2026-07-25T00:00:00.000Z",
      expiresAt: "2026-07-25T00:01:00.000Z",
      signature: ""
    )
    let input = try! HubNetworkSignedEnvelope.signatureInput(
      for: unsigned,
      domain: "hub-network/gateway-grant/v1"
    )
    return GatewayGrant(
      grantId: unsigned.grantId,
      hubKey: unsigned.hubKey,
      hubNetworkId: unsigned.hubNetworkId,
      clientKey: unsigned.clientKey,
      clientWireGuardKey: unsigned.clientWireGuardKey,
      gatewayKey: unsigned.gatewayKey,
      gatewayWireGuardKey: unsigned.gatewayWireGuardKey,
      ipv4: unsigned.ipv4,
      ipv6: unsigned.ipv6,
      dns: unsigned.dns,
      generation: unsigned.generation,
      issuedAt: unsigned.issuedAt,
      expiresAt: unsigned.expiresAt,
      signature: try! key.signature(for: input).base64EncodedString()
    )
  }

  private func binding(
    for grant: ConnectionGrant,
    generation: UInt64? = nil,
    resourceId: String? = nil
  ) -> ConnectionGrantBinding {
    ConnectionGrantBinding(
      trustedHubKey: grant.hubKey,
      hubNetworkId: grant.hubNetworkId,
      callerKey: grant.callerKey,
      callerWireGuardKey: grant.callerWireGuardKey,
      generation: generation,
      targetKey: grant.targetKey,
      targetWireGuardKey: grant.targetWireGuardKey,
      resourceId: resourceId ?? grant.resourceId,
      providerId: grant.providerId,
      protocol: grant.protocol,
      destinationAddress: grant.destinationAddress,
      destinationPort: grant.destinationPort
    )
  }

  private func copy(
    _ grant: ConnectionGrant,
    hubKey: String? = nil,
    destinationPort: UInt16? = nil,
    signature: String? = nil
  ) -> ConnectionGrant {
    ConnectionGrant(
      version: grant.version,
      grantId: grant.grantId,
      hubKey: hubKey ?? grant.hubKey,
      hubNetworkId: grant.hubNetworkId,
      callerKey: grant.callerKey,
      callerWireGuardKey: grant.callerWireGuardKey,
      callerAddress: grant.callerAddress,
      targetKey: grant.targetKey,
      targetWireGuardKey: grant.targetWireGuardKey,
      resourceId: grant.resourceId,
      providerId: grant.providerId,
      protocol: grant.protocol,
      destinationAddress: grant.destinationAddress,
      destinationPort: destinationPort ?? grant.destinationPort,
      generation: grant.generation,
      issuedAt: grant.issuedAt,
      expiresAt: grant.expiresAt,
      signature: signature ?? grant.signature
    )
  }

  private func timestamp(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)!
  }
}

private enum SHA256Digest {
  static func hexDigest(_ data: Data) -> String {
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
