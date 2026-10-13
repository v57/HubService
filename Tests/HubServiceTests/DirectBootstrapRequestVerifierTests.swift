import Foundation
import Testing
@testable import HubService

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@Suite("Direct bootstrap request verification")
struct DirectBootstrapRequestVerifierTests {
  private let now = Date(timeIntervalSince1970: 1_752_000_000)

  private func makeKeyChain() throws -> KeyChain {
    // A fresh random Ed25519 key held in memory only (not persisted).
    let key = Curve25519.Signing.PrivateKey()
    return try KeyChain(.none, rawRepresentation: key.rawRepresentation)
  }

  private func signRequest(
    key: KeyChain,
    replayId: String = "replay-id",
    joinerServiceKey: String? = nil,
    joinerWireGuardKey: String = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
    nonce: String = "abc",
    issuedAt: Date? = nil,
    signature: String? = nil
  ) throws -> DirectBootstrapRequest {
    var request = DirectBootstrapRequest(
      replayId: replayId,
      joinerServiceKey: joinerServiceKey ?? key.publicKey(),
      joinerWireGuardKey: joinerWireGuardKey,
      nonce: nonce,
      issuedAt: ISO8601DateFormatter.hubNetworkDateString(issuedAt ?? now),
      signature: signature ?? ""
    )
    if signature == nil {
      let input = try HubNetworkSignedEnvelope.signatureInput(
        for: request,
        domain: HubNetworkDirectBootstrapDomain.request
      )
      request = DirectBootstrapRequest(
        replayId: request.replayId,
        joinerServiceKey: request.joinerServiceKey,
        joinerWireGuardKey: request.joinerWireGuardKey,
        nonce: request.nonce,
        issuedAt: request.issuedAt,
        signature: try key.signature(for: input).base64EncodedString()
      )
    }
    return request
  }

  @Test("accepts a valid signed request")
  func acceptsValidRequest() throws {
    let key = try makeKeyChain()
    let request = try signRequest(key: key, replayId: "replay-id")
    try DirectBootstrapRequestVerifier.verify(
      request,
      expectedReplayId: "replay-id",
      expectedJoinerServiceKey: key.publicKey(),
      now: now
    )
  }

  @Test("rejects wrong replay id")
  func rejectsWrongReplayId() throws {
    let key = try makeKeyChain()
    let request = try signRequest(key: key, replayId: "replay-id")
    #expect(throws: DirectBootstrapRequestValidationError.invalidReplayId) {
      try DirectBootstrapRequestVerifier.verify(
        request,
        expectedReplayId: "other",
        expectedJoinerServiceKey: key.publicKey(),
        now: now
      )
    }
  }

  @Test("rejects wrong joiner service key")
  func rejectsWrongJoinerKey() throws {
    let key = try makeKeyChain()
    let other = try makeKeyChain()
    let request = try signRequest(key: key, replayId: "replay-id")
    #expect(throws: DirectBootstrapRequestValidationError.invalidJoinerKey) {
      try DirectBootstrapRequestVerifier.verify(
        request,
        expectedReplayId: "replay-id",
        expectedJoinerServiceKey: other.publicKey(),
        now: now
      )
    }
  }

  @Test("rejects a mismatched joiner wireguard key")
  func rejectsWrongWireGuardKey() throws {
    let key = try makeKeyChain()
    let request = try signRequest(key: key)
    #expect(throws: DirectBootstrapRequestValidationError.invalidJoinerWireGuardKey) {
      try DirectBootstrapRequestVerifier.verify(
        request,
        expectedReplayId: "replay-id",
        expectedJoinerServiceKey: key.publicKey(),
        expectedJoinerWireGuardKey: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=",
        now: now
      )
    }
  }

  @Test("rejects a bad signature")
  func rejectsBadSignature() throws {
    let key = try makeKeyChain()
    let request = try signRequest(key: key, signature: "not-a-signature")
    #expect(throws: DirectBootstrapRequestValidationError.invalidSignature) {
      try DirectBootstrapRequestVerifier.verify(
        request,
        expectedReplayId: "replay-id",
        expectedJoinerServiceKey: key.publicKey(),
        now: now
      )
    }
  }

  @Test("rejects issuedAt outside clock skew")
  func rejectsOutsideClockSkew() throws {
    let key = try makeKeyChain()
    let request = try signRequest(key: key, issuedAt: now.addingTimeInterval(60))
    #expect(throws: DirectBootstrapRequestValidationError.outsideClockSkew) {
      try DirectBootstrapRequestVerifier.verify(
        request,
        expectedReplayId: "replay-id",
        expectedJoinerServiceKey: key.publicKey(),
        now: now
      )
    }
  }

  @Test("rejects malformed wireguard key")
  func rejectsMalformedWireGuardKey() throws {
    let key = try makeKeyChain()
    let request = try signRequest(key: key, joinerWireGuardKey: "short")
    #expect(throws: DirectBootstrapRequestValidationError.invalidJoinerWireGuardKey) {
      try DirectBootstrapRequestVerifier.verify(
        request,
        expectedReplayId: "replay-id",
        expectedJoinerServiceKey: key.publicKey(),
        now: now
      )
    }
  }
}

@Suite("HubNetworkCrypto raw-byte signing")
struct HubNetworkCryptoTests {
  @Test("signBytes/verifyBytes round trip under inviter-registration domain")
  func signBytesRoundTrip() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let key = try KeyChain(.none, rawRepresentation: privateKey.rawRepresentation)
    let nonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    let signature = try HubNetworkCrypto.signBytes(
      nonce,
      domain: "hub-network/inviter-registration/v1",
      key: key
    )
    #expect(
      HubNetworkCrypto.verifyBytes(
        nonce,
        domain: "hub-network/inviter-registration/v1",
        spkiPublicKey: key.publicKey(),
        signature: signature
      )
    )
    #expect(
      !HubNetworkCrypto.verifyBytes(
        Data("wrong".utf8),
        domain: "hub-network/inviter-registration/v1",
        spkiPublicKey: key.publicKey(),
        signature: signature
      )
    )
  }

  @Test("base64url encode/decode round trip")
  func base64URLCoding() {
    let data = Data((0..<20).map { _ in UInt8.random(in: .min ... .max) })
    let encoded = HubNetworkCrypto.base64URLEncode(data)
    #expect(!encoded.contains("+"))
    #expect(!encoded.contains("/"))
    #expect(!encoded.contains("="))
    #expect(HubNetworkCrypto.base64URLDecode(encoded) == data)
  }
}
