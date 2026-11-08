import Foundation

/// The JSON Schema subset services describe their paths with (hub-service `docs/api-descriptions.md`, protocol.md
/// section 15). Keywords outside the subset are dropped when decoding.
public struct JSONSchema: Codable, Hashable, Sendable {
  public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
    case string, number, integer, boolean, object, array, null
  }
  public struct Property: Hashable, Sendable {
    public var name: String
    public var schema: JSONSchema
    public init(_ name: String, _ schema: JSONSchema) {
      self.name = name
      self.schema = schema
    }
  }
  /// `additionalProperties`: allowed or not, or a schema they match
  public indirect enum Additional: Codable, Hashable, Sendable {
    case allowed(Bool)
    case schema(JSONSchema)
    public init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let allowed = try? container.decode(Bool.self) { self = .allowed(allowed) } else { self = .schema(try container.decode(JSONSchema.self)) }
    }
    public func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .allowed(let allowed): try container.encode(allowed)
      case .schema(let schema): try container.encode(schema)
      }
    }
  }
  /// A JSON value, for `enum`, `const`, `default` and `examples`
  public indirect enum Value: Codable, Hashable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([Value])
    case object([String: Value])
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if container.decodeNil() { self = .null }
      else if let value = try? container.decode(Bool.self) { self = .bool(value) }
      else if let value = try? container.decode(Int.self) { self = .int(value) }
      else if let value = try? container.decode(Double.self) { self = .double(value) }
      else if let value = try? container.decode(String.self) { self = .string(value) }
      else if let value = try? container.decode([Value].self) { self = .array(value) }
      else { self = .object(try container.decode([String: Value].self)) }
    }
    public func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .null: try container.encodeNil()
      case .bool(let value): try container.encode(value)
      case .int(let value): try container.encode(value)
      case .double(let value): try container.encode(value)
      case .string(let value): try container.encode(value)
      case .array(let value): try container.encode(value)
      case .object(let value): try container.encode(value)
      }
    }
  }

  /// Empty when any type goes; encoded as a string when there is one
  public var type: [Kind] = []
  public var title: String?
  public var description: String?
  /// In declaration order when built or derived, by name when decoded
  public var properties: [Property] = []
  public var required: [String] = []
  public var additionalProperties: Additional?
  private var itemStorage: [JSONSchema] = []
  public var items: JSONSchema? {
    get { itemStorage.first }
    set { itemStorage = newValue.map { [$0] } ?? [] }
  }
  /// `enum`
  public var cases: [Value]?
  public var const: Value?
  public var anyOf: [JSONSchema]?
  public var format: String?
  public var pattern: String?
  public var minimum: Double?
  public var maximum: Double?
  public var minLength: Int?
  public var maxLength: Int?
  public var minItems: Int?
  public var maxItems: Int?
  public var `default`: Value?
  public var examples: [Value]?

  public init(type: [Kind] = [], description: String? = nil) {
    self.type = type
    self.description = description
  }

  // MARK: Builders

  /// Any value
  public static let any = JSONSchema()
  public static func string(_ description: String? = nil, format: String? = nil) -> JSONSchema {
    var schema = JSONSchema(type: [.string], description: description)
    schema.format = format
    return schema
  }
  public static func integer(_ description: String? = nil) -> JSONSchema { JSONSchema(type: [.integer], description: description) }
  public static func number(_ description: String? = nil) -> JSONSchema { JSONSchema(type: [.number], description: description) }
  public static func boolean(_ description: String? = nil) -> JSONSchema { JSONSchema(type: [.boolean], description: description) }
  public static func array(of items: JSONSchema, _ description: String? = nil) -> JSONSchema {
    var schema = JSONSchema(type: [.array], description: description)
    schema.items = items
    return schema
  }
  /// An object with these properties in this order; `required` names those that must be there
  public static func object(_ properties: KeyValuePairs<String, JSONSchema> = [:], required: [String] = [], _ description: String? = nil) -> JSONSchema {
    var schema = JSONSchema(type: [.object], description: description)
    schema.properties = properties.map { Property($0.key, $0.value) }
    schema.required = required
    return schema
  }
  /// A string that is one of `cases`
  public static func oneOf(_ cases: [String], _ description: String? = nil) -> JSONSchema {
    var schema = JSONSchema.string(description)
    schema.cases = cases.map(Value.string)
    return schema
  }
  /// This schema with a description
  public func described(_ description: String) -> JSONSchema {
    var schema = self
    schema.description = description
    return schema
  }
  /// This schema, also taking `null`
  public var nullable: JSONSchema {
    var schema = self
    if !schema.type.isEmpty, !schema.type.contains(.null) { schema.type.append(.null) }
    return schema
  }
  /// The schema of a property
  public subscript(property name: String) -> JSONSchema? {
    get { properties.first { $0.name == name }?.schema }
    set {
      if let index = properties.firstIndex(where: { $0.name == name }) {
        if let newValue { properties[index].schema = newValue } else { properties.remove(at: index) }
      } else if let newValue {
        properties.append(Property(name, newValue))
      }
    }
  }

  // MARK: Codable

  private struct Key: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }
  private struct Ordered: Codable {
    var properties: [Property]
    init(_ properties: [Property]) { self.properties = properties }
    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: Key.self)
      // JSONDecoder doesn't keep key order: decoded properties are sorted by name
      properties = try container.allKeys.sorted { $0.stringValue < $1.stringValue }.map {
        Property($0.stringValue, try container.decode(JSONSchema.self, forKey: $0))
      }
    }
    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: Key.self)
      for property in properties { try container.encode(property.schema, forKey: Key(property.name)) }
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    func value<T: Decodable>(_ key: String) -> T? { try? container.decodeIfPresent(T.self, forKey: Key(key)) }
    if let one: Kind = value("type") { type = [one] } else { type = value("type") ?? [] }
    title = value("title")
    description = value("description")
    properties = (value("properties") as Ordered?)?.properties ?? []
    required = value("required") ?? []
    additionalProperties = value("additionalProperties")
    items = value("items")
    cases = value("enum")
    const = value("const")
    anyOf = value("anyOf")
    format = value("format")
    pattern = value("pattern")
    minimum = value("minimum")
    maximum = value("maximum")
    minLength = value("minLength")
    maxLength = value("maxLength")
    minItems = value("minItems")
    maxItems = value("maxItems")
    `default` = value("default")
    examples = value("examples")
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    func put<T: Encodable>(_ key: String, _ value: T?) throws { if let value { try container.encode(value, forKey: Key(key)) } }
    if type.count == 1 { try put("type", type[0]) } else if !type.isEmpty { try put("type", type) }
    try put("title", title)
    try put("description", description)
    if !properties.isEmpty { try put("properties", Ordered(properties)) }
    if !required.isEmpty { try put("required", required) }
    try put("additionalProperties", additionalProperties)
    try put("items", items)
    try put("enum", cases)
    try put("const", const)
    try put("anyOf", anyOf)
    try put("format", format)
    try put("pattern", pattern)
    try put("minimum", minimum)
    try put("maximum", maximum)
    try put("minLength", minLength)
    try put("maxLength", maxLength)
    try put("minItems", minItems)
    try put("maxItems", maxItems)
    try put("default", `default`)
    try put("examples", examples)
  }
}

