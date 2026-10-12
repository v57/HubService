import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum DirectBootstrapRequestValidationError: Error, Equatable, Sendable {
  case unsupportedVersion(Int)
  case unexpectedDomain(String)
  case invalidReplayId
  case invalidJoinerKey
  case invalidJoinerWireGuardKey
  case invalidNonce
  case invalidTime
  case outsideClockSkew
  case invalidSignature
}

/// Inviter-side validation of a joiner's signed direct bootstrap request.
///
/// Mirrors `hub-net/agent/invitation` `VerifyJoinerRequest`: the request must
/// be version 1, use the direct-bootstrap-request domain, carry a valid replay
/// id (SHA-256 of the exact invitation payload), a canonical Ed25519 SPKI
/// joiner service key, a 32-byte WireGuard public key, a nonce, an `issuedAt`
/// within the shared clock skew, and an Ed25519 signature that verifies under
/// the asserted joiner service key — so the joiner proves possession of the
/// identity it binds to.
public enum DirectBootstrapRequestVerifier {
  public static func verify(
    _ request: DirectBootstrapRequest,
    expectedReplayId: String,
    expectedJoinerServiceKey: String,
    expectedJoinerWireGuardKey: String? = nil,
    now: Date = Date()
  ) throws {
    guard request.version == hubNetworkWireVersion else {
      throw DirectBootstrapRequestValidationError.unsupportedVersion(request.version)
    }
    guard request.signatureDomain == HubNetworkDirectBootstrapDomain.request else {
      throw DirectBootstrapRequestValidationError.unexpectedDomain(request.signatureDomain)
    }
    guard request.replayId == expectedReplayId else {
      throw DirectBootstrapRequestValidationError.invalidReplayId
    }
    guard request.joinerServiceKey == expectedJoinerServiceKey else {
      throw DirectBootstrapRequestValidationError.invalidJoinerKey
    }
    guard let rawWireGuardKey = Data(base64Encoded: request.joinerWireGuardKey),
          rawWireGuardKey.count == 32 else {
      throw DirectBootstrapRequestValidationError.invalidJoinerWireGuardKey
    }
    if let expectedJoinerWireGuardKey {
      guard request.joinerWireGuardKey == expectedJoinerWireGuardKey else {
        throw DirectBootstrapRequestValidationError.invalidJoinerWireGuardKey
      }
    }
    guard !request.nonce.isEmpty, request.nonce.utf8.count <= 128 else {
      throw DirectBootstrapRequestValidationError.invalidNonce
    }
    guard let issuedAt = ISO8601DateFormatter.hubNetworkDate(from: request.issuedAt) else {
      throw DirectBootstrapRequestValidationError.invalidTime
    }
    guard abs(issuedAt.timeIntervalSince(now)) <= HubNetworkSignedEnvelope.maximumClockSkew else {
      throw DirectBootstrapRequestValidationError.outsideClockSkew
    }
    guard let signature = Data(base64Encoded: request.signature),
          let rawJoinerKey = KeyChain.rawPublicKey(spkiBase64: request.joinerServiceKey),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawJoinerKey) else {
      throw DirectBootstrapRequestValidationError.invalidSignature
    }
    let input = try HubNetworkSignedEnvelope.signatureInput(
      for: request,
      domain: HubNetworkDirectBootstrapDomain.request
    )
    guard publicKey.isValidSignature(signature, for: input) else {
      throw DirectBootstrapRequestValidationError.invalidSignature
    }
  }
}
