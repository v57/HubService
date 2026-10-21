//
//  App elements.swift
//  HubService
//
//  Dashboard elements, layouts and options added in app protocol 2 (Docs/Apps/ui.md).
//

import Foundation

/// String options that read unknown values as nil instead of failing the element
public protocol LossyOption: RawRepresentable<String>, Codable, Hashable, Sendable {}
public extension LossyOption {
  init(from decoder: any Decoder) throws {
    let raw: String = try decoder.decode()
    guard let value = Self(rawValue: raw) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown option \(raw)"))
    }
    self = value
  }
}

public extension Element {
  /// A literal number or text, or `$key` to read the app's data
  enum Value: Codable, Hashable, Sendable, ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    case number(Double)
    case string(String)
    public init(from decoder: any Decoder) throws {
      if let number = try? decoder.singleValueContainer().decode(Double.self) {
        self = .number(number)
      } else {
        self = .string(try decoder.decode())
      }
    }
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .number(let value): try container.encode(value)
      case .string(let value): try container.encode(value)
      }
    }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
  }
  /// Chart or sparkline points: `$key` of an array in the app's data, or the points
  enum Points: Codable, Hashable, Sendable {
    case key(String)
    case points([AnyCodable])
    public init(from decoder: any Decoder) throws {
      if let key = try? decoder.singleValueContainer().decode(String.self) {
        self = .key(key)
      } else {
        self = .points(try decoder.decode())
      }
    }
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .key(let key): try container.encode(key)
      case .points(let points): try container.encode(points)
      }
    }
  }
  enum TextStyle: String, LossyOption {
    case largeTitle, title, headline, body, callout, caption, footnote, monospaced
  }
  enum ButtonStyle: String, LossyOption {
    case `default`, prominent, bordered, destructive
  }
  /// Asks before a button runs its action
  struct Confirmation: Codable, Hashable, Sendable {
    public var title: String
    public var message: String?
    /// Confirm button title, defaults to the button's
    public var button: String?
    public var destructive: Bool?
    public init(title: String, message: String? = nil, button: String? = nil, destructive: Bool? = nil) {
      self.title = title
      self.message = message
      self.button = button
      self.destructive = destructive
    }
  }

  struct Markdown: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .markdown }
    public let id = UUID().uuidString
    public let value: String
    enum CodingKeys: CodingKey {
      case value
    }
    public init(value: String) {
      self.value = value
    }
  }
  struct Image: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .image }
    public let id = UUID().uuidString
    public let url: String?
    public let symbol: String?
    public let width: Double?
    public let height: Double?
    public let mode: Mode?
    public let cornerRadius: Double?
    public let color: String?
    public enum Mode: String, LossyOption {
      case fit, fill
    }
    enum CodingKeys: CodingKey {
      case url, symbol, width, height, mode, cornerRadius, color
    }
    public init(url: String? = nil, symbol: String? = nil, width: Double? = nil, height: Double? = nil, mode: Mode? = nil, cornerRadius: Double? = nil, color: String? = nil) {
      self.url = url
      self.symbol = symbol
      self.width = width
      self.height = height
      self.mode = mode
      self.cornerRadius = cornerRadius
      self.color = color
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      url = container.decodeIfPresent(.url)
      symbol = container.decodeIfPresent(.symbol)
      width = container.decodeIfPresent(.width)
      height = container.decodeIfPresent(.height)
      mode = container.decodeIfPresent(.mode)
      cornerRadius = container.decodeIfPresent(.cornerRadius)
      color = container.decodeIfPresent(.color)
    }
  }
  struct Badge: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .badge }
    public let id = UUID().uuidString
    public let value: String
    public let color: String?
    enum CodingKeys: CodingKey {
      case value, color
    }
    public init(value: String, color: String? = nil) {
      self.value = value
      self.color = color
    }
  }
  struct Divider: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .divider }
    public let id = UUID().uuidString
    public init() {}
    public init(from decoder: any Decoder) throws {}
    public func encode(to encoder: any Encoder) throws {}
  }
  struct Link: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .link }
    public let id = UUID().uuidString
    public let title: String
    public let url: String
    public let icon: String?
    enum CodingKeys: CodingKey {
      case title, url, icon
    }
    public init(title: String, url: String, icon: String? = nil) {
      self.title = title
      self.url = url
      self.icon = icon
    }
  }
  struct Stat: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .stat }
    public let id = UUID().uuidString
    public let title: String
    public let value: Value
    public let unit: String?
    public let delta: Value?
    public let deltaFormat: DeltaFormat?
    public let positive: Direction?
    public let sparkline: Points?
    public let icon: String?
    public let color: String?
    public enum DeltaFormat: String, LossyOption {
      case number, percent
    }
    public enum Direction: String, LossyOption {
      case up, down
    }
    enum CodingKeys: CodingKey {
      case title, value, unit, delta, deltaFormat, positive, sparkline, icon, color
    }
    public init(title: String, value: Value, unit: String? = nil, delta: Value? = nil, deltaFormat: DeltaFormat? = nil, positive: Direction? = nil, sparkline: Points? = nil, icon: String? = nil, color: String? = nil) {
      self.title = title
      self.value = value
      self.unit = unit
      self.delta = delta
      self.deltaFormat = deltaFormat
      self.positive = positive
      self.sparkline = sparkline
      self.icon = icon
      self.color = color
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      title = try container.decode(.title)
      value = try container.decode(.value)
      unit = container.decodeIfPresent(.unit)
      delta = container.decodeIfPresent(.delta)
      deltaFormat = container.decodeIfPresent(.deltaFormat)
      positive = container.decodeIfPresent(.positive)
      sparkline = container.decodeIfPresent(.sparkline)
      icon = container.decodeIfPresent(.icon)
      color = container.decodeIfPresent(.color)
    }
  }
  struct Gauge: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .gauge }
    public let id = UUID().uuidString
    public let value: Value
    public let min: Double
    public let max: Double
    public let title: String?
    public let label: String?
    public let style: Style
    public let color: String?
    public let thresholds: [Threshold]
    public enum Style: String, LossyOption {
      case ring, semicircle, bar
    }
    public struct Threshold: Codable, Hashable, Sendable {
      public var value: Double
      public var color: String
      public init(value: Double, color: String) {
        self.value = value
        self.color = color
      }
    }
    enum CodingKeys: CodingKey {
      case value, min, max, title, label, style, color, thresholds
    }
    public init(value: Value, min: Double = 0, max: Double = 1, title: String? = nil, label: String? = nil, style: Style = .ring, color: String? = nil, thresholds: [Threshold] = []) {
      self.value = value
      self.min = min
      self.max = max
      self.title = title
      self.label = label
      self.style = style
      self.color = color
      self.thresholds = thresholds
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      value = try container.decode(.value)
      min = container.decodeIfPresent(.min, 0)
      max = container.decodeIfPresent(.max, 1)
      title = container.decodeIfPresent(.title)
      label = container.decodeIfPresent(.label)
      style = container.decodeIfPresent(.style, .ring)
      color = container.decodeIfPresent(.color)
      thresholds = container.decodeLossyIfPresent(.thresholds) ?? []
    }
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(value, forKey: .value)
      try container.encodeIfPresent(min, forKey: .min, defaultValue: 0)
      try container.encodeIfPresent(max, forKey: .max, defaultValue: 1)
      try container.encodeIfPresent(title, forKey: .title)
      try container.encodeIfPresent(label, forKey: .label)
      try container.encodeIfPresent(style, forKey: .style, defaultValue: .ring)
      try container.encodeIfPresent(color, forKey: .color)
      if !thresholds.isEmpty { try container.encode(thresholds, forKey: .thresholds) }
    }
  }
  struct Chart: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .chart }
    public let id = UUID().uuidString
    public let kind: Kind
    public let series: [Series]
    public let title: String?
    public let x: Axis?
    public let height: Double?
    public let stacked: Bool
    public let legend: Bool?
    public let yMin: Double?
    public let yMax: Double?
    public let unit: String?
    public enum Kind: String, LossyOption {
      case line, bar, area, pie, donut
    }
    public enum Axis: String, LossyOption {
      case number, category, time
    }
    public struct Series: Codable, Hashable, Sendable {
      public var name: String
      public var data: Points
      public var color: String?
      public init(name: String, data: Points, color: String? = nil) {
        self.name = name
        self.data = data
        self.color = color
      }
    }
    enum CodingKeys: CodingKey {
      case kind, series, title, x, height, stacked, legend, yMin, yMax, unit
    }
    public init(kind: Kind, series: [Series], title: String? = nil, x: Axis? = nil, height: Double? = nil, stacked: Bool = false, legend: Bool? = nil, yMin: Double? = nil, yMax: Double? = nil, unit: String? = nil) {
      self.kind = kind
      self.series = series
      self.title = title
      self.x = x
      self.height = height
      self.stacked = stacked
      self.legend = legend
      self.yMin = yMin
      self.yMax = yMax
      self.unit = unit
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      // A newer kind draws as a line
      kind = container.decodeIfPresent(.kind, .line)
      series = container.decodeLossy(.series)
      title = container.decodeIfPresent(.title)
      x = container.decodeIfPresent(.x)
      height = container.decodeIfPresent(.height)
      stacked = container.decodeIfPresent(.stacked, false)
      legend = container.decodeIfPresent(.legend)
      yMin = container.decodeIfPresent(.yMin)
      yMax = container.decodeIfPresent(.yMax)
      unit = container.decodeIfPresent(.unit)
    }
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(kind, forKey: .kind)
      try container.encode(series, forKey: .series)
      try container.encodeIfPresent(title, forKey: .title)
      try container.encodeIfPresent(x, forKey: .x)
      try container.encodeIfPresent(height, forKey: .height)
      try container.encodeIfPresent(stacked, forKey: .stacked, defaultValue: false)
      try container.encodeIfPresent(legend, forKey: .legend)
      try container.encodeIfPresent(yMin, forKey: .yMin)
      try container.encodeIfPresent(yMax, forKey: .yMax)
      try container.encodeIfPresent(unit, forKey: .unit)
    }
  }
  struct Table: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .table }
    public let id = UUID().uuidString
    public let data: String
    public let columns: [Column]
    public struct Column: Codable, Hashable, Sendable {
      public var title: String
      public var key: String
      public var align: Alignment?
      public var style: Style?
      public enum Alignment: String, LossyOption {
        case leading, center, trailing
      }
      public enum Style: String, LossyOption {
        case text, secondary, monospaced, badge
      }
      public init(title: String, key: String, align: Alignment? = nil, style: Style? = nil) {
        self.title = title
        self.key = key
        self.align = align
        self.style = style
      }
      enum CodingKeys: CodingKey {
        case title, key, align, style
      }
      public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(.title)
        key = try container.decode(.key)
        align = container.decodeIfPresent(.align)
        style = container.decodeIfPresent(.style)
      }
    }
    enum CodingKeys: CodingKey {
      case data, columns
    }
    public init(data: String, columns: [Column]) {
      self.data = data
      self.columns = columns
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      data = try container.decode(.data)
      columns = container.decodeLossy(.columns)
    }
  }
  final class Grid: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .grid }
    public let id = UUID().uuidString
    public let content: [Element]
    public let columns: Int?
    public let minWidth: Double?
    public let spacing: Double?
    enum CodingKeys: CodingKey {
      case content, columns, minWidth, spacing
    }
    public init(columns: Int? = nil, minWidth: Double? = nil, spacing: Double? = nil, content: [Element]) {
      self.content = content
      self.columns = columns
      self.minWidth = minWidth
      self.spacing = spacing
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      content = container.decodeLossy(.content)
      columns = container.decodeIfPresent(.columns)
      minWidth = container.decodeIfPresent(.minWidth)
      spacing = container.decodeIfPresent(.spacing)
    }
  }
  final class Section: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .section }
    public let id = UUID().uuidString
    public let title: String?
    public let subtitle: String?
    public let content: [Element]
    public let style: Style
    public enum Style: String, LossyOption {
      case card, plain
    }
    enum CodingKeys: CodingKey {
      case title, subtitle, content, style
    }
    public init(title: String? = nil, subtitle: String? = nil, style: Style = .card, content: [Element]) {
      self.title = title
      self.subtitle = subtitle
      self.content = content
      self.style = style
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      title = container.decodeIfPresent(.title)
      subtitle = container.decodeIfPresent(.subtitle)
      content = container.decodeLossy(.content)
      style = container.decodeIfPresent(.style, .card)
    }
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encodeIfPresent(title, forKey: .title)
      try container.encodeIfPresent(subtitle, forKey: .subtitle)
      try container.encode(content, forKey: .content)
      try container.encodeIfPresent(style, forKey: .style, defaultValue: .card)
    }
  }
  final class Tabs: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .tabs }
    public let id = UUID().uuidString
    public let tabs: [Tab]
    public let selected: String?
    public let style: Style?
    public enum Style: String, LossyOption {
      case segmented, tabs
    }
    public struct Tab: Codable, Sendable {
      public var title: String
      public var icon: String?
      public var content: [Element]
      public init(title: String, icon: String? = nil, content: [Element]) {
        self.title = title
        self.icon = icon
        self.content = content
      }
      enum CodingKeys: CodingKey {
        case title, icon, content
      }
      public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(.title)
        icon = container.decodeIfPresent(.icon)
        content = container.decodeLossy(.content)
      }
    }
    enum CodingKeys: CodingKey {
      case tabs, selected, style
    }
    public init(tabs: [Tab], selected: String? = nil, style: Style? = nil) {
      self.tabs = tabs
      self.selected = selected
      self.style = style
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      tabs = container.decodeLossy(.tabs)
      selected = container.decodeIfPresent(.selected)
      style = container.decodeIfPresent(.style)
    }
  }
  final class Sheet: ElementProtocol, Identifiable, Codable, Sendable {
    public var type: ElementType { .sheet }
    public let id = UUID().uuidString
    public let title: String
    public let icon: String?
    public let content: [Element]
    enum CodingKeys: CodingKey {
      case title, icon, content
    }
    public init(title: String, icon: String? = nil, content: [Element]) {
      self.title = title
      self.icon = icon
      self.content = content
    }
    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      title = try container.decode(.title)
      icon = container.decodeIfPresent(.icon)
      content = container.decodeLossy(.content)
    }
  }
}

