//
//  Requirements.swift
//  HubService
//
//  Who may call a path, errors with codes, per-caller rate limits and input validation
//  (hub-service docs/service-features.md).
//

import Foundation
import Channel

/// An error with a code. Thrown from a handler, the caller gets a `ChannelError` with the same message and code (the
/// hub passes them through). Other errors reach the caller as `internal error`.
///
/// ```swift
/// throw HubError.notFound("post not found")
/// throw HubError("payment required", code: 402)
/// ```
public struct HubError: Error, Hashable, Sendable, CustomStringConvertible {
  public var message: String
  public var code: ChannelError.Code?
  public init(_ message: String, code: ChannelError.Code? = nil) {
    self.message = message
    self.code = code
  }
  public var description: String { message }
  public var channelError: ChannelError { ChannelError(text: message, code: code) }

  /// No caller identity where one is needed: anonymous, or no caller from the hub
  public static func unauthorized(_ message: String = "unauthorized") -> HubError { HubError(message, code: "unauthorized") }
  /// The caller is known but may not do this. The message is the hub's own `permissions required`.
  public static func forbidden(_ message: String = "permissions required") -> HubError { HubError(message, code: "forbidden") }
  /// The body didn't decode or failed `Validatable.validate()`
  public static func invalidInput(_ message: String = "invalid input") -> HubError { HubError(message, code: "invalid_input") }
  public static func notFound(_ message: String = "not found") -> HubError { HubError(message, code: "not_found") }
  public static func conflict(_ message: String = "conflict") -> HubError { HubError(message, code: "conflict") }
  /// Too many calls. Swift services can't send `info` yet, so `retryAfter` is in the message only.
  public static func rateLimited(retryAfter: Int) -> HubError { HubError("rate limited, retry after \(retryAfter) s", code: "rate_limited") }
  /// The service isn't ready or is shutting down
  public static func unavailable(_ message: String = "service unavailable") -> HubError { HubError(message, code: "unavailable") }

  /// What a handler's error becomes on the wire
  static func wire(_ error: Error) -> Error {
    switch error {
    case let error as HubError: error.channelError
    case let error as HubRequestError: error.hubError.channelError
    default: error
    }
  }
}

extension ChannelError {
  /// The code as text: `"forbidden"`, `"404"`
  public var codeText: String? {
    switch code {
    case .string(let value): value
    case .int(let value): String(value)
    case nil: nil
    }
  }
}

/// Who may call a path, checked before the handler runs (`HubService.Options.auth`)
public enum Auth: String, Hashable, Sendable {
  /// A keyed caller, not anonymous
  case key
  /// A caller on an approved device of the hub
  case device
  /// A member of the hub's owners group
  case owner
  /// An end user a trusted gateway acts for (`HubRequest.user`, see `HubService.delegates`)
  case user
}

/// An end user a gateway acts for. The gateway sets `context.user` to an id or `{ "id": ..., "name": ... }`.
public struct DelegatedUser: Codable, Hashable, Sendable {
  public var id: String
  public var name: String?
  public init(id: String, name: String? = nil) {
    self.id = id
    self.name = name
  }
  public init(from decoder: any Decoder) throws {
    if let id = try? decoder.singleValueContainer().decode(String.self) {
      self.id = id
      name = nil
    } else {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(String.self, forKey: .id)
      name = try? container.decodeIfPresent(String.self, forKey: .name)
    }
    guard !id.isEmpty else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "empty user id")) }
  }
}

/// `limit` calls per `window` seconds for each caller: the delegated user, else the key, else the device, else every
/// anonymous caller together. Paths with the same `bucket` share their counts; each path has its own by default.
public struct RateLimit: Hashable, Sendable {
  /// No limit, also for a path when the service has a default one
  public static let off = RateLimit(limit: 0, window: 0)
  public var limit: Int
  public var window: TimeInterval
  public var bucket: String?
  public init(limit: Int, window: TimeInterval, bucket: String? = nil) {
    self.limit = limit
    self.window = window
    self.bucket = bucket
  }
}

/// A body type that checks itself after decoding; a thrown error becomes `invalid_input` (a `HubError` passes as it is)
public protocol Validatable {
  func validate() throws
}

