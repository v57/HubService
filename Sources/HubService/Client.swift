//
//  File.swift
//  WebSocket
//
//  Created by Dmitry Kozlov on 17/2/25.
//

import Foundation
import Channel

@MainActor
public class HubClient: @MainActor Identifiable {
  public static let test = HubClient(connect: false)
  public var id: URL { url }
  public nonisolated static var local: URL { URL(string: "ws://127.0.0.1:1997")! }
  public var isConnected: Bool { sender.ws.isConnected }
  public var isConnectedChanged: ((Bool) -> Void)? {
    get { sender.ws.isConnectedChanged }
    set { sender.ws.isConnectedChanged = newValue }
  }
  public var debugNetwork: Bool {
    get { sender.ws.debug }
    set { sender.ws.debug = newValue }
  }
  public let url: URL
  public let channel: Channel<Void>
  public let service: HubService
  public var profile: Profile
  private var sender: ClientSender<Void>!
  public init(_ url: URL = HubClient.local, keyChain: KeyChain? = nil, connect: Bool = true) {
    self.url = url
    channel = Channel()
    service = HubService(channel: channel)
    profile = Profile(name: .device, icon: .device)
    guard connect else { return }
    if let keyChain {
      let serviceKey = keyChain.publicKey()
      service.network.configureIdentity(keyChain)
      sender = channel.connect(url, options: ClientOptions(headers: {
        let key = serviceKey
        let time = "\(Int(Date().timeIntervalSince1970 + 60))"
        let sign = keyChain.sign(text: time)
        return ["auth": "key.\(key).\(sign).\(time)"]
      }, onConnect: { [weak self] sender in
        guard let self else { return }
        try? await sender.send("hub/profile/update", profile)
        try await service.sendServiceUpdates(first: true)
        try await service.network.didConnect(sender)
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
  public func send<Context: Encodable & Sendable, Output: Decodable>(_ path: String, context: Context?) async throws -> Output {
    try await sender.send(path, options: SendOptions(context: context))
  }
  public func send<Context: Encodable & Sendable>(_ path: String, context: Context?) async throws {
    try await sender.send(path, options: SendOptions(context: context))
  }
  public func send<Body: Encodable, Context: Encodable & Sendable>(_ path: String, _ body: Body?, context: Context?) async throws {
    try await sender.send(path, body, options: SendOptions(context: context))
  }
  public func send<Body: Encodable, Context: Encodable & Sendable, Output: Decodable>(_ path: String, _ body: Body?, context: Context?) async throws -> Output {
    try await sender.send(path, body, options: SendOptions(context: context))
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
  public func values<Context: Encodable & Sendable, Output: Decodable>(_ path: String, context: Context?) -> Values<Void, EmptyCodable, Context, Output> {
    sender.values(path, options: SendOptions(context: context))
  }
  public func values<Context: Encodable & Sendable>(_ path: String, context: Context?) -> Values<Void, EmptyCodable, Context, EmptyCodable> {
    sender.values(path, options: SendOptions(context: context))
  }
  public func values<Body: Encodable, Context: Encodable & Sendable>(_ path: String, _ body: Body?, context: Context?) -> Values<Void, Body, Context, EmptyCodable> {
    sender.values(path, body, options: SendOptions(context: context))
  }
  public func values<Body: Encodable, Context: Encodable & Sendable, Output: Decodable>(_ path: String, _ body: Body?, context: Context?) -> Values<Void, Body, Context, Output> {
    sender.values(path, body, options: SendOptions(context: context))
  }
  /// Reads one stream value and releases its iterator immediately, causing
  /// Channel to cancel the remote stream instead of leaving a subscription.
  public func oneValue<Output: Decodable & Sendable>(
    _ path: String,
    as type: Output.Type = Output.self
  ) async throws -> Output {
    var iterator: ValuesIterator<Void, EmptyCodable, EmptyCodable, Output>? =
      values(path).makeAsyncIterator()
    guard let value = try await iterator?.next() else {
      throw HubClientStreamError.finishedWithoutValue(path)
    }
    iterator = nil
    return value
  }

  /// Body-bearing variant used by one-value bootstrap and lookup streams.
  public func oneValue<Body: Encodable & Sendable, Output: Decodable & Sendable>(
    _ path: String,
    _ body: Body?,
    as type: Output.Type = Output.self
  ) async throws -> Output {
    var iterator: ValuesIterator<Void, Body, EmptyCodable, Output>? =
      values(path, body).makeAsyncIterator()
    guard let value = try await iterator?.next() else {
      throw HubClientStreamError.finishedWithoutValue(path)
    }
    iterator = nil
    return value
  }
  public func stop() {
    sender.stop()
  }
  public struct Profile: Codable, Sendable, Hashable {
    public var name: String
    public var icon: Icon
  }
}

public enum HubClientStreamError: Error, Equatable, Sendable {
  case finishedWithoutValue(String)
}
