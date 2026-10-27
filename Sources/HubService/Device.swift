//
//  Device.swift
//  HubService
//
//  Device keys and service certificates (Docs/Devices/protocol.md, sections 1 and 3).
//

import Foundation
#if canImport(Crypto)
import Crypto
#else
import CryptoKit
#endif

/// The key of the device this process runs on. It signs a short certificate for each service key, sent in the
/// `device` header, so the hub attaches the connection to the device.
public struct DeviceKey: Sendable {
  public let keyChain: KeyChain
  public init(_ keyChain: KeyChain) {
    self.keyChain = keyChain
  }

  /// Device SPKI, standard base64
  public var publicKey: String { keyChain.publicKey() }
  /// First 32 lowercase hex characters of SHA-256 of the device SPKI
  public var id: String { Self.id(publicKey: publicKey) }
  /// Six digits shown as `ddd ddd` on both devices during approval
  public var safetyCode: String { Self.safetyCode(publicKey: publicKey) }

  public static func id(publicKey: String) -> String {
    String(digest(publicKey).prefix(32))
  }

  public static func safetyCode(publicKey: String) -> String {
    let n = (UInt32(digest(publicKey).prefix(8), radix: 16) ?? 0) % 1_000_000
    let digits = String(n).leftPadded(to: 6)
    return "\(digits.prefix(3)) \(digits.suffix(3))"
  }

  /// Verifies a device signature (standard base64) over `text` with a device SPKI
  public static func verify(signature: String, text: String, publicKey: String) -> Bool {
    guard let raw = KeyChain.rawPublicKey(spkiBase64: publicKey),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
          let signature = Data(base64Encoded: signature) else { return false }
    return key.isValidSignature(signature, for: Data(text.utf8))
  }

