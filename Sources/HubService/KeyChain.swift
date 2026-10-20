//
//  File.swift
//  HubService
//
//  Created by Dmitry Kozlov on 30/4/25.
//

import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(Crypto)
import Crypto
#else
import CryptoKit
#endif

public struct KeyChain: Sendable {
  public enum Error: Swift.Error, Equatable {
    case keyNotFound
    case invalidPrivateKey
    case invalidPublicKey
    case keychainStatus(Int32)
  }

#if canImport(Security)
  public struct KeychainConfiguration: Sendable, Equatable {
    public let service: String
    public let account: String?
    public let accessGroup: String?
    public let useDataProtectionKeychain: Bool

    public init(
      service: String,
      account: String? = nil,
      accessGroup: String? = nil,
      useDataProtectionKeychain: Bool = false
    ) {
      self.service = service
      self.account = account
      self.accessGroup = accessGroup
      self.useDataProtectionKeychain = useDataProtectionKeychain
    }
  }
#endif

  @available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
  public static var home: KeyChain { KeyChain(.home) }
  public static var documents: KeyChain { KeyChain(.documents) }
  public static func file(_ url: URL) -> KeyChain {
    KeyChain(.file(url))
  }
#if canImport(Security)
  public static func keychain(_ tag: String) -> KeyChain {
    KeyChain(.keychain(tag))
  }
#endif
  public enum Location: Sendable {
    case file(URL)
    static var documents: Location {
      .file(FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("hub.key"))
    }
    @available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
    static var home: Location {
      .file(URL.homeDirectory.appendingPathComponent("hub.key"))
    }
    case none
#if canImport(Security)
    case keychain(String)
    case configuredKeychain(KeychainConfiguration)
#endif
    func load() -> Data? {
      switch self {
      case .file(let url):
        return try? Data(contentsOf: url)
      case .none: return nil
#if canImport(Security)
      case .keychain(let tag):
        let query = [
          kSecClass: kSecClassGenericPassword,
          kSecAttrService: tag,
          kSecReturnData: kCFBooleanTrue!,
          kSecMatchLimit: kSecMatchLimitOne
        ] as [CFString: Any] as CFDictionary
        var value: AnyObject?
        let status = SecItemCopyMatching(query, &value)
        guard status == errSecSuccess else { return nil }
        return value as? Data
      case .configuredKeychain(let configuration):
        return try? Self.load(configuration)
#endif
      }
    }
    func save(_ data: Data) {
      switch self {
      case .file(let url):
        try? data.write(to: url, options: .atomic)
      case .none: break
#if canImport(Security)
      case .keychain(let tag):
        let identity = [
          kSecClass: kSecClassGenericPassword,
          kSecAttrService: tag
        ] as [CFString: Any] as CFDictionary
        let query = [
          kSecClass: kSecClassGenericPassword,
          kSecAttrService: tag,
          kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
          kSecValueData: data
        ] as [CFString: Any] as CFDictionary
        SecItemDelete(identity)
        SecItemAdd(query, nil)
      case .configuredKeychain(let configuration):
        try? Self.save(data, configuration: configuration)
#endif
      }
    }

#if canImport(Security)
    private static func query(
      _ configuration: KeychainConfiguration
    ) -> [String: Any] {
      var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: configuration.service,
      ]
      if let account = configuration.account {
        query[kSecAttrAccount as String] = account
      }
      if let accessGroup = configuration.accessGroup {
        query[kSecAttrAccessGroup as String] = accessGroup
      }
      if configuration.useDataProtectionKeychain {
        query[kSecUseDataProtectionKeychain as String] = true
      }
      return query
    }

    fileprivate static func load(
      _ configuration: KeychainConfiguration
    ) throws -> Data? {
      var query = query(configuration)
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var value: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &value)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let data = value as? Data else {
        throw Error.keychainStatus(status)
      }
      return data
    }

    fileprivate static func replace(
      _ data: Data,
      configuration: KeychainConfiguration
    ) throws {
      SecItemDelete(query(configuration) as CFDictionary)
      try save(data, configuration: configuration)
    }

    fileprivate static func save(
      _ data: Data,
      configuration: KeychainConfiguration
    ) throws {
      var query = query(configuration)
      query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      query[kSecValueData as String] = data
      let status = SecItemAdd(query as CFDictionary, nil)
      guard status == errSecSuccess else {
        throw Error.keychainStatus(status)
      }
    }
