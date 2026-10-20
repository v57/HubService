import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Testing
@testable import HubService
import Channel

/// Docs/Devices/vectors.json, copied as Fixtures/device-vectors.json
struct Vectors: Decodable {
  struct Key: Decodable {
    var seed: String
    var keyFile: String
    var publicKey: String
    var deviceId: String?
    var safetyCode: String?
  }
  struct Token: Decodable {
    var signedData: String
    var signature: String
    var header: String
  }
  struct Certificate: Decodable {
    var json: String
    var payload: String
    var signature: String
    var header: String
  }
  var keys: [String: Key]
  var auth: Auth
  struct Auth: Decodable {
    var expiry: Int
    var v0: Token
    var v1: Token
  }
  var certificate: Certificate
  var childCertificate: Certificate

  static func load() throws -> Vectors {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/device-vectors", withExtension: "json"))
    return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
  }
}

func key(_ vector: Vectors.Key) throws -> KeyChain {
  try KeyChain(rawRepresentation: Data(hex: vector.seed))
}

func verify(_ signature: String, _ text: String, _ publicKey: String) -> Bool {
  guard let raw = KeyChain.rawPublicKey(spkiBase64: publicKey),
        let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
        let signature = Data(base64Encoded: signature) else { return false }
  return key.isValidSignature(signature, for: Data(text.utf8))
}

@Suite("Device layer: auth tokens")
struct AuthTokenTests {
  @Test("key file format round-trips and matches the seed")
  func keyFile() throws {
    let vectors = try Vectors.load()
    for vector in vectors.keys.values {
      let fromSeed = try key(vector)
      #expect(fromSeed.keyFile == vector.keyFile)
      #expect(fromSeed.publicKey() == vector.publicKey)
      let fromFile = try KeyChain(keyFile: vector.keyFile + "\n")
      #expect(fromFile.publicKey() == vector.publicKey)
    }
    #expect(throws: KeyChain.Error.self) { try KeyChain(keyFile: "bm90IGEga2V5") }
  }

  /// CryptoKit signs Ed25519 with randomness, so signatures can't equal the vectors byte for byte. The signed
  /// strings must, every signature must verify, and the vectors' signatures must verify with our keys.
  @Test("v0 and v1 tokens match the vectors")
  func tokens() throws {
    let vectors = try Vectors.load()
    let service = try key(vectors.keys["service"]!)
    let hub = vectors.keys["hub"]!.publicKey
    let expiry = vectors.auth.expiry
    for (hubKey, vector) in [(nil, vectors.auth.v0), (hub, vectors.auth.v1)] {
      #expect(HubAuth.signedData(expiry: expiry, hubKey: hubKey) == vector.signedData)
      #expect(verify(vector.signature, vector.signedData, service.publicKey()))
      let parts = HubAuth.token(service, expiry: expiry, hubKey: hubKey).split(separator: ".").map(String.init)
      let expected = vector.header.split(separator: ".").map(String.init)
      #expect(parts.count == 4 && [parts[0], parts[1], parts[3]] == [expected[0], expected[1], expected[3]])
      #expect(verify(parts[2], vector.signedData, service.publicKey()))
    }
  }

  @Test("headers: v0 without a hub key, v1 and the certificate with one")
  func headers() throws {
    let vectors = try Vectors.load()
    let service = try key(vectors.keys["service"]!)
    let hub = vectors.keys["hub"]!.publicKey
    let now = Date(timeIntervalSince1970: TimeInterval(vectors.auth.expiry - 60))
    let v0 = HubAuth.headers(service, hubKey: nil, certificate: "cert", now: now)
    #expect(v0["v"] == "0" && v0["device"] == nil)
    #expect(verify(String(v0["auth"]!.split(separator: ".")[2]), vectors.auth.v0.signedData, service.publicKey()))
    let v1 = HubAuth.headers(service, hubKey: hub, certificate: "cert", now: now)
    #expect(v1["v"] == "1" && v1["device"] == "cert")
    #expect(verify(String(v1["auth"]!.split(separator: ".")[2]), vectors.auth.v1.signedData, service.publicKey()))
  }

  @MainActor
  @Test("pins persist per address in hubs.json, forget clears one")
  func pins() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let keyChain = KeyChain(.file(directory.appendingPathComponent("auth")))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pins = HubKeyPins.beside(keyChain)
    let a = URL(string: "ws://127.0.0.1:1997")!
    let b = URL(string: "wss://hub.example/")!
    pins.pin("A", for: a)
    pins.pin("B", for: b)
    let file = directory.appendingPathComponent("hubs.json")
    let stored = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    #expect(stored == ["ws://127.0.0.1:1997": "A", "wss://hub.example/": "B"])
    pins.forget(a)
    let reloaded = HubKeyPins(.file(file))
    #expect(reloaded.key(for: a) == nil)
    #expect(reloaded.key(for: b) == "B")
  }

  @MainActor
  @Test("a client with a hub key up front pins it")
  func upFront() throws {
    let client = HubClient(keyChain: KeyChain(.none), connect: false, options: .init(hubKey: "H", hubKeys: HubKeyPins(.memory)))
    #expect(client.hubKey == "H")
    client.forgetHubKey()
    #expect(client.hubKey == nil)
  }
}

extension Data {
  init(hex: String) {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      data.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    self = data
  }
}
