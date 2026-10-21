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
  /// Decodes the body and the hub context on the main actor (the decoding container isn't thread-safe), then runs
  /// the handler with `HubRequest.current` set
  private func add<Input: Sendable>(path: String, options: Options?, decode: @escaping @Sendable @MainActor (AnyBody) throws -> Input, post: @escaping @Sendable (Input) async throws -> Encodable & Sendable) -> Self {
    if let options {
      self.options[path] = options
    }
    channel.postApi[path] = { body, path in
      let (request, input) = try await MainActor.run {
        (HubRequest(path: path, body: body.body), try decode(body.body))
      }
      return try await HubRequest.$current.withValue(request) {
        try await post(input)
      }
    }
    return self
  }
  private func add<Input: Sendable>(path: String, options: Options?, decode: @escaping @Sendable @MainActor (AnyBody) throws -> Input, stream: @escaping @Sendable (Input, AsyncThrowingStream<Encodable & Sendable, Error>.Continuation) async throws -> Void) -> Self {
    if let options {
      self.options[path] = options
    }
    channel.streamApi[path] = { body, path in
      AsyncThrowingStream { continuation in
        Task {
          do {
            let (request, input) = try await MainActor.run {
              (HubRequest(path: path, body: body.body), try decode(body.body))
            }
            try await HubRequest.$current.withValue(request) {
              try await stream(input, continuation)
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
      }
    }
    return self
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
    let update = HubService.Update(services: api.map { ServiceHeader(path: $0, options: options[$0]) }, apps: apps, reporter: isReporter ? true : nil)
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
    var isEmpty: Bool { services.isEmpty && apps.isEmpty && reporter == nil }
  }
  
  private enum ApiPath: Hashable {
    case stream(String)
    case post(String)
  }
  public struct Options: Hashable {
    public var limit: Int?
    public var permissions: Permissions?
    /// Callable by anyone when the hub denies by default
    public var isPublic: Bool
    public init(limit: Int? = nil, permissions: Permissions? = nil, isPublic: Bool = false) {
      self.limit = limit
      self.permissions = permissions
      self.isPublic = isPublic
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
