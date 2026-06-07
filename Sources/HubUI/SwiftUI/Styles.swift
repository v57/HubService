//
//  File.swift
//  HubService
//
//  Created by Linux on 04.04.26.
//

import SwiftUI

public extension ShapeStyle where Self == Color {
  static var hubTint: Color { Color.hubTint }
}
public extension Color {
  static var hubTint: Color {
#if os(visionOS)
    .white
#else
    .red
#endif
  }
}

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

#if os(watchOS)
public extension PickerStyle where Self == DefaultPickerStyle {
  static var main: DefaultPickerStyle { .automatic }
}
#elseif os(tvOS)
@available(tvOS 17.0, *)
public extension PickerStyle where Self == MenuPickerStyle {
  static var main: MenuPickerStyle { .menu }
}
#else
@available(iOS 17.0, macOS 14.0, *)
public extension PickerStyle where Self == PalettePickerStyle {
  static var main: PalettePickerStyle { .palette }
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
  @Environment(\.isFocused) private var isFocused
  private let selected: Bool
  public init(selected: Bool) {
    self.selected = selected
  }
  private var focusOffset: Double { isFocused ? 0.2 : 0.0 }
  public func makeBody(configuration: Configuration) -> some View {
    let up = configuration.isPressed
    configuration.label.note()
      .foregroundStyle(.hubTint)
      .labelStyle(LabelStyle())
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(.black.opacity(0.001))
      .background(.hubTint.opacity((selected ? 0.1 : 0) + focusOffset), in: .capsule)
      .scaleEffect((up ? 1.1 : 1.0) + focusOffset)
      .animation(.spring(response: up ? 0.1 : 0.5, dampingFraction: up ? 1.0 : 0.5), value: up)
      .animation(.spring, value: isFocused)
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
