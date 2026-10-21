import Foundation
import Testing
@testable import HubService
import Channel

@Suite("Service features")
@MainActor
struct ServiceFeaturesTests {
  let alice = #"{"hub":{"hubKey":"hub","caller":{"key":"alice","groups":[],"owner":false}}}"#
  let editor = #"{"hub":{"hubKey":"hub","caller":{"key":"ed","groups":["editors"],"owner":false}}}"#
  let owner = #"{"hub":{"hubKey":"hub","caller":{"key":"boss","groups":["owners"],"owner":true}}}"#
  let device = #"{"hub":{"hubKey":"hub","caller":{"key":"phone","device":{"id":"d1","name":"Phone"},"groups":[],"owner":false}}}"#

  @Test("auth and groups fail with unauthorized or forbidden before the handler runs")
  func requirements() async throws {
    let harness = Harness()
    _ = harness.service
      .post("t/key", options: .init(auth: .key)) { () -> String in "ok" }
      .post("t/device", options: .init(auth: .device)) { () -> String in "ok" }
      .post("t/owner", options: .init(auth: .owner)) { () -> String in "ok" }
      .post("t/group", options: .init(groups: ["editors"])) { () -> String in "ok" }
      .post("t/inside") { () -> String in
        try HubRequest.current?.requireOwner()
        return "ok"
      }
      .post("t/legacy") { () -> String in throw HubRequestError.permissionsRequired }
    let replies = try await harness.send([
      ("t/key", nil, nil), ("t/key", nil, alice), ("t/device", nil, alice), ("t/device", nil, device),
      ("t/owner", nil, alice), ("t/owner", nil, owner), ("t/group", nil, alice), ("t/group", nil, editor),
      ("t/group", nil, owner), ("t/inside", nil, alice), ("t/legacy", nil, alice),
    ])
    #expect(replies == [
      "unauthorized|unauthorized", "ok", "device required|forbidden", "ok",
      "permissions required|forbidden", "ok", "permissions required|forbidden", "ok",
      "ok", "permissions required|forbidden", "permissions required|forbidden",
    ])
  }

  @Test("a caller from another hub than the pinned one is not trusted")
  func pinnedHub() async throws {
    let harness = Harness()
    harness.service.trustedHubKey = { "other hub" }
    _ = harness.service.post("t/key", options: .init(auth: .key)) { () -> String in "ok" }
    #expect(try await harness.send([("t/key", nil, alice)]) == ["unauthorized|unauthorized"])
    harness.service.trustedHubKey = { "hub" }
    #expect(try await harness.send([("t/key", nil, alice)]) == ["ok"])
  }

  @Test("bodies that don't decode or validate fail with invalid_input; HubError keeps its code")
  func input() async throws {
    let harness = Harness()
    _ = harness.service
      .post("t/post") { (post: NewPost) -> String in post.text }
      .post("t/missing") { () -> String in throw HubError.notFound("post not found") }
    let replies = try await harness.send([
      ("t/post", #"{"text":"hi"}"#, alice), ("t/post", #"{"text":""}"#, alice), ("t/post", #"{"title":1}"#, alice),
      ("t/missing", nil, alice),
    ])
    #expect(replies == ["hi", "text required|invalid_input", "invalid input|invalid_input", "post not found|not_found"])
  }

  @Test("rate limits count each caller, share buckets and can be turned off")
  func rateLimits() async throws {
    let harness = Harness()
    harness.service.rateLimit = RateLimit(limit: 1, window: 60, bucket: "shared")
    _ = harness.service
      .post("t/limited", options: .init(rateLimit: RateLimit(limit: 2, window: 60))) { () -> String in "ok" }
      .post("t/a") { () -> String in "a" }
      .post("t/b") { () -> String in "b" }
      .post("t/free", options: .init(rateLimit: .off)) { () -> String in "free" }
    let replies = try await harness.send([
      ("t/limited", nil, alice), ("t/limited", nil, alice), ("t/limited", nil, alice), ("t/limited", nil, editor),
      ("t/a", nil, alice), ("t/b", nil, alice), ("t/free", nil, alice), ("t/free", nil, alice),
    ])
    #expect(replies == [
      "ok", "ok", "rate limited, retry after 60 s|rate_limited", "ok", "a", "rate limited, retry after 60 s|rate_limited", "free", "free",
    ])
  }

  @Test("context.user is trusted from delegates and owners only")
  func delegates() async throws {
    let harness = Harness()
    harness.service.delegates = ["editors"]
    _ = harness.service.post("posts/create", options: .init(auth: .user)) { () -> String in
      try HubRequest.current!.requireUser().id
    }
    func withUser(_ context: String, _ user: String) -> String {
      String(context.dropLast()) + #","user":\#(user)}"#
    }
    let replies = try await harness.send([
      ("posts/create", nil, withUser(editor, #""u1""#)), ("posts/create", nil, withUser(editor, #"{"id":"u2","name":"Ann"}"#)),
      ("posts/create", nil, withUser(owner, #""u3""#)), ("posts/create", nil, withUser(alice, #""u1""#)), ("posts/create", nil, editor),
    ])
    #expect(replies == ["u1", "u2", "u3", "user required|unauthorized", "user required|unauthorized"])
  }

  @Test("a permission is answered locally for owners and anonymous callers and fails closed without a hub")
  func permissions() async throws {
    let harness = Harness()
    _ = harness.service.post("posts/delete", options: .init(permission: "posts/moderate")) { () -> String in "deleted" }
    let replies = try await harness.send([("posts/delete", nil, owner), ("posts/delete", nil, nil), ("posts/delete", nil, alice)])
    #expect(replies == ["deleted", "unauthorized|unauthorized", "not connected to a hub|unavailable"])
  }

  @Test("a cancelled post or stream cancels its handler, also while a stream waits")
  func cancellation() async throws {
    let harness = Harness()
    let seen = Flags()
    _ = harness.service
      .post("t/slow") { () -> String in
        do {
          try await Task.sleep(nanoseconds: 10_000_000_000)
        } catch {
          await MainActor.run { seen.postCancelled = true }
          throw error
        }
        return "late"
      }
      .stream("t/feed") { continuation in
        continuation.yield("first")
        do {
          try await Task.sleep(nanoseconds: 10_000_000_000)
        } catch {
          await MainActor.run { seen.streamCancelled = true }
        }
      }
    harness.receive(#"[{"id":10,"path":"t/slow","context":\#(alice)},{"id":11,"stream":"t/feed","context":\#(alice)}]"#)
    try await wait { harness.service.runningCalls == 2 && harness.seen.responses.count == 1 }
    harness.receive(#"[{"cancel":10},{"cancel":11}]"#)
    try await wait { seen.postCancelled && seen.streamCancelled && harness.service.runningCalls == 0 }
  }

  @Test("a service that isn't ready refuses calls and registers draining")
  func ready() async throws {
    let harness = Harness()
    _ = harness.service.post("t/a") { () -> String in "a" }
    await harness.service.setReady(false)
    #expect(harness.service.health.status == .disconnected)
    #expect(try await harness.send([("t/a", nil, alice)]) == ["service unavailable|unavailable"])
    let update = HubService.Update(services: [], apps: [], reporter: nil, draining: harness.service.acceptsCalls ? nil : true)
    #expect(!update.isEmpty)
    await harness.service.setReady(true)
    #expect(try await harness.send([("t/a", nil, alice)]) == ["a"])
  }

  @Test("shutdown ends streams, waits for posts and refuses new calls")
  func shutdown() async throws {
    let harness = Harness()
    let gate = Gate()
    _ = harness.service
      .post("t/work") { () -> String in
        await gate.wait()
        return "done"
      }
      .stream("t/live") { continuation in
        while !Task.isCancelled {
          continuation.yield(1)
          try await Task.sleep(nanoseconds: 5_000_000)
        }
      }
    harness.receive(#"[{"id":20,"path":"t/work","context":\#(alice)},{"id":21,"stream":"t/live","context":\#(alice)}]"#)
    try await wait { harness.service.runningCalls == 2 }
    let shutdown = Task { await harness.service.shutdown(timeout: 5) }
    try await wait { harness.service.health.status == .shuttingDown && harness.service.runningCalls == 1 }
    #expect(harness.seen.responses.contains { $0.contains(#""done":true"#) && $0.contains(#""id":21"#) })
    #expect(try await harness.send([("t/work", nil, alice)]) == ["service unavailable|unavailable"])
    await gate.open()
    #expect(await shutdown.value)
    #expect(harness.seen.responses.contains { $0.contains(#""body":"done""#) && $0.contains(#""id":20"#) })
  }

  @Test("shutdown cancels calls still running at the timeout")
  func shutdownTimeout() async throws {
    let harness = Harness()
    let seen = Flags()
    _ = harness.service.post("t/stuck") { () -> String in
      do {
        try await Task.sleep(nanoseconds: 10_000_000_000)
      } catch {
        await MainActor.run { seen.postCancelled = true }
      }
      return "x"
    }
    harness.receive(#"[{"id":30,"path":"t/stuck","context":\#(alice)}]"#)
    try await wait { harness.service.runningCalls == 1 }
    #expect(!(await harness.service.shutdown(timeout: 0.05)))
    try await wait { seen.postCancelled }
  }
}

private struct NewPost: Decodable, Sendable, Validatable {
  var text: String
  func validate() throws {
    if text.isEmpty { throw HubError.invalidInput("text required") }
  }
}

@MainActor
private final class Flags {
  var postCancelled = false
  var streamCancelled = false
}

private actor Gate {
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

@MainActor
private func wait(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() {
    if Date() > deadline {
      Issue.record("timed out")
      return
    }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
}

/// A service fed raw channel messages, with its responses recorded
@MainActor
private final class Harness {
  let channel = Channel<Void>()
  let service: HubService
  let seen = Replies()
  private var nextId = 1000
  init() {
    service = HubService(channel: channel)
  }
  func receive(_ json: String) {
    let messages = try! JSONDecoder().decode([ReceivedResponse].self, from: Data(json.utf8))
    channel.receive(messages, controller: Recorder(seen: seen, sender: ChannelSender(ch: channel, connection: Silent())))
  }
  /// Sends posts and returns each reply as its body text, or `message|code` for an error
  func send(_ calls: [(path: String, body: String?, context: String?)]) async throws -> [String] {
    var replies = [String]()
    for call in calls {
      nextId += 1
      let id = nextId
      var message = #"{"id":\#(id),"path":"\#(call.path)""#
      if let body = call.body { message += #","body":\#(body)"# }
      if let context = call.context { message += #","context":\#(context)"# }
      receive("[\(message)}]")
      let deadline = Date().addingTimeInterval(3)
      while seen.reply(id) == nil, Date() < deadline {
        try await Task.sleep(nanoseconds: 2_000_000)
      }
      replies.append(seen.reply(id) ?? "no reply")
    }
    return replies
  }
}

@MainActor
private final class Replies {
  var responses = [String]()
  func reply(_ id: Int) -> String? {
    for response in responses {
      guard let object = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any], object["id"] as? Int == id else { continue }
      if let error = object["error"] as? String { return "\(error)|\(object["code"].map { "\($0)" } ?? "")" }
      if let body = object["body"] as? String { return body }
      return response
    }
    return nil
  }
}

private struct Encoded: Encodable {
  let value: Encodable
  func encode(to encoder: any Encoder) throws {
    try value.encode(to: encoder)
  }
}

private final class Silent: ConnectionInterface, @unchecked Sendable {
  func send<Body: Encodable>(_ body: Body) -> Int { 0 }
  func sent(_ id: Int) { }
  func cancel(_ id: Int) -> Bool { false }
  func notify<Body: Encodable>(_ body: Body) { }
  func addTopic(topic: String, event: @escaping @MainActor (AnyBody) -> Void) -> @Sendable @MainActor () -> Bool { { false } }
  func stop() { }
  var requestTimeout: TimeInterval? { nil }
}

@MainActor
private struct Recorder: Controller {
  let seen: Replies
  let sender: any Sender
  var state: Void { () }
  func respond(_ response: Encodable & Sendable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    if let data = try? encoder.encode(Encoded(value: response)) {
      seen.responses.append(String(decoding: data, as: UTF8.self))
    }
  }
  func subscribe(_ topic: String) { }
  func unsubscribe(_ topic: String) { }
  func event(_ topic: String, _ event: AnyBody) { }
}
