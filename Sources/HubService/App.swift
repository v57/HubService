//
//  File.swift
//  HubService
//
//  Created by Linux on 19.07.25.
//

import Foundation

public struct App: Sendable {
  public var header: AppHeader
  public var body: [Element]
  public var top: Element?
  public var bottom: Element?
  public var data: [String: AnyCodable]
  public init(header: AppHeader, body: [Element], top: Element? = nil, bottom: Element? = nil, data: [String: AnyCodable] = [:]) {
    self.header = header
    self.body = body
    self.top = top
    self.bottom = bottom
    self.data = data
  }
}

public extension HubService {
  func app(_ app: App) -> Self {
    apps.append(app.header)
    return stream(app.header.path) { continuation in
      continuation.yield(AppInterface(header: app.header, body: app.body, top: app.top, bottom: app.bottom, data: app.data))
    }
  }
}

public struct AppInterface: Codable, Sendable {
  public var header: AppHeader?
  public var body: [Element]?
  public var top: Element?
  public var bottom: Element?
  public var data: [String: AnyCodable]?
  enum CodingKeys: CodingKey {
    case header, body, top, bottom, data
  }
  
  public init(header: AppHeader, body: [Element], top: Element?, bottom: Element?, data: [String: AnyCodable]?) {
    self.header = header
    self.top = top
    self.bottom = bottom
    self.body = body
    self.data = data
  }
  public init() {
    
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    header = container.decodeIfPresent(.header)
    body = container.decodeLossyIfPresent(.body)
    top = container.decodeIfPresent(.top)
    bottom = container.decodeIfPresent(.bottom)
    data = container.decodeIfPresent(.data)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(header, forKey: .header)
    try container.encodeIfPresent(body, forKey: .body)
    try container.encodeIfPresent(top, forKey: .top)
    try container.encodeIfPresent(bottom, forKey: .bottom)
    try container.encodeIfPresent(data, forKey: .data)
  }
}

public enum ElementType: String, Codable {
  case text, progress // readonly
  case textField, button, slider, picker, files, fileOperation // actions
  case list, cell, hstack, vstack, zstack // containers
  case spacer // layout
}

public protocol ElementProtocol: Codable {
  var type: ElementType { get }
  var id: String { get }
}

public enum Element: Identifiable, Codable, Sendable {
  public var id: String {
    element.id
  }
  var element: ElementProtocol {
    switch self {
    case .text(let value): return value
    case .textField(let value): return value
    case .button(let value): return value
    case .slider(let value): return value
    case .list(let value): return value
    case .picker(let value): return value
    case .cell(let value): return value
    case .files(let value): return value
    case .fileOperation(let value): return value
    case .hstack(let value): return value
    case .vstack(let value): return value
    case .zstack(let value): return value
    case .spacer(let value): return value
    case .progress(let value): return value
    }
  }
  case text(Text)
  case textField(TextField)
  case button(Button)
  case slider(Slider)
  case list(List)
  case picker(Picker)
  case cell(Cell)
  case files(Files)
  case fileOperation(FileOperation)
  case hstack(HStack)
  case vstack(VStack)
  case zstack(ZStack)
  case spacer(Spacer)
  case progress(Progress)
  enum CodingKeys: CodingKey {
    case type
  }
  
