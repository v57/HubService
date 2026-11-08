import Foundation
import Testing
@testable import HubService
import Channel

/// A hub from before auth v2 can't prove its key: the client says the hub needs an update and never falls back to v0
@Suite("Hub needs an update")
struct HubNeedsUpdateTests {
  @Test func anAnswerWithAKeyButNoProofIsAnOldHub() {
    #expect(HubHandshake.isOutdated(HubInfo(key: "MCowBQYDK2VwAyEA", protocol: 1, pro: true, mode: "default-allow")))
    #expect(!HubHandshake.isOutdated(HubInfo(key: "MCowBQYDK2VwAyEA", protocol: 2, challenge: "c", proof: "p")))
    // A new hub asked without a nonce gives a challenge and no proof: not an old hub
    #expect(!HubHandshake.isOutdated(HubInfo(key: "MCowBQYDK2VwAyEA", protocol: 2, challenge: "c")))
  }

  @Test func hubLiteWithoutHubInfoIsAnOldHub() {
    #expect(HubHandshake.isOutdated(ChannelError(text: "api not found", code: .notFound)))
    #expect(!HubHandshake.isOutdated(ChannelError(text: "timeout", code: "timeout")))
    #expect(!HubHandshake.isOutdated(CancellationError()))
  }

  @Test func theRefusalNamesTheUpdate() {
    let text = HubClient.Refusal.hubNeedsUpdate.description
    #expect(text.hasPrefix("This Hub needs an update"))
    #expect(text.contains("hub update") && text.contains("docker pull v57dev/hub"))
  }

  /// Against a hub-server from before auth v2: `HUB_LIVE_OLD_URL=ws://127.0.0.1:<port> swift test --filter HubNeedsUpdate`
  @Test(.enabled(if: ProcessInfo.processInfo.environment["HUB_LIVE_OLD_URL"] != nil))
  @MainActor func anOldHubIsRefusedWithTheReason() async throws {
    let url = URL(string: ProcessInfo.processInfo.environment["HUB_LIVE_OLD_URL"]!)!
    #expect(await HubHandshake.needsUpdate(url))
    let key = try KeyChain(rawRepresentation: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    let client = HubClient(url, keyChain: key)
    defer { client.stop() }
    #expect(await client.refusalReason(timeout: 10) == .hubNeedsUpdate)
    #expect(!client.isConnected)
  }
}
