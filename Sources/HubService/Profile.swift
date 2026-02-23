//
//  File.swift
//  HubService
//
//  Created by Linux on 11.02.26.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct Icon: Codable, Hashable, Sendable {
  public static func plain(text: String? = nil, symbol: String? = nil) -> Icon {
    var icon = Icon()
    if let text {
      icon.text = Text(name: text)
    }
    if let symbol {
      icon.symbol = Symbol(name: symbol)
    }
    return icon
  }
  public var symbol: Symbol?
  public var text: Text?
  public init(symbol: Symbol? = nil, text: Text? = nil) {
    self.symbol = symbol
    self.text = text
  }
  public init(from decoder: any Decoder) throws {
    do {
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      self.text = .init(name: text)
    } catch {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      symbol = container.decodeIfPresent(.symbol)
      text = container.decodeIfPresent(.text)
    }
  }
  public struct Symbol: Codable, Hashable, Sendable {
    public var name: String
    public var colors: Colors?
    public init(from decoder: any Decoder) throws {
      do {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        self.name = text
      } catch {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(.name)
        colors = container.decodeIfPresent(.colors)
      }
    }
    public init(name: String, colors: Colors? = nil) {
      self.name = name
      self.colors = colors
    }
  }
  public struct Text: Codable, Hashable, Sendable {
    public var name: String
    public var colors: Colors?
    public init(from decoder: any Decoder) throws {
      do {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        self.name = text
      } catch {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(.name)
        colors = container.decodeIfPresent(.colors)
      }
    }
    public init(name: String, colors: Colors? = nil) {
      self.name = name
      self.colors = colors
    }
  }
  public struct Colors: Codable, Hashable, Sendable {
    public var foreground: String?
    public var foregroundDark: String?
    public var background: String?
    public var backgroundDark: String?
    public init(foreground: String? = nil, foregroundDark: String? = nil, background: String? = nil, backgroundDark: String? = nil) {
      self.foreground = foreground
      self.foregroundDark = foregroundDark
      self.background = background
      self.backgroundDark = backgroundDark
    }
    public func foreground(dark: Bool) -> String? {
      dark ? foregroundDark ?? foreground : foreground
    }
    public func background(dark: Bool) -> String? {
      dark ? backgroundDark ?? background : background
    }
  }
}

extension String {
  @MainActor
  static var device: String {
    #if canImport(UIKit)
    UIDevice.current.localizedModel
    #elseif os(macOS)
    Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    #else
    "Hub App"
    #endif
  }
}
extension Icon {
  @MainActor
  static var device: Icon {
    #if os(iOS)
    if UIDevice.current.userInterfaceIdiom == .pad {
      return .plain(text: "pad", symbol: "ipad")
    } else {
      return .plain(text: "phone", symbol: "iphone")
    }
    #elseif os(watchOS)
    return .plain(text: "watch", symbol: "applewatch")
    #elseif os(visionOS)
    return .plain(text: "VR", symbol: "vision.pro")
    #elseif os(macOS)
    return .plain(text: "mac", symbol: "macmini")
    #elseif os(tvOS)
    return .plain(text: "tv", symbol: "appletv")
    #else
    return .plain(text: "mac", symbol: "desktopcomputer")
    #endif
  }
}
