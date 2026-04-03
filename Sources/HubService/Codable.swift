//
//  File.swift
//  HubService
//
//  Created by Linux on 19.07.25.
//

import Foundation

public enum AnyCodable: Codable, Hashable, Sendable {
  case dictionary([String: AnyCodable])
  case array([AnyCodable])
  case string(String)
  case int(Int)
  case double(Double)
  case date(Date)
  case void
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode([String: AnyCodable].self) {
      self = .dictionary(value)
    } else if let value = try? container.decode([AnyCodable].self) {
      self = .array(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(Date.self) {
      self = .date(value)
    } else {
      self = .void
    }
  }
  
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .dictionary(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .int(let value):
      try container.encode(value)
    case .double(let value):
      try container.encode(value)
    case .date(let value):
      try container.encode(value)
    case .void: break
    }
  }
}
public extension AnyCodable {
  var dictionary: [String: AnyCodable]? {
    get {
      switch self {
      case .dictionary(let dictionary): dictionary
      default: nil
      }
    } set {
      if let newValue {
        self = .dictionary(newValue)
      }
    }
  }
  var array: [AnyCodable]? {
    get {
      switch self {
      case .array(let array): array
      case .string(let string): [.string(string)]
      case .int(let int): [.int(int)]
      case .double(let double): [.double(double)]
      case .date(let date): [.date(date)]
      default: nil
      }
    } set {
      if let newValue {
        self = .array(newValue)
      }
    }
  }
  var string: String? {
    get {
      switch self {
      case .dictionary, .array, .void: nil
      case .string(let string): string
      case .int(let int): String(int)
      case .double(let double): String(double)
      case .date(let date): date.formatted()
      }
    } set {
      if let newValue {
        self = .string(newValue)
      }
    }
  }
  var int: Int? {
    get {
      switch self {
      case .dictionary, .array, .date, .void: nil
      case .string(let string): Int(string)
      case .int(let int): int
      case .double(let double): Int(double)
      }
    } set {
      if let newValue {
        self = .int(newValue)
      }
    }
  }
  var double: Double? {
    get {
      switch self {
      case .dictionary, .array, .date, .void: nil
      case .string(let string): Double(string)
      case .int(let int): Double(int)
      case .double(let double): double
      }
    } set {
      if let newValue {
        self = .double(newValue)
      }
    }
  }
  var date: Date? {
    get {
      switch self {
      case .date(let date): date
      default: nil
      }
    } set {
      if let newValue {
        self = .date(newValue)
      }
    }
  }
}

struct Lossy<T: Decodable>: Decodable {
  let value: T?
  init(from decoder: any Decoder) throws {
    do {
      value = try decoder.decode()
    } catch {
      addWarning()
      value = nil
    }
  }
}
struct LossyArray<Element: Decodable>: Decodable {
  let value: [Element]
  init(from decoder: any Decoder) throws {
    value = (try? decoder.decodeLossy()) ?? []
  }
}

public extension Decoder {
  @inlinable
  func decode<T: Decodable>() throws -> T {
    try singleValueContainer().decode(T.self)
  }
  func decodeLossy<Element: Decodable>() throws -> [Element] {
    do {
      return try singleValueContainer().decode([Lossy<Element>].self).compactMap { $0.value }
    } catch {
      addWarning()
      return []
    }
  }
}

public extension KeyedDecodingContainer {
  @inlinable
  func decode<T: Decodable>(_ key: K) throws -> T {
    try decode(T.self, forKey: key)
  }
  @inlinable
  func decodeIfPresent<T: Decodable>(_ key: K) -> T? {
    do {
      return try decodeIfPresent(T.self, forKey: key)
    } catch {
      addWarning()
      return nil
    }
  }
  @inlinable
  func decodeIfPresent<T: Decodable>(_ key: K, _ defalutValue: @autoclosure () -> (T)) -> T {
    decodeIfPresent(key) ?? defalutValue()
  }
  func decodeLossy<Element: Decodable>(_ key: K) -> [Element] {
    do {
      return try decode([Lossy<Element>].self, forKey: key).compactMap { $0.value }
    } catch {
      addWarning()
      return []
    }
  }
  func decodeLossyIfPresent<Element: Decodable>(_ key: K) -> [Element]? {
    do {
      return try decodeIfPresent([Lossy<Element>].self, forKey: key)?
        .compactMap { $0.value }
    } catch {
      addWarning()
      return nil
    }
  }
}

@usableFromInline
enum DecodingWarnings {
  @usableFromInline
  @TaskLocal static var counter: Counter?
  
  @usableFromInline
  final class Counter: @unchecked Sendable {
    private(set) var count = 0
    
    @usableFromInline
    init() {}
    
    @usableFromInline
    func increment() {
      count += 1
    }
  }
}

@usableFromInline
@inline(__always)
func addWarning() {
  DecodingWarnings.counter?.increment()
}

public extension KeyedEncodingContainer {
  mutating func encodeIfPresent<T: Codable & Equatable>(_ value: T, forKey key: Key, defaultValue: T) throws {
    guard value != defaultValue else { return }
    try encode(value, forKey: key)
  }
}
