import Foundation
import Testing
@testable import HubService

/// Runs against a real hub-pro: `HUB_LIVE_URL=ws://127.0.0.1:1997 swift test --filter LiveHub`
@Suite("Device layer: live hub", .enabled(if: ProcessInfo.processInfo.environment["HUB_LIVE_URL"] != nil))
@MainActor
struct LiveHubTests {
  let url = URL(string: ProcessInfo.processInfo.environment["HUB_LIVE_URL"] ?? "ws://127.0.0.1:1997")!

  @Test("learns and pins the hub key, then reconnects with v1 and a certificate")
  func learnsHubKey() async throws {
    let pins = HubKeyPins(.memory)
    let device = DeviceIdentity(key: DeviceKey(KeyChain(.none)), name: "Swift live test", platform: "other")
    let client = HubClient(url, keyChain: KeyChain(.none), options: .init(hubKeys: pins, device: device, instance: "live-test"))
    defer { client.stop() }
    #expect(await client.waitUntilReady(timeout: 10))
    let info = try #require(client.info)
    #expect(client.hubKey == info.key)
    #expect(pins.key(for: url) == info.key)
    // The device is new and not an owner's, so it waits for approval and gets no reporter role
    await #expect(throws: (any Error).self) {
      try await client.devices.report(DeviceData(cpu: 0.1))
    }
  }

  @Test("a wrong pinned key is never replaced")
  func wrongPin() async throws {
    let pins = HubKeyPins(.memory)
    let other = KeyChain(.none).publicKey()
    let client = HubClient(url, keyChain: KeyChain(.none), options: .init(hubKey: other, hubKeys: pins))
    defer { client.stop() }
    #expect(!(await client.waitUntilReady(timeout: 3)))
    #expect(pins.key(for: url) == other)
  }
}
