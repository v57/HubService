//
//  Auth.swift
//  HubService
//
//  Hub-bound auth tokens and pinned hub keys (Docs/Devices/protocol.md, section 2).
//

import Foundation
#if canImport(Security)
import Security
#endif

public enum HubAuth {
  /// The string an `auth` token signs: `<expiry>` for v0, `hub1:<hub key>:<expiry>` for v1
  public static func signedData(expiry: Int, hubKey: String?) -> String {
    if let hubKey { "hub1:\(hubKey):\(expiry)" } else { "\(expiry)" }
  }

  /// `key.<service SPKI>.<signature>.<expiry>`. With `hubKey` the token only works on that hub (v1).
  public static func token(_ keyChain: KeyChain, expiry: Int, hubKey: String?) -> String {
    "key.\(keyChain.publicKey()).\(keyChain.sign(text: signedData(expiry: expiry, hubKey: hubKey))).\(expiry)"
  }

  /// Connection headers: `v`, `auth` and, with a certificate, `device`
  public static func headers(_ keyChain: KeyChain, hubKey: String?, certificate: String? = nil, now: Date = Date()) -> [String: String] {
    let expiry = Int(now.timeIntervalSince1970) + 60
    var headers = [
      "v": hubKey == nil ? "0" : "1",
      "auth": token(keyChain, expiry: expiry, hubKey: hubKey),
    ]
    if hubKey != nil, let certificate {
      headers["device"] = certificate
    }
    return headers
  }
}

/// `hub/info`: the hub's key and security mode. hub-lite doesn't answer it.
public struct HubInfo: Codable, Hashable, Sendable {
  public var key: String
  public var `protocol`: Int
  public var pro: Bool?
  /// `default-allow` or `default-deny`
  public var mode: String?
}

/// Hub keys pinned per hub address, so auth tokens are bound to the hub they were made for.
/// The first connection to a hub learns its key from `hub/info`; later ones send `v: 1` tokens.
@MainActor
public final class HubKeyPins {
  public enum Storage: Sendable {
    /// Lost when the process ends
    case memory
    /// A JSON object `{ "<address>": "<hub SPKI>" }`, `hubs.json` beside a key file
    case file(URL)
#if canImport(Security)
    /// The same JSON object in a Keychain item
    case keychain(KeyChain.KeychainConfiguration)
#endif
  }
  public let storage: Storage
  private var keys: [String: String]
  public init(_ storage: Storage) {
    self.storage = storage
    keys = Self.load(storage)
  }

  /// `hubs.json` beside a file key, a `<service>.hubs` Keychain item beside a Keychain key, memory otherwise
  public static func beside(_ keyChain: KeyChain) -> HubKeyPins {
    switch keyChain.location {
    case .file(let url):
      return HubKeyPins(.file(url.deletingLastPathComponent().appendingPathComponent("hubs.json")))
#if canImport(Security)
    case .keychain(let tag):
      return HubKeyPins(.keychain(.init(service: "\(tag).hubs")))
    case .configuredKeychain(let configuration):
      return HubKeyPins(.keychain(.init(
        service: "\(configuration.service).hubs",
        account: configuration.account,
        accessGroup: configuration.accessGroup,
        useDataProtectionKeychain: configuration.useDataProtectionKeychain
      )))
#endif
    case .some(.none), nil:
      return HubKeyPins(.memory)
    }
  }

  public var all: [String: String] { keys }

  public func key(for address: URL) -> String? {
    keys[address.absoluteString]
  }

  public func pin(_ key: String, for address: URL) {
    guard keys[address.absoluteString] != key else { return }
    keys[address.absoluteString] = key
    save()
  }

  /// Forgets the hub key, so the next connection learns it again with a v0 token
  public func forget(_ address: URL) {
    guard keys.removeValue(forKey: address.absoluteString) != nil else { return }
    save()
  }

  private static func load(_ storage: Storage) -> [String: String] {
    let data: Data?
    switch storage {
    case .memory: data = nil
    case .file(let url): data = try? Data(contentsOf: url)
#if canImport(Security)
    case .keychain(let configuration): data = try? KeyChain.loadData(keychain: configuration)
#endif
    }
    guard let data else { return [:] }
    return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
  }

  private func save() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(keys) else { return }
    switch storage {
    case .memory: break
    case .file(let url):
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: url, options: .atomic)
#if canImport(Security)
    case .keychain(let configuration):
      try? KeyChain.replaceData(data, keychain: configuration)
#endif
    }
  }
}
