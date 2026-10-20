import Foundation
import Testing
@testable import HubService
import Channel

@Suite("Device layer: caller")
@MainActor
struct CallerTests {
  @Test("the caller vector decodes")
  func decode() throws {
    let vectors = try Vectors.load()
    let hub = vectors.caller.context.hub
    #expect(hub.hubKey == vectors.keys["hub"]!.publicKey)
    #expect(hub.caller?.key == vectors.keys["service"]!.publicKey)
    #expect(hub.caller?.device == Caller.Device(id: "8cef065b7af83669150b7d32704d3d3e", name: "Mac Studio"))
    #expect(hub.caller?.groups == ["owners"])
    #expect(hub.caller?.owner == true)
  }

  @Test("post and stream handlers see HubRequest.caller")
  func handlers() async throws {
    let vectors = try Vectors.load()
    let channel = Channel<Void>()
    let service = HubService(channel: channel)
    let seen = Seen()
    _ = service
      .post("who") { (body: Int) -> String in
        "\(body) \(HubRequest.caller?.device?.name ?? "none") \(HubRequest.current?.path ?? "")"
      }
      .post("anonymous") { () -> Bool in
        HubRequest.caller == nil
      }
      .stream("watch") { continuation in
        continuation.yield(HubRequest.caller?.owner == true)
      }
    let context = try JSONEncoder().encode(["hub": vectors.caller.context.hub])
    let contextJSON = String(decoding: context, as: UTF8.self)
    let controller = RecordingController(seen: seen, sender: ChannelSender(ch: channel, connection: NoConnection()))
    let messages = try JSONDecoder().decode([ReceivedResponse].self, from: Data("""
    [{"id":0,"path":"who","body":7,"context":\(contextJSON)},
     {"id":1,"path":"anonymous"},
     {"id":2,"stream":"watch","context":\(contextJSON)}]
    """.utf8))
    channel.receive(messages, controller: controller)
    for _ in 0..<300 where seen.responses.count < 3 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let text = seen.responses.joined(separator: "\n")
    #expect(text.contains(#""body":"7 Mac Studio who""#))
    #expect(text.contains(#""id":1,"body":true"#) || text.contains(#""body":true,"id":1"#))
    #expect(text.contains(#""id":2"#))
    #expect(text.contains("true"))
  }
}

@MainActor
private final class Seen {
  var responses = [String]()
}

private struct Wrapped: Encodable {
  let value: Encodable
  func encode(to encoder: any Encoder) throws {
    try value.encode(to: encoder)
  }
}

private final class NoConnection: ConnectionInterface, @unchecked Sendable {
  func send<Body: Encodable>(_ body: Body) -> Int { 0 }
  func sent(_ id: Int) { }
  func cancel(_ id: Int) -> Bool { false }
  func notify<Body: Encodable>(_ body: Body) { }
  func addTopic(topic: String, event: @escaping @MainActor (AnyBody) -> Void) -> @Sendable @MainActor () -> Bool { { false } }
  func stop() { }
  var requestTimeout: TimeInterval? { nil }
}

@MainActor
private struct RecordingController: Controller {
  let seen: Seen
  let sender: any Sender
  var state: Void { () }
  func respond(_ response: Encodable & Sendable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    if let data = try? encoder.encode(Wrapped(value: response)) {
      seen.responses.append(String(decoding: data, as: UTF8.self))
    }
  }
  func subscribe(_ topic: String) { }
  func unsubscribe(_ topic: String) { }
  func event(_ topic: String, _ event: AnyBody) { }
}
