//
//  Caller.swift
//  HubService
//
//  Who is calling a service handler (Docs/Devices/protocol.md, section 4).
//

import Foundation
import Channel

/// The caller the hub attaches to every request it forwards, in `context.hub.caller`
public struct Caller: Codable, Hashable, Sendable {
  public struct Device: Codable, Hashable, Sendable {
    public var id: String
    public var name: String?
    public init(id: String, name: String? = nil) {
      self.id = id
      self.name = name
    }
  }
  /// Service SPKI, `nil` for anonymous callers
  public var key: String?
  /// Set when the caller's connection is attached to a device
  public var device: Device?
  /// Every group the key or its device belongs to
  public var groups: [String]
  public var owner: Bool
  /// Through a merged hub: that hub's key; `claimed` is its caller and isn't verified
  public var via: String?
  public var claimed: Claimed?
  public var isAnonymous: Bool { key == nil }
  public init(key: String? = nil, device: Device? = nil, groups: [String] = [], owner: Bool = false, via: String? = nil, claimed: Caller? = nil) {
    self.key = key
    self.device = device
    self.groups = groups
    self.owner = owner
    self.via = via
    self.claimed = claimed.map(Claimed.init)
  }
  enum CodingKeys: String, CodingKey {
    case key, device, groups, owner, via, claimed
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    key = try container.decodeIfPresent(String.self, forKey: .key)
    device = try? container.decodeIfPresent(Device.self, forKey: .device)
    groups = (try? container.decodeIfPresent([String].self, forKey: .groups)) ?? []
    owner = (try? container.decodeIfPresent(Bool.self, forKey: .owner)) ?? false
    via = try? container.decodeIfPresent(String.self, forKey: .via)
    claimed = try? container.decodeIfPresent(Claimed.self, forKey: .claimed)
  }
  /// Box for the recursive `claimed` caller
  public final class Claimed: Codable, Hashable, Sendable {
    public let caller: Caller
    init(_ caller: Caller) { self.caller = caller }
    public init(from decoder: any Decoder) throws {
      caller = try Caller(from: decoder)
    }
    public func encode(to encoder: any Encoder) throws {
      try caller.encode(to: encoder)
    }
    public static func == (lhs: Claimed, rhs: Claimed) -> Bool { lhs.caller == rhs.caller }
    public func hash(into hasher: inout Hasher) { hasher.combine(caller) }
  }
}

/// `context.hub` of a forwarded request
public struct HubRequestContext: Codable, Hashable, Sendable {
  public var caller: Caller?
  public var hubKey: String?
  public init(caller: Caller? = nil, hubKey: String? = nil) {
    self.caller = caller
    self.hubKey = hubKey
  }
}

/// The request a service handler is running for. Read it inside a `post` or `stream` handler:
///
/// ```swift
/// service.post("notes/delete") { (id: String) in
///   guard HubRequest.caller?.owner == true else { throw HubRequestError.permissionsRequired }
///   …
/// }
/// ```
public struct HubRequest: Sendable {
  public var path: String
  public var hub: HubRequestContext?
  public var caller: Caller? { hub?.caller }

  @TaskLocal public static var current: HubRequest?
  /// The caller of the request the current task handles. `nil` outside a handler, or when the hub didn't send one
  /// (older hubs)
  public static var caller: Caller? { current?.caller }

  init(path: String, body: AnyBody) {
    self.path = path
    hub = (try? body.context(Context?.self))?.hub
  }
  public init(path: String, hub: HubRequestContext?) {
    self.path = path
    self.hub = hub
  }
  private struct Context: Decodable {
    var hub: HubRequestContext?
    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      hub = try? container.decodeIfPresent(HubRequestContext.self, forKey: .hub)
    }
    enum CodingKeys: CodingKey { case hub }
  }
}

public enum HubRequestError: Error, Hashable, Sendable, CustomStringConvertible {
  case permissionsRequired
  public var description: String {
    switch self {
    case .permissionsRequired: "permissions required"
    }
  }
}
