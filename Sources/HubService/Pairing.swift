//
//  Pairing.swift
//  HubService
//
//  Pairs the first owner with the single-use code a new hub-server shows (protocol §12).
//

import Foundation
import Channel

/// The 6-symbol pairing code: Crockford base32 without `I L O U`, shown as `K7Q-2MX`
public enum PairingCode {
  public static let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  public static let length = 6

  /// Uppercases the input and drops spaces and `-`. Reads the look-alikes Crockford excludes (`O` as `0`, `I` and `L`
  /// as `1`), which a valid code never contains. `nil` unless the result is 6 symbols of the alphabet.
  public static func normalize(_ input: String) -> String? {
    var code = ""
    for character in input.uppercased() {
      switch character {
      case " ", "-", "\t", "\n", "\u{00A0}": continue
      case "O": code.append("0")
      case "I", "L": code.append("1")
      default:
        guard alphabet.contains(character) else { return nil }
        code.append(character)
      }
    }
    return code.count == length ? code : nil
  }

  /// `K7Q2MX` → `K7Q-2MX`. Other input is returned as it is.
  public static func format(_ code: String) -> String {
    guard let code = normalize(code) else { return code }
    return "\(code.prefix(3))-\(code.suffix(3))"
  }
}

/// `hub://pair?a=<address>&c=<code>`: a hub address and its pairing code, from the launcher's link or QR
public struct PairingLink: Hashable, Sendable {
  public static let scheme = "hub"
  public static let host = "pair"
  /// The hub address as the link carries it (`192.168.1.10:1997`, `ws://…`, `wss://…`)
  public var address: String
  /// The normalized code
  public var code: String

  public init?(address: String, code: String) {
    let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !address.isEmpty, let code = PairingCode.normalize(code) else { return nil }
    self.address = address
    self.code = code
  }

  public init?(url: URL) {
    guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.host,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
          let address = items.first(where: { $0.name == "a" })?.value,
          let code = items.first(where: { $0.name == "c" })?.value else { return nil }
    self.init(address: address, code: code)
  }

  /// Reads a pasted or scanned link; `nil` for anything else
  public init?(_ string: String) {
    guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    self.init(url: url)
  }

  /// Whether the text is meant as a pairing link, valid or not
  public static func isPairingLink(_ string: String) -> Bool {
    string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("\(scheme)://\(host)")
  }

  public var url: URL {
    var components = URLComponents()
    components.scheme = Self.scheme
    components.host = Self.host
    components.queryItems = [URLQueryItem(name: "a", value: address), URLQueryItem(name: "c", value: code)]
    return components.url!
  }
}

/// `hub/pair` answer: the caller is now an owner of the hub
public struct PairingResult: Codable, Hashable, Sendable {
  public var owner: Bool
  public var hubKey: String
  public var name: String?
  public init(owner: Bool, hubKey: String, name: String? = nil) {
    self.owner = owner
    self.hubKey = hubKey
    self.name = name
  }
}

public enum PairingError: Error, Hashable, Sendable, LocalizedError, CustomStringConvertible {
  /// The input isn't 6 symbols of the code alphabet
  case malformedCode
  /// The hub rejected the code (`invalid pairing code`). After 10 wrong codes the hub drops the code.
  case invalidCode
  /// The hub has no pairing code (`no pairing code`): it expired, was used, or the hub already has an owner
  case noCode
  /// The connection didn't become ready, with the hub's refusal when it gave one
  case notConnected(HubClient.Refusal?)
  /// The hub that answered `hub/pair` has another key than the one pinned at connect
  case hubKeyMismatch(pinned: String, received: String)
  /// The hub doesn't pair: no `hub/pair` or no `hub/info` (an older hub)
  case unsupported
  case timeout
  case failed(String)

  public init(_ error: Error) {
    if let error = error as? PairingError {
      self = error
      return
    }
    guard let error = error as? ChannelError else {
      self = .failed(error.localizedDescription)
      return
    }
    switch error.text {
    case "invalid pairing code": self = .invalidCode
    case "no pairing code": self = .noCode
    default:
      if error.code == .notFound || error.text == "not found" || error.text == "api not found" {
        self = .unsupported
      } else if error.code == .timeout {
        self = .timeout
      } else if error.code == .refused {
        self = .notConnected(nil)
      } else {
        self = .failed(error.text)
      }
    }
  }

  public var description: String {
    switch self {
    case .malformedCode: "A pairing code has 6 letters and digits, like K7Q-2MX."
    case .invalidCode: "This pairing code is wrong. Check it and try again; after 10 wrong codes the hub needs a new one."
    case .noCode: "The hub has no pairing code: it expired or was already used. Create a new one with hub-launcher or `hub-server --pair`."
    case .notConnected(let refusal?): refusal.description
    case .notConnected(nil): "Couldn't connect to the hub. Check the address and that hub-server is running."
    case .hubKeyMismatch: "Another hub answered than the one this device connected to."
    case .unsupported: "This hub doesn't support pairing. Update it to hub-server."
    case .timeout: "The hub didn't answer in time. Try again."
    case .failed(let text): text
    }
  }
  public var errorDescription: String? { description }
}

/// Where a pairing is, for UI. Verification takes at least a second on the hub, so `verifying` is a visible state.
public enum PairingState: Hashable, Sendable {
  case idle
  /// Connecting and learning the hub key
  case connecting
  /// `hub/pair` sent; the hub checks one code at a time, at least a second each
  case verifying
  case paired(PairingResult)
  case failed(PairingError)

  public var isWorking: Bool {
    switch self {
    case .connecting, .verifying: true
    default: false
    }
  }
}

public extension HubClient {
  /// Sends a pairing code to the hub and makes this client's key (and its device, when it has one) an owner.
  ///
  /// Waits until the connection is ready, so the hub key is pinned and `hub/pair` goes over the hub-bound `v: 1`
  /// connection with the device certificate. Takes at least a second: the hub verifies one code at a time.
  /// - Parameter code: as typed: case, spaces and `-` don't matter
  /// - Parameter progress: called with `.connecting` and `.verifying`
  /// - Throws: `PairingError`
  @discardableResult
  func pair(code: String, timeout: TimeInterval = 30,
            progress: (@MainActor (PairingState) -> Void)? = nil) async throws -> PairingResult {
    guard let code = PairingCode.normalize(code) else { throw PairingError.malformedCode }
    progress?(.connecting)
    guard await waitUntilReady(timeout: 15) else {
      throw PairingError.notConnected(await refusalReason(timeout: 3))
    }
    // Without a hub key the hub can't bind the owner to this hub or see the device certificate
    guard hubKey != nil else { throw PairingError.unsupported }
    progress?(.verifying)
    let result: PairingResult
    do {
      result = try await send("hub/pair", Pair(code: code), timeout: timeout)
    } catch {
      throw PairingError(error)
    }
    if let pinned = hubKey, pinned != result.hubKey {
      throw PairingError.hubKeyMismatch(pinned: pinned, received: result.hubKey)
    }
    return result
  }

  internal struct Pair: Codable, Sendable {
    var code: String
  }
}
