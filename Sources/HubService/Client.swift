//
//  File.swift
//  WebSocket
//
//  Created by Dmitry Kozlov on 17/2/25.
//

import Foundation
import Channel
import Observation

@MainActor
@Observable
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
  /// Hub keys pinned per address
  public let hubKeys: HubKeyPins
  /// The pinned key of this hub, proven over `hub/info` or supplied up front
  public var hubKey: String? { hubKeys.key(for: url) }
  /// The address the client is connected or connecting to: `url`, or one of `Options.alternateURLs`
  public var currentURL: URL { sender?.ws.currentURL ?? url }
  /// `nil` when the client connects without a device
  public let device: DeviceIdentity?
  /// How this client's connection travels: `.localNetwork` is plain `ws://` on the LAN, which a UI should say
  public var transport: HubTransport { HubTransport(url) }
  /// Set when the hub proved its key over `hub/info`
  public private(set) var info: HubInfo?
  /// The current connection finished its setup: the services are sent. Wait for this before calls that need the
  /// device-attached connection.
  public private(set) var isReady = false
  /// Called when the hub at this address proves another key than the pinned one
  @ObservationIgnored public var onHubKeyError: ((HubKeyError) -> Void)?
  /// Set while the hub refuses this client's connection, with the reason; cleared when a connection opens.
  /// Posts fail with Channel's `refused` error meanwhile, and the client tries again every 30 seconds.
  public private(set) var refusal: Refusal?
  /// Called when the hub refused the connection, once the reason is known
  @ObservationIgnored public var onRefused: ((Refusal) -> Void)?
  @ObservationIgnored private var sender: ClientSender<Void>!
  @ObservationIgnored private var reporter: DeviceReporter?
  /// Bumped by every connection attempt, so a handshake still waiting for an older one ends
  @ObservationIgnored private var handshake = 0
  /// Why this side refused to connect, when it did
  @ObservationIgnored private var ownRefusal: Refusal?
  /// One refused connect asks for a new challenge at once: it can be gone after a hub restart
  @ObservationIgnored private var retriedRefusal = false
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
    /// Other addresses of the same hub, tried in turn when the hub's address doesn't answer (see Channel's
    /// `ClientOptions.alternateURLs`). The hub key stays the one pinned for the hub's address, so another server
    /// answering there can't take the hub's place.
    public var alternateURLs: (@MainActor () async -> [URL])?
    /// Allows plain `ws://` beyond loopback, the overlay and the local network, for a private network
    public var allowPlaintext: Bool
    public init(hubKey: String? = nil, hubKeys: HubKeyPins? = nil, device: DeviceIdentity? = nil, instance: String? = nil, alternateURLs: (@MainActor () async -> [URL])? = nil, allowPlaintext: Bool = false) {
      self.hubKey = hubKey
      self.hubKeys = hubKeys
      self.device = device
      self.instance = instance
      self.alternateURLs = alternateURLs
      self.allowPlaintext = allowPlaintext
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
      // Callers are trusted only from the pinned hub, as in hub-service
      service.trustedHubKey = { [weak self] in self?.hubKey }
      let serviceKey = keyChain.publicKey()
      let issuer = device.map {
        CertificateIssuer(device: $0, service: serviceKey) { [weak self] in
          if let instance = options.instance { return instance }
          if let name = self?.profile.name, !name.isEmpty { return name }
          return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent
        }
      }
      service.network.configureIdentity(keyChain)
      let allowPlaintext = options.allowPlaintext
      @Sendable func allowed(_ url: URL) -> Bool { allowPlaintext || HubTransport(url) != .refused }
      var alternates: (@MainActor () async -> [URL])?
      if let urls = options.alternateURLs {
        alternates = { await urls().filter(allowed) }
      }
      let alternateURLs = alternates
      sender = channel.connect(url, options: ClientOptions(headers: { [weak self] in
        guard let self else { return [:] }
        guard allowed(url) else {
          refuseConnecting(.plaintextNotAllowed)
          return [:]
        }
        return await connectHeaders(keyChain, issuer: issuer, alternates: alternateURLs)
      }, onConnect: { [weak self] sender in
        guard let self else { return }
        await connectionOpened()
        try? await sender.send("hub/profile/update", profile)
        try await service.sendServiceUpdates(first: true)
        await setReady()
        await reporter?.connected(self)
        try await service.network.didConnect(sender)
      }, alternateURLs: alternateURLs))
    } else {
      sender = channel.connect(url, options: ClientOptions(alternateURLs: options.alternateURLs))
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
    /// This client doesn't connect: credentials would cross networks in the clear. The address needs `wss://`.
    case plaintextNotAllowed
    /// The hub is from before auth v2: it can't prove its key, so this client sends it nothing (no v0 fallback). The
    /// client looks again every 30 seconds, so it connects once the hub is updated.
    case hubNeedsUpdate

    public var description: String {
      switch self {
      case .keyRefused: "The hub refused this device: its key or the device was revoked, or the device clock is wrong."
      case .hubKeyChanged: "The hub's key changed since this device first connected, or another server answers at this address."
      case .hubNotAvailable: "The hub only accepts devices it already knows."
      case .refused(let statusCode): "The hub refused the connection (HTTP \(statusCode))."
      case .plaintextNotAllowed: "This address isn't encrypted and isn't on this network, so this device doesn't connect to it. Use a wss:// address."
      case .hubNeedsUpdate: HubClient.hubNeedsUpdateText
      }
    }
  }

  /// What `Refusal.hubNeedsUpdate` tells the user, with the ways a Hub is updated
  public nonisolated static let hubNeedsUpdateText = "This Hub needs an update: it can't prove who it is, so this device "
    + "sends it nothing. On the Hub's machine, run `hub update`, or choose Update All on the Launcher page of an older "
    + "Hub app. For Docker, run `docker pull v57dev/hub` and recreate the container."

  /// Headers for one connection attempt, after the hub proves its key. Waits while nothing answers with a proof, since
  /// the hub gets nothing before that; a reconnect or `stop()` ends the wait.
  private func connectHeaders(_ keyChain: KeyChain, issuer: CertificateIssuer?, alternates: (@MainActor () async -> [URL])?) async -> [String: String] {
    isReady = false
    handshake += 1
    let handshake = handshake
    var delay: UInt64 = 500_000_000
    while handshake == self.handshake, sender?.ws.isRunning != false, !Task.isCancelled {
      let pinned = hubKey
      let urls = await pinned == nil ? [url] : [url] + (alternates?() ?? [])
      switch await HubHandshake.ask(urls, pinned: pinned) {
      case .proven(let info, let challenge, let address):
        guard handshake == self.handshake else { return [:] }
        self.info = info
        // The token goes where the proof came from, not to an address that may not be the hub
        sender.ws.nextURL = address
        hubKeys.pin(info.key, for: url)
        return HubAuth.headers(keyChain, hubKey: info.key, nonce: challenge, certificate: issuer?.header())
      case .mismatch(let current):
        guard handshake == self.handshake, let pinned else { return [:] }
        refuseConnecting(.hubKeyChanged(pinned: pinned, current: current))
        onHubKeyError?(.mismatch(pinned: pinned, received: current))
        return [:]
      case .none:
        // A hub from before auth v2 answers without a proof: say so, and never fall back to v0
        if await HubHandshake.needsUpdate(url) {
          guard handshake == self.handshake else { return [:] }
          refuseConnecting(.hubNeedsUpdate)
          return [:]
        }
        try? await Task.sleep(nanoseconds: delay)
        delay = min(delay * 2, 5_000_000_000)
      }
    }
    return [:]
  }

  /// Like a refused upgrade: posts fail, and the client looks again every 30 seconds
  private func refuseConnecting(_ refusal: Refusal) {
    ownRefusal = refusal
    sender.ws.refuseConnecting(ConnectionRefusal(statusCode: 0))
  }

  private func refused(statusCode: Int) async {
    if let ownRefusal {
      self.ownRefusal = nil
      refusal = ownRefusal
      onRefused?(ownRefusal)
      return
    }
    guard retriedRefusal else {
      retriedRefusal = true
      sender.ws.reconnectNow()
      return
    }
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
    retriedRefusal = false
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

  /// Forgets the pinned key, so the next connection pins what the hub proves
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
  public func send<Body: Encodable, Output: Decodable>(_ path: String, _ body: Body?, timeout: TimeInterval) async throws -> Output {
    try await sender.send(path, body, options: SendOptions(timeout: timeout))
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
  /// Graceful shutdown of this client's service (`HubService.shutdown`), then disconnects. Returns true when every
  /// running call finished within `timeout` seconds.
  @discardableResult
  public func shutdown(timeout: TimeInterval = 10) async -> Bool {
    let finished = await service.shutdown(timeout: timeout)
    stop()
    return finished
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
