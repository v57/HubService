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
  var apps = [AppHeader]()
  var api: [String] {
    Array(Set(channel.postApi.keys).union(channel.streamApi.keys))
  }
  var disabled = Set<String>()
  var groups = [Group]()
  private var serviceUpdatesTask: Task<Void, Error>? {
    didSet { oldValue?.cancel() }
  }
  public init(channel: Channel<Void>) {
    self.channel = channel
  }
  public func post<Input: Decodable & Sendable, Output: Encodable & Sendable>(_ path: String, request: @escaping (@Sendable (Input) async throws -> Output)) -> Self {
    _ = channel.post(path, request: request)
    return self
  }
  public func post<Input: Decodable & Sendable>(_ path: String, request: @escaping (@Sendable (Input) async throws -> Void)) -> Self {
    _ = channel.post(path, request: request)
    return self
  }
  public func post<Output: Encodable & Sendable>(_ path: String, request: @escaping (@Sendable () async throws -> Output)) -> Self {
    _ = channel.post(path, request: request)
    return self
  }
  public func post(_ path: String, request: @escaping (@Sendable () async throws -> Void)) -> Self {
    _ = channel.post(path, request: request)
    return self
  }
  public func stream<Input: Decodable & Sendable>(_ path: String, request: @escaping @Sendable (Input, AsyncThrowingStream<Encodable & Sendable, Error>.Continuation) async throws -> Void) -> Self {
    _ = channel.stream(path, request: request)
    return self
  }
  public func stream(_ path: String, request: @escaping @Sendable (AsyncThrowingStream<Encodable & Sendable, Error>.Continuation) async throws -> Void) -> Self {
    _ = channel.stream(path, request: request)
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
    let update = HubService.Update(services: api.map { ServiceHeader(path: $0) }, apps: apps)
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
    var isEmpty: Bool { services.isEmpty && apps.isEmpty }
  }
  
  @MainActor
  public class Group {
    private weak var service: HubService?
    @MainActor
    @Published public var isEnabled: Bool {
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
    public func post<Input: Decodable & Sendable, Output: Encodable & Sendable>(_ path: String, request: @escaping (@Sendable (Input) async throws -> Output)) -> Self {
      _ = service?.post(path, request: request)
      return append(path)
    }
    public func post<Input: Decodable & Sendable>(_ path: String, request: @escaping (@Sendable (Input) async throws -> Void)) -> Self {
      _ = service?.post(path, request: request)
      return append(path)
    }
    public func post<Output: Encodable & Sendable>(_ path: String, request: @escaping (@Sendable () async throws -> Output)) -> Self {
      _ = service?.post(path, request: request)
      return append(path)
    }
    public func post(_ path: String, request: @escaping (@Sendable () async throws -> Void)) -> Self {
      _ = service?.post(path, request: request)
      return append(path)
    }
    public func stream<Input: Decodable & Sendable>(_ path: String, request: @escaping @Sendable (Input, AsyncThrowingStream<Encodable & Sendable, Error>.Continuation) async throws -> Void) -> Self {
      _ = service?.stream(path, request: request)
      return append(path)
    }
    public func stream(_ path: String, request: @escaping @Sendable (AsyncThrowingStream<Encodable & Sendable, Error>.Continuation) async throws -> Void) -> Self {
      _ = service?.stream(path, request: request)
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

public struct AppHeader: Identifiable, Hashable, Codable, Sendable {
  public var id: String { path }
  public let type: AppType
  public let name: String
  public let path: String
  public var services: Int?
  public var isOnline: Bool { (services ?? 1) != 0 }
  public enum AppType: String, Codable, Sendable {
    case app
  }
  public init(type: AppType, name: String, path: String) {
    self.type = type
    self.name = name
    self.path = path
  }
}

struct ServiceHeader: Encodable, Sendable {
  let path: String
  init(path: String) {
    self.path = path
  }
}
