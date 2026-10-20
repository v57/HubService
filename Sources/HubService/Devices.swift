//
//  Devices.swift
//  HubService
//
//  Devices API and the reporter role (Docs/Devices/protocol.md, sections 6 and 7).
//

import Foundation
import Channel

public struct Device: Codable, Hashable, Identifiable, Sendable {
  public struct Service: Codable, Hashable, Identifiable, Sendable {
    public var id: String { key }
    public var key: String
    public var instance: String
    public var name: String?
    public var online: Bool
    public var paths: [String]
  }
  public enum NetworkState: String, Codable, Hashable, Sendable {
    case online, offline
  }
  public var id: String
  public var key: String
  public var name: String
  public var platform: String?
  public var os: String?
  public var arch: String?
  public var parent: String?
  public var approved: Bool
  public var revoked: Bool
  public var online: Bool
  public var network: NetworkState?
  public var lastSeen: Date?
  public var capabilities: Capabilities?
  public var services: [Service]

  enum CodingKeys: String, CodingKey {
    case id, key, name, platform, os, arch, parent, approved, revoked, online, network, lastSeen, capabilities, services
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    key = try container.decode(String.self, forKey: .key)
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
    platform = try container.decodeIfPresent(String.self, forKey: .platform)
    os = try container.decodeIfPresent(String.self, forKey: .os)
    arch = try container.decodeIfPresent(String.self, forKey: .arch)
    parent = try container.decodeIfPresent(String.self, forKey: .parent)
    approved = try container.decodeIfPresent(Bool.self, forKey: .approved) ?? false
    revoked = try container.decodeIfPresent(Bool.self, forKey: .revoked) ?? false
    online = try container.decodeIfPresent(Bool.self, forKey: .online) ?? false
    network = try? container.decodeIfPresent(NetworkState.self, forKey: .network)
    lastSeen = (try? container.decodeIfPresent(String.self, forKey: .lastSeen)).flatMap(Self.date)
    capabilities = try? container.decodeIfPresent(Capabilities.self, forKey: .capabilities)
    services = (try? container.decodeIfPresent([Service].self, forKey: .services)) ?? []
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(key, forKey: .key)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(platform, forKey: .platform)
    try container.encodeIfPresent(os, forKey: .os)
    try container.encodeIfPresent(arch, forKey: .arch)
    try container.encodeIfPresent(parent, forKey: .parent)
    try container.encode(approved, forKey: .approved)
    try container.encode(revoked, forKey: .revoked)
    try container.encode(online, forKey: .online)
    try container.encodeIfPresent(network, forKey: .network)
    try container.encodeIfPresent(lastSeen.map(ISO8601DateFormatter.hubNetworkDateString), forKey: .lastSeen)
    try container.encodeIfPresent(capabilities, forKey: .capabilities)
    try container.encode(services, forKey: .services)
  }
  static func date(_ value: String) -> Date? {
    ISO8601DateFormatter.hubNetworkDate(from: value)
  }
}

public struct PendingDevice: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var key: String
  public var name: String?
  public var platform: String?
  public var parent: String?
  /// `ddd ddd`, shown on both devices; compare before approving
  public var safetyCode: String
  public var firstSeen: String?
  public var firstSeenDate: Date? { firstSeen.flatMap(Device.date) }
}

/// Claims a device makes about itself. They steer placement and UI and never grant access.
public struct Capabilities: Codable, Hashable, Sendable {
  public struct CPU: Codable, Hashable, Sendable {
    public var cores: Int?
    public var model: String?
    public init(cores: Int? = nil, model: String? = nil) {
      self.cores = cores
      self.model = model
    }
  }
  public struct Disk: Codable, Hashable, Sendable {
    public var name: String
    public var total: Int64?
    public var free: Int64?
    public init(name: String, total: Int64? = nil, free: Int64? = nil) {
      self.name = name
      self.total = total
      self.free = free
    }
  }
  public enum Power: String, Codable, Hashable, Sendable {
    case ac, battery
  }
  public struct Tools: Codable, Hashable, Sendable {
    public var xcode: String?
    public var swift: String?
    public var simulators: [String]?
    public var adb: Bool?
    public var docker: Bool?
    public init(xcode: String? = nil, swift: String? = nil, simulators: [String]? = nil, adb: Bool? = nil, docker: Bool? = nil) {
      self.xcode = xcode
      self.swift = swift
      self.simulators = simulators
      self.adb = adb
      self.docker = docker
    }
  }
  public struct SSH: Codable, Hashable, Sendable {
    public var port: Int
    public var user: String?
    /// OpenSSH public key line
    public var hostKey: String
    /// Device signature over `ssh1:<hostKey>`
    public var hostKeySignature: String
    public init(port: Int, user: String? = nil, hostKey: String, device: DeviceKey) {
      self.port = port
      self.user = user
      self.hostKey = hostKey
      hostKeySignature = device.keyChain.sign(text: "ssh1:\(hostKey)")
    }
  }
  public var cpu: CPU?
  public var memory: Int64?
  public var gpu: String?
  public var disks: [Disk]?
  public var power: Power?
  public var tools: Tools?
  public var ssh: SSH?
  /// The app reporting the device, e.g. `{ "model": "iPhone17,1" }`; free-form keys of the protocol
  public var model: String?
  public init(cpu: CPU? = nil, memory: Int64? = nil, gpu: String? = nil, disks: [Disk]? = nil, power: Power? = nil, tools: Tools? = nil, ssh: SSH? = nil, model: String? = nil) {
    self.cpu = cpu
    self.memory = memory
    self.gpu = gpu
    self.disks = disks
    self.power = power
    self.tools = tools
    self.ssh = ssh
    self.model = model
  }
  enum CodingKeys: String, CodingKey {
    case cpu, memory, gpu, disks, power, tools, ssh, model
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    cpu = try? container.decodeIfPresent(CPU.self, forKey: .cpu)
    memory = try? container.decodeIfPresent(Int64.self, forKey: .memory)
    gpu = try? container.decodeIfPresent(String.self, forKey: .gpu)
    disks = try? container.decodeIfPresent([Disk].self, forKey: .disks)
    power = try? container.decodeIfPresent(Power.self, forKey: .power)
    tools = try? container.decodeIfPresent(Tools.self, forKey: .tools)
    ssh = try? container.decodeIfPresent(SSH.self, forKey: .ssh)
    model = try? container.decodeIfPresent(String.self, forKey: .model)
  }
}

