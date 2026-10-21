import Foundation
import Network
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

extension ISO8601DateFormatter {
  static func hubNetworkDate(from value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  static func hubNetworkDateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}
import Channel

public let hubNetworkWireVersion = 1

/// Public, persisted Hub display metadata returned by `hub/header`.
public struct HubHeader: Codable, Equatable, Sendable {
  public static let maximumNameScalars = 128

  public let name: String

  public init(name: String) throws {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
          normalized.unicodeScalars.count <= Self.maximumNameScalars else {
      throw HubHeaderError.invalidName
    }
    self.name = normalized
  }

  private enum CodingKeys: String, CodingKey {
    case name
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(name: container.decode(String.self, forKey: .name))
  }
}

public enum HubHeaderError: Error, Equatable, Sendable {
  case invalidName
}

public enum InvitationBootstrapAudience: String, Codable, Sendable {
  case node
  case invitingAgent = "inviting-agent"
  case joiner
  /// hub-server; the wire name keeps the old one
  case hubPro = "hub-pro"
}

public enum InvitationBootstrapAction: String, Codable, Sendable {
  case bootstrapRendezvous = "bootstrap-rendezvous"
  case bootstrapPeer = "bootstrap-peer"
  case enrollProfile = "enroll-profile"
  case readHubHeader = "read-hub-header"
}

public struct InvitationBootstrapScope: Codable, Equatable, Sendable {
  public let audience: InvitationBootstrapAudience
  public let actions: [InvitationBootstrapAction]

  public init(
    audience: InvitationBootstrapAudience,
    actions: [InvitationBootstrapAction]
  ) {
    self.audience = audience
    self.actions = actions
  }
}

public enum NetworkInvitationBindingKind: String, Codable, Sendable {
  case machine
  case appleApp = "apple-app"
}

/// Canonical Hub-signed invitation envelope. Encoding/parsing policy remains
/// separate so Codable consumers cannot accidentally treat decoding as trust.
public struct NetworkInvitation: Codable, Equatable, Sendable {
  public let version: Int
  public let signatureDomain: String
  public let tokenId: String
  public let issuedAt: String
  public let expiresAt: String
  public let hubKey: String
  public let invitingKey: String
  public let invitingAgentAddress: String
  public let hubProHost: String
  public let node: String?
  public let bindingKind: NetworkInvitationBindingKind?
  public let tunnelInstanceId: String?
  public let generation: UInt64?
  public let scopes: [InvitationBootstrapScope]
  public let signature: String

  public init(
    version: Int = hubNetworkWireVersion,
    signatureDomain: String = "hub-network/invitation/v1",
    tokenId: String,
    issuedAt: String,
    expiresAt: String,
    hubKey: String,
    invitingKey: String,
    invitingAgentAddress: String,
    hubProHost: String,
    node: String? = nil,
    bindingKind: NetworkInvitationBindingKind? = nil,
    tunnelInstanceId: String? = nil,
    generation: UInt64? = nil,
    scopes: [InvitationBootstrapScope],
    signature: String
  ) {
    self.version = version
    self.signatureDomain = signatureDomain
    self.tokenId = tokenId
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.hubKey = hubKey
    self.invitingKey = invitingKey
    self.invitingAgentAddress = invitingAgentAddress
    self.hubProHost = hubProHost
    self.node = node
    self.bindingKind = bindingKind
    self.tunnelInstanceId = tunnelInstanceId
    self.generation = generation
    self.scopes = scopes
    self.signature = signature
  }
}

public enum NetworkProtocol: String, Codable, Sendable {
  case tcp
  case udp
}

public enum NetworkPolicyMode: String, Codable, Sendable {
  case hub
  case group
  case keys
  case `private`
  case disabled
}

public struct NetworkPolicy: Codable, Equatable, Sendable {
  public let mode: NetworkPolicyMode
  public let group: String?
  public let keys: [String]?

  private init(mode: NetworkPolicyMode, group: String? = nil, keys: [String]? = nil) {
    precondition(mode == .group ? !(group?.isEmpty ?? true) : group == nil)
    precondition(mode == .keys ? !(keys?.isEmpty ?? true) : keys == nil)
    self.mode = mode
    self.group = group
    self.keys = keys
  }

  public static let hub = NetworkPolicy(mode: .hub)
  public static let `private` = NetworkPolicy(mode: .private)
  public static let disabled = NetworkPolicy(mode: .disabled)
  public static func group(_ name: String) -> NetworkPolicy {
    NetworkPolicy(mode: .group, group: name)
  }
  public static func keys(_ keys: [String]) -> NetworkPolicy {
    NetworkPolicy(mode: .keys, keys: keys)
  }

