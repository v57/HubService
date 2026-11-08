# HubUI

## Purpose

`HubUI` draws what services publish: their apps, Home widgets and web apps, plus a file browser for the hub's
storage service and a pairing status view. It is the renderer the Hub app uses, so a client that embeds it shows a
service's app the way the Hub app does. It reads the connection from the SwiftUI environment and streams each app
itself; you give it an `AppHeader`.

It does not publish apps (a service does that with [HubService](HubService.md#apps) or hub-service's
[app builders](https://github.com/v57/hub-service/blob/main/docs/apps.md)), and it has no navigation or list of apps
of its own: the client decides where apps appear.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/HubService.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [
    .product(name: "HubService", package: "HubService"),
    .product(name: "HubUI", package: "HubService"),
  ]),
]
```

A list of a hub's apps that opens each one. The hub lists apps in the `apps` of `hub/status/badges`:

```swift
import SwiftUI
import HubService
import HubUI

struct ServiceApps: View {
  let client: HubClient
  @State private var apps = [AppHeader]()
  var body: some View {
    NavigationStack {
      List(apps) { header in
        NavigationLink(header.name) {
          if header.web != nil {
            HubWebAppView(header: header)
          } else {
            HubAppView(header: header)
          }
        }
      }
      .task {
        do {
          for try await badges: Badges in client.values("hub/status/badges") { apps = badges.apps ?? [] }
        } catch {}
      }
    }
    .environment(client) // every HubUI view reads the HubClient from here
  }
  private struct Badges: Decodable { var apps: [AppHeader]? }
}
```

`AppHeader.isOnline` is false when no connected service publishes the app (`services == 0`).

## Main API

| API | What it does |
|---|---|
| `HubAppView(header:)` | Opens the app's stream at `header.path` and draws its body, top and bottom bars, keeping `data` and running actions as the user. With several providers of the app, a picker at the bottom chooses one |
| `HubWidgetView(header:size:)` | The app's widget body for a `WidgetSize` (`.x11`, `.x12`, `.x21`, `.x22` for 1x1 ... 2x2), or its body; resubscribes when the stream ends |
| `HubWebAppView(header:)` | A web app in a web view kept on its origin and `origins`, with `window.hub` (page tokens, posts under the app's path). Needs WebKit |
| `HubFiles(path:)` | A file browser for the hub's storage service (`s3/list`, `s3/read`, `s3/delete`, uploads by drag and drop) |
| `HubStorageUpload.upload(files:directory:to:context:)` | Uploads files through HubUI's upload queue (`s3/write`), for clients with their own file browser |
| `HubPairing`, `PairingStatusView` | Pairing state for a view (`pair(_:code:)`, `state`, `reset()`) and a view that shows it |
| `AppPreview { ... }` | Elements drawn without a hub, for SwiftUI previews: `.top { }`, `.bottom { }`, `.data([...])` |
| `.hubCardStyle { $0.background(.thinMaterial) }` | Draws the apps' cards (card sections, file panels) as the client's own cards |
| `EnvironmentValues.hubName`, `.serviceContext` | The hub's display name; the `HubContext` (provider choice) calls are sent with |

`Element` conforms to `View`, so a client can also draw elements it built or decoded itself inside the environment of
a `HubAppView`.

How the elements behave (bindings, actions, lists, charts, files) is the app protocol, described in hub-service's
[Apps](https://github.com/v57/hub-service/blob/main/docs/apps.md) and in `Docs/Apps/ui.md` in the Hub workspace.
Elements HubUI doesn't know are dropped, and the page then says the service uses a newer interface.

## Platform notes

- **macOS 14, iOS and iPadOS 17, visionOS, tvOS 17, watchOS 10**: the views are marked for these. Some controls
  differ: sliders aren't drawn on tvOS, and the file browser shows no file list on tvOS and
  watchOS. Charts use Swift Charts. `HubWebAppView` needs WebKit (macOS, iOS, visionOS).
- **Linux**: the manifest builds HubUI on v57/SwiftUI (GitHub `main`, or a local checkout at `../../../v57/SwiftUI`
  with `V57_LOCAL=1`). Charts show "Charts aren't available here", and there is no `HubWebAppView`. Not tested at
  runtime.
- **Windows, Android**: the manifest uses v57/SwiftUI there too; no build is recorded.

## Testing

HubUI has no test target. `swift test` runs the package's `HubServiceTests`, which decode the shared app fixture
(`Tests/HubServiceTests/Fixtures/app-interface.json`, a copy of hub-service's `testdata/apps/interface.json`) into
the `Element` types HubUI draws. Use `AppPreview` and `HubClient.test` in previews; to see a real app, run a service
against a local hub (`bunx v57/hub-server --local`) and open it in a `HubAppView`.
