//
//  File.swift
//  HubService
//
//  Created by Linux on 19.07.25.
//

import Foundation
import Channel

@MainActor
public class HubService {
  let channel: Channel<Void>
  var sender: ClientSender<Void>?
  public let network = HubNetworkService()
  var apps = [AppHeader]()
  var api: [String] {
    Array(Set(channel.postApi.keys).union(channel.streamApi.keys))
  }
  var disabled = Set<String>()
  var groups = [Group]()
  /// Asks for the reporter role of this connection's device (`hub/device/describe`, `hub/device/data`).
  /// The hub gives it to the first connected service of a device that asks.
  public var isReporter = false {
    didSet {
      guard isReporter != oldValue else { return }
      sendServiceUpdates()
    }
  }
  private var options = [String: Options]()
  private var serviceUpdatesTask: Task<Void, Error>? {
    didSet { oldValue?.cancel() }
  }
  /// Hub groups whose members may act for end users: a gateway in one of them (or an owner) sets `context.user`, and
  /// handlers read it as `HubRequest.user`. From other callers `context.user` is ignored.
  public var delegates = [String]()
  /// Per-caller limit of every path without its own `Options.rateLimit`
  public var rateLimit: RateLimit?
  /// The pinned hub key: when set, a request's caller is trusted only when it names that hub. `HubClient` sets it.
  public var trustedHubKey: (@MainActor () -> String?)?
  /// False between `setReady(false)` and `setReady(true)`
  public private(set) var isReady = true
  public private(set) var isShuttingDown = false
  /// Takes calls: ready and not shutting down
  public var acceptsCalls: Bool { isReady && !isShuttingDown }
  /// Calls whose handlers are running
  public var runningCalls: Int { running.count }
  private var running = [Int: RunningCall]()
  private var nextCall = 0
  private var limiters = [String: RateLimiter]()
  public init(channel: Channel<Void>) {
    self.channel = channel
  }
  public func post<Input: Decodable & Sendable, Output: Encodable & Sendable>(_ path: String, options: Options? = nil, request: @escaping (@Sendable (Input) async throws -> Output)) -> Self {
    add(path: path, options: options, decode: { try $0.body() as Input }) { input in
      try await request(input)
    }
  }
  public func post<Input: Decodable & Sendable>(_ path: String, options: Options? = nil, request: @escaping (@Sendable (Input) async throws -> Void)) -> Self {
    add(path: path, options: options, decode: { try $0.body() as Input }) { input in
      try await request(input)
      return NoOutput()
    }
  }
  public func post<Output: Encodable & Sendable>(_ path: String, options: Options? = nil, request: @escaping (@Sendable () async throws -> Output)) -> Self {
    add(path: path, options: options, decode: { _ in }) {
      try await request()
    }
  }
  public func post(_ path: String, options: Options? = nil, request: @escaping (@Sendable () async throws -> Void)) -> Self {
    add(path: path, options: options, decode: { _ in }) {
      try await request()
      return NoOutput()
    }
  }
  public func stream<Input: Decodable & Sendable>(_ path: String, options: Options? = nil, request: @escaping @Sendable (Input, AsyncThrowingStream<Encodable & Sendable, Error>.Continuation) async throws -> Void) -> Self {
    add(path: path, options: options, decode: { try $0.body() as Input }) { input, continuation in
      try await request(input, continuation)
    }
  }
  public func stream(_ path: String, options: Options? = nil, request: @escaping @Sendable (AsyncThrowingStream<Encodable & Sendable, Error>.Continuation) async throws -> Void) -> Self {
    add(path: path, options: options, decode: { _ in }) { _, continuation in
      try await request(continuation)
    }
  }
  /// Checks the request on the main actor (the decoding container isn't thread-safe): readiness, `auth`, `groups` and
  /// the rate limit, then decodes the body. The handler runs with `HubRequest.current` set once the `permission` check
  /// passed; a body that doesn't decode or validate fails with `invalid_input`.
  private func add<Input: Sendable>(path: String, options: Options?, decode: @escaping @Sendable @MainActor (AnyBody) throws -> Input, post: @escaping @Sendable (Input) async throws -> Encodable & Sendable) -> Self {
    if let options {
      self.options[path] = options
    }
    let shutdown = options?.shutdown ?? .wait
    channel.postApi[path] = { [weak self] body, path in
      do {
        guard let self else { throw HubError.unavailable() }
        let (request, input) = try await MainActor.run {
          let request = try self.admit(path: path, body: body.body, options: options)
          return (request, Result { try decode(body.body) })
        }
        return try await self.track(shutdown) {
          try await HubRequest.$current.withValue(request) {
            try await post(Self.input(input, request: request, options: options))
          }
        }
      } catch {
        throw HubError.wire(error)
      }
    }
    return self
  }
  private func add<Input: Sendable>(path: String, options: Options?, decode: @escaping @Sendable @MainActor (AnyBody) throws -> Input, stream: @escaping @Sendable (Input, AsyncThrowingStream<Encodable & Sendable, Error>.Continuation) async throws -> Void) -> Self {
    if let options {
      self.options[path] = options
    }
    let shutdown = options?.shutdown ?? .end
    channel.streamApi[path] = { [weak self] body, path in
      let service = self
      return AsyncThrowingStream { continuation in
        let task = Task { @Sendable in
          var call: Int?
          do {
            guard let self = service else { throw HubError.unavailable() }
            let (request, input) = try await MainActor.run {
              let request = try self.admit(path: path, body: body.body, options: options)
              return (request, Result { try decode(body.body) })
            }
            // Ending a stream finishes it for the caller, which cancels this task
            call = await self.begin(shutdown) { continuation.finish() }
            try await HubRequest.$current.withValue(request) {
              try await stream(Self.input(input, request: request, options: options), continuation)
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: HubError.wire(error))
          }
          if let call { await service?.end(call) }
        }
        // A caller that cancels or leaves cancels the handler, also while it waits between values
        continuation.onTermination = { _ in task.cancel() }
      }
    }
    return self
  }
  /// A request for `path` that passed readiness, `auth`, `groups` and the rate limit
  private func admit(path: String, body: AnyBody, options: Options?) throws -> HubRequest {
    guard acceptsCalls else { throw HubError.unavailable() }
    var request = HubRequest(path: path, body: body)
    if let trustedHubKey {
      let pinned = trustedHubKey()
      if pinned == nil || request.hub?.hubKey != pinned { request.hub = nil }
    }
    if let user = request.claimedUser, let caller = request.caller, caller.key != nil,
      caller.owner || delegates.contains(where: caller.groups.contains)
    {
      request.user = user
    }
    request.grants = GrantAnswers { [weak self] permission, caller in
      guard let self else { throw HubError.unavailable("not connected to a hub") }
      return try await self.checkGrant(permission, caller)
    }
    try request.require(options?.auth, groups: options?.groups ?? [])
    if let limit = options?.rateLimit ?? rateLimit, limit.limit > 0 {
      let bucket = limit.bucket ?? path
      let limiter = limiters[bucket].flatMap { $0.options == limit ? $0 : nil } ?? RateLimiter(limit)
      limiters[bucket] = limiter
      try limiter.take(request.rateLimitKey)
    }
    return request
  }
  /// The handler's input once `permission` passed; decoding and `Validatable` failures are `invalid_input`
  private nonisolated static func input<Input>(_ decoded: Result<Input, Error>, request: HubRequest, options: Options?) async throws -> Input {
    if let permission = options?.permission { try await request.requirePermission(permission) }
    let input: Input
    do {
      input = try decoded.get()
    } catch {
      throw HubError.invalidInput()
    }
    if let validatable = input as? Validatable {
      do {
        try validatable.validate()
      } catch let error as HubError {
        throw error
      } catch {
        throw HubError.invalidInput("\(error)")
      }
    }
    return input
  }
  /// Runs a post as its own task, kept in `running` so `shutdown` can wait for it or cancel it
  private nonisolated func track<T: Sendable>(_ shutdown: ShutdownMode, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let task = Task { try await work() }
    let call = await begin(shutdown) { task.cancel() }
    do {
      let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
      await end(call)
      return value
    } catch {
      await end(call)
      throw error
    }
  }
  private func begin(_ shutdown: ShutdownMode, end: @escaping @Sendable () -> Void) -> Int {
    nextCall += 1
    running[nextCall] = RunningCall(shutdown: shutdown, end: end)
    return nextCall
  }
  private func end(_ call: Int) {
    running[call] = nil
  }
  /// Asks the hub whether `permission` is granted to `caller` (`hub/grant/check`)
  private func checkGrant(_ permission: String, _ caller: Caller) async throws -> Bool {
    guard let sender else { throw HubError.unavailable("not connected to a hub") }
    let answer: GrantAnswer = try await sender.send("hub/grant/check", GrantCheck(path: permission, caller: GrantCheck.Subject(caller)))
    return answer.allowed
  }