// MARK: - Deriving from Codable types

public extension JSONSchema {
  /// The schema of `T`, from decoding it once with a decoder that records what it's asked for: keys, which ones are
  /// optional, value types and nested containers. Nil for types whose `init(from:)` rejects placeholder values,
  /// recursive types and enums with associated values. `Date` is an ISO 8601 string, as Channel sends it.
  init?<T: Decodable>(for type: T.Type) {
    guard let (_, schema) = try? SchemaSampler.sample(type, depth: 0) else { return nil }
    self = schema
  }
  /// The schema of `T` when it's `Decodable`, as `init(for:)`; nil for a type that is only `Encodable`
  static func of<T>(_ type: T.Type) -> JSONSchema? {
    guard let decodable = type as? any Decodable.Type else { return nil }
    return derive(decodable)
  }
  private static func derive<T: Decodable>(_ type: T.Type) -> JSONSchema? { JSONSchema(for: type) }
}

private struct SchemaSampleError: Error {}

/// Makes a placeholder value of a type and its schema
private enum SchemaSampler {
  static let maxDepth = 12

  static func sample<T: Decodable>(_ type: T.Type, depth: Int) throws -> (T, JSONSchema) {
    if let known = known(type) { return known }
    guard depth < maxDepth else { throw SchemaSampleError() }
    let node = SchemaNode()
    let value = try T(from: SchemaDecoder(node: node, depth: depth + 1))
    return (value, node.finished)
  }

