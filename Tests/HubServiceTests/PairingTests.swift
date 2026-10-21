import Foundation
import Testing
import Channel
@testable import HubService

@Suite("Pairing")
struct PairingTests {
  @Test("codes ignore case, spaces and dashes, and read Crockford look-alikes")
  func normalize() {
    #expect(PairingCode.normalize("K7Q-2MX") == "K7Q2MX")
    #expect(PairingCode.normalize(" k7q 2mx ") == "K7Q2MX")
    #expect(PairingCode.normalize("k7q-2-m-x") == "K7Q2MX")
    #expect(PairingCode.normalize("O1L-I00") == "011100")
    #expect(PairingCode.normalize("K7Q2M") == nil)
    #expect(PairingCode.normalize("K7Q2MXA") == nil)
    #expect(PairingCode.normalize("K7Q-2MU") == nil)
    #expect(PairingCode.normalize("K7Q_2MX") == nil)
    #expect(PairingCode.normalize("") == nil)
    #expect(PairingCode.format("k7q2mx") == "K7Q-2MX")
    #expect(PairingCode.format("nope") == "nope")
  }

  @Test("hub://pair links carry the address and the code")
  func links() throws {
    let link = try #require(PairingLink("hub://pair?a=192.168.1.10:1997&c=k7q-2mx"))
    #expect(link.address == "192.168.1.10:1997" && link.code == "K7Q2MX")
    let ws = try #require(PairingLink("  hub://pair?c=K7Q2MX&a=ws%3A%2F%2Fmac.local%3A1997  "))
    #expect(ws.address == "ws://mac.local:1997")
    #expect(PairingLink(ws.url.absoluteString) == ws)
    #expect(PairingLink(url: try #require(PairingLink(address: "wss://hub.example.com", code: "K7Q2MX")).url)?.address == "wss://hub.example.com")
    #expect(PairingLink("hub://pair?a=host&c=bad") == nil)
    #expect(PairingLink("hub://pair?c=K7Q2MX") == nil)
    #expect(PairingLink("hub://join?a=host&c=K7Q2MX") == nil)
    #expect(PairingLink("https://pair?a=host&c=K7Q2MX") == nil)
    #expect(PairingLink.isPairingLink("HUB://pair?a=x"))
    #expect(!PairingLink.isPairingLink("hub://v1.invite"))
  }

  @Test("hub errors map to pairing errors")
  func errors() {
    #expect(PairingError(ChannelError(text: "invalid pairing code")) == .invalidCode)
    #expect(PairingError(ChannelError(text: "no pairing code")) == .noCode)
    #expect(PairingError(ChannelError(text: "api not found")) == .unsupported)
    #expect(PairingError(ChannelError(text: "x", code: .notFound)) == .unsupported)
    #expect(PairingError(ChannelError(text: "timeout", code: .timeout)) == .timeout)
    #expect(PairingError(ChannelError(text: "unauthorized")) == .failed("unauthorized"))
    #expect(PairingError(PairingError.noCode) == .noCode)
    #expect(PairingError.invalidCode.localizedDescription.contains("wrong"))
  }

  @Test("hub/pair sends the normalized code and decodes the result")
  func wire() throws {
    #expect(String(decoding: try JSONEncoder().encode(HubClient.Pair(code: "K7Q2MX")), as: UTF8.self) == #"{"code":"K7Q2MX"}"#)
    let result = try JSONDecoder().decode(PairingResult.self, from: Data(#"{"owner":true,"hubKey":"K","name":"Mac"}"#.utf8))
    #expect(result == PairingResult(owner: true, hubKey: "K", name: "Mac"))
    #expect(PairingState.verifying.isWorking && !PairingState.idle.isWorking)
  }

  @MainActor
  @Test("a malformed code fails before connecting")
  func malformed() async {
    await #expect(throws: PairingError.malformedCode) {
      try await HubClient.test.pair(code: "12")
    }
  }
}

/// Pairs against a hub that shows a pairing code (a fresh hub-server, or `hub-server --pair`):
/// `HUB_PAIR_URL=ws://127.0.0.1:1997 HUB_PAIR_CODE=K7Q-2MX swift test --filter LivePairing`
@Suite("Pairing: live hub", .serialized, .enabled(if: ProcessInfo.processInfo.environment["HUB_PAIR_CODE"] != nil))
@MainActor
struct LivePairingTests {
  let url = URL(string: ProcessInfo.processInfo.environment["HUB_PAIR_URL"] ?? "ws://127.0.0.1:1997")!
  let code = ProcessInfo.processInfo.environment["HUB_PAIR_CODE"] ?? ""

  @Test("a wrong code fails after at least a second, the right one makes the key an owner, then the code is gone")
  func pairs() async throws {
    let device = DeviceIdentity(key: DeviceKey(KeyChain(.none)), name: "Swift pairing test", platform: "other")
    let client = HubClient(url, keyChain: KeyChain(.none), options: .init(hubKeys: HubKeyPins(.memory), device: device, instance: "pair-test"))
    defer { client.stop() }

    var states = [PairingState]()
    let wrong = PairingCode.normalize(code) == "000000" ? "111111" : "000000"
    let started = Date()
    await #expect(throws: PairingError.invalidCode) {
      try await client.pair(code: wrong) { states.append($0) }
    }
    #expect(Date().timeIntervalSince(started) >= 0.9)
    #expect(states == [.connecting, .verifying])

    let result = try await client.pair(code: code.lowercased())
    #expect(result.owner)
    #expect(result.hubKey == client.hubKey)

    await #expect(throws: PairingError.noCode) {
      try await client.pair(code: code)
    }
  }
}
