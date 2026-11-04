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
    var nonce: String
    var v0: Token
    var v1: Token
  }
  var hubInfo: HubInfoVector
  struct HubInfoVector: Decodable {
    var nonce: String
    var signedData: String
    var proof: String
  }
  var credentials: Credentials
  struct Credentials: Decodable {
    var deviceSeed: String
    var salt: String
    var canonical: [Canonical]
    struct Canonical: Decodable {
      var input: String
      var address: String
    }
    var keys: [DerivedKey]
    struct DerivedKey: Decodable {
      var role: String
      var address: String
      var seed: String
      var publicKey: String
    }
  }
  var transport: [TransportCase]
  struct TransportCase: Decodable {
    var url: String
    var transport: String
  }
  var certificate: Certificate
  var childCertificate: Certificate
  var caller: CallerVector
  struct CallerVector: Decodable {
    var context: Context
    struct Context: Decodable { var hub: HubRequestContext }
  }

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
  @Test("tokens match the vectors")
  func tokens() throws {
    let vectors = try Vectors.load()
    let service = try key(vectors.keys["service"]!)
    let hub = vectors.keys["hub"]!.publicKey
    let expiry = vectors.auth.expiry
    #expect(HubAuth.signedData(expiry: expiry, hubKey: nil) == vectors.auth.v0.signedData)
    #expect(verify(vectors.auth.v0.signature, vectors.auth.v0.signedData, service.publicKey()))
    let vector = vectors.auth.v1
    #expect(HubAuth.signedData(expiry: expiry, hubKey: hub, nonce: vectors.auth.nonce) == vector.signedData)
    #expect(verify(vector.signature, vector.signedData, service.publicKey()))
    let parts = HubAuth.token(service, expiry: expiry, hubKey: hub, nonce: vectors.auth.nonce).split(separator: ".").map(String.init)
    let expected = vector.header.split(separator: ".").map(String.init)
    #expect(parts.count == 5 && [parts[0], parts[1], parts[3], parts[4]] == [expected[0], expected[1], expected[3], expected[4]])
    #expect(verify(parts[2], vector.signedData, service.publicKey()))
  }

  @Test("headers are v1 over the challenge, for at most 30 seconds, with the certificate")
  func headers() throws {
    let vectors = try Vectors.load()
    let service = try key(vectors.keys["service"]!)
    let hub = vectors.keys["hub"]!.publicKey
    let now = Date(timeIntervalSince1970: TimeInterval(vectors.auth.expiry - HubAuth.tokenLifetime))
    let v1 = HubAuth.headers(service, hubKey: hub, nonce: vectors.auth.nonce, certificate: "cert", now: now)
    #expect(v1["v"] == "1" && v1["device"] == "cert")
    #expect(verify(String(v1["auth"]!.split(separator: ".")[2]), vectors.auth.v1.signedData, service.publicKey()))
  }

  @Test("a hub proves its key over the client's nonce")
  func proof() throws {
    let vectors = try Vectors.load()
    let hub = vectors.keys["hub"]!
    let vector = vectors.hubInfo
    #expect(HubHandshake.signedData(hubKey: hub.publicKey, nonce: vector.nonce) == vector.signedData)
    let answer = HubInfo(key: hub.publicKey, protocol: 2, challenge: "challenge", proof: vector.proof)
    #expect(HubHandshake.proves(answer, nonce: vector.nonce))
    // Another nonce, a key the signer doesn't hold, no proof and no challenge all fail
    #expect(!HubHandshake.proves(answer, nonce: HubHandshake.makeNonce()))
    var claim = answer
    claim.key = vectors.keys["device"]!.publicKey
    #expect(!HubHandshake.proves(claim, nonce: vector.nonce))
    var bare = answer
    bare.proof = nil
    #expect(!HubHandshake.proves(bare, nonce: vector.nonce))
    bare = answer
    bare.challenge = nil
    #expect(!HubHandshake.proves(bare, nonce: vector.nonce))
    #expect(HubHandshake.makeNonce().range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil)
  }

  @Test("canonical addresses and credentials match the vectors")
  func credentials() throws {
    let vectors = try Vectors.load().credentials
    for vector in vectors.canonical {
      #expect(HubAddress.canonical(vector.input) == vector.address, "\(vector.input)")
    }
    let device = try KeyChain(rawRepresentation: Data(hex: vectors.deviceSeed))
    #expect(vectors.salt == "hub-credentials-v1")
    for vector in vectors.keys {
      let role = try #require(HubCredentials.Role(rawValue: vector.role))
      let seed = HubCredentials.seed(deviceSeed: Data(hex: vectors.deviceSeed), role: role, address: vector.address)
      #expect(seed == Data(hex: vector.seed), "\(vector.role) \(vector.address)")
      #expect(device.hubCredential(role, address: vector.address).publicKey() == vector.publicKey)
    }
  }

  @Test("how an address travels matches the vectors")
  func transport() throws {
    for vector in try Vectors.load().transport {
      #expect(HubTransport(address: vector.url).rawValue == vector.transport, "\(vector.url)")
    }
    #expect(HubTransport(URL(string: "ws://192.168.1.5:1997")!).isUnencryptedNetwork)
    #expect(!HubTransport(URL(string: "ws://100.64.0.1:1997")!).isUnencryptedNetwork)
  }

  @MainActor
  @Test("a plain public address is refused before dialing, and posts fail")
  func plaintextRefused() async throws {
    let client = HubClient(URL(string: "ws://hub.example.com:1997")!, keyChain: KeyChain(.none), options: .init(hubKeys: HubKeyPins(.memory)))
    defer { client.stop() }
    #expect(client.transport == .refused)
    #expect(await client.refusalReason(timeout: 3) == .plaintextNotAllowed)
    #expect(!(await client.waitUntilReady(timeout: 0.1)))
    await #expect(throws: (any Error).self) { try await client.send("hub/info") as HubInfo }
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