  /// Types whose wire form isn't what their `init(from:)` asks for, and enums with a fixed set of cases
  private static func known<T>(_ type: T.Type) -> (T, JSONSchema)? {
    func cast(_ value: Any, _ schema: JSONSchema) -> (T, JSONSchema)? { (value as? T).map { ($0, schema) } }
    if type is Date.Type { return cast(Date(), .string(format: "date-time")) }
    if type is URL.Type { return cast(URL(string: "https://example.com")!, .string(format: "uri")) }
    if type is UUID.Type { return cast(UUID(), .string(format: "uuid")) }
    if type is Data.Type { return cast(Data(), .string(format: "byte")) }
    if type is Decimal.Type { return cast(Decimal(0), .number()) }
    if let caseIterable = type as? any CaseIterable.Type, let (value, cases) = enumeration(caseIterable) {
      var schema = JSONSchema()
      let values = cases.compactMap(Self.value)
      schema.type = Array(Set(values.map { value -> JSONSchema.Kind in if case .string = value { .string } else { .integer } })).sorted { $0.rawValue < $1.rawValue }
      schema.cases = values
      return cast(value, schema)
    }
    return nil
  }
  private static func enumeration<C: CaseIterable>(_ type: C.Type) -> (Any, [Any])? {
    let cases = Array(type.allCases)
    guard let first = cases.first else { return nil }
    return (first, cases.map { $0 as Any })
  }
  /// The raw value of an enum case
  private static func value(_ item: Any) -> JSONSchema.Value? {
    guard let raw = (item as? any RawRepresentable).map({ $0.rawValue as Any }) else { return nil }
    if let string = raw as? String { return .string(string) }
    if let int = raw as? Int { return .int(int) }
    return nil
  }
}

private final class SchemaNode {
  var schema = JSONSchema()
  var nullable = false
  /// Nested containers, filled in after they were handed out: properties of a keyed container, or the items of an
  /// unkeyed one (`name` nil)
  var nested: [(name: String?, node: SchemaNode)] = []
  var finished: JSONSchema {
    var result = schema
    for (name, node) in nested {
      if let name {
        if result[property: name] == nil { result[property: name] = node.finished }
        if !result.required.contains(name) { result.required.append(name) }
      } else {
        result.items = node.finished
      }
    }
    return nullable ? result.nullable : result
  }
  func nested(_ name: String?, type: JSONSchema.Kind) -> SchemaNode {
    let child = SchemaNode()
    child.schema.type = [type]
    nested.append((name, child))
    return child
  }
  func addProperty(_ name: String, _ schema: JSONSchema, required: Bool) {
    if self.schema[property: name] == nil { self.schema[property: name] = schema }
    if required, !self.schema.required.contains(name) { self.schema.required.append(name) }
  }
}

private struct SchemaDecoder: Decoder {
  let node: SchemaNode
  let depth: Int
  var codingPath: [CodingKey] = []
  var userInfo: [CodingUserInfoKey: Any] = [:]
  func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
    node.schema.type = [.object]
    return KeyedDecodingContainer(KeyedSchemaContainer<Key>(node: node, depth: depth))
  }
  func unkeyedContainer() throws -> UnkeyedDecodingContainer {
    node.schema.type = [.array]
    return UnkeyedSchemaContainer(node: node, depth: depth)
  }
  func singleValueContainer() throws -> SingleValueDecodingContainer {
    SingleSchemaContainer(node: node, depth: depth)
  }
}

/// Placeholder values of the primitive types and their schemas
private func primitive<T>(_ type: T.Type) throws -> (T, JSONSchema) {
  let pair: (Any, JSONSchema.Kind)
  switch type {
  case is String.Type: pair = ("", .string)
  case is Bool.Type: pair = (false, .boolean)
  case is Double.Type: pair = (Double(0), .number)
  case is Float.Type: pair = (Float(0), .number)
  case is Int.Type: pair = (0, .integer)
  case is Int8.Type: pair = (Int8(0), .integer)
  case is Int16.Type: pair = (Int16(0), .integer)
  case is Int32.Type: pair = (Int32(0), .integer)
  case is Int64.Type: pair = (Int64(0), .integer)
  case is UInt.Type: pair = (UInt(0), .integer)
  case is UInt8.Type: pair = (UInt8(0), .integer)
  case is UInt16.Type: pair = (UInt16(0), .integer)
  case is UInt32.Type: pair = (UInt32(0), .integer)
  case is UInt64.Type: pair = (UInt64(0), .integer)
  default: throw SchemaSampleError()
  }
  guard let value = pair.0 as? T else { throw SchemaSampleError() }
  return (value, JSONSchema(type: [pair.1]))
}