  private enum CodingKeys: String, CodingKey {
    case mode
    case group
    case keys
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let mode = try container.decode(NetworkPolicyMode.self, forKey: .mode)
    let group = try container.decodeIfPresent(String.self, forKey: .group)
    let keys = try container.decodeIfPresent([String].self, forKey: .keys)
    guard mode == .group ? !(group?.isEmpty ?? true) && keys == nil : group == nil,
          mode == .keys ? !(keys?.isEmpty ?? true) && group == nil : keys == nil else {
      throw DecodingError.dataCorruptedError(
        forKey: .mode,
        in: container,
        debugDescription: "Network policy fields do not match mode"
      )
    }
    self.mode = mode
    self.group = group
    self.keys = keys
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mode, forKey: .mode)
    try container.encodeIfPresent(group, forKey: .group)
    try container.encodeIfPresent(keys, forKey: .keys)
  }
}

public enum NetworkPolicyChange: Sendable {
  case unchanged
  case set(NetworkPolicy)
  case clear
}

public struct LocalTarget: Codable, Equatable, Sendable {
  public let host: String
  public let port: UInt16

  public init(host: String = "127.0.0.1", port: UInt16) {
    self.host = host
    self.port = port
  }
}

public struct NetworkShare: Codable, Equatable, Sendable {
  public let name: String
  public let `protocol`: NetworkProtocol
  public let target: LocalTarget
  public let policy: NetworkPolicy?

  public init(
    name: String,
    protocol: NetworkProtocol,
    target: LocalTarget,
    policy: NetworkPolicy? = .private
  ) {
    self.name = name
    self.`protocol` = `protocol`
    self.target = target
    self.policy = policy
  }
}

public struct NetworkSharePublication: Codable, Equatable, Sendable {
  public let version: Int
  public let resourceId: String
  public let authority: String
  public let providerId: String
  public let `protocol`: NetworkProtocol
  public let overlayAddress: String
  public let port: UInt16

  public init(
    version: Int = hubNetworkWireVersion,
    resourceId: String,
    authority: String,
    providerId: String,
    protocol: NetworkProtocol,
    overlayAddress: String,
    port: UInt16
  ) {
    self.version = version
    self.resourceId = resourceId
    self.authority = authority
    self.providerId = providerId
    self.`protocol` = `protocol`
    self.overlayAddress = overlayAddress
    self.port = port
  }
}

public struct AgentAttestation: Codable, Equatable, Sendable {
  public let version: Int
  public let attestationId: String
  public let serviceKey: String
  public let key: String
  public let shareName: String
  public let `protocol`: NetworkProtocol
  public let target: LocalTarget
  public let issuedAt: String
  public let expiresAt: String
  public let signature: String

  public init(
    version: Int = hubNetworkWireVersion,
    attestationId: String,
    serviceKey: String,
    key: String,
    shareName: String,
    protocol: NetworkProtocol,
    target: LocalTarget,
    issuedAt: String,
    expiresAt: String,
    signature: String
  ) {
    self.version = version
    self.attestationId = attestationId
    self.serviceKey = serviceKey
    self.key = key
    self.shareName = shareName
    self.`protocol` = `protocol`
    self.target = target
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.signature = signature
  }
}

public struct WireNetworkShare: Codable, Equatable, Sendable {
  public let version: Int
  public let name: String
  public let `protocol`: NetworkProtocol
  public let target: LocalTarget
  public let policy: NetworkPolicy?
  public let attestation: AgentAttestation

  public init(
    version: Int = hubNetworkWireVersion,
    share: NetworkShare,
    attestation: AgentAttestation
  ) {
    self.version = version
    name = share.name
    self.`protocol` = share.protocol
    target = share.target
    policy = share.policy
    self.attestation = attestation
  }
}

public struct NetworkSharesReplace: Codable, Equatable, Sendable {
  public let shares: [WireNetworkShare]

  public init(shares: [WireNetworkShare]) {
    self.shares = shares
  }
}

public struct NetworkSharesReplaceResponse: Codable, Equatable, Sendable {
  public let shares: [NetworkSharePublication]

  public init(shares: [NetworkSharePublication]) {
    self.shares = shares
  }
}

/// Hub-signed authorization for one caller, one provider, and one transport
/// destination. Field names and integer widths mirror Hub Network wire v1.
public struct ConnectionGrant: Codable, Equatable, Sendable {
  public let version: Int
  public let grantId: String
  public let hubKey: String
  public let hubNetworkId: String
  public let callerKey: String
  public let callerWireGuardKey: String
  public let callerAddress: String
  public let targetKey: String
  public let targetWireGuardKey: String
  public let resourceId: String
  public let providerId: String
  public let `protocol`: NetworkProtocol
  public let destinationAddress: String
  public let destinationPort: UInt16
  public let generation: UInt64
  public let issuedAt: String
  public let expiresAt: String
  public let signature: String

