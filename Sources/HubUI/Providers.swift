//
//  File.swift
//  HubService
//
//  Created by Linux on 04.04.26.
//

import HubService
import SwiftUI

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension View {
  func syncProviders(path: String) -> some View {
    modifier(ServiceProvider.Sync(path: path))
  }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public struct ServiceProvider: Codable, Sendable, Hashable, Identifiable {
  public let id: String
  public let name: String?
  var label: String {
    let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let name, !name.isEmpty else { return id }
    return "\(name) (\(id))"
  }
  public init(id: String, name: String? = nil) {
    self.id = id
    self.name = name
  }
  struct Picker: View {
    @EnvironmentObject private var hub: HubClient
    @Environment(\.serviceProviders) private var providers
    
    let path: String
    @Binding var context: HubContext
    
    var body: some View {
      if !providers.isEmpty {
        SwiftUI.Picker("Provider", selection: $context.service) {
          Text("Automatic").tag(Optional<String>.none)
          ForEach(providers) { provider in
            Text(provider.label).tag(provider.id)
          }
        }.pickerStyle(.main).task(id: providers) {
          guard let service = context.service else { return }
          guard !providers.contains(where: { $0.id == service }) else { return }
          context.service = nil
        }
      }
    }
  }
  struct Sync: ViewModifier {
    @EnvironmentObject var hub: HubClient
    @State private var providers: [ServiceProvider] = []
    let path: String
    
    func body(content: Content) -> some View {
      content.task(id: hub.id) {
        do {
          for try await value: [ServiceProvider] in hub.values("hub/api/services", path) {
            providers = value
          }
        } catch { }
      }.environment(\.serviceProviders, providers)
    }
  }
}
struct ServicePickerModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
  }
}

public extension EnvironmentValues {
  var hubName: String {
    get { self[HubName.self] }
    set { self[HubName.self] = newValue }
  }
  var serviceContext: HubContext? {
    get { self[ServiceContextKey.self] }
    set { self[ServiceContextKey.self] = newValue }
  }
  @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
  var serviceProviders: [ServiceProvider] {
    get { self[Providers.self] }
    set { self[Providers.self] = newValue }
  }
  private struct HubName: EnvironmentKey {
    static var defaultValue: String { "Hub" }
  }
  @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
  private struct Providers: EnvironmentKey {
    static var defaultValue: [ServiceProvider] { [] }
  }
}
struct ServiceContextKey: EnvironmentKey, PreferenceKey {
  static var defaultValue: HubContext? { nil }
  static func reduce(value: inout HubContext?, nextValue: () -> HubContext?) {}
}
