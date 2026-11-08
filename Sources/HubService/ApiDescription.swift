import Foundation

/// MCP's tool annotations, passed through as they are (protocol.md section 15)
public struct ApiAnnotations: Codable, Hashable, Sendable {
  /// Changes nothing
  public var readOnlyHint: Bool?
  /// May delete or overwrite (meaningful when not read-only)
  public var destructiveHint: Bool?
  /// Calling again with the same body has no further effect
  public var idempotentHint: Bool?
  /// Reaches beyond the hub (the internet, other systems)
  public var openWorldHint: Bool?
  public init(readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil, idempotentHint: Bool? = nil, openWorldHint: Bool? = nil) {
    self.readOnlyHint = readOnlyHint
    self.destructiveHint = destructiveHint
    self.idempotentHint = idempotentHint
    self.openWorldHint = openWorldHint
  }
  public static let readOnly = ApiAnnotations(readOnlyHint: true)
}

/// What `hub/api/list` says about a path and kind: what its service described (protocol.md section 15)
public struct ApiDescription: Codable, Hashable, Sendable, Identifiable {
  public enum Kind: String, Codable, Hashable, Sendable {
    case post, stream
  }
  public var path: String
  /// Nil when the service didn't say
  public var kind: Kind?
  public var title: String?
  public var description: String?
  public var inputSchema: JSONSchema?
  /// For a stream, the schema of each value
  public var outputSchema: JSONSchema?
  public var annotations: ApiAnnotations?
  public var id: String { kind.map { "\(path) \($0.rawValue)" } ?? path }
  public init(path: String, kind: Kind? = nil, title: String? = nil, description: String? = nil, inputSchema: JSONSchema? = nil,
    outputSchema: JSONSchema? = nil, annotations: ApiAnnotations? = nil)
  {
    self.path = path
    self.kind = kind
    self.title = title
    self.description = description
    self.inputSchema = inputSchema
    self.outputSchema = outputSchema
    self.annotations = annotations
  }
  /// Unknown kinds read as nil, so a newer hub's entries still decode
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decode(String.self, forKey: .path)
    kind = (try? container.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0.flatMap(Kind.init(rawValue:)) }
    title = try? container.decodeIfPresent(String.self, forKey: .title)
    description = try? container.decodeIfPresent(String.self, forKey: .description)
    inputSchema = try? container.decodeIfPresent(JSONSchema.self, forKey: .inputSchema)
    outputSchema = try? container.decodeIfPresent(JSONSchema.self, forKey: .outputSchema)
    annotations = try? container.decodeIfPresent(ApiAnnotations.self, forKey: .annotations)
  }
}

@MainActor
public extension HubClient {
  /// The hub's APIs this client may call, with what their services say about them (`hub/api/list`, protocol.md
  /// section 15). A hub from before descriptions answers `api not found`.
  func apiList() async throws -> [ApiDescription] {
    try await send("hub/api/list")
  }
}