private struct SingleSchemaContainer: SingleValueDecodingContainer {
  let node: SchemaNode
  let depth: Int
  var codingPath: [CodingKey] = []
  func decodeNil() -> Bool {
    node.nullable = true
    return false
  }
  private func record<T>(_ type: T.Type) throws -> T {
    let (value, schema) = try primitive(type)
    node.schema.type = schema.type
    return value
  }
  func decode(_ type: Bool.Type) throws -> Bool { try record(type) }
  func decode(_ type: String.Type) throws -> String { try record(type) }
  func decode(_ type: Double.Type) throws -> Double { try record(type) }
  func decode(_ type: Float.Type) throws -> Float { try record(type) }
  func decode(_ type: Int.Type) throws -> Int { try record(type) }
  func decode(_ type: Int8.Type) throws -> Int8 { try record(type) }
  func decode(_ type: Int16.Type) throws -> Int16 { try record(type) }
  func decode(_ type: Int32.Type) throws -> Int32 { try record(type) }
  func decode(_ type: Int64.Type) throws -> Int64 { try record(type) }
  func decode(_ type: UInt.Type) throws -> UInt { try record(type) }
  func decode(_ type: UInt8.Type) throws -> UInt8 { try record(type) }
  func decode(_ type: UInt16.Type) throws -> UInt16 { try record(type) }
  func decode(_ type: UInt32.Type) throws -> UInt32 { try record(type) }
  func decode(_ type: UInt64.Type) throws -> UInt64 { try record(type) }
  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    if let value = try? primitive(type) {
      node.schema.type = value.1.type
      return value.0
    }
    let (value, schema) = try SchemaSampler.sample(type, depth: depth)
    let nullable = node.nullable
    node.schema = schema
    node.nullable = nullable
    return value
  }
}

private struct KeyedSchemaContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
  let node: SchemaNode
  let depth: Int
  var codingPath: [CodingKey] = []
  var allKeys: [Key] { [] }
  func contains(_ key: Key) -> Bool { true }
  func decodeNil(forKey key: Key) throws -> Bool { false }

  private func value<T: Decodable>(_ type: T.Type, _ key: Key, required: Bool) throws -> T {
    let (value, schema) = try (try? primitive(type)) ?? SchemaSampler.sample(type, depth: depth)
    node.addProperty(key.stringValue, schema, required: required)
    return value
  }
  func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try value(type, key, required: true) }
  func decode(_ type: String.Type, forKey key: Key) throws -> String { try value(type, key, required: true) }
  func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try value(type, key, required: true) }
  func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try value(type, key, required: true) }
  func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try value(type, key, required: true) }
  func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try value(type, key, required: true) }
  func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try value(type, key, required: true) }
  func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try value(type, key, required: true) }
  func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try value(type, key, required: true) }
  func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try value(type, key, required: true) }
  func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try value(type, key, required: true) }
  func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try value(type, key, required: true) }
  func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try value(type, key, required: true) }
  func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try value(type, key, required: true) }
  func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try value(type, key, required: true) }
  func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { try value(type, key, required: false) }
  func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { try value(type, key, required: false) }
  func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { try value(type, key, required: false) }
  func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? { try value(type, key, required: false) }
  func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { try value(type, key, required: false) }
  func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? { try value(type, key, required: false) }
  func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? { try value(type, key, required: false) }
  func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { try value(type, key, required: false) }
  func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { try value(type, key, required: false) }
  func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? { try value(type, key, required: false) }
  func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? { try value(type, key, required: false) }
  func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? { try value(type, key, required: false) }
  func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? { try value(type, key, required: false) }
  func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? { try value(type, key, required: false) }
  func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? { try value(type, key, required: false) }

  func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
    guard depth < SchemaSampler.maxDepth else { throw SchemaSampleError() }
    return KeyedDecodingContainer(KeyedSchemaContainer<NestedKey>(node: node.nested(key.stringValue, type: .object), depth: depth + 1))
  }
  func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
    guard depth < SchemaSampler.maxDepth else { throw SchemaSampleError() }
    return UnkeyedSchemaContainer(node: node.nested(key.stringValue, type: .array), depth: depth + 1)
  }
  func superDecoder() throws -> Decoder { SchemaDecoder(node: node, depth: depth) }
  func superDecoder(forKey key: Key) throws -> Decoder { throw SchemaSampleError() }
}

private struct UnkeyedSchemaContainer: UnkeyedDecodingContainer {
  let node: SchemaNode
  let depth: Int
  var codingPath: [CodingKey] = []
  var count: Int? { 1 }
  var isAtEnd: Bool { currentIndex > 0 }
  var currentIndex = 0
  mutating func decodeNil() throws -> Bool { false }
  mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
    let (value, schema) = try (try? primitive(type)) ?? SchemaSampler.sample(type, depth: depth)
    node.schema.items = schema
    currentIndex += 1
    return value
  }
  mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
    guard depth < SchemaSampler.maxDepth else { throw SchemaSampleError() }
    currentIndex += 1
    return KeyedDecodingContainer(KeyedSchemaContainer<NestedKey>(node: node.nested(nil, type: .object), depth: depth + 1))
  }
  mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
    guard depth < SchemaSampler.maxDepth else { throw SchemaSampleError() }
    currentIndex += 1
    return UnkeyedSchemaContainer(node: node.nested(nil, type: .array), depth: depth + 1)
  }
  mutating func superDecoder() throws -> Decoder { throw SchemaSampleError() }
}