/// `hub/device/describe`
public struct DeviceDescription: Codable, Hashable, Sendable {
  public var name: String?
  public var os: String?
  public var arch: String?
  public var capabilities: Capabilities?
  public init(name: String? = nil, os: String? = nil, arch: String? = nil, capabilities: Capabilities? = nil) {
    self.name = name
    self.os = os
    self.arch = arch
    self.capabilities = capabilities
  }
}

/// Live device data (`hub/device/data`). The known keys are typed; the hub accepts any others.
public struct DeviceData: Codable, Hashable, Sendable {
  public enum Network: String, Codable, Hashable, Sendable {
    case wifi, cellular, ethernet, other
  }
  /// 0–1
  public var cpu: Double?
  public var memoryUsed: Int64?
  /// 0–1
  public var battery: Double?
  public var charging: Bool?
  public var network: Network?
  /// `nominal`, `fair`, `serious`, `critical`
  public var thermal: String?
  /// Free bytes on the main volume
  public var storageFree: Int64?
  public var storageTotal: Int64?
  public init(cpu: Double? = nil, memoryUsed: Int64? = nil, battery: Double? = nil, charging: Bool? = nil, network: Network? = nil, thermal: String? = nil, storageFree: Int64? = nil, storageTotal: Int64? = nil) {
    self.cpu = cpu
    self.memoryUsed = memoryUsed
    self.battery = battery
    self.charging = charging
    self.network = network
    self.thermal = thermal
    self.storageFree = storageFree
    self.storageTotal = storageTotal
  }
  enum CodingKeys: String, CodingKey {
    case cpu, memoryUsed, battery, charging, network, thermal, storageFree, storageTotal
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    cpu = try? container.decodeIfPresent(Double.self, forKey: .cpu)
    memoryUsed = try? container.decodeIfPresent(Int64.self, forKey: .memoryUsed)
    battery = try? container.decodeIfPresent(Double.self, forKey: .battery)
    charging = try? container.decodeIfPresent(Bool.self, forKey: .charging)
    network = try? container.decodeIfPresent(Network.self, forKey: .network)
    thermal = try? container.decodeIfPresent(String.self, forKey: .thermal)
    storageFree = try? container.decodeIfPresent(Int64.self, forKey: .storageFree)
    storageTotal = try? container.decodeIfPresent(Int64.self, forKey: .storageTotal)
  }
}

public struct SecurityMode: Codable, Hashable, Sendable {
  public enum Mode: String, Codable, Hashable, Sendable {
    case defaultAllow = "default-allow"
    case defaultDeny = "default-deny"
  }
  public var mode: Mode
  public var requireV1: Bool
  public init(mode: Mode, requireV1: Bool = false) {
    self.mode = mode
    self.requireV1 = requireV1
  }
}

