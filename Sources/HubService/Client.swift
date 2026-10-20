//
//  File.swift
//  WebSocket
//
//  Created by Dmitry Kozlov on 17/2/25.
//

import Foundation
import Channel

@MainActor
public class HubClient: @MainActor Identifiable {
  public static let test = HubClient(connect: false)
  public var id: URL { url }
  public nonisolated static var local: URL { URL(string: "ws://127.0.0.1:1997")! }
  public var isConnected: Bool { sender.ws.isConnected }
  public var isConnectedChanged: ((Bool) -> Void)? {
    get { sender.ws.isConnectedChanged }
    set { sender.ws.isConnectedChanged = newValue }
  }
  public var debugNetwork: Bool {
    get { sender.ws.debug }
    set { sender.ws.debug = newValue }
  }
  public let url: URL
  public let channel: Channel<Void>
  public let service: HubService
  public var profile: Profile
  /// Hub keys pinned per address; a pinned key makes the connection send hub-bound `v: 1` tokens
  public let hubKeys: HubKeyPins
  /// The pinned key of this hub, learned from `hub/info` or supplied up front
  public var hubKey: String? { hubKeys.key(for: url) }
  /// `nil` when the client connects without a device
  public let device: DeviceIdentity?
  /// Set when the hub answered `hub/info`
  public private(set) var info: HubInfo?
  /// Called when a hub's key couldn't be learned or no longer matches
  public var onHubKeyError: ((HubKeyError) -> Void)?
  private var sender: ClientSender<Void>!
  public struct Options {
    /// The hub's key when it is known up front (from an invitation or configuration); it is pinned
    public var hubKey: String?
    /// Where hub keys are pinned. `nil` keeps them beside the key: `hubs.json` or a Keychain item
    public var hubKeys: HubKeyPins?
    /// The device this client runs on. `nil` connects without a device (no `device` header)
    public var device: DeviceIdentity?
    /// The instance name in the certificate, unique per device: `s3-local/Backup Disk`. Defaults to the process name
    public var instance: String?
    public init(hubKey: String? = nil, hubKeys: HubKeyPins? = nil, device: DeviceIdentity? = nil, instance: String? = nil) {
      self.hubKey = hubKey
      self.hubKeys = hubKeys
      self.device = device
      self.instance = instance
    }
  }
  public init(_ url: URL = HubClient.local, keyChain: KeyChain? = nil, connect: Bool = true, options: Options = Options()) {
    self.url = url
    channel = Channel()
    service = HubService(channel: channel)
    profile = Profile(name: .device, icon: .device)
    hubKeys = options.hubKeys ?? keyChain.map(HubKeyPins.beside) ?? HubKeyPins(.memory)
    device = keyChain == nil ? nil : options.device
    if let hubKey = options.hubKey {
      hubKeys.pin(hubKey, for: url)
    }
    guard connect else { return }
    if let keyChain {
      let serviceKey = keyChain.publicKey()
      let issuer = device.map {
        CertificateIssuer(device: $0, service: serviceKey, instance: options.instance ?? ProcessInfo.processInfo.processName)
      }
      service.network.configureIdentity(keyChain)
      sender = channel.connect(url, options: ClientOptions(headers: { [weak self] in
        let hubKey = self?.hubKey
        return HubAuth.headers(keyChain, hubKey: hubKey, certificate: hubKey == nil ? nil : issuer?.header())
      }, onConnect: { [weak self] sender in
        guard let self else { return }
        try? await sender.send("hub/profile/update", profile)
        guard await learnHubKey(sender) else { return }
        try await service.sendServiceUpdates(first: true)
        try await service.network.didConnect(sender)
      }))
    } else {
      sender = channel.connect(url)
    }
    service.sender = sender
  }

  /// Forgets the pinned key, so the next connection learns it again with a v0 token
  public func forgetHubKey() {
    hubKeys.forget(url)
    sender?.reconnectNow()
  }

  /// Reads `hub/info`. Without a pinned key, pins it and reconnects with a v1 token (and the device certificate).
  /// A different key than the pinned one is reported and never replaces it.
  /// - Returns: `false` when the connection is about to be replaced
  private func learnHubKey(_ sender: ChannelSender<Void>) async -> Bool {
    guard let info: HubInfo = try? await sender.send("hub/info") else { return true }
    self.info = info
    guard let pinned = hubKey else {
      hubKeys.pin(info.key, for: url)
      self.sender?.reconnectNow()
      return false
    }
    if pinned != info.key {
      onHubKeyError?(.mismatch(pinned: pinned, received: info.key))
    }
    return true
  }

