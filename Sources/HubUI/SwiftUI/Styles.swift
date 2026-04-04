//
//  File.swift
//  HubService
//
//  Created by Linux on 04.04.26.
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension Text {
  func note() -> Text {
    font(.system(size: 12, weight: .medium, design: .rounded))
  }
  func secondary() -> Text {
    note().foregroundStyle(.secondary)
  }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension View {
  func note() -> some View {
    font(.system(size: 12, weight: .medium, design: .rounded))
  }
  func secondary() -> some View {
    note().foregroundStyle(.secondary)
  }
}

#if !os(tvOS)
@available(iOS 17.0, macOS 14.0, watchOS 10.0, *)
public extension PickerStyle where Self == PalettePickerStyle {
  static var main: PalettePickerStyle { .palette }
}
#else
@available(tvOS 17.0, *)
public extension PickerStyle where Self == MenuPickerStyle {
  static var main: MenuPickerStyle { .menu }
}
#endif

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public extension View {
  func textSelection() -> some View {
#if os(iOS) || os(macOS)
    textSelection(.enabled)
#else
    self
#endif
  }
  func dropFiles<Transferable: SwiftUI.Transferable>(action: @escaping ([Transferable], CGPoint) -> Bool) -> some View {
#if os(iOS) || os(macOS)
    dropDestination(action: action)
#else
    self
#endif
  }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public struct TabButtonStyle: ButtonStyle {
  private let selected: Bool
  public init(selected: Bool) {
    self.selected = selected
  }
  public func makeBody(configuration: Configuration) -> some View {
    let up = configuration.isPressed
    configuration.label.note()
      .foregroundStyle(.red)
      .labelStyle(LabelStyle())
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(.black.opacity(0.001))
      .background(.red.opacity(selected ? 0.1 : 0), in: .capsule)
      .scaleEffect(up ? 1.1 : 1.0)
      .animation(.spring(response: up ? 0.1 : 0.5, dampingFraction: up ? 1.0 : 0.5), value: up)
      .contentTransition(.numericText())
  }
  struct LabelStyle: SwiftUI.LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
      HStack(spacing: 4) {
        configuration.icon.frame(height: 0).contentTransition(.symbolEffect)
        configuration.title
      }
    }
  }
}