extension HubRequest {
  /// A keyed caller. Throws `unauthorized` for anonymous callers and when the hub sent no caller.
  @discardableResult
  public func requireKey() throws -> Caller {
    guard let caller, caller.key != nil else { throw HubError.unauthorized() }
    return caller
  }
  /// A caller on an approved device of the hub
  @discardableResult
  public func requireDevice() throws -> Caller {
    let caller = try requireKey()
    guard caller.device != nil else { throw HubError.forbidden("device required") }
    return caller
  }
  /// An owner of the hub
  @discardableResult
  public func requireOwner() throws -> Caller {
    let caller = try requireKey()
    guard caller.owner else { throw HubError.forbidden() }
    return caller
  }
  /// A member of one of `groups`, or an owner
  @discardableResult
  public func requireGroup(_ groups: String...) throws -> Caller {
    try requireGroup(in: groups)
  }
  @discardableResult
  public func requireGroup(in groups: [String]) throws -> Caller {
    let caller = try requireKey()
    guard caller.owner || groups.contains(where: caller.groups.contains) else { throw HubError.forbidden() }
    return caller
  }
  /// The end user a trusted gateway acts for
  @discardableResult
  public func requireUser() throws -> DelegatedUser {
    guard let user else { throw HubError.unauthorized("user required") }
    return user
  }
  /// Checks `auth` and `groups`
  public func require(_ auth: Auth?, groups: [String] = []) throws {
    switch auth {
    case .key: try requireKey()
    case .device: try requireDevice()
    case .owner: try requireOwner()
    case .user: try requireUser()
    case nil: break
    }
    if !groups.isEmpty { try requireGroup(in: groups) }
  }
  /// Whether an owner granted `permission` to the caller (`hub/grant/check`); owners always have it, anonymous callers
  /// never. The answer is kept for the rest of this request.
  public func can(_ permission: String) async throws -> Bool {
    guard let caller, caller.key != nil else { return false }
    if caller.owner { return true }
    guard let grants else { throw HubError.unavailable("not connected to a hub") }
    return try await grants.answer(permission, caller)
  }
  /// Throws `unauthorized` or `forbidden` unless the caller has `permission`
  public func requirePermission(_ permission: String) async throws {
    try requireKey()
    guard try await can(permission) else { throw HubError.forbidden() }
  }
}

/// `hub/grant/check` answers of one request
final class GrantAnswers: @unchecked Sendable {
  private let lock = NSLock()
  private var answers = [String: Bool]()
  private let check: @Sendable (String, Caller) async throws -> Bool
  init(check: @escaping @Sendable (String, Caller) async throws -> Bool) {
    self.check = check
  }
  func answer(_ permission: String, _ caller: Caller) async throws -> Bool {
    if let known = lock.withLock({ answers[permission] }) { return known }
    let allowed = try await check(permission, caller)
    lock.withLock { answers[permission] = allowed }
    return allowed
  }
}

/// Counts calls per key in memory, a sliding window of accepted calls
@MainActor
final class RateLimiter {
  let options: RateLimit
  private var calls = [String: [Date]]()
  private var swept = Date()
  init(_ options: RateLimit) {
    self.options = options
  }
  /// Throws `rate_limited` when the key is over its limit
  func take(_ key: String, now: Date = Date()) throws {
    let start = now.addingTimeInterval(-options.window)
    if now.timeIntervalSince(swept) > options.window {
      swept = now
      calls = calls.filter { $0.value.last.map { $0 > start } ?? false }
    }
    var times = calls[key, default: []].filter { $0 > start }
    if times.count >= options.limit, let oldest = times.first {
      calls[key] = times
      throw HubError.rateLimited(retryAfter: max(1, Int(ceil(oldest.addingTimeInterval(options.window).timeIntervalSince(now)))))
    }
    times.append(now)
    calls[key] = times
  }
}

extension HubRequest {
  /// Whom a rate limit counts: the delegated user, else the key, else the device, else every anonymous caller
  var rateLimitKey: String {
    if let user { return "user:\(user.id)" }
    if let key = caller?.key { return "key:\(key)" }
    if let device = caller?.device { return "device:\(device.id)" }
    return "anonymous"
  }
}
