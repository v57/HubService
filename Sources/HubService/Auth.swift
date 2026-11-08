//
//  Auth.swift
//  HubService
//
//  Hub-bound auth tokens and pinned hub keys (Docs/Devices/protocol.md, section 2).
//

import Foundation
import Channel
#if canImport(Security)
import Security
#endif

public enum HubAuth {
  /// A token's lifetime: the hub takes at most 60 seconds ahead
  public static let tokenLifetime = 30

  /// The string an `auth` token signs: `hub1:<hub key>:<nonce>:<expiry>` for v1. `<expiry>` alone is v0, which hubs
  /// refuse and nothing here sends; the test vectors still check it.
  public static func signedData(expiry: Int, hubKey: String?, nonce: String? = nil) -> String {
    if let hubKey { "hub1:\(hubKey):\(nonce ?? ""):\(expiry)" } else { "\(expiry)" }
  }

  /// `key.<service SPKI>.<signature>.<expiry>.<nonce>`: works once, on that hub
  public static func token(_ keyChain: KeyChain, expiry: Int, hubKey: String, nonce: String) -> String {
    "key.\(keyChain.publicKey()).\(keyChain.sign(text: signedData(expiry: expiry, hubKey: hubKey, nonce: nonce))).\(expiry).\(nonce)"
  }

  /// Connection headers for a hub that proved its key and gave `nonce` as its challenge: `v`, `auth` and, with a
  /// certificate, `device`
  public static func headers(_ keyChain: KeyChain, hubKey: String, nonce: String, certificate: String? = nil, now: Date = Date()) -> [String: String] {
    var headers = [
      "v": "1",
      "auth": token(keyChain, expiry: Int(now.timeIntervalSince1970) + tokenLifetime, hubKey: hubKey, nonce: nonce),
    ]
    if let certificate {
      headers["device"] = certificate
    }
    return headers
  }
}

/// `hub/info`: the hub's key and security mode, and with a nonce a proof of that key and a challenge to sign
public struct HubInfo: Codable, Hashable, Sendable {
  public var key: String
  public var `protocol`: Int
  /// Sent by hub-server (formerly hub-pro) for one more release; nothing depends on it
  public var pro: Bool?
  /// `default-allow` or `default-deny`
  public var mode: String?
  /// One-time, for one connection, valid for a minute
  public var challenge: String?
  /// The hub key's signature of `hubinfo1:<key>:<client nonce>`
  public var proof: String?
}

/// Asking a hub who it is before it gets anything: an anonymous connection, a nonce, and a signature of it by the key the
/// hub claims. A relayed answer passes too, so a proof pins a key and never decides which credentials a hub gets.
@MainActor
public enum HubHandshake {
  public enum Answer: Hashable, Sendable {
    /// The hub proved its key at `url`, the pinned key if there is a pin
    case proven(HubInfo, challenge: String, url: URL)
    /// The hub at the address proved another key than the pinned one
    case mismatch(current: String)
    /// Nothing answered with a proof, which never counts as a key
    case none
  }