  public init(
    version: Int = hubNetworkWireVersion,
    grantId: String,
    hubKey: String,
    hubNetworkId: String,
    callerKey: String,
    callerWireGuardKey: String,
    callerAddress: String,
    targetKey: String,
    targetWireGuardKey: String,
    resourceId: String,
    providerId: String,
    protocol: NetworkProtocol,
    destinationAddress: String,
    destinationPort: UInt16,
    generation: UInt64,
    issuedAt: String,
    expiresAt: String,
    signature: String
  ) {
    self.version = version
    self.grantId = grantId
    self.hubKey = hubKey
    self.hubNetworkId = hubNetworkId
    self.callerKey = callerKey
    self.callerWireGuardKey = callerWireGuardKey
    self.callerAddress = callerAddress
    self.targetKey = targetKey
    self.targetWireGuardKey = targetWireGuardKey
    self.resourceId = resourceId
    self.providerId = providerId
    self.`protocol` = `protocol`
    self.destinationAddress = destinationAddress
    self.destinationPort = destinationPort
    self.generation = generation
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.signature = signature
  }
}

public enum RendezvousRole: String, Codable, Sendable {
  case rendezvous
}

public enum RendezvousSessionPurpose: String, Codable, Sendable {
  case peerConnect = "peer-connect"
}

/// Short-lived Hub credential accepted by a rendezvous-only node.
public struct RendezvousTicket: Codable, Equatable, Sendable {
  public let version: Int
  public let ticketId: String
  public let hubKey: String
  public let hubNetworkId: String
  public let key: String
  public let nodeId: String
  public let roles: [RendezvousRole]
  public let sessionPurpose: RendezvousSessionPurpose
  public let issuedAt: String
  public let expiresAt: String
  public let signature: String

  public init(
    version: Int = hubNetworkWireVersion,
    ticketId: String,
    hubKey: String,
    hubNetworkId: String,
    key: String,
    nodeId: String,
    roles: [RendezvousRole] = [.rendezvous],
    sessionPurpose: RendezvousSessionPurpose = .peerConnect,
    issuedAt: String,
    expiresAt: String,
    signature: String
  ) {
    self.version = version
    self.ticketId = ticketId
    self.hubKey = hubKey
    self.hubNetworkId = hubNetworkId
    self.key = key
    self.nodeId = nodeId
    self.roles = roles
    self.sessionPurpose = sessionPurpose
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.signature = signature
  }
}

public enum NetworkCandidateKind: String, Codable, Sendable {
  case host
  case serverReflexive = "server-reflexive"
}

public enum NetworkCandidateTransport: String, Codable, Sendable {
  case udp
}

/// Direct-connect transport metadata. Candidates never grant network access.
public struct NetworkCandidate: Codable, Equatable, Sendable {
  public let version: Int
  public let candidateId: String
  public let sessionId: String
  public let key: String
  public let kind: NetworkCandidateKind
  public let transport: NetworkCandidateTransport
  public let address: String
  public let port: UInt16
  public let priority: UInt32
  public let foundation: String?
  public let expiresAt: String

  public init(
    version: Int = hubNetworkWireVersion,
    candidateId: String,
    sessionId: String,
    key: String,
    kind: NetworkCandidateKind,
    transport: NetworkCandidateTransport = .udp,
    address: String,
    port: UInt16,
    priority: UInt32,
    foundation: String? = nil,
    expiresAt: String
  ) {
    self.version = version
    self.candidateId = candidateId
    self.sessionId = sessionId
    self.key = key
    self.kind = kind
    self.transport = transport
    self.address = address
    self.port = port
    self.priority = priority
    self.foundation = foundation
    self.expiresAt = expiresAt
  }
}

/// Transport source measured by rendezvous node, separate from agent claims.
public struct NetworkObservedEndpoint: Codable, Equatable, Sendable {
  public let version: Int
  public let key: String
  public let transport: String
  public let address: String
  public let port: UInt16

  public init(
    version: Int = hubNetworkWireVersion,
    key: String,
    transport: String,
    address: String,
    port: UInt16
  ) {
    self.version = version
    self.key = key
    self.transport = transport
    self.address = address
    self.port = port
  }
}

/// Explicit, disabled-by-default capability advertised by an exit provider.
public struct GatewayCapability: Codable, Equatable, Sendable {
  public let version: Int
  public let capability: String
  public let ipv4: Bool
  public let ipv6: Bool
  public let dns: Bool
  public let metered: Bool
  public let updatedAt: String