  public init(from decoder: any Decoder) throws {
    do {
      let value: String = try decoder.decode()
      self = .text(Text(value: value))
    } catch {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let type: ElementType = try container.decode(.type)
      switch type {
      case .text:
        self = try .text(Text(from: decoder))
      case .textField:
        self = try .textField(TextField(from: decoder))
      case .button:
        self = try .button(Button(from: decoder))
      case .slider:
        self = try .slider(Slider(from: decoder))
      case .list:
        self = try .list(List(from: decoder))
      case .picker:
        self = try .picker(Picker(from: decoder))
      case .cell:
        self = try .cell(Cell(from: decoder))
      case .files:
        self = try .files(Files(from: decoder))
      case .fileOperation:
        self = try .fileOperation(FileOperation(from: decoder))
      case .hstack:
        self = try .hstack(HStack(from: decoder))
      case .vstack:
        self = try .vstack(VStack(from: decoder))
      case .zstack:
        self = try .zstack(ZStack(from: decoder))
      case .spacer:
        self = try .spacer(Spacer(from: decoder))
      case .progress:
        self = try .progress(Progress(from: decoder))
      }
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    let value = element
    try container.encode(value.type, forKey: .type)
    try value.encode(to: encoder)
  }
  public struct Text: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .text }
    public let id = UUID().uuidString
    public let value: String
    public let secondary: Bool
    enum CodingKeys: CodingKey {
      case value
      case secondary
    }
    public init(value: String, secondary: Bool = false) {
      self.value = value
      self.secondary = secondary
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.value = try container.decode(.value)
      self.secondary = container.decodeIfPresent(.secondary, false)
    }
  }
  public struct Progress: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .progress }
    public let id = UUID().uuidString
    public let value: String
    public let min: Double
    public let max: Double
    enum CodingKeys: CodingKey {
      case value, min, max
    }
    public init(value: String, min: Double = 0, max: Double = 1) {
      self.value = value
      self.min = min
      self.max = max
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.value = try container.decode(.value)
      self.min = container.decodeIfPresent(.min, 0)
      self.max = container.decodeIfPresent(.max, 1)
    }
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: Element.Progress.CodingKeys.self)
      try container.encode(self.value, forKey: .value)
      try container.encodeIfPresent(min, forKey: .min, defaultValue: 0)
      try container.encodeIfPresent(max, forKey: .max, defaultValue: 1)
    }
  }
  public struct TextField: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .textField }
    public let id = UUID().uuidString
    public let value: String
    public let placeholder: String
    public let action: Action?
    enum CodingKeys: CodingKey {
      case value, placeholder, action
    }
    public init(value: String, placeholder: String, action: Element.Action? = nil) {
      self.value = value
      self.placeholder = placeholder
      self.action = action
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.value = try container.decode(.value)
      self.placeholder = container.decodeIfPresent(.placeholder, "")
      self.action = try container.decode(.action)
    }
  }
  public struct Slider: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .slider }
    public let id = UUID().uuidString
    public let value: String
    public let defaultValue: Double?
    public let min: Double
    public let max: Double
    public let step: Double?
    public let action: Action?
    enum CodingKeys: CodingKey {
      case value, defaultValue, min, max, step, action
    }
    public init(value: String, defaultValue: Double? = nil, min: Double = 0, max: Double = 1, step: Double? = nil, action: Element.Action? = nil) {
      self.value = value
      self.defaultValue = defaultValue
      self.min = min
      self.max = max
      self.step = step
      self.action = action
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.value = try container.decode(.value)
      self.defaultValue = container.decodeIfPresent(.defaultValue)
      self.min = container.decodeIfPresent(.min, 0)
      self.max = container.decodeIfPresent(.max, 1)
      self.step = container.decodeIfPresent(.step)
      self.action = container.decodeIfPresent(.action)
    }
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(value, forKey: .value)
      try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
      try container.encodeIfPresent(min, forKey: .min, defaultValue: 0)
      try container.encodeIfPresent(max, forKey: .max, defaultValue: 1)
      try container.encodeIfPresent(step, forKey: .step)
      try container.encodeIfPresent(action, forKey: .action)
    }
  }
  public struct Button: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .button }
    public let id = UUID().uuidString
    public let title: String
    public let action: Action
    enum CodingKeys: CodingKey {
      case title
      case action
    }
    public init(title: String, action: Action) {
      self.title = title
      self.action = action
    }
  }
  public final class List: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .list }
    public let id = UUID().uuidString
    public let data: String
    public let content: Element
    enum CodingKeys: CodingKey {
      case data, content
    }
    public init(data: String, content: Element) {
      self.data = data
      self.content = content
    }
  }
  public final class HStack: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .hstack }
    public let id = UUID().uuidString
    public let spacing: Double?
    public let content: [Element]
    enum CodingKeys: CodingKey {
      case spacing, content
    }
    public init(spacing: Double? = nil, content: [Element]) {
      self.spacing = spacing
      self.content = content
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.spacing = container.decodeIfPresent(.spacing)
      self.content = container.decodeLossy(.content)
    }
  }
  public final class VStack: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .vstack }
    public let id = UUID().uuidString
    public let spacing: Double?
    public let content: [Element]
    enum CodingKeys: CodingKey {
      case spacing, content
    }
    public init(spacing: Double? = nil, content: [Element]) {
      self.spacing = spacing
      self.content = content
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.spacing = container.decodeIfPresent(.spacing)
      self.content = container.decodeLossy(.content)
    }
  }
  public final class ZStack: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .zstack }
    public let id = UUID().uuidString
    public let content: [Element]
    enum CodingKeys: CodingKey {
      case content
    }
    public init(content: [Element]) {
      self.content = content
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.content = container.decodeLossy(.content)
    }
  }
  public final class Spacer: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .spacer }
    public let id = UUID().uuidString
    public init() {}
    public init(from decoder: any Decoder) throws { }
    public func encode(to encoder: any Encoder) throws { }
  }
  public struct Picker: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .picker }
    public let id = UUID().uuidString
    public let options: [String]
    public let selected: String
    enum CodingKeys: CodingKey {
      case options, selected
    }
    public init(options: [String], selected: String) {
      self.options = options
      self.selected = selected
    }
  }
  public final class Cell: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .cell }
    public let id = UUID().uuidString
    public let title: Element?
    public let subtitle: Element?
    enum CodingKeys: CodingKey {
      case title, subtitle
    }
    public init(title: Element?, subtitle: Element?) {
      self.title = title
      self.subtitle = subtitle
    }
  }
  public final class Files: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .files }
    public let id = UUID().uuidString
    public let title: Element?
    public let value: String
    public let action: Action
    enum CodingKeys: CodingKey {
      case title, value, action
    }
    init(title: Element?, value: String, action: Action) {
      self.title = title
      self.value = value
      self.action = action
    }
  }
  public final class FileOperation: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .fileOperation }
    public let id = UUID().uuidString
    public let title: Element?
    public let value: String
    public let action: Action
    enum CodingKeys: CodingKey {
      case title, value, action
    }
    public init(title: Element?, value: String, action: Action) {
      self.title = title
      self.value = value
      self.action = action
    }
  }
  public struct Action: Codable, Sendable {
    public var path: String
    public var body: ActionBody
    public var output: ActionBody?
    enum CodingKeys: CodingKey {
      case path, body, output
    }
    public init(path: String, body: ActionBody, output: ActionBody? = nil) {
      self.path = path
      self.body = body
      self.output = output
    }
  }
  public enum ActionBody: Codable, Sendable {
    case void
    case single(String)
    case multiple([String: String])
    enum CodingKeys: CodingKey {
      case single, multiple
    }
    
    public init(from decoder: any Decoder) throws {
      do {
        do {
          self = try .single(decoder.decode())
        } catch {
          self = try .multiple(decoder.decode())
        }
      } catch {
        self = .void
      }
    }
    
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .single(let string):
        try container.encode(string)
      case .multiple(let dictionary):
        try container.encode(dictionary)
      case .void: break
      }
    }
  }
}
