//
//  File.swift
//  WebSocket
//
//  Created by Dmitry Kozlov on 17/2/25.
//

import Foundation
import Combine
import Channel

@MainActor
public class HubClient {
  public nonisolated static var local: URL { URL(string: "ws://127.0.0.1:1997")! }
  public var isConnected: Published<Bool>.Publisher {
    sender.ws.$isConnected
  }
  public var debugNetwork: Bool {
    get { sender.ws.debug }
    set { sender.ws.debug = newValue }
  }
  public let channel: Channel<Void>
  public let service: HubService
  public var profile: Profile
  private var sender: ClientSender<Void>!
  public init(_ url: URL = HubClient.local, keyChain: KeyChain? = nil) {
    channel = Channel()
    service = HubService(channel: channel)
    profile = Profile(name: .device, icon: .device)
    if let keyChain {
      sender = channel.connect(url, options: ClientOptions(headers: {
        let key = keyChain.publicKey()
        let time = "\(Int(Date().timeIntervalSince1970 + 60))"
        let sign = keyChain.sign(text: time)
        return ["auth": "key.\(key).\(sign).\(time)"]
      }, onConnect: { [weak self] sender in
        guard let self else { return }
        try? await sender.send("hub/profile/update", profile)
        try await service.sendServiceUpdates()
      }))
    } else {
      sender = channel.connect(url)
    }
    service.sender = sender
  }
  // No body
  public func send<Output: Decodable>(_ path: String) async throws -> Output {
    try await sender.send(path)
  }
  public func send(_ path: String) async throws {
    try await sender.send(path)
  }
  // With body
  public func send<Body: Encodable>(_ path: String, _ body: Body?) async throws {
    try await sender.send(path, body)
  }
  public func send<Body: Encodable, Output: Decodable>(_ path: String, _ body: Body?) async throws -> Output {
    try await sender.send(path, body)
  }
  // With context
  public func send<Context: Encodable, Output: Decodable>(_ path: String, context: Context?) async throws -> Output {
    try await sender.send(path, context: context)
  }
  public func send<Context: Encodable>(_ path: String, context: Context?) async throws {
    try await sender.send(path, context: context)
  }
  public func send<Body: Encodable, Context: Encodable>(_ path: String, _ body: Body?, context: Context?) async throws {
    try await sender.send(path, body, context: context)
  }
  public func send<Body: Encodable, Context: Encodable, Output: Decodable>(_ path: String, _ body: Body?, context: Context?) async throws -> Output {
    try await sender.send(path, body, context: context)
  }
  // No body
  public func values<Output: Decodable>(_ path: String) -> Values<Void, EmptyCodable, EmptyCodable, Output> {
    sender.values(path)
  }
  public func values(_ path: String) -> Values<Void, EmptyCodable, EmptyCodable, EmptyCodable> {
    sender.values(path)
  }
  // With body
  public func values<Body: Encodable>(_ path: String, _ body: Body?) -> Values<Void, Body, EmptyCodable, EmptyCodable> {
    sender.values(path, body)
  }
  public func values<Body: Encodable, Output: Decodable>(_ path: String, _ body: Body?) -> Values<Void, Body, EmptyCodable, Output> {
    sender.values(path, body)
  }
  // With context
  public func values<Context: Encodable, Output: Decodable>(_ path: String, context: Context?) -> Values<Void, EmptyCodable, Context, Output> {
    sender.values(path, context: context)
  }
  public func values<Context: Encodable>(_ path: String, context: Context?) -> Values<Void, EmptyCodable, Context, EmptyCodable> {
    sender.values(path, context: context)
  }
  public func values<Body: Encodable, Context: Encodable>(_ path: String, _ body: Body?, context: Context?) -> Values<Void, Body, Context, EmptyCodable> {
    sender.values(path, body, context: context)
  }
  public func values<Body: Encodable, Context: Encodable, Output: Decodable>(_ path: String, _ body: Body?, context: Context?) -> Values<Void, Body, Context, Output> {
    sender.values(path, body, context: context)
  }
  public func stop() {
    sender.stop()
  }
  public struct Profile: Codable, Sendable, Hashable {
    public var name: String
    public var icon: Icon
  }
}