  public init(
    version: Int = hubNetworkWireVersion,
    capability: String = "internet-gateway-v1",
    ipv4: Bool,
    ipv6: Bool,
    dns: Bool,
    metered: Bool,
    updatedAt: String
  ) {
    self.version = version
    self.capability = capability
    self.ipv4 = ipv4
    self.ipv6 = ipv6
    self.dns = dns
    self.metered = metered
    self.updatedAt = updatedAt
  }
}

public enum GatewayState: String, Codable, Sendable {
  case disabled
  case available
  case unavailable
}

/// Permission-filtered reachability and capability view for one gateway peer.
public struct GatewayStatus: Codable, Equatable, Sendable {
  public let version: Int
  public let hubNetworkId: String
  public let key: String
  public let wireGuardKey: String
  public let endpoint: String
  public let capability: GatewayCapability
  public let state: GatewayState
  public let updatedAt: String
  public let error: NetworkGatewayError?

  public init(version: Int = hubNetworkWireVersion, hubNetworkId: String, key: String,
               wireGuardKey: String, endpoint: String, capability: GatewayCapability,
              state: GatewayState, updatedAt: String, error: NetworkGatewayError? = nil) {
    self.version = version; self.hubNetworkId = hubNetworkId; self.key = key
    self.wireGuardKey = wireGuardKey; self.capability = capability
    self.endpoint = endpoint
    self.state = state; self.updatedAt = updatedAt; self.error = error
  }
}

/// Hub-signed, purpose-separated authorization for one full-tunnel client.
public struct GatewayGrant: Codable, Equatable, Sendable {
  public let version: Int
  public let grantId: String
  public let hubKey: String
  public let hubNetworkId: String
  public let clientKey: String
  public let clientWireGuardKey: String
  public let gatewayKey: String
  public let gatewayWireGuardKey: String
  public let ipv4: Bool
  public let ipv6: Bool
  public let dns: Bool
  public let generation: UInt64
  public let issuedAt: String
  public let expiresAt: String
  public let signature: String

  public init(version: Int = hubNetworkWireVersion, grantId: String, hubKey: String,
              hubNetworkId: String, clientKey: String, clientWireGuardKey: String,
              gatewayKey: String, gatewayWireGuardKey: String, ipv4: Bool, ipv6: Bool,
              dns: Bool, generation: UInt64, issuedAt: String, expiresAt: String, signature: String) {
    self.version = version; self.grantId = grantId; self.hubKey = hubKey; self.hubNetworkId = hubNetworkId
    self.clientKey = clientKey; self.clientWireGuardKey = clientWireGuardKey
    self.gatewayKey = gatewayKey; self.gatewayWireGuardKey = gatewayWireGuardKey
    self.ipv4 = ipv4; self.ipv6 = ipv6; self.dns = dns; self.generation = generation
    self.issuedAt = issuedAt; self.expiresAt = expiresAt; self.signature = signature
  }
}

public struct GatewayRevocation: Codable, Equatable, Sendable {
  public let version: Int
  public let hubNetworkId: String
  public let gatewayKey: String
  public let generation: UInt64
  public let revokedAt: String
  public let reason: String

  public init(version: Int = hubNetworkWireVersion, hubNetworkId: String, gatewayKey: String,
              generation: UInt64, revokedAt: String, reason: String) {
    self.version = version; self.hubNetworkId = hubNetworkId; self.gatewayKey = gatewayKey
    self.generation = generation; self.revokedAt = revokedAt; self.reason = reason
  }
}

public struct NetworkGatewayError: Codable, Equatable, Sendable {
  public let version: Int
  public let code: String
  public let message: String
  public let retryable: Bool
  public let details: [String: GatewayDiagnosticValue]?

  public init(version: Int = hubNetworkWireVersion, code: String, message: String,
              retryable: Bool, details: [String: GatewayDiagnosticValue]? = nil) {
    self.version = version; self.code = code; self.message = message
    self.retryable = retryable; self.details = details
  }
}