  public enum HubKeyError: Error, Hashable, Sendable {
    /// The hub at this address has another key than the pinned one: the hub key changed or another server answers
    case mismatch(pinned: String, received: String)
  }
  // No body
  public func send<Output: Decodable>(_ path: String) async throws -> Output {
    try await sender.send(path)
  }
  public func send(_ path: String) async throws {
    try await sender.send(path)
  }
  // With body
  public func send<Body: Encodable>(_ path: String, _ body: Body?) async throws {
    try await sender.send(path, body)
  }
  public func send<Body: Encodable, Output: Decodable>(_ path: String, _ body: Body?) async throws -> Output {
    try await sender.send(path, body)
  }
  // With context
  public func send<Context: Encodable & Sendable, Output: Decodable>(_ path: String, context: Context?) async throws -> Output {
    try await sender.send(path, options: SendOptions(context: context))
  }
  public func send<Context: Encodable & Sendable>(_ path: String, context: Context?) async throws {
    try await sender.send(path, options: SendOptions(context: context))
  }
  public func send<Body: Encodable, Context: Encodable & Sendable>(_ path: String, _ body: Body?, context: Context?) async throws {
    try await sender.send(path, body, options: SendOptions(context: context))
  }
  public func send<Body: Encodable, Context: Encodable & Sendable, Output: Decodable>(_ path: String, _ body: Body?, context: Context?) async throws -> Output {
    try await sender.send(path, body, options: SendOptions(context: context))
  }
  // No body
  public func values<Output: Decodable>(_ path: String) -> Values<Void, EmptyCodable, EmptyCodable, Output> {
    sender.values(path)
  }
  public func values(_ path: String) -> Values<Void, EmptyCodable, EmptyCodable, EmptyCodable> {
    sender.values(path)
  }
  // With body
  public func values<Body: Encodable>(_ path: String, _ body: Body?) -> Values<Void, Body, EmptyCodable, EmptyCodable> {
    sender.values(path, body)
  }
  public func values<Body: Encodable, Output: Decodable>(_ path: String, _ body: Body?) -> Values<Void, Body, EmptyCodable, Output> {
    sender.values(path, body)
  }
  // With context
  public func values<Context: Encodable & Sendable, Output: Decodable>(_ path: String, context: Context?) -> Values<Void, EmptyCodable, Context, Output> {
    sender.values(path, options: SendOptions(context: context))
  }
  public func values<Context: Encodable & Sendable>(_ path: String, context: Context?) -> Values<Void, EmptyCodable, Context, EmptyCodable> {
    sender.values(path, options: SendOptions(context: context))
  }
  public func values<Body: Encodable, Context: Encodable & Sendable>(_ path: String, _ body: Body?, context: Context?) -> Values<Void, Body, Context, EmptyCodable> {
    sender.values(path, body, options: SendOptions(context: context))
  }
  public func values<Body: Encodable, Context: Encodable & Sendable, Output: Decodable>(_ path: String, _ body: Body?, context: Context?) -> Values<Void, Body, Context, Output> {
    sender.values(path, body, options: SendOptions(context: context))
  }
  /// Reads one stream value and releases its iterator immediately, causing
  /// Channel to cancel the remote stream instead of leaving a subscription.
  public func oneValue<Output: Decodable & Sendable>(
    _ path: String,
    as type: Output.Type = Output.self
  ) async throws -> Output {
    var iterator: ValuesIterator<Void, EmptyCodable, EmptyCodable, Output>? =
      values(path).makeAsyncIterator()
    guard let value = try await iterator?.next() else {
      throw HubClientStreamError.finishedWithoutValue(path)
    }
    iterator = nil
    return value
  }

  /// Body-bearing variant used by one-value bootstrap and lookup streams.
  public func oneValue<Body: Encodable & Sendable, Output: Decodable & Sendable>(
    _ path: String,
    _ body: Body?,
    as type: Output.Type = Output.self
  ) async throws -> Output {
    var iterator: ValuesIterator<Void, Body, EmptyCodable, Output>? =
      values(path, body).makeAsyncIterator()
    guard let value = try await iterator?.next() else {
      throw HubClientStreamError.finishedWithoutValue(path)
    }
    iterator = nil
    return value
  }
  public func stop() {
    sender.stop()
  }
  public struct Profile: Codable, Sendable, Hashable {
    public var name: String
    public var icon: Icon
  }
}

public enum HubClientStreamError: Error, Equatable, Sendable {
  case finishedWithoutValue(String)
}