public extension ElementBuilder {
  static func buildExpression(_ expression: Element.Markdown) -> [Element] { [.markdown(expression)] }
  static func buildExpression(_ expression: Element.Image) -> [Element] { [.image(expression)] }
  static func buildExpression(_ expression: Element.Badge) -> [Element] { [.badge(expression)] }
  static func buildExpression(_ expression: Element.Divider) -> [Element] { [.divider(expression)] }
  static func buildExpression(_ expression: Element.Link) -> [Element] { [.link(expression)] }
  static func buildExpression(_ expression: Element.Stat) -> [Element] { [.stat(expression)] }
  static func buildExpression(_ expression: Element.Gauge) -> [Element] { [.gauge(expression)] }
  static func buildExpression(_ expression: Element.Chart) -> [Element] { [.chart(expression)] }
  static func buildExpression(_ expression: Element.Table) -> [Element] { [.table(expression)] }
  static func buildExpression(_ expression: Element.Grid) -> [Element] { [.grid(expression)] }
  static func buildExpression(_ expression: Element.Section) -> [Element] { [.section(expression)] }
  static func buildExpression(_ expression: Element.Tabs) -> [Element] { [.tabs(expression)] }
  static func buildExpression(_ expression: Element.Sheet) -> [Element] { [.sheet(expression)] }
}

public typealias HMarkdown = Element.Markdown
public typealias HImage = Element.Image
public typealias HBadge = Element.Badge
public typealias HDivider = Element.Divider
public typealias HLink = Element.Link
public typealias HStat = Element.Stat
public typealias HGauge = Element.Gauge
public typealias HChart = Element.Chart
public typealias HTable = Element.Table
public typealias HGrid = Element.Grid
public typealias HSection = Element.Section
public typealias HTabs = Element.Tabs
public typealias HSheet = Element.Sheet
