import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum HubNetworkGrantValidationError: Error, Equatable, Sendable {
  case unsupportedVersion(Int)
  case malformedGrant
  case trustRootMismatch
  case bindingMismatch
  case generationMismatch
  case invalidLifetime
  case invalidPublicKey
  case invalidSignature
}

/// Local values a signed connection grant must bind before it may configure a
/// packet-tunnel peer. A trusted Hub key must come from profile configuration,
/// never from the unverified grant alone.
public struct ConnectionGrantBinding: Equatable, Sendable {
  public let trustedHubKey: String
  public let hubNetworkId: String
  public let callerKey: String
  public let callerWireGuardKey: String
  public let generation: UInt64?
  public let targetKey: String?
  public let targetWireGuardKey: String?
  public let resourceId: String?
  public let providerId: String?
  public let `protocol`: NetworkProtocol?
  public let destinationAddress: String?
  public let destinationPort: UInt16?

  public init(
    trustedHubKey: String,
    hubNetworkId: String,
    callerKey: String,
    callerWireGuardKey: String,
    generation: UInt64? = nil,
    targetKey: String? = nil,
    targetWireGuardKey: String? = nil,
    resourceId: String? = nil,
    providerId: String? = nil,
    protocol: NetworkProtocol? = nil,
    destinationAddress: String? = nil,
    destinationPort: UInt16? = nil
  ) {
    self.trustedHubKey = trustedHubKey
    self.hubNetworkId = hubNetworkId
    self.callerKey = callerKey
    self.callerWireGuardKey = callerWireGuardKey
    self.generation = generation
    self.targetKey = targetKey
    self.targetWireGuardKey = targetWireGuardKey
    self.resourceId = resourceId
    self.providerId = providerId
    self.`protocol` = `protocol`
    self.destinationAddress = destinationAddress
    self.destinationPort = destinationPort
  }
}

/// Local gateway-provider values that a Hub-signed gateway grant must bind.
///
/// Provider must supply trusted Hub key from enrolled membership state. Grant's
/// self-declared `hubKey` is never a trust root.
public struct GatewayGrantBinding: Equatable, Sendable {
  public let trustedHubKey: String
  public let hubNetworkId: String
  public let gatewayKey: String
  public let gatewayWireGuardKey: String
  public let generation: UInt64
  public let clientKey: String?
  public let clientWireGuardKey: String?
  public let ipv4: Bool?
  public let ipv6: Bool?
  public let dns: Bool?

  public init(
    trustedHubKey: String,
    hubNetworkId: String,
    gatewayKey: String,
    gatewayWireGuardKey: String,
    generation: UInt64,
    clientKey: String? = nil,
    clientWireGuardKey: String? = nil,
    ipv4: Bool? = nil,
    ipv6: Bool? = nil,
    dns: Bool? = nil
  ) {
    self.trustedHubKey = trustedHubKey
    self.hubNetworkId = hubNetworkId
    self.gatewayKey = gatewayKey
    self.gatewayWireGuardKey = gatewayWireGuardKey
    self.generation = generation
    self.clientKey = clientKey
    self.clientWireGuardKey = clientWireGuardKey
    self.ipv4 = ipv4
    self.ipv6 = ipv6
    self.dns = dns
  }
}

public enum HubNetworkSignedEnvelope {
  public static let connectionGrantMaximumLifetime: TimeInterval = 5 * 60
  public static let gatewayGrantMaximumLifetime: TimeInterval = 5 * 60
  public static let maximumClockSkew: TimeInterval = 30

  /// Returns exact Hub Network v1 signed bytes:
  /// domain || NUL || uint32BE(canonicalJSON.count) || canonicalJSON.
  public static func signatureInput<T: Encodable>(for envelope: T, domain: String) throws -> Data {
    let encoded = try JSONEncoder().encode(envelope)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
      throw HubNetworkGrantValidationError.malformedGrant
    }
    object.removeValue(forKey: "signature")
    let payload = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    guard payload.count <= Int(UInt32.max),
          let domainData = domain.data(using: .ascii)
    else {
      throw HubNetworkGrantValidationError.malformedGrant
    }