public enum GatewayDiagnosticValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if let string = try? value.decode(String.self) { self = .string(string) }
    else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
    else { self = .number(try value.decode(Double.self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self { case .string(let v): try value.encode(v); case .number(let v): try value.encode(v); case .bool(let v): try value.encode(v) }
  }
}

public struct GatewayDiagnostic: Codable, Equatable, Sendable {
  public let version: Int
  public let hubNetworkId: String
  public let gatewayKey: String
  public let code: String
  public let message: String
  public let retryable: Bool
  public let updatedAt: String
  public let details: [String: GatewayDiagnosticValue]?

  public init(version: Int = hubNetworkWireVersion, hubNetworkId: String, gatewayKey: String,
              code: String, message: String, retryable: Bool, updatedAt: String,
              details: [String: GatewayDiagnosticValue]? = nil) {
    self.version = version; self.hubNetworkId = hubNetworkId; self.gatewayKey = gatewayKey
    self.code = code; self.message = message; self.retryable = retryable; self.updatedAt = updatedAt
    self.details = details
  }
}

@MainActor
public final class HubNetworkService {
  public typealias Signer = @Sendable (String) async throws -> String
  typealias ReplaceHandler =
    ([WireNetworkShare]) async throws -> [NetworkSharePublication]
  public typealias AttestationProvider = (
    _ share: NetworkShare,
    _ serviceKey: String,
    _ sign: @escaping Signer
  ) async throws -> AgentAttestation

  private var shares: [String: NetworkShare] = [:]
  private var publicationsByShare: [String: NetworkSharePublication] = [:]
  private var reconnectCallbacks: [([NetworkSharePublication]) -> Void] = []
  private var attestationProvider: AttestationProvider?
  private var serviceKey: String?
  private var signer: Signer?
  private var replaceHandler: ReplaceHandler?
  private var mutationInProgress = false
  private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

  init(attestationProvider: AttestationProvider? = nil) {
    self.attestationProvider = attestationProvider
  }

  public func setAttestationProvider(_ provider: @escaping AttestationProvider) {
    attestationProvider = provider
  }

  func configureIdentity(_ keyChain: KeyChain) {
    configureIdentity(serviceKey: keyChain.publicKey()) { challenge in
      keyChain.sign(text: challenge)
    }
#if canImport(Network)
    useAppleLocalAgent()
#endif
  }

  func configureIdentity(
    serviceKey: String,
    sign: @escaping Signer
  ) {
    self.serviceKey = serviceKey
    signer = sign
  }

  func setReplaceHandler(_ handler: @escaping ReplaceHandler) {
    replaceHandler = handler
  }

  func didConnect(_ sender: ChannelSender<Void>) async throws {
    setReplaceHandler { shares in
      let response: NetworkSharesReplaceResponse = try await sender.send(
        "network/shares/replace",
        NetworkSharesReplace(shares: shares)
      )
      return response.shares
    }
    guard !declaredShares.isEmpty else { return }
    _ = try await republish()
  }

  public var declaredShares: [NetworkShare] {
    shares.values.sorted { $0.name < $1.name }
  }

  public var publications: [NetworkSharePublication] {
    publicationsByShare.values.sorted { $0.resourceId < $1.resourceId }
  }

  @discardableResult
  public func publish(
    _ share: NetworkShare
  ) async throws -> [NetworkSharePublication] {
    await acquireMutation()
    defer { releaseMutation() }
    return try await publishImpl(share)
  }

  private func publishImpl(
    _ share: NetworkShare
  ) async throws -> [NetworkSharePublication] {
    let previous = shares.updateValue(share, forKey: share.name)
    do {
      return try await synchronize()
    } catch {
      if let previous {
        shares[share.name] = previous
      } else {
        shares.removeValue(forKey: share.name)
      }
      throw error
    }
  }

  @discardableResult
  public func update(
    _ name: String,
    port: UInt16? = nil,
    policy: NetworkPolicyChange = .unchanged
  ) async throws -> [NetworkSharePublication] {
    await acquireMutation()
    defer { releaseMutation() }
    guard let current = shares[name] else {
      throw HubNetworkError.shareNotFound(name)
    }
    let updatedPolicy: NetworkPolicy?
    switch policy {
    case .unchanged:
      updatedPolicy = current.policy
    case .set(let policy):
      updatedPolicy = policy
    case .clear:
      updatedPolicy = nil
    }
    let updated = NetworkShare(
      name: current.name,
      protocol: current.protocol,
      target: LocalTarget(host: current.target.host, port: port ?? current.target.port),
      policy: updatedPolicy
    )
    return try await publishImpl(updated)
  }

  @discardableResult
  public func remove(
    _ name: String
  ) async throws -> [NetworkSharePublication] {
    await acquireMutation()
    defer { releaseMutation() }
    guard let removed = shares.removeValue(forKey: name) else {
      throw HubNetworkError.shareNotFound(name)
    }
    do {
      return try await synchronize()
    } catch {
      shares[name] = removed
      throw error
    }
  }

  @discardableResult
  public func republish() async throws -> [NetworkSharePublication] {
    await acquireMutation()
    defer { releaseMutation() }
    let result = try await synchronize()
    reconnectCallbacks.forEach { $0(result) }
    return result
  }

  public func publication(forShare name: String) -> NetworkSharePublication? {
    publicationsByShare[name]
  }

  public func onReconnect(_ callback: @escaping ([NetworkSharePublication]) -> Void) {
    reconnectCallbacks.append(callback)
  }

  private func synchronize() async throws -> [NetworkSharePublication] {
    guard let attestationProvider,
          let serviceKey,
          let signer,
          let replaceHandler else {
      throw HubNetworkError.agentUnavailable
    }

    var wireShares: [WireNetworkShare] = []
    for share in declaredShares {
      let attestation = try await attestationProvider(share, serviceKey, signer)
      guard attestation.version == hubNetworkWireVersion,
            attestation.serviceKey == serviceKey,
            attestation.shareName == share.name,
            attestation.protocol == share.protocol,
            attestation.target == share.target else {
        throw HubNetworkError.attestationMismatch
      }
      guard let issuedAt = ISO8601DateFormatter.hubNetworkDate(from: attestation.issuedAt),
            let expiresAt = ISO8601DateFormatter.hubNetworkDate(from: attestation.expiresAt),
            expiresAt > Date(),
            expiresAt > issuedAt else {
        throw HubNetworkError.attestationExpired
      }
      wireShares.append(WireNetworkShare(share: share, attestation: attestation))
    }

    let result = try await replaceHandler(wireShares)
    guard result.count == declaredShares.count else {
      throw HubNetworkError.invalidHubResponse
    }
    publicationsByShare = Dictionary(
      uniqueKeysWithValues: zip(declaredShares.map(\.name), result)
    )
    return result
  }

  private func acquireMutation() async {
    if !mutationInProgress {
      mutationInProgress = true
      return
    }
    await withCheckedContinuation { continuation in
      mutationWaiters.append(continuation)
    }
  }

  private func releaseMutation() {
    if mutationWaiters.isEmpty {
      mutationInProgress = false
    } else {
      mutationWaiters.removeFirst().resume()
    }
  }
}

public enum HubNetworkError: Error, Equatable {
  case agentUnavailable
  case agentTimeout
  case agentTransport(String)
  case agentRejected(status: Int, message: String)
  case invalidAgentResponse
  case invalidHubResponse
  case attestationMismatch
  case attestationExpired
  case shareNotFound(String)
}

public struct AgentProfile: Codable, Equatable, Sendable {
  public let version: Int
  public let key: String
  public let wireGuardKey: String
  public let name: String?
  public let platform: String?
  public let overlayAddresses: [String]
  public let connectedAt: String
  /// Member key: `device:<id>` for a device-attached agent, else the service key
  public let member: String?
  /// Device id when the agent is device-attached
  public let device: String?
  /// `<label>-<16>.v1-<hub>.hub.invalid`, resolving to the device's overlay address
  public let deviceAuthority: String?

  public init(
    version: Int = hubNetworkWireVersion,
    key: String,
    
    wireGuardKey: String,
    name: String? = nil,
    platform: String? = nil,
    overlayAddresses: [String],
    connectedAt: String,
    member: String? = nil,
    device: String? = nil,
    deviceAuthority: String? = nil
  ) {
    self.version = version
    self.key = key
    self.wireGuardKey = wireGuardKey
    self.name = name
    self.platform = platform
    self.overlayAddresses = overlayAddresses
    self.connectedAt = connectedAt
    self.member = member
    self.device = device
    self.deviceAuthority = deviceAuthority
  }
}

public struct AppleBootstrapStatus: Codable, Equatable, Sendable {
  public let version: Int
  public let assignmentId: String
  public let tokenDigest: String
  public let transactionId: String
  public let tunnelInstanceId: String
  public let generation: UInt64
  public let state: String
  public let updatedAt: String
  public let peerWireGuardKey: String?
  public let error: NetworkError?

  public init(
    version: Int = hubNetworkWireVersion,
    assignmentId: String,
    tokenDigest: String,
    transactionId: String,
    tunnelInstanceId: String,
    generation: UInt64,
    state: String,
    updatedAt: String,
    peerWireGuardKey: String? = nil,
    error: NetworkError? = nil
  ) {
    self.version = version
    self.assignmentId = assignmentId
    self.tokenDigest = tokenDigest
    self.transactionId = transactionId
    self.tunnelInstanceId = tunnelInstanceId
    self.generation = generation
    self.state = state
    self.updatedAt = updatedAt
    self.peerWireGuardKey = peerWireGuardKey
    self.error = error
  }
}

public struct NetworkError: Codable, Equatable, Sendable {
  public let version: Int
  public let code: String
  public let message: String
  public let retryable: Bool
  public let details: [String: GatewayDiagnosticValue]?

  public init(
    version: Int = hubNetworkWireVersion,
    code: String,
    message: String,
    retryable: Bool,
    details: [String: GatewayDiagnosticValue]? = nil
  ) {
    self.version = version
    self.code = code
    self.message = message
    self.retryable = retryable
    self.details = details
  }
}

// MARK: Direct bootstrap

/// Hub Network direct bootstrap signature domains. A joiner signs a request
/// proving its service identity; the inviter signs a response bound to the
/// invitation replay id and joiner keys, using the same key that signed the
/// compact invitation.
public enum HubNetworkDirectBootstrapDomain {
  public static let request = "hub-network/direct-bootstrap-request/v1"
  public static let response = "hub-network/direct-bootstrap-response/v1"
  public static let maximumLifetime: TimeInterval = 10 * 60
}

/// A direct WireGuard endpoint advertised by an inviter for the temporary
/// bootstrap link.
public struct BootstrapEndpoint: Codable, Hashable, Sendable {
  public let address: String
  public let port: UInt16
  public let transport: String

  public init(address: String, port: UInt16, transport: String) {
    self.address = address
    self.port = port
    self.transport = transport
  }
}

/// Temporary point-to-point address pair assigned for the bootstrap link,
/// distinct from the permanent overlay addresses hub-server assigns after bind.
public struct BootstrapAddress: Codable, Hashable, Sendable {
  public let ipv4: String
  public let ipv6: String

  public init(ipv4: String, ipv6: String) {
    self.ipv4 = ipv4
    self.ipv6 = ipv6
  }
}

/// Signed by the joiner's service key. The replayId binds the request to a
/// specific compact invitation (SHA-256 of its payload); nonce and issuedAt
/// make the request itself single-use against the inviter.
public struct DirectBootstrapRequest: Codable, Equatable, Sendable {
  public let version: Int
  public let signatureDomain: String
  public let replayId: String
  public let joinerServiceKey: String
  public let joinerWireGuardKey: String
  public let nonce: String
  public let issuedAt: String
  public let signature: String

  public init(
    version: Int = hubNetworkWireVersion,
    signatureDomain: String = HubNetworkDirectBootstrapDomain.request,
    replayId: String,
    joinerServiceKey: String,
    joinerWireGuardKey: String,
    nonce: String,
    issuedAt: String,
    signature: String
  ) {
    self.version = version
    self.signatureDomain = signatureDomain
    self.replayId = replayId
    self.joinerServiceKey = joinerServiceKey
    self.joinerWireGuardKey = joinerWireGuardKey
    self.nonce = nonce
    self.issuedAt = issuedAt
    self.signature = signature
  }
}

/// Signed by the inviter's invitation service key (the same key that signed
/// the compact invitation). Bound to the request by replayId and joiner
/// identities, it supplies the temporary point-to-point configuration the
/// joiner needs to reach hub-server through the inviter. Once the joiner
/// completes `hub/net/bind` it receives permanent overlay addresses and must
/// drop this temporary tunnel.
public struct DirectBootstrapResponse: Codable, Hashable, Sendable {
  public let version: Int
  public let signatureDomain: String
  public let replayId: String
  public let inviterServiceKey: String
  public let joinerServiceKey: String
  public let joinerWireGuardKey: String
  public let inviterWireGuardKey: String
  public let endpoints: [BootstrapEndpoint]
  public let joinerAddress: BootstrapAddress
  public let inviterAddress: BootstrapAddress
  public let hubProHost: String
  public let issuedAt: String
  public let expiresAt: String
  public let signature: String

  public init(
    version: Int = hubNetworkWireVersion,
    signatureDomain: String = HubNetworkDirectBootstrapDomain.response,
    replayId: String,
    inviterServiceKey: String,
    joinerServiceKey: String,
    joinerWireGuardKey: String,
    inviterWireGuardKey: String,
    endpoints: [BootstrapEndpoint],
    joinerAddress: BootstrapAddress,
    inviterAddress: BootstrapAddress,
    hubProHost: String,
    issuedAt: String,
    expiresAt: String,
    signature: String
  ) {
    self.version = version
    self.signatureDomain = signatureDomain
    self.replayId = replayId
    self.inviterServiceKey = inviterServiceKey
    self.joinerServiceKey = joinerServiceKey
    self.joinerWireGuardKey = joinerWireGuardKey
    self.inviterWireGuardKey = inviterWireGuardKey
    self.endpoints = endpoints
    self.joinerAddress = joinerAddress
    self.inviterAddress = inviterAddress
    self.hubProHost = hubProHost
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.signature = signature
  }
}

public enum DirectBootstrapValidationError: Error, Equatable, Sendable {
  case unsupportedVersion(Int)
  case unexpectedDomain(String)
  case replayMismatch
  case joinerMismatch
  case invalidInviterKey
  case invalidInviterWireGuardKey
  case invalidEndpoint
  case invalidAddress
  case addressCollision
  case invalidHubProHost
  case invalidTime
  case outsideClockSkew
  case expired
  case invalidSignature
}

/// Shared joiner-side validation of an inviter's signed direct bootstrap
/// response. Mirrors hub-net/agent `VerifyInviterResponse`: the signature must
/// verify under the invitation service key (the same key that signed the
/// compact invitation), and every identity and replay field must bind to the
/// request that produced it.
public enum DirectBootstrapVerifier {
  public static func verify(
    _ response: DirectBootstrapResponse,
    request: DirectBootstrapRequest,
    expectedInviterServiceKey: String,
    now: Date = Date()
  ) throws {
    guard response.version == hubNetworkWireVersion else {
      throw DirectBootstrapValidationError.unsupportedVersion(response.version)
    }
    guard response.signatureDomain == HubNetworkDirectBootstrapDomain.response else {
      throw DirectBootstrapValidationError.unexpectedDomain(response.signatureDomain)
    }
    guard response.replayId == request.replayId else {
      throw DirectBootstrapValidationError.replayMismatch
    }
    guard response.joinerServiceKey == request.joinerServiceKey,
          response.joinerWireGuardKey == request.joinerWireGuardKey else {
      throw DirectBootstrapValidationError.joinerMismatch
    }
    guard response.inviterServiceKey == expectedInviterServiceKey else {
      throw DirectBootstrapValidationError.invalidInviterKey
    }
    guard let rawInviterWireGuardKey = Data(base64Encoded: response.inviterWireGuardKey),
          rawInviterWireGuardKey.count == 32 else {
      throw DirectBootstrapValidationError.invalidInviterWireGuardKey
    }
    guard !response.endpoints.isEmpty else {
      throw DirectBootstrapValidationError.invalidEndpoint
    }
    for endpoint in response.endpoints {
      guard endpoint.transport == "udp",
            endpoint.port != 0,
            IPv4Address(endpoint.address) != nil ||
              IPv6Address(endpoint.address) != nil else {
        throw DirectBootstrapValidationError.invalidEndpoint
      }
    }
    let joinerV4 = IPv4Address(response.joinerAddress.ipv4)
    let joinerV6 = IPv6Address(response.joinerAddress.ipv6)
    let inviterV4 = IPv4Address(response.inviterAddress.ipv4)
    let inviterV6 = IPv6Address(response.inviterAddress.ipv6)
    guard let joinerV4, let joinerV6,
          let inviterV4, let inviterV6,
          joinerV4.rawValue.count == 4, joinerV6.rawValue.count == 16,
          inviterV4.rawValue.count == 4, inviterV6.rawValue.count == 16 else {
      throw DirectBootstrapValidationError.invalidAddress
    }
    guard joinerV4.rawValue != inviterV4.rawValue,
          joinerV6.rawValue != inviterV6.rawValue else {
      throw DirectBootstrapValidationError.addressCollision
    }
    guard IPv4Address(response.hubProHost) != nil ||
            IPv6Address(response.hubProHost) != nil else {
      throw DirectBootstrapValidationError.invalidHubProHost
    }
    guard let issuedAt = ISO8601DateFormatter.hubNetworkDate(from: response.issuedAt),
          let expiresAt = ISO8601DateFormatter.hubNetworkDate(from: response.expiresAt) else {
      throw DirectBootstrapValidationError.invalidTime
    }
    guard expiresAt >= issuedAt,
          expiresAt.timeIntervalSince(issuedAt) <= HubNetworkDirectBootstrapDomain.maximumLifetime else {
      throw DirectBootstrapValidationError.invalidTime
    }
    guard abs(issuedAt.timeIntervalSince(now)) <= HubNetworkSignedEnvelope.maximumClockSkew else {
      throw DirectBootstrapValidationError.outsideClockSkew
    }
    guard expiresAt > now else {
      throw DirectBootstrapValidationError.expired
    }
    guard let signature = Data(base64Encoded: response.signature),
          let rawInviterKey = KeyChain.rawPublicKey(spkiBase64: expectedInviterServiceKey),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawInviterKey) else {
      throw DirectBootstrapValidationError.invalidSignature
    }
    let input = try HubNetworkSignedEnvelope.signatureInput(
      for: response,
      domain: HubNetworkDirectBootstrapDomain.response
    )
    guard publicKey.isValidSignature(signature, for: input) else {
      throw DirectBootstrapValidationError.invalidSignature
    }
  }
}
