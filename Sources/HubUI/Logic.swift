//
//  UI Types.swift
//  Hub
//
//  Created by Dmitry Kozlov on 6/7/25.
//

import Foundation
import HubService

struct InterfaceData {
  var string: [String: String]
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@Observable
class ServiceApp {
  var app = AppInterface()
  var data = [String: AnyCodable]()
  var lists = [String: [NestedList]]()
  struct List: Identifiable {
    var id: String
    var string: [String: AnyCodable]
  }
  init() {
    
  }
  @MainActor
  func sync(hub: HubClient, path: String, context: HubContext? = nil) async {
    do {
      print("syncing", path)
      for try await event: AppInterface in hub.values(path, context: context) {
        if let header = event.header {
          self.app.header = header
        }
        if let body = event.body {
          self.app.body = body
        }
        if let data = event.data {
          self.data = data
        }
      }
    } catch {
      print(error)
    }
  }
  func store(_ value: AnyCodable, for key: String, nested: NestedList?) {
    if let nested {
      if nested.data?[key] != value {
        nested.data?[key] = value
      }
    } else if data[key] != value {
      data[key] = value
    }
  }
  func reset() {
    app = AppInterface()
    data = [:]
    lists = [:]
  }
}


public struct HubContext: Codable, Sendable, Hashable {
  public var service: String?
  public init(service: String? = nil) {
    self.service = service
  }
}

extension HubClient: ObservableObject { }

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@MainActor
extension Element.Action {
  func perform(hub: HubClient, app: ServiceApp, nested: NestedList?, context: HubContext?) async throws {
    let body = body.resolve(app: app, nested: nested)
    let result: AnyCodable = try await hub.send(path, body, context: context)
    result.update(app: app, nested: nested, output: output)
  }
  func perform(hub: HubClient, app: ServiceApp, nested: NestedList?, context: HubContext?, customValues: (inout [String: AnyCodable]) -> Void) async throws {
    var body: AnyCodable? = body.resolve(app: app, nested: nested)
    switch body {
    case .dictionary(var dictionary):
      customValues(&dictionary)
      body = .dictionary(dictionary)
    default:
      var dictionary = [String: AnyCodable]()
      customValues(&dictionary)
      body = .dictionary(dictionary)
    }
    let result: AnyCodable = try await hub.send(path, body, context: context)
    result.update(app: app, nested: nested, output: output)
  }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension Element.ActionBody {
  func resolve(app: ServiceApp, nested: NestedList?) -> AnyCodable? {
    switch self {
    case .single(let string):
      guard let string = nested?.data?[string] ?? app.data[string] else { return nil }
      return string
    case .multiple(let dictionary):
      let data = dictionary.compactMapValues { (string: String) -> AnyCodable? in
        guard let value = nested?.data?[string] ?? app.data[string] else { return nil }
        return value
      }
      return .dictionary(data)
    case .void:
      return nil
    }
  }
  func resolved() -> [String: String] {
    switch self {
    case .void: [:]
    case .single(let string): [string: string]
    case .multiple(let dictionary): dictionary
    }
  }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension AnyCodable {
  func update(app: ServiceApp, nested: NestedList?, output: Element.ActionBody?) {
    let data = map(output)
    if let nested, nested.data != nil {
      nested.data?.insert(contentsOf: data)
    } else {
      app.data.insert(contentsOf: data)
    }
  }
  func map(_ output: Element.ActionBody?) -> [String: AnyCodable] {
    switch output {
    case .void, nil:
      switch self {
      case .dictionary(let dictionary): return dictionary
      default: return [:]
      }
    case .single(let key):
      return [key: self]
    case .multiple(let keys):
      guard var dictionary else { return [:] }
      for (key, value) in dictionary {
        if let mapped = keys[key] {
          dictionary[key] = nil
          dictionary[mapped] = value
        }
      }
      return dictionary
    }
  }
}

extension Dictionary {
  mutating func insert(contentsOf dictionary: Dictionary) {
    dictionary.forEach { key, value in
      self[key] = value
    }
  }
}

public struct HubTask: Hashable {
  public let id: URL
  public let path: String
  public let context: HubContext
}
