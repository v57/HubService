import Foundation
import Testing
import CryptoKit
@testable import HubService

private func compactInvitation(expires: UInt32, query: String? = nil) -> (
  code: String, url: String, payload: String, publicKey: String
) {
  let key = Curve25519.Signing.PrivateKey()
  func part(_ value: Data) -> String {
    value.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
  var expiration = expires.bigEndian
  var nonce = UInt32(7).bigEndian
  let expirationPart = withUnsafeBytes(of: &expiration) { part(Data($0)) }
  let noncePart = withUnsafeBytes(of: &nonce) { part(Data($0)) }
  let publicKey = part(key.publicKey.rawRepresentation)
  var payload = "\(publicKey).\(expirationPart).\(noncePart)"
  if let query {
    payload += "?" + query
  }
  let signature = try! key.signature(for: Data(payload.utf8))
  let code = payload + "/" + part(signature)
  return (code, NetworkInvitationParser.urlPrefix + code, payload, publicKey)
}

private struct SharesReplace: Codable, Equatable {
  let version: Int
  let type: String
  let requestId: String?
  let payload: NetworkSharesReplace
}

private struct Grant: Codable, Equatable {
  let version: Int
  let grantId: String
  let hubKey: String
  let hubNetworkId: String
  let callerKey: String
  let callerWireGuardKey: String
  let callerAddress: String
  let targetKey: String
  let targetWireGuardKey: String
  let resourceId: String
  let providerId: String
  let `protocol`: String
  let destinationAddress: String
  let destinationPort: UInt16
  let generation: UInt64
  let issuedAt: String
  let expiresAt: String
  let signature: String
}

private struct Ticket: Codable, Equatable {
  let version: Int
  let ticketId: String
  let hubKey: String
  let hubNetworkId: String
  let key: String
  let nodeId: String
  let roles: [String]
  let sessionPurpose: String
  let issuedAt: String
  let expiresAt: String
  let signature: String
}

private struct Candidate: Codable, Equatable {
  let version: Int
  let candidateId: String
  let sessionId: String
  let key: String
  let kind: String
  let transport: String
  let address: String
  let port: UInt16
  let priority: UInt32
  let foundation: String?
  let expiresAt: String
}

private struct RendezvousFixture: Codable, Equatable {
  let ticket: Ticket
  let candidate: Candidate
  let observedEndpoint: NetworkObservedEndpoint
}

private struct GatewayFixture: Codable, Equatable {
  let capability: GatewayCapability
  let status: GatewayStatus
  let grant: GatewayGrant
  let revocation: GatewayRevocation
  let diagnostic: GatewayDiagnostic
}

private struct DirectBootstrapFixture: Codable, Equatable {
  let request: DirectBootstrapRequest
  let response: DirectBootstrapResponse
}

@Suite("Hub Network v1 Codable compatibility")
struct HubNetworkWireCompatibilityTests {
  @Test("shared Go fixtures decode and survive a semantic round trip")
  func sharedFixturesRoundTrip() throws {
    try roundTrip(SharesReplace.self, fixture: "shares-replace.json")
    try roundTrip(Grant.self, fixture: "grant.json")
    try roundTrip(RendezvousFixture.self, fixture: "rendezvous.json")
    try roundTrip(GatewayFixture.self, fixture: "gateway.json")
    try roundTrip(DirectBootstrapFixture.self, fixture: "direct-bootstrap.json")
  }

  @Test("compact invitation verifies exact signed payload")
  func invitationFixture() throws {
    let now = Date(timeIntervalSince1970: 1_785_796_800)
    let fixture = compactInvitation(expires: UInt32(now.timeIntervalSince1970) + 600)
    let decodedCode = try NetworkInvitationParser.decode(fixture.code, now: now)
    let decodedURL = try NetworkInvitationParser.decode(fixture.url, now: now)
    #expect(decodedCode == decodedURL)
    #expect(decodedCode.node == NetworkInvitationParser.defaultNode)
    #expect(decodedCode.url == fixture.url)
    #expect(decodedCode.payload == fixture.payload)
    #expect(decodedCode.publicKey == fixture.publicKey)
  }

  @Test("invitation parser rejects non-canonical and untrusted inputs")
  func invitationParserRejectsInvalidInputs() throws {
    let now = Date(timeIntervalSince1970: 1_785_796_800)
    let fixture = compactInvitation(expires: UInt32(now.timeIntervalSince1970) + 600)

    #expect(throws: NetworkInvitationError.self) {
      try NetworkInvitationParser.decode(fixture.code + "=", now: now)
    }
    #expect(throws: NetworkInvitationError.self) {
      try NetworkInvitationParser.decode("https://example.com/\(fixture.code)", now: now)
    }
    #expect(throws: NetworkInvitationError.self) {
      try NetworkInvitationParser.decode(fixture.code, now: Date(timeIntervalSince1970: 0))
    }
    #expect(throws: NetworkInvitationError.self) {
      try NetworkInvitationParser.decode(
        fixture.code,
        now: Date(timeIntervalSince1970: 2_000_000_000)
      )
    }
  }

  @Test("invitation e query is canonical and matches Go escaping")
  func invitationEndpointQuery() throws {
    let now = Date(timeIntervalSince1970: 1_785_796_800)
    let endpoint = "node.example.test:51820/rendezvous"
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let escaped = endpoint.addingPercentEncoding(withAllowedCharacters: allowed)!
    let fixture = compactInvitation(
      expires: UInt32(now.timeIntervalSince1970) + 600,
      query: "e=" + escaped
    )
    let decoded = try NetworkInvitationParser.decode(fixture.code, now: now)
    #expect(decoded.node == endpoint)
    #expect(decoded.payload.hasSuffix("?e=" + escaped))

    // Unescaped path characters are non-canonical and must be rejected.
    let bad = compactInvitation(
      expires: UInt32(now.timeIntervalSince1970) + 600,
      query: "e=" + endpoint
    )
    #expect(throws: NetworkInvitationError.self) {
      try NetworkInvitationParser.decode(bad.code, now: now)
    }
  }

  @Test("Hub header normalizes and bounds display name")
  func hubHeaderValidation() throws {
    #expect(try HubHeader(name: "  My Hub \n").name == "My Hub")
    #expect(throws: HubHeaderError.invalidName) {
      try HubHeader(name: " ")
    }
    #expect(throws: HubHeaderError.invalidName) {
      try HubHeader(name: String(repeating: "😀", count: 129))
    }
    let boundary = try HubHeader(name: String(repeating: "😀", count: 128))
    #expect(boundary.name.unicodeScalars.count == 128)
  }

  @Test("core service library has no WireGuard implementation dependency")
  func noWireGuardDependency() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let packageManifest = try String(
      contentsOf: packageRoot.appendingPathComponent("Package.swift"),
      encoding: .utf8
    )
    let sourceRoot = packageRoot.appendingPathComponent("Sources/HubService")
    let sourceFiles = try FileManager.default.contentsOfDirectory(
      at: sourceRoot,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" }
    let source = try sourceFiles
      .map { try String(contentsOf: $0, encoding: .utf8) }
      .joined(separator: "\n")

    #expect(!packageManifest.localizedCaseInsensitiveContains("WireGuardKit"))
    #expect(!source.localizedCaseInsensitiveContains("import WireGuardKit"))
  }

  @Test("network policy rejects fields inconsistent with mode")
  func invalidNetworkPolicies() {
    for json in [
      #"{"mode":"group"}"#,
      #"{"mode":"keys","keys":[]}"#,
      #"{"mode":"private","group":"unexpected"}"#,
    ] {
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(NetworkPolicy.self, from: Data(json.utf8))
      }
    }
  }

  private func roundTrip<Value: Codable & Equatable>(
    _ type: Value.Type,
    fixture name: String
  ) throws {
    let input = try Data(contentsOf: fixtureDirectory().appendingPathComponent(name))
    let decoded = try JSONDecoder().decode(type, from: input)
    let encoded = try JSONEncoder().encode(decoded)
    let roundTripped = try JSONDecoder().decode(type, from: encoded)
    #expect(roundTripped == decoded)
    let fixtureJSON = try JSONSerialization.jsonObject(with: input)
    let encodedJSON = try JSONSerialization.jsonObject(with: encoded)
    #expect((fixtureJSON as AnyObject).isEqual(encodedJSON))
  }

  private func fixtureDirectory() throws -> URL {
    if let path = ProcessInfo.processInfo.environment["HUB_NETWORK_FIXTURES"] {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
  }
}
