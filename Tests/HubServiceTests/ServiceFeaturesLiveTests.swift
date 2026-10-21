import Foundation
import Testing
@testable import HubService
import Channel

/// The service features through a real hub-server, for example in local mode:
/// `bun index.ts --local --port 2450 --owner <SPKI>`, then
/// `HUB_LIVE_URL=ws://127.0.0.1:2450 HUB_LIVE_OWNER_KEY=<key file> swift test --filter ServiceFeaturesLive`
@Suite("Service features: live hub", .enabled(if: ProcessInfo.processInfo.environment["HUB_LIVE_OWNER_KEY"] != nil))
@MainActor
struct ServiceFeaturesLiveTests {
  let url = URL(string: ProcessInfo.processInfo.environment["HUB_LIVE_URL"] ?? "ws://127.0.0.1:1997")!

  private func ownerKey() throws -> KeyChain {
    try KeyChain(keyFile: String(contentsOfFile: ProcessInfo.processInfo.environment["HUB_LIVE_OWNER_KEY"]!, encoding: .utf8))
  }
  private func client(_ keyChain: KeyChain = KeyChain(.none)) async -> HubClient {
    let client = HubClient(url, keyChain: keyChain, options: .init(hubKeys: HubKeyPins(.memory)))
    _ = await client.waitUntilReady(timeout: 10)
    return client
  }
  /// `message|code` of a failed call
  private func failure(_ call: () async throws -> String) async -> String {
    do {
      return try await call()
    } catch let error as ChannelError {
      return "\(error.text)|\(error.codeText ?? "")"
    } catch {
      return "\(error)"
    }
  }

  @Test("permissions, delegated users, error codes and shutdown through the hub")
  func throughTheHub() async throws {
    let suffix = UUID().uuidString.prefix(8)
    let path = "swift\(suffix)"
    let gateways = "swift-gateways-\(suffix)"
    let gate = LiveGate()
    let owner = await client(try ownerKey())
    defer { owner.stop() }
    // The provider runs with the owner key, so its hosting needs no approval
    let host = HubClient(url, keyChain: try ownerKey(), options: .init(hubKeys: HubKeyPins(.memory)))
    host.service.delegates = [gateways]
    _ = host.service
      .post("\(path)/delete", options: .init(permission: "\(path)/moderate")) { () -> String in "deleted" }
      .post("\(path)/create", options: .init(auth: .user)) { () -> String in try HubRequest.current!.requireUser().id }
      .post("\(path)/missing") { () -> String in throw HubError.notFound("post not found") }
      .post("\(path)/slow") { () -> String in
        await gate.wait()
        return "slow done"
      }
    _ = await host.waitUntilReady(timeout: 10)
    try await Task.sleep(nanoseconds: 300_000_000)

    let strangerKeys = KeyChain(.none)
    let strangerKey = strangerKeys.publicKey()
    let stranger = await client(strangerKeys)
    defer { stranger.stop() }
    #expect(await failure { try await stranger.send("\(path)/delete") } == "permissions required|forbidden")
    struct Grant: Decodable { let id: String }
    struct GrantBody: Encodable { let subject: [String: String]; let object: [String: String] }
    let grant: Grant = try await owner.send("hub/grant/add", GrantBody(subject: ["key": strangerKey], object: ["path": "\(path)/moderate"]))
    #expect(await failure { try await stranger.send("\(path)/delete") } == "deleted")
    try await owner.send("hub/grant/remove", ["id": grant.id])

    struct Group: Encodable { let group: String; let add: [String] }
    try await owner.send("hub/group/create", gateways)
    try await owner.send("hub/group/update/users", Group(group: gateways, add: ["key:\(strangerKey)"]))
    #expect(await failure { try await stranger.send("\(path)/create", context: ["user": "u1"]) } == "u1")

    #expect(await failure { try await stranger.send("\(path)/missing") } == "post not found|not_found")
    #expect(await failure { try await stranger.send("\(path)/nothing") } == "api not found|not_found")

    // Shutdown: the running call finishes before the provider disconnects
    let running = Task { await failure { try await stranger.send("\(path)/slow") } }
    for _ in 0..<200 where host.service.runningCalls == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(host.service.runningCalls == 1)
    let shutdown = Task { await host.shutdown(timeout: 5) }
    for _ in 0..<200 where host.service.health.status != .shuttingDown { try await Task.sleep(nanoseconds: 10_000_000) }
    await gate.open()
    #expect(await running.value == "slow done")
    #expect(await shutdown.value)
  }
}

private actor LiveGate {
  private var isOpen = false
  private var waiting = [CheckedContinuation<Void, Never>]()
  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiting.append($0) }
  }
  func open() {
    isOpen = true
    waiting.forEach { $0.resume() }
    waiting = []
  }
}
