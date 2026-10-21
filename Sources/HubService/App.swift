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
  public var widget: WidgetInterface?
  public init(header: AppHeader, body: [Element], top: Element? = nil, bottom: Element? = nil, data: [String: AnyCodable] = [:]) {
    self.header = header
    self.body = body
    self.top = top
    self.bottom = bottom
    self.data = data
  }
  public init(header: AppHeader, top: Element? = nil, bottom: Element? = nil, data: [String: AnyCodable] = [:], @ElementBuilder body: () -> [Element]) {
    self.init(header: header, body: body(), top: top, bottom: bottom, data: data)
  }
  /// Makes the app a Home widget as well. Tapping the widget opens the app.
  public func widget(sizes: [WidgetSize] = WidgetSize.allCases, body: [Element]? = nil, bodies: [WidgetSize: [Element]] = [:]) -> App {
    var app = self
    app.header.widget = AppHeader.Widget(sizes: sizes)
    app.widget = WidgetInterface(body: body, sizes: bodies.filter { sizes.contains($0.key) })
    return app
  }
}

public extension HubService {
  func app(_ app: App) -> Self {
    apps.append(app.header)
    return stream(app.header.path) { continuation in
      var interface = AppInterface(header: app.header, body: app.body, top: app.top, bottom: app.bottom, data: app.data)
      interface.widget = app.widget
      continuation.yield(interface)
    }
  }
}

/// An app in `hub/status/badges` and `hub/service/update`. Unknown fields are ignored, so newer kinds of app still
/// list in older clients; `widget` and `web` say how newer clients show it.
public struct AppHeader: Identifiable, Hashable, Codable, Sendable {
  public var id: String { path }
  public let type: AppType
  public let name: String
  public let path: String
  /// SF Symbol name
  public var icon: String?
  /// The app is also a Home widget
  public var widget: Widget?
  /// The app is a web page
  public var web: Web?
  public var services: Int?
  public var isOnline: Bool { (services ?? 1) != 0 }
  public enum AppType: String, Codable, Sendable {
    case app
    /// Unknown types read as apps
    public init(from decoder: any Decoder) throws {
      self = AppType(rawValue: try decoder.decode()) ?? .app
    }
  }
  public struct Widget: Hashable, Codable, Sendable {
    /// Supported sizes, the first is the default. Unknown sizes are dropped.
    public var sizes: [WidgetSize]
    public init(sizes: [WidgetSize]) {
      self.sizes = sizes
    }
    enum CodingKeys: CodingKey {
      case sizes
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let sizes: [String] = container.decodeIfPresent(.sizes, [])
      self.sizes = sizes.compactMap(WidgetSize.init(rawValue:))
      if self.sizes.isEmpty { self.sizes = [.x11] }
    }
    public var defaultSize: WidgetSize { sizes.first ?? .x11 }
  }
  public struct Web: Hashable, Codable, Sendable {
    /// `{hubHost}` is replaced by the host the client uses for the hub
    public var url: String
    /// Other origins the page may navigate to without asking
    public var origins: [String]?
    /// The client fetches a page token from `<path>/token`
    public var token: Bool?
    public init(url: String, origins: [String]? = nil, token: Bool? = nil) {
      self.url = url
      self.origins = origins
      self.token = token
    }
    /// The page URL for a hub at `hubHost`
    public func url(hubHost: String?) -> URL? {
      URL(string: url.replacingOccurrences(of: "{hubHost}", with: hubHost ?? "localhost"))
    }
  }
  public init(type: AppType, name: String, path: String, icon: String? = nil, widget: Widget? = nil, web: Web? = nil) {
    self.type = type
    self.name = name
    self.path = path
    self.icon = icon
    self.widget = widget
    self.web = web
  }
  enum CodingKeys: CodingKey {
    case type, name, path, icon, widget, web, services
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = container.decodeIfPresent(.type, .app)
    name = try container.decode(.name)
    path = try container.decode(.path)
    icon = container.decodeIfPresent(.icon)
    widget = container.decodeIfPresent(.widget)
    web = container.decodeIfPresent(.web)
    services = container.decodeIfPresent(.services)
  }
}

/// Home tile sizes, width x height
public enum WidgetSize: String, Codable, CaseIterable, Hashable, Sendable {
  case x11 = "1x1", x12 = "1x2", x21 = "2x1", x22 = "2x2"
  public var width: Int { self == .x21 || self == .x22 ? 2 : 1 }
  public var height: Int { self == .x12 || self == .x22 ? 2 : 1 }
}

