import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Testing
@testable import HubService

@Suite("Hub Network service identity proof")
struct KeyChainNetworkTests {
  @Test("challenge proof uses the existing service identity")
  func challengeProof() throws {
    let keyChain = KeyChain(.none)
    let challenge = "hub-network/local-agent/challenge/v1:test-nonce"
    let signature = try #require(Data(base64Encoded: keyChain.sign(text: challenge)))
    let rawPublicKey = try #require(KeyChain.rawPublicKey(spkiBase64: keyChain.publicKey()))
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)

    #expect(publicKey.isValidSignature(signature, for: Data(challenge.utf8)))
  }

  @Test("proof does not expose private key material")
  func proofShape() throws {
    let keyChain = KeyChain(.none)
    let proof = try #require(Data(base64Encoded: keyChain.sign(text: "nonce")))

    #expect(proof.count == 64)
    #expect(proof != Data(base64Encoded: keyChain.publicKey()))
  }

  @Test("raw and SPKI public keys round trip")
  func publicKeyRoundTrip() throws {
    let raw = Data((0..<32).map(UInt8.init))
    let spki = try #require(KeyChain.spkiPublicKey(rawRepresentation: raw))

    #expect(KeyChain.rawPublicKey(spkiRepresentation: spki) == raw)
    #expect(KeyChain.spkiPublicKey(rawBase64: raw.base64EncodedString()) == spki.base64EncodedString())
    #expect(KeyChain.rawPublicKey(spkiBase64: spki.base64EncodedString()) == raw)
  }

  @Test("SPKI validation rejects malformed keys")
  func rejectsMalformedPublicKeys() throws {
    let raw = Data(repeating: 1, count: 32)
    var wrongPrefix = try #require(KeyChain.spkiPublicKey(rawRepresentation: raw))
    wrongPrefix[0] ^= 0xff

    #expect(KeyChain.spkiPublicKey(rawRepresentation: Data(repeating: 0, count: 31)) == nil)
    #expect(KeyChain.rawPublicKey(spkiRepresentation: wrongPrefix) == nil)
    #expect(KeyChain.rawPublicKey(spkiRepresentation: Data(repeating: 0, count: 44)) == nil)
    #expect(KeyChain.rawPublicKey(spkiBase64: "not base64") == nil)
  }

  @Test("imported private key preserves public key and signs data")
  func importedPrivateKey() throws {
    let seed = Data((0..<32).map(UInt8.init))
    let keyChain = try KeyChain(.none, rawRepresentation: seed)
    let message = Data("message".utf8)
    let signature = try keyChain.signature(for: message)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyChain.data)
    #expect(publicKey.isValidSignature(signature, for: message))
  }

#if canImport(Security)
  @Test("configured Keychain preserves storage selectors")
  func configuredStorageSelectors() {
    let configuration = KeyChain.KeychainConfiguration(
      service: "dev.v57.test",
      account: "identity",
      accessGroup: "TEAM.dev.v57.shared",
      useDataProtectionKeychain: true
    )

    #expect(configuration.service == "dev.v57.test")
    #expect(configuration.account == "identity")
    #expect(configuration.accessGroup == "TEAM.dev.v57.shared")
    #expect(configuration.useDataProtectionKeychain)
  }

  @Test("configured Keychain rejects invalid imported private keys")
  func configuredStorageRejectsInvalidKey() {
    let configuration = KeyChain.KeychainConfiguration(
      service: "dev.v57.test.invalid.\(UUID().uuidString)"
    )

    #expect(throws: KeyChain.Error.invalidPrivateKey) {
      try KeyChain(
        keychain: configuration,
        rawRepresentation: Data(repeating: 0, count: 31)
      )
    }
  }
#endif
}