public struct Grant: Codable, Hashable, Identifiable, Sendable {
  public enum Subject: Codable, Hashable, Sendable {
    case key(String)
    case device(String)
    case group(String)
    case everyone
    enum CodingKeys: String, CodingKey { case key, device, group, everyone }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      if let key = try container.decodeIfPresent(String.self, forKey: .key) {
        self = .key(key)
      } else if let device = try container.decodeIfPresent(String.self, forKey: .device) {
        self = .device(device)
      } else if let group = try container.decodeIfPresent(String.self, forKey: .group) {
        self = .group(group)
      } else if try container.decodeIfPresent(Bool.self, forKey: .everyone) == true {
        self = .everyone
      } else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown grant subject"))
      }
    }
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .key(let key): try container.encode(key, forKey: .key)
      case .device(let device): try container.encode(device, forKey: .device)
      case .group(let group): try container.encode(group, forKey: .group)
      case .everyone: try container.encode(true, forKey: .everyone)
      }
    }
  }
  public enum Object: Codable, Hashable, Sendable {
    case path(String)
    case prefix(String)
    /// A Hub Network resource id
    case share(String)
    enum CodingKeys: String, CodingKey { case path, prefix, share }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      if let path = try container.decodeIfPresent(String.self, forKey: .path) {
        self = .path(path)
      } else if let prefix = try container.decodeIfPresent(String.self, forKey: .prefix) {
        self = .prefix(prefix)
      } else if let share = try container.decodeIfPresent(String.self, forKey: .share) {
        self = .share(share)
      } else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown grant object"))
      }
    }
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .path(let path): try container.encode(path, forKey: .path)
      case .prefix(let prefix): try container.encode(prefix, forKey: .prefix)
      case .share(let share): try container.encode(share, forKey: .share)
      }
    }
  }
  public var id: String
  public var subject: Subject
  public var object: Object
  public var by: String?
  public var at: String?
}

/// `hub/api/services`: a provider of a path
public struct ServiceProvider: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var key: String?
  public var name: String?
  public var device: Caller.Device?
  public var instance: String?
  public var online: Bool?
}

/// Calls of the Devices API. Read with `client.devices`.
@MainActor
public struct HubDevicesAPI {
  let client: HubClient

  /// `hub/devices`: devices with their services, presence and capabilities
  public func list() -> Values<Void, EmptyCodable, EmptyCodable, [Device]> {
    client.values("hub/devices")
  }
  /// `hub/devices/pending`: devices waiting for approval
  public func pending() -> Values<Void, EmptyCodable, EmptyCodable, [PendingDevice]> {
    client.values("hub/devices/pending")
  }
  /// `hub/devices/data`: the latest live data of a device, then updates
  public func data(_ id: String) -> Values<Void, ID, EmptyCodable, DeviceData> {
    client.values("hub/devices/data", ID(id: id))
  }
  @discardableResult
  public func approve(_ id: String) async throws -> Device {
    try await client.send("hub/device/approve", ID(id: id))
  }
  @discardableResult
  public func rename(_ id: String, to name: String) async throws -> Device {
    try await client.send("hub/device/rename", Rename(id: id, name: name))
  }
  /// Detaches the device: it can enrol again, as pending
  public func remove(_ id: String) async throws {
    try await client.send("hub/device/remove", ID(id: id))
  }
  /// Revokes the device for good, with its service keys except `keepServices`
  public func revoke(_ id: String, keepServices: [String]? = nil) async throws {
    try await client.send("hub/device/revoke", Revoke(id: id, keepServices: keepServices))
  }

  // Reporter
  /// `hub/device/describe`, only from the device's reporter connection
  public func describe(_ description: DeviceDescription) async throws {
    try await client.send("hub/device/describe", description)
  }
  /// `hub/device/data`, only from the device's reporter connection
  public func report(_ data: DeviceData) async throws {
    try await client.send("hub/device/data", data)
  }

  // Security
  public func securityMode() -> Values<Void, EmptyCodable, EmptyCodable, SecurityMode> {
    client.values("hub/security/mode")
  }
  public func setSecurityMode(_ mode: SecurityMode.Mode? = nil, requireV1: Bool? = nil) async throws {
    try await client.send("hub/security/mode/set", SetMode(mode: mode, requireV1: requireV1))
  }
  public func grants() -> Values<Void, EmptyCodable, EmptyCodable, [Grant]> {
    client.values("hub/grants")
  }
  @discardableResult
  public func addGrant(_ subject: Grant.Subject, _ object: Grant.Object) async throws -> Grant {
    try await client.send("hub/grant/add", AddGrant(subject: subject, object: object))
  }
  public func removeGrant(_ id: String) async throws {
    try await client.send("hub/grant/remove", ID(id: id))
  }
  /// `hub/api/services`: providers of a path, with their device and instance
  public func providers(_ path: String) -> Values<Void, String, EmptyCodable, [ServiceProvider]> {
    client.values("hub/api/services", path)
  }

  public struct ID: Codable, Hashable, Sendable {
    public var id: String
  }
  struct Rename: Encodable, Sendable {
    var id: String
    var name: String
  }
  struct Revoke: Encodable, Sendable {
    var id: String
    var keepServices: [String]?
  }
  struct SetMode: Encodable, Sendable {
    var mode: SecurityMode.Mode?
    var requireV1: Bool?
  }
  struct AddGrant: Encodable, Sendable {
    var subject: Grant.Subject
    var object: Grant.Object
  }
}

public extension HubClient {
  var devices: HubDevicesAPI { HubDevicesAPI(client: self) }
}
