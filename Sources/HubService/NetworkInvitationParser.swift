import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct DecodedNetworkInvitation: Equatable, Sendable {
  public let publicKey: String
  public let agentKey: String
  public let expires: UInt32
  public let nonce: UInt32
  public let payload: String
  public let replayId: String
  public let signature: String
  public let node: String
  public let code: String
  public let url: String

  public var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(expires)) }
}

public struct NetworkInvitationError: Error, Equatable, Sendable {
  public enum Code: String, Sendable {
    case nonCanonical = "invite_non_canonical"
    case malformed = "invite_malformed"
    case unsupportedVersion = "invite_unsupported_version"
    case invalidTime = "invite_invalid_time"
    case expired = "invite_expired"
    case invalidSignature = "invite_invalid_signature"
  }

  public let code: Code
  public let message: String

  public init(code: Code, message: String) {
    self.code = code
    self.message = message
  }
}

public enum NetworkInvitationParser {
  public static let urlPrefix = "hub://join/"
  public static let defaultNode = "hub.v57.dev/node"
  public static let maximumCodeBytes = 1_024
  public static let maximumLifetime: TimeInterval = 8 * 24 * 60 * 60

  public static func decode(
    _ input: String,
    now: Date = Date()
  ) throws -> DecodedNetworkInvitation {
    let code = try code(from: input)
    guard !code.isEmpty, code.utf8.count <= maximumCodeBytes,
          !code.contains("#") else {
      throw failure(.nonCanonical, "invitation encoding is not canonical")
    }
    guard let slash = code.lastIndex(of: "/"), slash != code.startIndex,
          code.index(after: slash) != code.endIndex else {
      throw failure(.malformed, "invalid invitation format")
    }
    let payload = String(code[..<slash])
    let signaturePart = String(code[code.index(after: slash)...])
    let payloadParts = payload.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    let base = String(payloadParts[0])
    let parts = base.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else {
      throw failure(.unsupportedVersion, "unsupported invitation version")
    }
    guard let publicKey = decodePart(String(parts[0]), count: 32),
          let expiresData = decodePart(String(parts[1]), count: 4),
          let nonceData = decodePart(String(parts[2]), count: 4),
          let signature = decodePart(signaturePart, count: 64) else {
      throw failure(.nonCanonical, "invalid invitation encoding")
    }

    let expires = uint32(expiresData)
    let nonce = uint32(nonceData)
    let expiration = Date(timeIntervalSince1970: TimeInterval(expires))
    guard expiration > now else {
      throw failure(.expired, "invitation has expired")
    }
    guard expiration.timeIntervalSince(now) <= maximumLifetime else {
      throw failure(.invalidTime, "invitation exceeds maximum lifetime")
    }

    let node: String
    if payloadParts.count == 1 {
      node = defaultNode
    } else {
      let rawQuery = String(payloadParts[1])
      guard let components = URLComponents(string: "x://x/?" + rawQuery),
            components.percentEncodedQuery == rawQuery,
            components.queryItems?.count == 1,
            components.queryItems?.first?.name == "e",
            let endpoint = components.queryItems?.first?.value,
            !endpoint.isEmpty,
            canonicalEndpointQuery(endpoint) == rawQuery else {
        throw failure(.nonCanonical, "invalid invitation query")
      }
      node = endpoint
    }

    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
          key.isValidSignature(signature, for: Data(payload.utf8)) else {
      throw failure(.invalidSignature, "invitation signature is invalid")
    }
    let replay = Data(SHA256.hash(data: Data(payload.utf8)))
    let spkiPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
    return DecodedNetworkInvitation(
      publicKey: encodeBase64URL(publicKey),
      agentKey: (spkiPrefix + publicKey).base64EncodedString(),
      expires: expires,
      nonce: nonce,
      payload: payload,
      replayId: encodeBase64URL(replay),
      signature: encodeBase64URL(signature),
      node: node,
      code: code,
      url: urlPrefix + code
    )
  }

  private static func code(from input: String) throws -> String {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.contains("://") else { return value }
    guard value.hasPrefix(urlPrefix) else {
      throw failure(.malformed, "invalid invitation URL")
    }
    let code = String(value.dropFirst(urlPrefix.count))
    guard !code.isEmpty, !code.contains("#") else {
      throw failure(.malformed, "invalid invitation URL")
    }
    return code
  }

  private static func canonicalEndpointQuery(_ endpoint: String) -> String {
    // RFC 3986 unreserved characters only, matching Go's url.QueryEscape and
    // the node verifier's canonical `query.Encode() == rawQuery` check.
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return "e=" + (endpoint.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
  }

  private static func decodePart(_ value: String, count: Int) -> Data? {
    guard !value.isEmpty, !value.contains("=") else { return nil }
    var standard = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
    guard let data = Data(base64Encoded: standard), data.count == count,
          encodeBase64URL(data) == value else { return nil }
    return data
  }

  private static func encodeBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func uint32(_ data: Data) -> UInt32 {
    data.reduce(0) { ($0 << 8) | UInt32($1) }
  }

  private static func failure(
    _ code: NetworkInvitationError.Code,
    _ message: String
  ) -> NetworkInvitationError {
    NetworkInvitationError(code: code, message: message)
  }
}