    var length = UInt32(payload.count).bigEndian
    var input = Data()
    input.append(domainData)
    input.append(0)
    withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
    input.append(payload)
    return input
  }

  /// Low-level cross-language Ed25519 check. Call `validateConnectionGrant`
  /// for production authorization because it also anchors trust and bindings.
  public static func verifyConnectionGrantSignature(
    _ grant: ConnectionGrant,
    publicKey: String
  ) throws -> Bool {
    guard let signature = Data(base64Encoded: grant.signature) else {
      throw HubNetworkGrantValidationError.invalidSignature
    }
    guard let rawKey = KeyChain.rawPublicKey(spkiBase64: publicKey)
    else {
      throw HubNetworkGrantValidationError.invalidPublicKey
    }
    let key: Curve25519.Signing.PublicKey
    do {
      key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    } catch {
      throw HubNetworkGrantValidationError.invalidPublicKey
    }
    let input = try signatureInput(
      for: grant,
      domain: "hub-network/connection-grant/v1"
    )
    return key.isValidSignature(signature, for: input)
  }

  /// Validates every locally knowable authorization invariant and returns only
  /// after signature verification under the configured Hub trust root.
  public static func validateConnectionGrant(
    _ grant: ConnectionGrant,
    binding: ConnectionGrantBinding,
    now: Date = Date()
  ) throws {
    guard grant.version == hubNetworkWireVersion else {
      throw HubNetworkGrantValidationError.unsupportedVersion(grant.version)
    }
    guard !grant.grantId.isEmpty,
          !grant.resourceId.isEmpty,
          !grant.providerId.isEmpty,
          !grant.callerAddress.isEmpty,
          !grant.targetKey.isEmpty,
          !grant.targetWireGuardKey.isEmpty,
          !grant.destinationAddress.isEmpty,
          grant.destinationPort != 0
    else {
      throw HubNetworkGrantValidationError.malformedGrant
    }
    guard grant.hubKey == binding.trustedHubKey else {
      throw HubNetworkGrantValidationError.trustRootMismatch
    }
    guard grant.hubNetworkId == binding.hubNetworkId,
          grant.callerKey == binding.callerKey,
          grant.callerWireGuardKey == binding.callerWireGuardKey
    else {
      throw HubNetworkGrantValidationError.bindingMismatch
    }
    if let generation = binding.generation, grant.generation != generation {
      throw HubNetworkGrantValidationError.generationMismatch
    }
    guard binding.targetKey.map({ grant.targetKey == $0 }) ?? true,
          binding.targetWireGuardKey.map({ grant.targetWireGuardKey == $0 }) ?? true,
          binding.resourceId.map({ grant.resourceId == $0 }) ?? true,
          binding.providerId.map({ grant.providerId == $0 }) ?? true,
          binding.protocol.map({ grant.protocol == $0 }) ?? true,
          binding.destinationAddress.map({ grant.destinationAddress == $0 }) ?? true,
          binding.destinationPort.map({ grant.destinationPort == $0 }) ?? true else {
      throw HubNetworkGrantValidationError.bindingMismatch
    }

    guard let issuedAt = ISO8601DateFormatter.hubNetworkDate(from: grant.issuedAt),
          let expiresAt = ISO8601DateFormatter.hubNetworkDate(from: grant.expiresAt),
          issuedAt <= now.addingTimeInterval(maximumClockSkew),
          expiresAt > now,
          expiresAt > issuedAt,
          expiresAt.timeIntervalSince(issuedAt) <= connectionGrantMaximumLifetime
    else {
      throw HubNetworkGrantValidationError.invalidLifetime
    }
    guard try verifyConnectionGrantSignature(grant, publicKey: binding.trustedHubKey) else {
      throw HubNetworkGrantValidationError.invalidSignature
    }
  }

  public static func verifyGatewayGrantSignature(_ grant: GatewayGrant, publicKey: String) throws -> Bool {
    guard let signature = Data(base64Encoded: grant.signature) else {
      throw HubNetworkGrantValidationError.invalidSignature
    }
    guard let rawKey = KeyChain.rawPublicKey(spkiBase64: publicKey)
    else {
      throw HubNetworkGrantValidationError.invalidPublicKey
    }
    let key: Curve25519.Signing.PublicKey
    do {
      key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    } catch {
      throw HubNetworkGrantValidationError.invalidPublicKey
    }
    let input = try signatureInput(
      for: grant,
      domain: "hub-network/gateway-grant/v1"
    )
    return key.isValidSignature(signature, for: input)
  }

  /// Validates gateway grant before provider installs any forwarding state.
  public static func validateGatewayGrant(_ grant: GatewayGrant, binding: GatewayGrantBinding, now: Date = Date()) throws {
    guard grant.version == hubNetworkWireVersion else {
      throw HubNetworkGrantValidationError.unsupportedVersion(grant.version)
    }
    guard !grant.grantId.isEmpty,
          !grant.clientKey.isEmpty,
          !grant.clientWireGuardKey.isEmpty,
          !grant.gatewayKey.isEmpty,
          !grant.gatewayWireGuardKey.isEmpty,
          grant.ipv4 || grant.ipv6
    else {
      throw HubNetworkGrantValidationError.malformedGrant
    }
    guard grant.hubKey == binding.trustedHubKey else {
      throw HubNetworkGrantValidationError.trustRootMismatch
    }
    guard grant.hubNetworkId == binding.hubNetworkId,
          grant.gatewayKey == binding.gatewayKey,
          grant.gatewayWireGuardKey == binding.gatewayWireGuardKey
    else {
      throw HubNetworkGrantValidationError.bindingMismatch
    }
    guard grant.generation == binding.generation else {
      throw HubNetworkGrantValidationError.generationMismatch
    }
    guard binding.clientKey.map({ grant.clientKey == $0 }) ?? true,
          binding.clientWireGuardKey.map({ grant.clientWireGuardKey == $0 }) ?? true,
          binding.ipv4.map({ grant.ipv4 == $0 }) ?? true,
          binding.ipv6.map({ grant.ipv6 == $0 }) ?? true,
          binding.dns.map({ grant.dns == $0 }) ?? true
    else {
      throw HubNetworkGrantValidationError.bindingMismatch
    }
    guard let issuedAt = ISO8601DateFormatter.hubNetworkDate(from: grant.issuedAt),
          let expiresAt = ISO8601DateFormatter.hubNetworkDate(from: grant.expiresAt),
          issuedAt <= now.addingTimeInterval(maximumClockSkew),
          expiresAt > now,
          expiresAt > issuedAt,
          expiresAt.timeIntervalSince(issuedAt) <= gatewayGrantMaximumLifetime
    else {
      throw HubNetworkGrantValidationError.invalidLifetime
    }
    guard try verifyGatewayGrantSignature(
      grant,
      publicKey: binding.trustedHubKey
    ) else {
      throw HubNetworkGrantValidationError.invalidSignature
    }
  }

}
