//
//  Widget.swift
//  HubUI
//
//  A service app shown as a Home widget (Docs/Apps/ui.md, "Widgets").
//

#if !canImport(SwiftCrossUI)
import SwiftUI
import HubService

/// The widget body for `size`, or the app's `body` when it has no widget content. Streams the app like `HubAppView`.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
public struct HubWidgetView: View {
  @EnvironmentObject private var hub: HubClient
  @State private var app = ServiceApp()
  let header: AppHeader
  let size: WidgetSize
  public init(header: AppHeader, size: WidgetSize) {
    self.header = header
    self.size = size
  }
  public var body: some View {
    // The tile's size comes from Home's grid: content taller than the tile (a long list) is cut off, never drawn
    // over the next tiles. A flexible frame would grow to the content, so lay it over a view that takes the tile's size
    Color.clear.overlay(alignment: .topLeading) {
      VStack(alignment: .leading, spacing: 8) {
        if let body = app.app.widget?[size] ?? app.app.body {
          ForEach(body) { $0 }
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }.frame(maxWidth: .infinity, alignment: .topLeading)
    }.clipped()
      .environment(app)
      .environment(\.hubWidgetSize, size)
      .task(id: Subscription(client: ObjectIdentifier(hub), path: header.path)) {
        app.reset()
        // Home keeps widgets on screen for long, so they subscribe again when their stream ends or fails
        while !Task.isCancelled {
          await app.sync(hub: hub, path: header.path)
          try? await Task.sleep(for: .seconds(3))
        }
      }
  }
  /// A new client for the same hub (after pairing, or a new identity) restarts the stream
  struct Subscription: Hashable {
    let client: ObjectIdentifier
    let path: String
  }
}
#endif
