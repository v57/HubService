import Foundation
import Testing
@testable import HubService
import Channel

private struct Search: Codable, Sendable {
  enum Order: String, Codable, CaseIterable, Sendable { case newest, oldest }
  var query: String
  var limit: Int?
  var order: Order
  var tags: [String]
  var since: Date?
  var site: URL?
  var nested: Nested
  struct Nested: Codable, Sendable {
    var flag: Bool
    var ratio: Double?
  }
}

private struct Note: Codable, Sendable {
  var id: UUID
  var text: String
}

/// Only Encodable: no schema can be derived
private struct Receipt: Encodable, Sendable {
  var ok: Bool
}

/// Decodes by hand through nested containers
private struct Manual: Decodable, Sendable {
  var name: String
  var values: [Int]
  enum Keys: String, CodingKey { case info, values, name }
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    let info = try container.nestedContainer(keyedBy: Keys.self, forKey: .info)
    name = try info.decode(String.self, forKey: .name)
    var list = try container.nestedUnkeyedContainer(forKey: .values)
    var values = [Int]()
    while !list.isAtEnd { values.append(try list.decode(Int.self)) }
    self.values = values
  }
}

private indirect enum Tree: Codable, Sendable {
  case leaf(Int)
  case node([Tree])
}

private func json(_ value: some Encodable) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return String(decoding: try encoder.encode(value), as: UTF8.self)
}

@Suite("API descriptions")
@MainActor
struct ApiDescriptionTests {
  @Test("schemas come from Codable types: required and optional keys, enums, arrays, nested types, dates and URLs")
  func derived() throws {
    let schema = try #require(JSONSchema(for: Search.self))
    #expect(schema.type == [.object])
    #expect(schema.properties.map(\.name) == ["query", "limit", "order", "tags", "since", "site", "nested"])
    #expect(schema.required == ["query", "order", "tags", "nested"])
    #expect(schema[property: "limit"] == .integer())
    #expect(schema[property: "order"]?.cases == ["newest", "oldest"])
    #expect(schema[property: "tags"] == .array(of: .string()))
    #expect(schema[property: "since"] == .string(format: "date-time"))
    #expect(schema[property: "site"] == .string(format: "uri"))
    #expect(schema[property: "nested"] == .object(["flag": .boolean(), "ratio": .number()], required: ["flag"]))
    #expect(JSONSchema(for: String.self) == .string())
    #expect(JSONSchema(for: [Note].self) == .array(of: .object(["id": .string(format: "uuid"), "text": .string()], required: ["id", "text"])))
    #expect(JSONSchema(for: Int?.self) == JSONSchema(type: [.integer, .null]))
    #expect(JSONSchema(for: Manual.self) == .object(["info": .object(["name": .string()], required: ["name"]), "values": .array(of: .integer())], required: ["info", "values"]))
    #expect(JSONSchema.of(Receipt.self) == nil)
    #expect(JSONSchema(for: Tree.self) == nil)
  }

  @Test("schemas encode as JSON Schema, keeping property order, and decode back")
  func coding() throws {
    var schema = JSONSchema.object(["b": .string("B").nullable, "a": .oneOf(["x", "y"])], required: ["b"], "Thing")
    schema.additionalProperties = .allowed(false)
    let encoder = JSONEncoder()
    let text = String(decoding: try encoder.encode(schema), as: UTF8.self)
    #expect(text.range(of: "\"b\"")!.lowerBound < text.range(of: "\"a\"")!.lowerBound)
    var sorted = schema
    sorted.properties.sort { $0.name < $1.name }
    #expect(try JSONDecoder().decode(JSONSchema.self, from: Data(text.utf8)) == sorted)
    #expect(try json(JSONSchema.array(of: .integer())) == #"{"items":{"type":"integer"},"type":"array"}"#)
    #expect(try json(JSONSchema.string().nullable) == #"{"type":["string","null"]}"#)
    let other = try JSONDecoder().decode(JSONSchema.self, from: Data(##"{"type":"object","$ref":"#/x","additionalProperties":{"type":"string"}}"##.utf8))
    #expect(other.additionalProperties == .schema(.string()))
  }

  @Test("headers carry kind and the description, with derived schemas unless options give them")
  func headers() throws {
    let service = HubService(channel: Channel<Void>())
    _ = service
      .post("notes/search", options: .init(title: "Search", description: "Notes whose text contains the query.", annotations: .readOnly)) { (_: Search) -> [Note] in [] }
      .post("notes/add", options: .init(inputSchema: .string("Text"), deriveSchemas: true)) { (_: String) -> Receipt in Receipt(ok: true) }
      .post("notes/raw", options: .init(deriveSchemas: false)) { (_: String) -> Int in 1 }
      .stream("notes/changes", options: .init(description: "Every change.", outputSchema: .array(of: .string()))) { _ in }
      .post("notes/changes") { () -> Int in 0 }
    let headers = try service.serviceHeaders().map { try json($0) }
    #expect(headers.count == 5)
    #expect(headers[0] == #"{"inputSchema":{"description":"Text","type":"string"},"kind":"post","path":"notes\/add"}"#)
    #expect(headers[1] == #"{"kind":"post","outputSchema":{"type":"integer"},"path":"notes\/changes"}"#)
    #expect(headers[2] == #"{"kind":"post","path":"notes\/raw"}"#)
    #expect(headers[3].contains(#""annotations":{"readOnlyHint":true}"#))
    #expect(headers[3].contains(#""title":"Search""#) && headers[3].contains(#""inputSchema":{"properties""#) && headers[3].contains(#""outputSchema":{"items""#))
    #expect(headers[4] == #"{"description":"Every change.","kind":"stream","outputSchema":{"items":{"type":"string"},"type":"array"},"path":"notes\/changes"}"#)
    #expect(service.apiDescriptions.map(\.id) == ["notes/add post", "notes/changes post", "notes/changes stream", "notes/raw post", "notes/search post"])
  }

  @Test("hub/api/list entries decode, with unknown kinds and keywords tolerated")
  func listing() throws {
    let text = #"[{"path":"a","kind":"post","description":"A","inputSchema":{"type":"string"},"annotations":{"readOnlyHint":true}},{"path":"b"},{"path":"c","kind":"rpc"}]"#
    let list = try JSONDecoder().decode([ApiDescription].self, from: Data(text.utf8))
    #expect(list == [
      ApiDescription(path: "a", kind: .post, description: "A", inputSchema: .string(), annotations: .readOnly),
      ApiDescription(path: "b"), ApiDescription(path: "c"),
    ])
  }
}
