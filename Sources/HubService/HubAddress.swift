//
//  HubAddress.swift
//  HubService
//
//  Canonical hub addresses, per-address credentials and how an address travels (Docs/Devices/protocol.md, section 2).
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A hub address cut into the parts the rules below look at
struct HubAddressParts {
  var scheme: String
  /// Lowercased, one trailing dot dropped, IPv6 in brackets
  var host: String
  var port: Int?
  var path: String

  init?(_ address: String) {
    var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if text.allSatisfy(\.isNumber) { text = "localhost:\(text)" }
    if !text.contains("://") { text = "ws://\(text)" }
    guard let separator = text.range(of: "://") else { return nil }
    scheme = text[..<separator.lowerBound].lowercased()
    var rest = text[separator.upperBound...]
    if let end = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = rest[..<end] }
    let slash = rest.firstIndex(of: "/") ?? rest.endIndex
    path = String(rest[slash...])
    var authority = rest[..<slash]
    if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
    let hostText: Substring
    if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
      hostText = authority[...close]
      let tail = authority[authority.index(after: close)...]
      port = tail.hasPrefix(":") ? Int(tail.dropFirst()) : nil
    } else if let colon = authority.lastIndex(of: ":") {
      hostText = authority[..<colon]
      port = Int(authority[authority.index(after: colon)...])
    } else {
      hostText = authority
      port = nil
    }
    host = hostText.lowercased()
    if host.hasSuffix(".") { host.removeLast() }
    guard !host.isEmpty else { return nil }
  }
}

public enum HubAddress {
  /// The form credentials are derived from: scheme and host lowercased, `http`/`https` read as `ws`/`wss`, a bare port
  /// is `ws://localhost:<port>`, the scheme's default port dropped, no user info, query, fragment or trailing `/`.
  public static func canonical(_ address: String) -> String? {
    guard var parts = HubAddressParts(address) else { return nil }
    if parts.scheme == "http" { parts.scheme = "ws" }
    if parts.scheme == "https" { parts.scheme = "wss" }
    let isDefaultPort = (parts.scheme == "ws" && parts.port == 80) || (parts.scheme == "wss" && parts.port == 443)
    let port = parts.port.flatMap { isDefaultPort ? nil : ":\($0)" } ?? ""
    var path = parts.path
    while path.hasSuffix("/") { path.removeLast() }
    return "\(parts.scheme)://\(parts.host)\(port)\(path)"
  }

  public static func canonical(_ url: URL) -> String? {
    canonical(url.absoluteString)
  }
}

/// How a connection to an address travels, known before anything is dialed
public enum HubTransport: String, Sendable, Hashable, CaseIterable {
  /// `wss://`, `quic://`
  case encrypted
  /// This device
  case loopback
  /// Hub Network's overlay, encrypted underneath
  case overlay
  /// Plain `ws://` on the local network: allowed, and the app says the connection isn't encrypted
  case localNetwork
  /// Plain `ws://` anywhere else: credentials and calls would cross networks in the clear
  case refused

  public init(_ url: URL) {
    self.init(address: url.absoluteString)
  }

  public init(address: String) {
    self = Self.classify(address)
  }

  /// Whether the app should say that this connection isn't encrypted
  public var isUnencryptedNetwork: Bool { self == .localNetwork }

  private static func classify(_ address: String) -> HubTransport {
    guard let parts = HubAddressParts(address) else { return .refused }
    switch parts.scheme {
    case "wss", "https", "quic": return .encrypted
    case "ws", "http": break
    default: return .refused
    }
    let host = parts.host
    if host.hasPrefix("[") {
      let v6 = host.dropFirst().dropLast()
      if v6 == "::1" { return .loopback }
      if v6.hasPrefix("fc") || v6.hasPrefix("fd") { return .localNetwork }
      if ["fe8", "fe9", "fea", "feb"].contains(where: { v6.hasPrefix($0) }) { return .localNetwork }
      return .refused
    }
    if let v4 = ipv4(host) {
      let (a, b) = (v4[0], v4[1])
      if a == 127 { return .loopback }
      if a == 100, (64...127).contains(b) { return .overlay }
      if a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254) {
        return .localNetwork
      }
      return .refused
    }
    if host == "localhost" || host.hasSuffix(".localhost") { return .loopback }
    if host.hasSuffix(".hub.invalid") { return .overlay }
    if host.hasSuffix(".local") { return .localNetwork }
    return .refused
  }

  private static func ipv4(_ host: String) -> [Int]? {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    let bytes = parts.compactMap { part -> Int? in
      guard (1...3).contains(part.count), part.allSatisfy(\.isNumber) else { return nil }
      return Int(part).flatMap { $0 <= 255 ? $0 : nil }
    }
    return bytes.count == 4 ? bytes : nil
  }
}

/// Keys of their own for each hub an app adds, so what a hub receives, relays or claims means nothing on another hub.
/// Derived on demand from this device's key and the address dialed; they never leave the device.
public enum HubCredentials {
  public enum Role: String, Sendable, Hashable {
    /// The device key on that hub, the same in every app on the device
    case device
    /// The v57 apps' service key
    case client
    /// The Hub app's service key
    case hubApp = "hub-app"
  }

  /// `HKDF-SHA256(ikm = device seed, salt = "hub-credentials-v1", info = "<role>:<canonical address>", 32)`
  public static func seed(deviceSeed: Data, role: Role, address: String) -> Data {
    let key = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: deviceSeed),
      salt: Data("hub-credentials-v1".utf8),
      info: Data("\(role.rawValue):\(address)".utf8),
      outputByteCount: 32
    )
    return key.withUnsafeBytes { Data($0) }
  }
}
