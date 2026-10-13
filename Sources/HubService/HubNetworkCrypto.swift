import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Low-level signed-byte helpers shared by the Hub Network wire protocols.
///
/// The signing framing is identical to `HubNetworkSignedEnvelope.signatureInput`
/// (`domain || 0x00 || uint32BE(len) || payload`) but operates on raw byte
/// payloads instead of canonical JSON envelopes. This is what the
/// online-inviter registration challenge uses: the nonce is signed as raw
/// bytes, mirroring `hub-service-go/protocol` `SignatureInputForBytes`.
public enum HubNetworkCrypto {
  public enum Error: Swift.Error, Equatable {
    case invalidDomain
    case oversizedPayload
  }

  /// Returns `domain || 0x00 || uint32BE(len(payload)) || payload`.
  public static func signatureInput(
    domain: String,
    payload: Data
  ) throws -> Data {
    guard let domainData = domain.data(using: .ascii) else {
      throw Error.invalidDomain
    }
    guard payload.count <= Int(UInt32.max) else {
      throw Error.oversizedPayload
    }
    var length = UInt32(payload.count).bigEndian
    var input = Data()
    input.append(domainData)
    input.append(0)
    withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
    input.append(payload)
    return input
  }

  /// Signs a raw byte payload under `domain` with an Ed25519 key and returns
  /// the standard-base64 signature. Mirrors Go `SignBytes`.
  public static func signBytes(
    _ payload: Data,
    domain: String,
    key: KeyChain
  ) throws -> String {
    let input = try signatureInput(domain: domain, payload: payload)
    return try key.signature(for: input).base64EncodedString()
  }

  /// Verifies a standard-base64 Ed25519 signature over a raw byte payload
  /// under `domain`. The public key is a canonical Ed25519 SPKI base64 string.
  public static func verifyBytes(
    _ payload: Data,
    domain: String,
    spkiPublicKey: String,
    signature: String
  ) -> Bool {
    guard let signatureData = Data(base64Encoded: signature),
          let rawKey = KeyChain.rawPublicKey(spkiBase64: spkiPublicKey),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
          let input = try? signatureInput(domain: domain, payload: payload)
    else { return false }
    return publicKey.isValidSignature(signatureData, for: input)
  }

  /// RFC 4648 base64url (unpadded) encoding.
  public static func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// RFC 4648 base64url (unpadded, or padded fallback) decoding.
  public static func base64URLDecode(_ value: String) -> Data? {
    var standard = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = standard.count % 4
    if remainder != 0 {
      standard += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: standard)
  }
}