  private static func digest(_ publicKey: String) -> String {
    let data = Data(base64Encoded: publicKey) ?? Data(publicKey.utf8)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// `HUB_DEVICE_KEY`, else `/var/lib/hub/device.key` for root on Linux, else `~/.hub/device.key`
  public static var defaultFile: URL {
    if let path = ProcessInfo.processInfo.environment["HUB_DEVICE_KEY"], !path.isEmpty {
      return URL(fileURLWithPath: path)
    }
#if os(Linux)
    if getuid() == 0 {
      return URL(fileURLWithPath: "/var/lib/hub/device.key")
    }
#endif
    return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hub/device.key")
  }

  /// Loads the device key file (Hub key file format) or creates it atomically: directory 0700, file 0600
  public static func file(_ url: URL = DeviceKey.defaultFile) throws -> DeviceKey {
    let manager = FileManager.default
    if let text = try? String(contentsOf: url, encoding: .utf8) {
      return DeviceKey(try KeyChain(keyFile: text))
    }
    let directory = url.deletingLastPathComponent()
    try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let key = try KeyChain(rawRepresentation: Curve25519.Signing.PrivateKey().rawRepresentation)
    let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
    guard manager.createFile(atPath: temp.path, contents: Data(key.keyFile.utf8), attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    do {
      // Another process may have created it first; keep theirs
      if manager.fileExists(atPath: url.path) {
        try? manager.removeItem(at: temp)
        return DeviceKey(try KeyChain(keyFile: String(contentsOf: url, encoding: .utf8)))
      }
      try manager.moveItem(at: temp, to: url)
    } catch {
      try? manager.removeItem(at: temp)
      throw error
    }
    return DeviceKey(key)
  }

#if canImport(Security) || canImport(SecretService)
  /// A device key in any Keychain item the caller chooses, e.g. a sandboxed app's own. Created if missing.
  public static func keychain(_ configuration: KeyChain.KeychainConfiguration) throws -> DeviceKey {
    DeviceKey(try KeyChain(keychain: configuration))
  }

  public static let keychainService = "dev.v57.Hub.device.v1"
  /// Keychain item `dev.v57.Hub.device.v1`, `ThisDeviceOnly`, shared with extensions through `accessGroup`
  public static func keychain(accessGroup: String? = nil, useDataProtectionKeychain: Bool = true) throws -> DeviceKey {
    DeviceKey(try KeyChain(keychain: .init(
      service: keychainService,
      account: "ed25519-private-key",
      accessGroup: accessGroup,
      useDataProtectionKeychain: useDataProtectionKeychain
    )))
  }
#endif

  /// Signs a certificate for a service key
  public func certificate(
    service: String,
    instance: String,
    deviceName: String? = nil,
    platform: String? = nil,
    parent: String? = nil,
    hub: String? = nil,
    issuedAt: Int,
    lifetime: Int = ServiceCertificate.maxLifetime
  ) -> ServiceCertificate {
    ServiceCertificate(device: self, fields: .init(
      device: publicKey, service: service, instance: instance, deviceName: deviceName,
      platform: platform, parent: parent, hub: hub,
      iat: issuedAt, exp: issuedAt + min(lifetime, ServiceCertificate.maxLifetime)
    ))
  }
}

/// `<base64url(JSON)>.<signature>`; the device key signs the base64url payload string
public struct ServiceCertificate: Hashable, Sendable {
  /// Longest lifetime the hub accepts, 7 days
  public static let maxLifetime = 604_800
  /// Renewed at connect when less than this is left, 24 hours
  public static let renewBefore = 86_400

  public struct Fields: Codable, Hashable, Sendable {
    public var v = 1
    public var device: String
    public var service: String
    public var instance: String
    public var deviceName: String?
    public var platform: String?
    public var parent: String?
    public var hub: String?
    public var iat: Int
    public var exp: Int
  }
  public let fields: Fields
  public let payload: String
  public let signature: String
  public var header: String { "\(payload).\(signature)" }

  init(device: DeviceKey, fields: Fields) {
    self.fields = fields
    payload = Data(Self.json(fields).utf8).base64URLEncoded()
    signature = device.keyChain.sign(text: payload)
  }

  /// Whether the certificate should be replaced at `now`
  public func needsRenewal(now: Int) -> Bool {
    fields.exp - now < Self.renewBefore
  }

  /// Fields in the protocol's order with no whitespace, so certificates match the test vectors
  static func json(_ fields: Fields) -> String {
    var parts = ["\"v\":\(fields.v)"]
    func add(_ key: String, _ value: String?) {
      guard let value else { return }
      parts.append("\"\(key)\":\(jsonString(value))")
    }
    add("device", fields.device)
    add("service", fields.service)
    add("instance", fields.instance)
    add("deviceName", fields.deviceName)
    add("platform", fields.platform)
    add("parent", fields.parent)
    add("hub", fields.hub)
    parts.append("\"iat\":\(fields.iat)")
    parts.append("\"exp\":\(fields.exp)")
    return "{\(parts.joined(separator: ","))}"
  }

  private static func jsonString(_ value: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return String(decoding: (try? encoder.encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
  }
}

/// What a client sends as its device: the key plus the names it suggests to the hub
public struct DeviceIdentity: Sendable {
  public var key: DeviceKey
  /// Suggested device name, at most 64 bytes
  public var name: String?
  /// `macos`, `ios`, `ipados`, `visionos`, `tvos`, `watchos`, `linux`, `windows`, `android`, `other`
  public var platform: String?
  /// Declared parent device name for containers and VMs
  public var parent: String?
  public init(key: DeviceKey, name: String? = nil, platform: String? = DeviceIdentity.currentPlatform, parent: String? = nil) {
    self.key = key
    self.name = name.map { $0.truncated(bytes: 64) }
    self.platform = platform
    self.parent = parent.map { $0.truncated(bytes: 64) }
  }

  /// The device key file (`HUB_DEVICE_KEY` or `~/.hub/device.key`) named after this computer
  public static func file(_ url: URL = DeviceKey.defaultFile, name: String? = DeviceIdentity.computerName) throws -> DeviceIdentity {
    DeviceIdentity(key: try DeviceKey.file(url), name: name)
  }

  /// The computer name the user chose (macOS ComputerName), else the host name
  public static var computerName: String {
#if os(macOS)
    if let name = Host.current().localizedName, !name.isEmpty { return name }
#endif
    return ProcessInfo.processInfo.hostName
  }

  public static var currentPlatform: String {
#if os(macOS) || targetEnvironment(macCatalyst)
    "macos"
#elseif os(visionOS)
    "visionos"
#elseif os(iOS)
    "ios"
#elseif os(tvOS)
    "tvos"
#elseif os(watchOS)
    "watchos"
#elseif os(Linux)
    "linux"
#elseif os(Windows)
    "windows"
#elseif os(Android)
    "android"
#else
    "other"
#endif
  }
}

/// Signs and renews the certificate of one service key
@MainActor
final class CertificateIssuer {
  let device: DeviceIdentity
  let service: String
  private let instance: @MainActor () -> String
  private var current: ServiceCertificate?
  init(device: DeviceIdentity, service: String, instance: @escaping @MainActor () -> String) {
    self.device = device
    self.service = service
    self.instance = instance
  }
  convenience init(device: DeviceIdentity, service: String, instance: String) {
    self.init(device: device, service: service, instance: { instance })
  }
  func header(now: Date = Date()) -> String {
    let now = Int(now.timeIntervalSince1970)
    var instance = String(self.instance().truncated(bytes: 128))
    if instance.isEmpty { instance = "service" }
    if let current, current.fields.instance == instance, !current.needsRenewal(now: now) {
      return current.header
    }
    let certificate = device.key.certificate(
      service: service, instance: instance, deviceName: device.name,
      platform: device.platform, parent: device.parent, issuedAt: now
    )
    current = certificate
    return certificate.header
  }
}

extension Data {
  func base64URLEncoded() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

extension String {
  func leftPadded(to length: Int) -> String {
    count >= length ? self : String(repeating: "0", count: length - count) + self
  }
  /// The longest prefix that fits in `bytes` UTF-8 bytes
  func truncated(bytes: Int) -> String {
    guard utf8.count > bytes else { return self }
    var result = ""
    for character in self {
      guard result.utf8.count + String(character).utf8.count <= bytes else { break }
      result.append(character)
    }
    return result
  }
}