  /// 32 random bytes in base64url
  public nonisolated static func makeNonce() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
    return Data(bytes).base64URLEncoded()
  }

  /// The string `proof` signs
  public nonisolated static func signedData(hubKey: String, nonce: String) -> String {
    "hubinfo1:\(hubKey):\(nonce)"
  }

  /// Whether an answer proves its key over `nonce`
  public nonisolated static func proves(_ info: HubInfo, nonce: String) -> Bool {
    guard let proof = info.proof, info.challenge != nil else { return false }
    return DeviceKey.verify(signature: proof, text: signedData(hubKey: info.key, nonce: nonce), publicKey: info.key)
  }

  private struct Request: Encodable, Sendable {
    var nonce: String
  }

  /// `hub/info` on a connection of its own, without credentials. `nil` unless the answer proves its key.
  public static func ask(_ url: URL, timeout: TimeInterval = 5) async -> HubInfo? {
    let nonce = makeNonce()
    let probe = Channel<Void>().connect(url)
    defer { probe.stop() }
    return await withTaskCancellationHandler {
      guard let info: HubInfo = try? await probe.send("hub/info", Request(nonce: nonce), options: SendOptions(timeout: timeout)) else {
        return nil
      }
      return proves(info, nonce: nonce) ? info : nil
    } onCancel: {
      Task { @MainActor in probe.stop() }
    }
  }

  /// Whether the server at `url` is a hub from before auth v2: it answers `hub/info` with a key but no proof, or (hub-lite)
  /// has no `hub/info` at all. Such a hub gets nothing from this client, which never falls back to v0; the user has to
  /// update it. `false` when nothing answers.
  public static func needsUpdate(_ url: URL, timeout: TimeInterval = 5) async -> Bool {
    let nonce = makeNonce()
    let probe = Channel<Void>().connect(url)
    defer { probe.stop() }
    return await withTaskCancellationHandler {
      do {
        let info: HubInfo = try await probe.send("hub/info", Request(nonce: nonce), options: SendOptions(timeout: timeout))
        return isOutdated(info)
      } catch {
        return isOutdated(error)
      }
    } onCancel: {
      Task { @MainActor in probe.stop() }
    }
  }

  /// An answer from a hub from before auth v2: a key, but no proof and no challenge
  public nonisolated static func isOutdated(_ info: HubInfo) -> Bool {
    !info.key.isEmpty && info.proof == nil && info.challenge == nil
  }

  /// hub-lite, which predates `hub/info`, answers it with `api not found`
  public nonisolated static func isOutdated(_ error: Error) -> Bool {
    guard let error = error as? ChannelError else { return false }
    return error.code == .notFound || error.text == "api not found"
  }

  /// Asks every address at once and takes the first that proves `pinned`, or with no pin what the first address proves.
  /// Only the first address, the one the hub is known by, can report a mismatch: the others are just other ways in.
  public static func ask(_ urls: [URL], pinned: String?, timeout: TimeInterval = 5) async -> Answer {
    guard let main = urls.first else { return .none }
    return await withTaskGroup(of: AddressAnswer.self, returning: Answer.self) { group in
      for url in pinned == nil ? [main] : urls {
        group.addTask { await AddressAnswer.ask(url, timeout: timeout) }
      }
      var other: HubInfo?
      while let answer = await group.next() {
        guard let info = answer.info else { continue }
        if pinned == nil || info.key == pinned, let challenge = info.challenge {
          group.cancelAll()
          return .proven(info, challenge: challenge, url: answer.url)
        }
        if answer.url == main { other = info }
      }
      if let other { return .mismatch(current: other.key) }
      return .none
    }
  }

  private struct AddressAnswer: Sendable {
    var url: URL
    var info: HubInfo?
    @MainActor static func ask(_ url: URL, timeout: TimeInterval) async -> AddressAnswer {
      AddressAnswer(url: url, info: await HubHandshake.ask(url, timeout: timeout))
    }
  }
}

/// Hub keys pinned per hub address, so auth tokens are bound to the hub they were made for.
/// The first connection to a hub pins the key it proves over `hub/info`; every connection then has to prove the same.
@MainActor
public final class HubKeyPins {
  public enum Storage: Sendable {
    /// Lost when the process ends
    case memory
    /// A JSON object `{ "<address>": "<hub SPKI>" }`, `hubs.json` beside a key file
    case file(URL)
#if canImport(Security) || canImport(SecretService)
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
#if canImport(Security) || canImport(SecretService)
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

  /// Forgets the hub key, so the next connection pins what the hub proves
  public func forget(_ address: URL) {
    guard keys.removeValue(forKey: address.absoluteString) != nil else { return }
    save()
  }

  private static func load(_ storage: Storage) -> [String: String] {
    let data: Data?
    switch storage {
    case .memory: data = nil
    case .file(let url): data = try? Data(contentsOf: url)
#if canImport(Security) || canImport(SecretService)
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
#if canImport(Security) || canImport(SecretService)
    case .keychain(let configuration):
      try? KeyChain.replaceData(data, keychain: configuration)
#endif
    }
  }
}
