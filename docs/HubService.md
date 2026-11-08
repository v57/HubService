# HubService

## Purpose

`HubService` connects a Swift program to a [Hub](https://github.com/v57/hub-server). One `HubClient` is both a client,
calling any path the hub routes (`send`, `values`), and a service, publishing its own paths (`client.service.post`,
`.stream`) and apps. It handles auth v2 (the hub proves its key before the client sends anything), device
certificates, pairing with a new hub-server, the devices API and Hub Network shares. The Hub app is built on it, and
so are Swift services and the v57 apps that talk to a hub.

It is the Swift port of the TypeScript reference, [hub-service](https://github.com/v57/hub-service). The concepts
(paths, post and stream, settings, apps, the wire contract) are explained once in
[the hub-service guide](https://github.com/v57/hub-service/blob/main/docs/README.md); this page covers the Swift API.
It is not a hub: to run one in Swift, see `HubServer` in the Hub project. Drawing service apps is
[HubUI](HubUI.md)'s job.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/HubService.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "HubService", package: "HubService")]),
]
```

Add `.package(url: "https://github.com/v57/ChannelSwift.git", branch: "main")` and its `Channel` product too when
your code names Channel's types (`ChannelError`, `Channel`).

A service that is also a client, against a local hub (`bunx v57/hub-server --local` listens on `127.0.0.1:1997`):

```swift
import Foundation
import HubService

@main @MainActor
struct Echo {
  static func main() async throws {
    // The service key, created on first run. `.keychain("com.example.Echo")` keeps it in the Keychain instead.
    let client = HubClient(HubClient.local, keyChain: .file(URL(fileURLWithPath: "echo.key")))
    client.profile.name = "Echo"
    client.profile.icon = .plain(text: "E", symbol: "arrow.left.arrow.right")
    _ = client.service
      .post("echo/upper") { (text: String) in text.uppercased() }
      .stream("echo/count") { (to: Int, continuation) in
        for i in 1...max(to, 1) { continuation.yield(i) } // returning ends the stream
      }

    guard await client.waitUntilReady() else {
      print(client.refusal?.description ?? "not connected")
      return
    }
    let upper: String = try await client.send("echo/upper", "hello")   // "HELLO"
    for try await n: Int in client.values("echo/count", 3) { print(n) } // 1, 2, 3
    print(upper)
    while true { try await Task.sleep(nanoseconds: 60_000_000_000) }
  }
}
```

`HubClient` is `@MainActor` and `@Observable`. It starts connecting in its initializer; register paths, apps and the
profile right after creating it, before the connection opens. Paths added later reach the hub with
`client.service.sendServiceUpdates()`. An owner has to allow a new service key before it can host paths (the Hub
app shows it); a hub in local mode allows everything.

## Main API

### Connecting: `HubClient`

| API | What it does |
|---|---|
| `HubClient(_ url: URL = HubClient.local, keyChain: KeyChain? = nil, connect: Bool = true, options: Options = Options())` | Connects. Without a `keyChain` the connection is anonymous: it can call public paths and publishes nothing |
| `Options(hubKey:hubKeys:device:instance:alternateURLs:allowPlaintext:)` | A hub key known up front, where pins live, the device and instance name for certificates, other addresses of the same hub, plain `ws://` on a private network |
| `send(_:)`, `send(_:_:)`, `send(_:_:timeout:)`, `send(_:_:context:)` | Posts; the return type picks the decoded output |
| `values(_:)`, `values(_:_:)`, `values(_:_:context:)` | Streams, as an `AsyncSequence` |
| `oneValue(_:as:)`, `oneValue(_:_:as:)` | The first value of a stream, then cancels it |
| `isConnected`, `isReady`, `waitUntilReady(timeout:)` | Connection state; `isReady` means the services are registered |
| `info`, `hubKey`, `transport`, `currentURL` | `hub/info` as proven, the pinned key, how the connection travels (`HubTransport`), the address in use |
| `profile` | `name` and `icon` (`Icon.plain(text:symbol:)`), sent as `hub/profile/update` on connect; the device's name and icon by default |
| `stop()`, `shutdown(timeout:)` | Disconnect, or shut the service down gracefully first |
| `apiList()` | `hub/api/list`, see [API descriptions](#api-descriptions) |
| `devices` | The devices API, see [Devices](#devices-and-certificates) |
| `pair(code:timeout:progress:)` | Pairs with a new hub-server and makes this key an owner ([README](../README.md#pairing-with-a-new-hub-server)) |

Keys (`KeyChain`): `.file(URL)` (the raw 32-byte key), `.keychain(String)` (a Keychain item on Apple platforms, the
Secret Service on Linux), `KeyChain(keychain: KeychainConfiguration)` (service, account, access group),
`KeyChain(keyFile:)` (the Hub key file format of a TypeScript service's `auth` file and of `device.key`) and
`KeyChain(.none)` (in memory, new each time). `keyChain.publicKey()` is the base64 SPKI key owners see.
`keyChain.hubCredential(_:address:)` derives a separate key per hub address from a device key (`HubCredentials`,
`HubAddress.canonical`), so what one hub sees means nothing on another.

### Publishing: `HubService`

`client.service` is the client's `HubService`. Each method returns the service, so calls chain.

| API | What it does |
|---|---|
| `post(_ path:, options:, request:)` | A request handler: `(Input) async throws -> Output`, `(Input) -> Void`, `() -> Output` or `() -> Void`. `Input` is `Decodable`, `Output` `Encodable` |
| `stream(_ path:, options:, request:)` | A stream handler: `(Input, Continuation) async throws -> Void` or `(Continuation) async throws -> Void`; `yield` values, and returning (or throwing) ends the stream |
| `app(_ app: App)` | Publishes an app, see [Apps](#apps) |
| `group(enabled:)` | A `Group` of paths and apps that can be switched off and on together (`isEnabled`) |
| `delegates`, `rateLimit` | Hub groups whose members may act for end users; the default per-caller limit |
| `setReady(_:)`, `shutdown(timeout:)`, `health`, `runningCalls`, `acceptsCalls` | Readiness and graceful shutdown |
| `apiDescriptions` | What the service says about its paths, as it will send them |
| `network` | `HubNetworkService`: Hub Network shares (`publish(_:)`, `update`, `remove`, `publications`) through the local hub-net agent |

### Options: who may call, limits, descriptions

`HubService.Options` is the third argument of `post` and `stream`:

| Option | Meaning |
|---|---|
| `auth` | `.key`, `.device`, `.owner` or `.user`, checked before the handler |
| `groups` | The caller must be in one of these hub groups (owners pass) |
| `permission` | A permission an owner grants on the hub, checked with `hub/grant/check`; it must be under the first segment of one of the service's paths |
| `rateLimit` | `RateLimit(limit:window:bucket:)` per caller; `.off` for none |
| `limit` | Calls the hub runs at once on this provider |
| `isPublic` | Callable by anyone on a hub in `default-deny` mode |
| `shutdown` | `.wait` (posts' default) or `.end` (streams' default) |
| `title`, `description`, `inputSchema`, `outputSchema`, `annotations`, `deriveSchemas` | [API descriptions](#api-descriptions) |
| `permissions` | The older permission label (`Permissions(group:name:)`), sent for hubs that use it |

```swift
client.service.delegates = ["gateways"]
_ = client.service
  .post("posts/create", options: .init(auth: .user, rateLimit: RateLimit(limit: 30, window: 60))) { (post: NewPost) in
    try await posts.insert(post, author: HubRequest.current!.requireUser().id)
  }
  .post("posts/delete", options: .init(permission: "posts/moderate")) { (id: String) in
    guard await posts.exists(id) else { throw HubError.notFound("post not found") }
    await posts.delete(id)
  }

struct NewPost: Decodable, Sendable, Validatable {
  var text: String
  func validate() throws { if text.isEmpty { throw HubError.invalidInput("text required") } }
}
```

- Inside a handler, `HubRequest.current` is the request: `caller` (trusted only when the hub that forwarded it is the
  pinned hub), `user`, `path`, and the checks `requireKey()`, `requireDevice()`, `requireOwner()`,
  `requireGroup(_:)`, `requireUser()`, `can(_:)`, `requirePermission(_:)`.
- A body that doesn't decode, or a `Validatable` body whose `validate()` throws, fails with `invalid_input`.
- Throw `HubError` for errors the caller should see: `.unauthorized`, `.forbidden`, `.invalidInput`, `.notFound`,
  `.conflict`, `.rateLimited(retryAfter:)`, `.unavailable`, or `HubError(message, code:)`. Other errors reach the
  caller as `internal error`. Swift services can't attach `info` to an error yet.
- Cancellation is the task's: a caller that cancels or leaves cancels the handler, streams included.

The rules, error codes and hub APIs behind these are in hub-service's
[Service features](https://github.com/v57/hub-service/blob/main/docs/service-features.md).

### API descriptions

A path can say what it does, the way an MCP server describes its tools: `title`, `description`, `inputSchema`,
`outputSchema` (a `JSONSchema`) and `annotations` (`ApiAnnotations`, MCP's hints). The service sends them with its
paths, and any connection reads them back with `apiList()`. The design, the hub's rules and the mapping to MCP tools
are in hub-service's [API descriptions](https://github.com/v57/hub-service/blob/main/docs/api-descriptions.md); the
wire contract is section 15 of the Hub protocol.

The typed `post` overloads derive both schemas from the handler's Codable types when the options don't give them
(`deriveSchemas: false` turns that off). The typed `stream` overload derives the input schema only; give a stream's
`outputSchema` (the schema of each value) yourself.

```swift
import Foundation
import HubService

struct SearchQuery: Codable, Sendable {
  enum Order: String, Codable, CaseIterable, Sendable { case newest, oldest }
  var query: String
  var limit: Int?
  var order: Order
}

struct Note: Codable, Sendable {
  var id: UUID
  var text: String
  var updatedAt: Date
}

/// `NotesStore` is your storage: `search(_:) async -> [Note]`, `delete(_:) async`, `changes() -> AsyncStream<[Note]>`
@MainActor
func serveNotes(on client: HubClient, notes: NotesStore) {
  _ = client.service
    // inputSchema from SearchQuery, outputSchema from [Note]
    .post("notes/search", options: .init(
      title: "Search notes",
      description: "Notes whose text contains the query, newest first unless `order` says otherwise.",
      annotations: .readOnly
    )) { (query: SearchQuery) -> [Note] in
      await notes.search(query)
    }
    .stream("notes/changes", options: .init(
      title: "Watch notes",
      description: "Every note now, then again after each change.",
      outputSchema: .array(of: JSONSchema(for: Note.self) ?? .any),
      annotations: .readOnly
    )) { continuation in
      for await all in notes.changes() { continuation.yield(all) }
    }
    .post("notes/delete", options: .init(
      description: "Deletes a note. Deleting it again changes nothing.",
      inputSchema: .string("Note id", format: "uuid"),
      annotations: ApiAnnotations(destructiveHint: true, idempotentHint: true)
    )) { (id: UUID) in
      await notes.delete(id)
    }
}
```

`SearchQuery` becomes an object with `query` (string), `limit` (integer, not required), `order` (a string with
`enum: ["newest", "oldest"]`); `Note` an object with `id` (`format: uuid`), `text` and `updatedAt` (`format:
date-time`, as Channel sends dates).

Reading them back, from any connection:

```swift
for api in try await client.apiList() where api.path.hasPrefix("notes/") {
  print(api.id, "-", api.title ?? "", api.annotations?.readOnlyHint == true)
}
// notes/changes stream - Watch notes true
// notes/delete post - false
// notes/search post - Search notes true

for try await list: [ApiDescription] in client.values("hub/api/list") {
  print(list.count) // again whenever the hub's APIs change
}
```

- `JSONSchema(for: T.self)` derives a schema by decoding `T` once with a decoder that records what it is asked for:
  keys, optional keys, value types, nested containers, arrays, `Date`, `URL`, `UUID`, and `RawRepresentable &
  CaseIterable` enums. It is `nil` for types whose `init(from:)` rejects placeholder values, recursive types and enums
  with associated values; an output type that is only `Encodable` gets no schema. Describe those by hand.
- `JSONSchema` builders: `.string(_:format:)`, `.integer(_:)`, `.number(_:)`, `.boolean(_:)`, `.array(of:_:)`,
  `.object(_:required:_:)`, `.oneOf(_:_:)`, `.any`; `.described(_:)`, `.nullable` and `[property:]` adjust one; the
  other keywords of the subset (`minLength`, `maximum`, `pattern`, `cases`, `additionalProperties`, ...) are
  properties. Per-property descriptions come only from schemas you write.
- Schemas are published, not checked: the Swift SDK has no schema validator. Bodies are checked by decoding and
  `Validatable`.
- `ApiDescription` is one entry of `hub/api/list`: `path`, `kind` (`.post`, `.stream`, or `nil`), `title`,
  `description`, `inputSchema`, `outputSchema`, `annotations`, and `id` (`"<path> <kind>"`). Unknown kinds and
  keywords decode without failing. A hub from before descriptions answers `apiList()` with `api not found`.
- `client.service.apiDescriptions` lists what the service will send, sorted by path, which a test can check without a
  hub.

### Auth v2 and refusals

Before every connection the client asks `hub/info` on an anonymous connection with a nonce of its own. It pins the
hub's key only when the answer proves it (an Ed25519 signature over the nonce), then connects with a token for that
hub and that one challenge, valid for 30 seconds, sent only to the address that proved the key. Until a hub proves
its key the client sends it nothing. The details are section 2 of the Hub protocol (`Docs/Devices/protocol.md` in the
Hub workspace) and hub-service's [Auth](https://github.com/v57/hub-service/blob/main/docs/README.md#auth).

- Pins are kept per address in `HubKeyPins`: `hubs.json` beside a file key, a `<service>.hubs` Keychain item beside
  a Keychain key, memory otherwise (`Options.hubKeys` chooses). `forgetHubKey()` clears the pin and reconnects.
- `transport` says how the connection travels (`HubTransport`): `.encrypted` (`wss://`), `.loopback`, `.overlay` (Hub
  Network), `.localNetwork` (plain `ws://` on the LAN: allowed, and a UI should say it isn't encrypted) or `.refused`.
  Plain `ws://` beyond loopback, the overlay and the LAN isn't dialed unless `Options.allowPlaintext` is set.
- When the connection fails, `refusal` (observable) and `onRefused` say why, as a `HubClient.Refusal`:

| Refusal | Meaning |
|---|---|
| `.keyRefused` | The hub refuses this key: it or its device was revoked, or the device clock is off by more than 30 s |
| `.hubKeyChanged(pinned:current:)` | Another key answers at this address than the pinned one; `onHubKeyError` is called too |
| `.hubNotAvailable` | The hub accepts only clients it knows |
| `.plaintextNotAllowed` | The address would carry the key unencrypted; use `wss://` |
| `.hubNeedsUpdate` | The hub is from before auth v2 and can't prove its key. The client sends it nothing and looks again every 30 s, so it connects once the hub is updated. `HubClient.hubNeedsUpdateText` is the message to show |
| `.refused(statusCode:)` | Refused for another reason |

```swift
client.onRefused = { refusal in
  switch refusal {
  case .hubNeedsUpdate: showAlert(HubClient.hubNeedsUpdateText)
  case .hubKeyChanged: askToForgetKey()
  default: showAlert(refusal.description)
  }
}
```

`refusalReason(timeout:)` waits for the reason while disconnected. While refused, posts fail with Channel's `refused`
error and the client tries again every 30 seconds.

### Devices and certificates

A client that runs on a device sends a service certificate signed by the device key with every connection, so the
hub can tell which device a service runs on and owners approve the device once. Give it a `DeviceIdentity`:

```swift
// A command-line service: the device key file every service of this machine shares
let device = try DeviceIdentity.file() // HUB_DEVICE_KEY, else ~/.hub/device.key (/var/lib/hub for root on Linux)
// An app: a Keychain item, shared with its extensions through an access group
// let device = DeviceIdentity(key: try DeviceKey.keychain(accessGroup: nil), name: "My Mac")

let client = HubClient(url, keyChain: .keychain("com.example.Notes"), options: .init(device: device, instance: "notes"))
```

Certificates last at most 7 days and are signed again when needed. `instance` names this service on the device
(defaults to the profile name). `client.devices` is the devices API: `list()`, `pending()`, `request()` (this device's
own state), `data(_:)`, `approve`, `rename`, `remove`, `revoke`, grants (`grants()`, `addGrant`, `removeGrant`),
the security mode, providers of a path (`providers(_:)`), and child devices (`attachRequests()`, `askAttach`,
`attach(_:signingWith:hubKey:)`, `detach`, `setLinked`). Show `PendingDevice.verifiedCode(hubKey:)`, not the hub's
own `safetyCode`, so the code is checked against the key you pinned. `client.report(every:description:data:)` takes
the device's reporter role (`DeviceDescription`, `DeviceData`). The protocol is sections 3, 4, 13 and 14 of the Hub
protocol.

### Apps

A Swift service publishes apps with the same JSON as the TypeScript builders: `App`, `AppHeader`, and `Element`
values (aliases `HText`, `HTextField`, `HButton`, `HCell`, `HList`, `HStat`, ... and `HAction` for actions), built with
the `@ElementBuilder` result builder:

```swift
let hash = HAction(path: "hasher/all", body: .single("value"), output: .multiple(["sha256": "sha256"]))
_ = client.service
  .post("hasher/all") { (value: String) in ["sha256": sha256(value)] }
  .app(App(header: AppHeader(type: .app, name: "Hasher", path: "hasher/ui"), data: ["value": .string(""), "sha256": .string("")]) {
    HTextField(value: "value", placeholder: "Text to hash", action: hash)
    HCell(title: .text(HText(value: "SHA 256")), subtitle: .text(HText(value: "$sha256")))
    HButton(title: "Hash", action: hash)
  })
```

`app.widget(sizes:body:bodies:)` makes it a Home widget too. A Swift app sends one event: it has no live state yet,
and `Element.Files` has no public initializer. The binding rules and elements are in hub-service's
[Apps](https://github.com/v57/hub-service/blob/main/docs/apps.md); [HubUI](HubUI.md) draws them.

## Platform notes

- **macOS 14, iOS and iPadOS 17, visionOS 1, tvOS 17, watchOS 10, Mac Catalyst 17**: the package's platforms (the
  Observation macro sets the minimum). Keys use CryptoKit and the Keychain. Built and tested on macOS; the Hub app
  ships on it.
- **Linux**: builds (since 2026-10-28) with swift-crypto, and `KeyChain`'s Keychain locations store in the freedesktop
  Secret Service (libsecret, through v57/SwiftUI's `SecretService`); Hub Network address checks parse with
  `inet_pton`. File keys work everywhere.
- **Windows, Android**: the manifest selects swift-crypto for them and file keys work, but no build or test is
  recorded; there is no Keychain storage there.

## Testing

```sh
swift test                                  # unit tests, no hub needed
swift test --filter ApiDescription          # one suite
HUB_LIVE_URL=ws://127.0.0.1:1997 swift test --filter LiveHub
HUB_LIVE_URL=ws://127.0.0.1:1997 HUB_LIVE_OWNER_KEY=<owner key file> swift test --filter ServiceFeaturesLive
HUB_LIVE_OLD_URL=ws://127.0.0.1:<port> swift test --filter HubNeedsUpdate   # a hub-server from before auth v2
```

The live suites run only when their variables are set, against a hub-server you start. The package ships no fakes, but
it needs few for an app's tests:

- `HubService(channel: Channel<Void>())` (with `import Channel`) is a service with no connection: register paths and
  check `apiDescriptions`.
- `HubClient(url, keyChain: KeyChain(.none), options: .init(hubKeys: HubKeyPins(.memory)))` leaves no key or pin
  behind.
- `HubClient.test` is a client that never connects, for SwiftUI previews that don't call the hub.
- For a service's behaviour over a real hub, start hub-server in local mode and point a client at it, as the live
  suites do.