#endif
  }
  
  private let privateKey: Curve25519.Signing.PrivateKey
  /// Where the key is stored, `nil` for keys that only live in memory
  public let location: Location?
  public init(_ location: Location) {
    self.location = location
    if let data = location.load(), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
      self.privateKey = key
    } else {
      let key = Curve25519.Signing.PrivateKey()
      location.save(key.rawRepresentation)
      self.privateKey = key
    }
  }

  public init(_ location: Location, rawRepresentation: Data) throws {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    privateKey = key
    self.location = location
    location.save(key.rawRepresentation)
  }

  /// A key that isn't stored anywhere, from its 32-byte seed
  public init(rawRepresentation: Data) throws {
    privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    location = nil
  }

  /// A key in the Hub key file format: base64 of the PKCS#8 DER private key (48 bytes) followed by the
  /// SPKI DER public key (44 bytes). Service `auth` files and `device.key` use it.
  public init(keyFile text: String) throws {
    guard let bytes = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          bytes.count == Self.pkcs8Prefix.count + 32 + Self.prefix.count + 32,
          bytes.starts(with: Self.pkcs8Prefix) else { throw Error.invalidPrivateKey }
    let seed = bytes.subdata(in: Self.pkcs8Prefix.count..<Self.pkcs8Prefix.count + 32)
    do {
      privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    } catch {
      throw Error.invalidPrivateKey
    }
    guard bytes.suffix(Self.prefix.count + 32) == Self.prefix + privateKey.publicKey.rawRepresentation else {
      throw Error.invalidPublicKey
    }
    location = nil
  }

  /// The key in the Hub key file format, see `init(keyFile:)`
  public var keyFile: String {
    (Self.pkcs8Prefix + privateKey.rawRepresentation + publicKeyData()).base64EncodedString()
  }

#if canImport(Security)
  public init(keychain configuration: KeychainConfiguration, createIfMissing: Bool = true) throws {
    location = .configuredKeychain(configuration)
    if let data = try Location.load(configuration) {
      do {
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
      } catch {
        throw Error.invalidPrivateKey
      }
    } else {
      guard createIfMissing else { throw Error.keyNotFound }
      let key = Curve25519.Signing.PrivateKey()
      try Location.save(key.rawRepresentation, configuration: configuration)
      privateKey = key
    }
  }

  public init(keychain configuration: KeychainConfiguration, rawRepresentation: Data) throws {
    let key: Curve25519.Signing.PrivateKey
    do {
      key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    } catch {
      throw Error.invalidPrivateKey
    }
    try Location.save(key.rawRepresentation, configuration: configuration)
    privateKey = key
    location = .configuredKeychain(configuration)
  }

  /// Reads a configured Keychain item, `nil` when it doesn't exist
  public static func loadData(keychain configuration: KeychainConfiguration) throws -> Data? {
    try Location.load(configuration)
  }

  /// Writes a configured Keychain item, replacing an existing one
  public static func replaceData(_ data: Data, keychain configuration: KeychainConfiguration) throws {
    try Location.replace(data, configuration: configuration)
  }
#endif

  public var data: Data {
    privateKey.publicKey.rawRepresentation
  }

  public func signature(for data: Data) throws -> Data {
    try privateKey.signature(for: data)
  }

  public static func spkiPublicKey(rawRepresentation: Data) -> Data? {
    guard rawRepresentation.count == 32 else { return nil }
    return prefix + rawRepresentation
  }

  public static func rawPublicKey(spkiRepresentation: Data) -> Data? {
    guard spkiRepresentation.count == prefix.count + 32, spkiRepresentation.starts(with: prefix)
    else { return nil }
    return Data(spkiRepresentation.dropFirst(prefix.count))
  }

  public static func spkiPublicKey(rawBase64: String) -> String? {
    guard let raw = Data(base64Encoded: rawBase64), let spki = spkiPublicKey(rawRepresentation: raw)
    else { return nil }
    return spki.base64EncodedString()
  }

  public static func rawPublicKey(spkiBase64: String) -> Data? {
    guard let spki = Data(base64Encoded: spkiBase64) else { return nil }
    return rawPublicKey(spkiRepresentation: spki)
  }

  public func sign(text: String) -> String {
    sign(data: Data(text.utf8))
  }
  
  public func sign(data: Data) -> String {
    try! signature(for: data).base64EncodedString()
  }

  public func publicKey() -> String {
    publicKeyData().base64EncodedString()
  }
  
  public func publicKeyData() -> Data {
    Self.prefix + data
  }

  /// ED25519 PKCS#8 prefix, followed by the 32-byte seed
  private static let pkcs8Prefix = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20])
  /// ED25519 spki prefix
  private static let prefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
}