/// Widget content in the app stream: one body per size, or `body` for sizes without their own
public struct WidgetInterface: Codable, Sendable {
  public var body: [Element]?
  public var sizes: [WidgetSize: [Element]]
  public init(body: [Element]? = nil, sizes: [WidgetSize: [Element]] = [:]) {
    self.body = body
    self.sizes = sizes
  }
  public subscript(size: WidgetSize) -> [Element]? {
    sizes[size] ?? body
  }
  struct Key: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    body = container.decodeLossyIfPresent(Key(stringValue: "body"))
    var sizes = [WidgetSize: [Element]]()
    for size in WidgetSize.allCases {
      if let elements: [Element] = container.decodeLossyIfPresent(Key(stringValue: size.rawValue)) {
        sizes[size] = elements
      }
    }
    self.sizes = sizes
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encodeIfPresent(body, forKey: Key(stringValue: "body"))
    for (size, elements) in sizes {
      try container.encode(elements, forKey: Key(stringValue: size.rawValue))
    }
  }
}

public struct AppInterface: Codable, Sendable {
  public var header: AppHeader?
  public var body: [Element]?
  public var top: Element?
  public var bottom: Element?
  public var data: [String: AnyCodable]?
  public var widget: WidgetInterface?
  public var warnings: Int
  enum CodingKeys: CodingKey {
    case header, body, top, bottom, data, widget
  }
  
  public init(header: AppHeader, body: [Element], top: Element?, bottom: Element?, data: [String: AnyCodable]?) {
    self.header = header
    self.top = top
    self.bottom = bottom
    self.body = body
    self.data = data
    self.warnings = 0
  }
  public init(header: AppHeader? = nil, top: Element? = nil, bottom: Element? = nil, data: [String: AnyCodable]? = nil, widget: WidgetInterface? = nil, @ElementBuilder body: () -> [Element]) {
    self.header = header
    self.top = top
    self.bottom = bottom
    self.body = body()
    self.data = data
    self.widget = widget
    self.warnings = 0
  }
  public init() {
    warnings = 0
  }
  public init(from decoder: any Decoder) throws {
    let counter = DecodingWarnings.Counter()
    (header, body, top, bottom, data, widget, warnings) = try DecodingWarnings.$counter.withValue(counter) {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let header: AppHeader? = container.decodeIfPresent(.header)
      let body: [Element]? = container.decodeLossyIfPresent(.body)
      let top: Element? = container.decodeIfPresent(.top)
      let bottom: Element? = container.decodeIfPresent(.bottom)
      let data: [String: AnyCodable]? = container.decodeIfPresent(.data)
      let widget: WidgetInterface? = container.decodeIfPresent(.widget)
      return (header, body, top, bottom, data, widget, counter.count)
    }
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(header, forKey: .header)
    try container.encodeIfPresent(body, forKey: .body)
    try container.encodeIfPresent(top, forKey: .top)
    try container.encodeIfPresent(bottom, forKey: .bottom)
    try container.encodeIfPresent(data, forKey: .data)
    try container.encodeIfPresent(widget, forKey: .widget)
  }
}