  /// Whether the hub may route new calls here. While not ready, the paths stay registered but the hub sends their
  /// calls to other providers or keeps them waiting (`hub/service/update { draining: true }`), and calls that still
  /// arrive fail with `unavailable`. Running calls go on.
  public func setReady(_ ready: Bool) async {
    guard isReady != ready else { return }
    isReady = ready
    await sendDraining()
  }
  /// Graceful shutdown: tells the hub to send no more calls, ends running streams (paths with `shutdown: .end`, the
  /// default for streams), waits up to `timeout` seconds for the other running calls, cancels what is left and
  /// disconnects. Returns true when every call finished in time.
  @discardableResult
  public func shutdown(timeout: TimeInterval = 10) async -> Bool {
    isShuttingDown = true
    await sendDraining()
    for call in running.values where call.shutdown == .end { call.end() }
    let deadline = Date().addingTimeInterval(timeout)
    while !running.isEmpty, Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    let finished = running.isEmpty
    for call in running.values { call.end() }
    // The last calls' responses go out before the connection closes
    try? await Task.sleep(nanoseconds: 50_000_000)
    sender?.stop()
    return finished
  }
  /// What a supervisor or health check needs to know
  public var health: Health {
    let connected = sender?.ws.isConnected == true
    let status: Health.Status = isShuttingDown ? .shuttingDown : !connected ? .disconnected : isReady ? .ready : .notReady
    return Health(status: status, connected: connected, ready: isReady, running: running.count)
  }
  public struct Health: Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
      case ready, notReady, shuttingDown, disconnected
    }
    public var status: Status
    public var connected: Bool
    public var ready: Bool
    /// Calls whose handlers are running
    public var running: Int
  }
  private func sendDraining() async {
    guard let sender, sender.ws.isConnected else { return }
    let _: EmptyCodable? = try? await sender.send("hub/service/update", Draining(draining: !acceptsCalls), options: SendOptions<EmptyCodable>(timeout: 2))
  }
  public func sendServiceUpdates() {
    guard sender?.ws.isConnected == true else { return }
    serviceUpdatesTask = Task {
      try await Task.sleep(nanoseconds: 100_000_000)
      try await sendServiceUpdates(first: false)
    }
  }
  func sendServiceUpdates(first: Bool) async throws {
    guard let sender else { return }
    var api = Set(channel.postApi.keys).union(channel.streamApi.keys)
    var disabledApps = Set<String>()
    groups.forEach { group in
      if !group.isEnabled {
        api.subtract(group.apis)
        disabledApps.formUnion(group.apps)
      }
    }
    let apps = apps.filter { !disabledApps.contains($0.path) }
    // A service that isn't ready registers its paths without taking calls
    let update = HubService.Update(services: api.map { ServiceHeader(path: $0, options: options[$0]) }, apps: apps, reporter: isReporter ? true : nil,
      draining: acceptsCalls ? nil : true)
    if !first || !update.isEmpty {
      try await sender.send("hub/service/update", update)
    }
  }
  public func group(enabled: Bool) -> Group {
    let group = Group(service: self, isEnabled: enabled)
    groups.append(group)
    return group
  }
  struct Update: Encodable {
    var services: [ServiceHeader]
    var apps: [AppHeader]
    var reporter: Bool?
    var draining: Bool?
    var isEmpty: Bool { services.isEmpty && apps.isEmpty && reporter == nil && draining == nil }
  }
  struct Draining: Encodable, Sendable {
    var draining: Bool
  }
  struct GrantCheck: Encodable, Sendable {
    var path: String
    var caller: Subject
    struct Subject: Encodable, Sendable {
      var key: String?
      var device: Device?
      var via: String?
      struct Device: Encodable, Sendable { var id: String }
      init(_ caller: Caller) {
        key = caller.key
        device = caller.device.map { Device(id: $0.id) }
        via = caller.via
      }
    }
  }
  struct GrantAnswer: Decodable, Sendable {
    var allowed: Bool
  }
  /// What `shutdown` does with a running call: wait for it (posts' default) or end it at once (streams' default)
  public enum ShutdownMode: Hashable, Sendable {
    case wait, end
  }
  struct RunningCall {
    let shutdown: ShutdownMode
    /// Cancels a post's task, finishes a stream for its caller
    let end: @Sendable () -> Void
  }
  
  private enum ApiPath: Hashable {
    case stream(String)
    case post(String)
  }
  public struct Options: Hashable, Sendable {
    /// Calls the hub runs at once on this provider
    public var limit: Int?
    public var permissions: Permissions?
    /// Callable by anyone when the hub denies by default
    public var isPublic: Bool
    /// Who may call, checked before the handler
    public var auth: Auth?
    /// The caller must be in one of these hub groups (owners pass)
    public var groups: [String]
    /// A permission an owner grants on the hub (`hub/grant/check`), under the first segment of a path this service
    /// registers (`posts/moderate` for a service of `posts/*`); owners pass
    public var permission: String?
    /// Per-caller limit (`HubService.rateLimit` by default); a limit of 0 turns it off
    public var rateLimit: RateLimit?
    /// What `shutdown` does with a running call; `.wait` for posts and `.end` for streams by default
    public var shutdown: ShutdownMode?
    public init(limit: Int? = nil, permissions: Permissions? = nil, isPublic: Bool = false, auth: Auth? = nil, groups: [String] = [],
      permission: String? = nil, rateLimit: RateLimit? = nil, shutdown: ShutdownMode? = nil)
    {
      self.limit = limit
      self.permissions = permissions
      self.isPublic = isPublic
      self.auth = auth
      self.groups = groups
      self.permission = permission
      self.rateLimit = rateLimit
      self.shutdown = shutdown
    }
  }
  public struct Permissions: Hashable, Encodable, Sendable {
    public let group: String
    public let name: String
    public init(group: String, name: String) { self.group = group; self.name = name }
  }
  
  @MainActor
  public class Group {
    private weak var service: HubService?
    @MainActor
    public var isEnabled: Bool {
      didSet {
        guard isEnabled != oldValue else { return }
        service?.sendServiceUpdates()
      }
    }
    fileprivate var apis = Set<String>()
    fileprivate var apps = Set<String>()
    init(service: HubService, isEnabled: Bool) {
      self.service = service
      self.isEnabled = isEnabled
    }
    private func append(_ path: String) -> Self {
      self.apis.insert(path)
      return self
    }
    public func post<Input: Decodable & Sendable, Output: Encodable & Sendable>(_ path: String, options: Options? = nil, request: @escaping (@Sendable (Input) async throws -> Output)) -> Self {
      _ = service?.post(path, options: options, request: request)
      return append(path)
    }
    public func post<Input: Decodable & Sendable>(_ path: String, options: Options? = nil, request: @escaping (@Sendable (Input) async throws -> Void)) -> Self {
      _ = service?.post(path, options: options, request: request)
      return append(path)
    }
    public func post<Output: Encodable & Sendable>(_ path: String, options: Options? = nil, request: @escaping (@Sendable () async throws -> Output)) -> Self {
      _ = service?.post(path, options: options, request: request)
      return append(path)
    }
    public func post(_ path: String, options: Options? = nil, request: @escaping (@Sendable () async throws -> Void)) -> Self {
      _ = service?.post(path, options: options, request: request)
      return append(path)
    }
    public func stream<Input: Decodable & Sendable>(_ path: String, options: Options? = nil, request: @escaping @Sendable (Input, AsyncThrowingStream<Encodable & Sendable, Error>.Continuation) async throws -> Void) -> Self {
      _ = service?.stream(path, options: options, request: request)
      return append(path)
    }
    public func stream(_ path: String, options: Options? = nil, request: @escaping @Sendable (AsyncThrowingStream<Encodable & Sendable, Error>.Continuation) async throws -> Void) -> Self {
      _ = service?.stream(path, options: options, request: request)
      return append(path)
    }
    public func app(_ app: App) -> Self {
      _ = service?.app(app)
      apis.insert(app.header.path)
      apps.insert(app.header.path)
      return self
    }
    private struct Api {
      let type: ApiType
      let path: String
    }
    private enum ApiType {
      case post, stream, app
    }
  }
}

struct ServiceHeader: Encodable, Sendable {
  let path: String
  let limit: Int?
  let permissions: HubService.Permissions?
  let `public`: Bool?
  init(path: String, options: HubService.Options?) {
    self.path = path
    self.limit = options?.limit
    self.permissions = options?.permissions
    self.public = options?.isPublic == true ? true : nil
  }
}

/// Result of handlers that return nothing, encoded like Channel's `EmptyCodable`
private struct NoOutput: Encodable, Sendable { }
