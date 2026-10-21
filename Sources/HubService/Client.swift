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
  /// The current connection finished its setup: the hub key is learned (or the hub doesn't offer one) and the
  /// services are sent. A new hub key makes the client reconnect first, so wait for this before calls that need
  /// the hub-bound, device-attached connection.
  public private(set) var isReady = false
  /// Called when a hub's key couldn't be learned or no longer matches
  public var onHubKeyError: ((HubKeyError) -> Void)?
  /// Set while the hub refuses this client's connection, with the reason; cleared when a connection opens.
  /// Posts fail with Channel's `refused` error meanwhile, and the client tries again every 30 seconds.
  public private(set) var refusal: Refusal?
  /// Called when the hub refused the connection, once the reason is known
  public var onRefused: ((Refusal) -> Void)?
  private var sender: ClientSender<Void>!
  private var reporter: DeviceReporter?
  public struct Options {
    /// The hub's key when it is known up front (from an invitation or configuration); it is pinned
    public var hubKey: String?
    /// Where hub keys are pinned. `nil` keeps them beside the key: `hubs.json` or a Keychain item
    public var hubKeys: HubKeyPins?
    /// The device this client runs on. `nil` connects without a device (no `device` header)
    public var device: DeviceIdentity?
    /// The instance name in the certificate, unique per device: `s3-local/Backup Disk`. Defaults to the profile
    /// name, else the working directory's name
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
        CertificateIssuer(device: $0, service: serviceKey) { [weak self] in
          if let instance = options.instance { return instance }
          if let name = self?.profile.name, !name.isEmpty { return name }
          return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent
        }
      }
      service.network.configureIdentity(keyChain)
      sender = channel.connect(url, options: ClientOptions(headers: { [weak self] in
        self?.isReady = false
        let hubKey = self?.hubKey
        return HubAuth.headers(keyChain, hubKey: hubKey, certificate: hubKey == nil ? nil : issuer?.header())
      }, onConnect: { [weak self] sender in
        guard let self else { return }
        await connectionOpened()
        try? await sender.send("hub/profile/update", profile)
        guard await learnHubKey(sender) else { return }
        try await service.sendServiceUpdates(first: true)
        await setReady()
        await reporter?.connected(self)
        try await service.network.didConnect(sender)
      }))
    } else {
      sender = channel.connect(url)
    }
    service.sender = sender
    sender.ws.onRefused = { [weak self] refusal in
      Task { await self?.refused(statusCode: refusal.statusCode) }
    }
  }

  /// Why the hub refuses the connection. A refused upgrade carries only an HTTP status, so the client asks the hub
  /// anonymously to tell the cases apart.
  public enum Refusal: Error, Hashable, Sendable, CustomStringConvertible {
    /// The hub accepts other clients and its key is the pinned one, so it refuses this key: the key or its device
    /// was revoked (or this device's clock is off by more than 30 seconds)
    case keyRefused
    /// A different hub key answers at this address than the pinned one
    case hubKeyChanged(pinned: String, current: String)
    /// The hub refuses every client it doesn't know (whitelist or lockdown)
    case hubNotAvailable
    /// The hub refused the connection and didn't answer the anonymous check
    case refused(statusCode: Int)

    public var description: String {
      switch self {
      case .keyRefused: "The hub refused this device: its key or the device was revoked, or the device clock is wrong."
      case .hubKeyChanged: "The hub's key changed since this device first connected, or another server answers at this address."
      case .hubNotAvailable: "The hub only accepts devices it already knows."
      case .refused(let statusCode): "The hub refused the connection (HTTP \(statusCode))."
      }
    }
  }

  private func refused(statusCode: Int) async {
    let refusal = await diagnoseRefusal(statusCode: statusCode)
    // A connection may have opened meanwhile
    guard sender?.ws.refusal != nil else { return }
    self.refusal = refusal
    onRefused?(refusal)
  }

  /// Connects without a key and reads `hub/info`
  private func diagnoseRefusal(statusCode: Int) async -> Refusal {
    let probe = Channel<Void>().connect(url)
    defer { probe.stop() }
    do {
      let info: HubInfo = try await probe.send("hub/info", options: SendOptions(timeout: 5))
      if let pinned = hubKey, pinned != info.key {
        return .hubKeyChanged(pinned: pinned, current: info.key)
      }
      return .keyRefused
    } catch let error as ChannelError where error.code == .refused {
      return .hubNotAvailable
    } catch {
      return .refused(statusCode: statusCode)
    }
  }

  /// Takes the reporter role for this client's device: describes the device on every connection and sends live
  /// data every `interval` seconds while connected. Another connection of the device may hold the role; then the
  /// hub refuses and this client keeps trying.
  public func report(
    every interval: TimeInterval = 30,
    description: @escaping @MainActor () async -> DeviceDescription,
    data: @escaping @MainActor () async -> DeviceData
  ) {
    reporter?.stop()
    reporter = DeviceReporter(interval: interval, description: description, data: data)
    service.isReporter = true
    if isConnected {
      reporter?.connected(self)
    }
  }

  public func stopReporting() {
    reporter?.stop()
    reporter = nil
    service.isReporter = false
  }

  private func setReady() {
    isReady = true
  }

  private func connectionOpened() {
    refusal = nil
  }

  /// Waits until `isReady`, at most `timeout` seconds. Returns whether the connection is ready; `false` at once
  /// when the hub refuses the connection (see `refusal`).
  @discardableResult
  public func waitUntilReady(timeout: TimeInterval = 10) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !(isReady && isConnected) {
      guard Date() < deadline, !Task.isCancelled, sender?.ws.refusal == nil else { return false }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return true
  }

  /// Forgets the pinned key, so the next connection learns it again with a v0 token
  public func forgetHubKey() {
    hubKeys.forget(url)
    sender?.ws.reconnect()
  }

  /// The refusal, waiting up to `timeout` seconds while disconnected for the hub to refuse the next attempt and for
  /// the reason. `nil` when connected, or when the connection is down for another reason.
  public func refusalReason(timeout: TimeInterval = 8) async -> Refusal? {
    let deadline = Date().addingTimeInterval(timeout)
    while refusal == nil, !isConnected || sender?.ws.refusal != nil, Date() < deadline, !Task.isCancelled {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    if let refusal { return refusal }
    return sender?.ws.refusal.map { .refused(statusCode: $0.statusCode) }
  }

  /// Reads `hub/info`. Without a pinned key, pins it and reconnects with a v1 token (and the device certificate).
  /// A different key than the pinned one is reported and never replaces it.
  /// - Returns: `false` when the connection is about to be replaced
  private func learnHubKey(_ sender: ChannelSender<Void>) async -> Bool {
    guard let info: HubInfo = try? await sender.send("hub/info") else { return true }
    self.info = info
    guard let pinned = hubKey else {
      hubKeys.pin(info.key, for: url)
      self.sender?.ws.reconnect()
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

@MainActor
final class DeviceReporter {
  let interval: TimeInterval
  let description: @MainActor () async -> DeviceDescription
  let data: @MainActor () async -> DeviceData
  private var task: Task<Void, Never>? {
    didSet { oldValue?.cancel() }
  }
  init(interval: TimeInterval, description: @escaping @MainActor () async -> DeviceDescription, data: @escaping @MainActor () async -> DeviceData) {
    self.interval = interval
    self.description = description
    self.data = data
  }
  func connected(_ client: HubClient) {
    task = Task { [weak client, interval, description, data] in
      guard let devices = client?.devices else { return }
      try? await devices.describe(description())
      while !Task.isCancelled, client?.isConnected == true {
        try? await devices.report(data())
        try? await Task.sleep(nanoseconds: UInt64(max(interval, 1) * 1_000_000_000))
      }
    }
  }
  func stop() {
    task = nil
  }
}

public enum HubClientStreamError: Error, Equatable, Sendable {
  case finishedWithoutValue(String)
}