public enum ElementType: String, Codable {
  case text, progress, markdown, image, badge, divider, stat, gauge, chart, table // readonly
  case textField, button, slider, picker, files, fileOperation, link, sheet // actions
  case list, cell, hstack, vstack, zstack, grid, section, tabs // containers
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
    case .markdown(let value): return value
    case .image(let value): return value
    case .badge(let value): return value
    case .divider(let value): return value
    case .link(let value): return value
    case .stat(let value): return value
    case .gauge(let value): return value
    case .chart(let value): return value
    case .table(let value): return value
    case .grid(let value): return value
    case .section(let value): return value
    case .tabs(let value): return value
    case .sheet(let value): return value
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
  case markdown(Markdown)
  case image(Image)
  case badge(Badge)
  case divider(Divider)
  case link(Link)
  case stat(Stat)
  case gauge(Gauge)
  case chart(Chart)
  case table(Table)
  case grid(Grid)
  case section(Section)
  case tabs(Tabs)
  case sheet(Sheet)
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
      case .markdown:
        self = try .markdown(Markdown(from: decoder))
      case .image:
        self = try .image(Image(from: decoder))
      case .badge:
        self = try .badge(Badge(from: decoder))
      case .divider:
        self = .divider(Divider())
      case .link:
        self = try .link(Link(from: decoder))
      case .stat:
        self = try .stat(Stat(from: decoder))
      case .gauge:
        self = try .gauge(Gauge(from: decoder))
      case .chart:
        self = try .chart(Chart(from: decoder))
      case .table:
        self = try .table(Table(from: decoder))
      case .grid:
        self = try .grid(Grid(from: decoder))
      case .section:
        self = try .section(Section(from: decoder))
      case .tabs:
        self = try .tabs(Tabs(from: decoder))
      case .sheet:
        self = try .sheet(Sheet(from: decoder))
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
    public let style: TextStyle?
    public let color: String?
    enum CodingKeys: CodingKey {
      case value
      case secondary
      case style
      case color
    }
    public init(value: String, secondary: Bool = false, style: TextStyle? = nil, color: String? = nil) {
      self.value = value
      self.secondary = secondary
      self.style = style
      self.color = color
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.value = try container.decode(.value)
      self.secondary = container.decodeIfPresent(.secondary, false)
      self.style = container.decodeIfPresent(.style)
      self.color = container.decodeIfPresent(.color)
    }
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(value, forKey: .value)
      try container.encodeIfPresent(secondary, forKey: .secondary, defaultValue: false)
      try container.encodeIfPresent(style, forKey: .style)
      try container.encodeIfPresent(color, forKey: .color)
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
      self.action = container.decodeIfPresent(.action)
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
    public let icon: String?
    public let style: ButtonStyle?
    public let confirm: Confirmation?
    enum CodingKeys: CodingKey {
      case title, action, icon, style, confirm
    }
    public init(title: String, action: Action, icon: String? = nil, style: ButtonStyle? = nil, confirm: Confirmation? = nil) {
      self.title = title
      self.action = action
      self.icon = icon
      self.style = style
      self.confirm = confirm
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      title = try container.decode(.title)
      action = try container.decode(.action)
      icon = container.decodeIfPresent(.icon)
      style = container.decodeIfPresent(.style)
      confirm = container.decodeIfPresent(.confirm)
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
    public init(spacing: Double? = nil, @ElementBuilder content: () -> [Element]) {
      self.spacing = spacing
      self.content = content()
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
    public init(spacing: Double? = nil, @ElementBuilder content: () -> [Element]) {
      self.spacing = spacing
      self.content = content()
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
    public init(@ElementBuilder content: () -> [Element]) {
      self.content = content()
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
    public let format: String?
    public let action: Action
    enum CodingKeys: CodingKey {
      case title, format, action
    }
    public init(title: Element?, format: String?, action: Action) {
      self.title = title
      self.format = format
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
    public init(path: String, body: ActionBody = .void, output: ActionBody? = nil) {
      self.path = path
      self.body = body
      self.output = output
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      path = try container.decode(.path)
      body = container.decodeIfPresent(.body, .void)
      output = container.decodeIfPresent(.output)
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

public typealias HText = Element.Text
public typealias HProgress = Element.Progress
public typealias HTextField = Element.TextField
public typealias HSlider = Element.Slider
public typealias HButton = Element.Button
public typealias HList = Element.List
public typealias HPicker = Element.Picker
public typealias HCell = Element.Cell
public typealias HFiles = Element.Files
public typealias HFileOperation = Element.FileOperation
public typealias HHStack = Element.HStack
public typealias HVStack = Element.VStack
public typealias HZStack = Element.ZStack
public typealias HSpacer = Element.Spacer
public typealias HAction = Element.Action
public typealias HActionBody = Element.ActionBody

@resultBuilder
public enum ElementBuilder {
  public static func buildBlock(_ components: [Element]...) -> [Element] {
    components.flatMap { $0 }
  }
  public static func buildExpression(_ expression: Element) -> [Element] {
    [expression]
  }
  public static func buildExpression(_ expression: [Element]) -> [Element] {
    expression
  }
  public static func buildExpression(_ expression: Element.Text) -> [Element] {
    [.text(expression)]
  }
  public static func buildExpression(_ expression: Element.Progress) -> [Element] {
    [.progress(expression)]
  }
  public static func buildExpression(_ expression: Element.TextField) -> [Element] {
    [.textField(expression)]
  }
  public static func buildExpression(_ expression: Element.Slider) -> [Element] {
    [.slider(expression)]
  }
  public static func buildExpression(_ expression: Element.Button) -> [Element] {
    [.button(expression)]
  }
  public static func buildExpression(_ expression: Element.List) -> [Element] {
    [.list(expression)]
  }
  public static func buildExpression(_ expression: Element.Picker) -> [Element] {
    [.picker(expression)]
  }
  public static func buildExpression(_ expression: Element.Cell) -> [Element] {
    [.cell(expression)]
  }
  public static func buildExpression(_ expression: Element.HStack) -> [Element] {
    [.hstack(expression)]
  }
  public static func buildExpression(_ expression: Element.VStack) -> [Element] {
    [.vstack(expression)]
  }
  public static func buildExpression(_ expression: Element.ZStack) -> [Element] {
    [.zstack(expression)]
  }
  public static func buildExpression(_ expression: Element.Spacer) -> [Element] {
    [.spacer(expression)]
  }
  public static func buildOptional(_ component: [Element]?) -> [Element] {
    component ?? []
  }
  public static func buildEither(first component: [Element]) -> [Element] {
    component
  }
  public static func buildEither(second component: [Element]) -> [Element] {
    component
  }
  public static func buildArray(_ components: [[Element]]) -> [Element] {
    components.flatMap { $0 }
  }
  public static func buildLimitedAvailability(_ component: [Element]) -> [Element] {
    component
  }
}
