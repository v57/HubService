import Foundation
import Testing
@testable import HubService

/// Runs against a real hub-server: `HUB_LIVE_URL=ws://127.0.0.1:1997 swift test --filter LiveHub`
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

  @Test("a wrong pinned key is never replaced, and the refusal says the hub key changed")
  func wrongPin() async throws {
    let pins = HubKeyPins(.memory)
    let other = KeyChain(.none).publicKey()
    let client = HubClient(url, keyChain: KeyChain(.none), options: .init(hubKey: other, hubKeys: pins))
    defer { client.stop() }
    #expect(!(await client.waitUntilReady(timeout: 3)))
    #expect(pins.key(for: url) == other)
    guard case .hubKeyChanged(let pinned, _) = await client.refusalReason() else {
      Issue.record("expected hubKeyChanged, got \(String(describing: client.refusal))")
      return
    }
    #expect(pinned == other)
  }

  /// Needs an owner: `HUB_LIVE_OWNER_KEY=<key file>` whose public key the hub was started with (`--owner`)
  @Test("a revoked device is refused at once with a reason, and posts fail instead of waiting",
        .enabled(if: ProcessInfo.processInfo.environment["HUB_LIVE_OWNER_KEY"] != nil))
  func revoked() async throws {
    let ownerFile = try String(contentsOfFile: ProcessInfo.processInfo.environment["HUB_LIVE_OWNER_KEY"]!, encoding: .utf8)
    let owner = HubClient(url, keyChain: try KeyChain(keyFile: ownerFile), options: .init(hubKeys: HubKeyPins(.memory)))
    defer { owner.stop() }
    #expect(await owner.waitUntilReady())

    let deviceKey = DeviceKey(KeyChain(.none))
    let client = HubClient(url, keyChain: KeyChain(.none), options: .init(
      hubKeys: HubKeyPins(.memory), device: DeviceIdentity(key: deviceKey, name: "Swift revoke test", platform: "other"),
      instance: "revoke-test"))
    defer { client.stop() }
    var reported = [HubClient.Refusal]()
    client.onRefused = { reported.append($0) }
    #expect(await client.waitUntilReady())
    try await owner.devices.approve(deviceKey.id)
    try await owner.devices.revoke(deviceKey.id)

    let start = Date()
    #expect(await client.refusalReason(timeout: 10) == .keyRefused)
    #expect(Date().timeIntervalSince(start) < 10)
    #expect(reported == [.keyRefused])
    #expect(!(await client.waitUntilReady(timeout: 5)))
    // Fails at once, not after the 30 s retry
    let failed = Date()
    await #expect(throws: (any Error).self) {
      let _: HubInfo = try await client.send("hub/info")
    }
    #expect(Date().timeIntervalSince(failed) < 1)
  }
}
