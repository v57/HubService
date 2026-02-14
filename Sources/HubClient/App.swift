//
//  File.swift
//  HubClient
//
//  Created by Linux on 19.07.25.
//

import Foundation

public struct App: Sendable {
  public var header: AppHeader
  public var body: [Element]
  public var data: [String: String]
  public init(header: AppHeader, body: [Element], data: [String: String]) {
    self.header = header
    self.body = body
    self.data = data
  }
}

public extension HubService {
  func app(_ app: App) -> Self {
    apps.append(app.header)
    return stream(app.header.path) { continuation in
      continuation.yield(AppInterface(header: app.header, body: app.body))
    }
  }
}

public struct AppInterface: Codable, Sendable {
  public var header: AppHeader?
  public var body: [Element]?
  public var data: [String: AnyCodable]?
  enum CodingKeys: CodingKey {
    case header, body, data
  }
  
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    header = container.decodeIfPresent(.header)
    body = container.decodeLossyIfPresent(.body)
    data = container.decodeIfPresent(.data)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(header, forKey: .header)
    try container.encodeIfPresent(body, forKey: .body)
    try container.encodeIfPresent(data, forKey: .data)
  }
  public init(header: AppHeader, body: [Element]) {
    self.header = header
    self.body = body
  }
  public init() {
    
  }
}

public enum ElementType: String, Codable {
  case text, textField, button, list, picker, cell, files, fileOperation
}

public protocol ElementProtocol {
  var type: ElementType { get }
  var id: String { get }
}

public enum Element: Identifiable, Codable, Sendable {
  public var id: String {
    switch self {
    case .text(let a): a.id
    case .textField(let a): a.id
    case .button(let a): a.id
    case .list(let a): a.id
    case .picker(let a): a.id
    case .cell(let a): a.id
    case .files(let a): a.id
    case .fileOperation(let a): a.id
    }
  }
  case text(Text)
  case textField(TextField)
  case button(Button)
  case list(List)
  case picker(Picker)
  case cell(Cell)
  case files(Files)
  case fileOperation(FileOperation)
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
      }
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let text):
      try container.encode(ElementType.text, forKey: .type)
      try text.encode(to: encoder)
    case .textField(let textField):
      try container.encode(ElementType.textField, forKey: .type)
      try textField.encode(to: encoder)
    case .button(let button):
      try container.encode(ElementType.button, forKey: .type)
      try button.encode(to: encoder)
    case .list(let list):
      try container.encode(ElementType.list, forKey: .type)
      try list.encode(to: encoder)
    case .picker(let picker):
      try container.encode(ElementType.picker, forKey: .type)
      try picker.encode(to: encoder)
    case .cell(let cell):
      try container.encode(ElementType.cell, forKey: .type)
      try cell.encode(to: encoder)
    case .files(let files):
      try container.encode(ElementType.files, forKey: .type)
      try files.encode(to: encoder)
    case .fileOperation(let fileOperation):
      try container.encode(ElementType.fileOperation, forKey: .type)
      try fileOperation.encode(to: encoder)
    }
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
    public let elements: Element
    enum CodingKeys: CodingKey {
      case data, elements
    }
    public init(data: String, elements: Element) {
      self.data = data
      self.elements = elements
    }
  }
  public struct Picker: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .list }
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
