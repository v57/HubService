<h1>
  <img alt="Containerization logo" src="./icon.png" width="70" valign="middle">
  &nbsp;Hub Service
</h1>

> Made for [Hub](https://hub.v57.dev)

Hub Service allows you to connect to Hub, use it's api or share your own. 

### Features
- Connect to hub-server and pair as its first owner
- Call api, stream updates
- Add your own `async` and `AsyncIterator` api to Hub, with caller checks, permissions, rate limits and graceful shutdown
- Display and interract with apps
- Post your own apps


### Getting started
```swift
// Create hub connection
let url: URL // "wss://example.com/hub"
let client = HubClient(url, keyChain: KeyChain(keyChain: "com.example.YourApp"), connect: true)

// Host your service
client.service.post("myservice/x2") { (value: Int) in
  return value * 2
}

// Call Hub api
let availableApi: Set<String> = try await client.send("hub/api")

// Test your service
print(try await client.send("myservice/x2", 2) == 4)
```

### Pairing with a new hub-server
A new hub-server shows a 6-symbol pairing code (and a `hub://pair?a=<address>&c=<code>` link). Sending it makes
the client's key, and its device, an owner. The hub checks one code at a time, at least a second each.
```swift
let link = PairingLink("hub://pair?a=192.168.1.10:1997&c=K7Q-2MX") // or PairingCode.normalize("k7q 2mx")
let client = HubClient(url, keyChain: keyChain, options: .init(device: device))
do {
  let result = try await client.pair(code: "k7q-2mx") { state in print(state) } // .connecting, .verifying
  print(result.owner, result.hubKey)
} catch let error as PairingError {
  print(error) // .invalidCode, .noCode, .notConnected, ...
}
```
HubUI's `HubPairing` keeps the state for a view and `PairingStatusView` shows it.

### Who may call, errors and shutdown
Handlers read the caller from `HubRequest.current` (trusted only from the pinned hub). Options declare who may call,
checked before the handler; failures are `HubError`s whose message and code reach the caller through the hub.
```swift
client.service.delegates = ["gateways"]   // members may act for end users with `context.user`
client.service
  .post("posts/create", options: .init(auth: .user, rateLimit: RateLimit(limit: 30, window: 60))) { (post: NewPost) in
    try await posts.insert(post, author: HubRequest.current!.requireUser().id)
  }
  .post("posts/delete", options: .init(permission: "posts/moderate")) { (id: String) in   // an owner grants it on the hub
    guard try await posts.exists(id) else { throw HubError.notFound("post not found") }
  }
  .post("admin/reindex", options: .init(auth: .owner)) { () in … }

struct NewPost: Decodable, Sendable, Validatable {   // bodies that don't decode or validate fail with invalid_input
  var text: String
  func validate() throws { if text.isEmpty { throw HubError.invalidInput("text required") } }
}
```
- `auth`: `.key`, `.device`, `.owner`, `.user`; `groups: [...]`; `permission: "posts/moderate"` (asks the hub with
  `hub/grant/check`); `rateLimit` per caller (`HubService.rateLimit` is the default, `.off` turns it off). Inside a
  handler: `HubRequest.current?.requireOwner()`, `requireDevice()`, `requireGroup(...)`, `requireUser()`,
  `can(_:)`, `requirePermission(_:)`.
- Codes: `unauthorized`, `forbidden`, `invalid_input`, `rate_limited`, `unavailable`, `not_found`. Other errors reach
  the caller as `internal error`. Swift services can't attach `info` yet.
- Cancellation is the task's: a caller that cancels or leaves cancels the handler (posts and streams, also while a
  stream waits between values).
- `await service.setReady(false)` keeps the paths registered without taking calls; `await client.shutdown(timeout: 10)`
  stops new calls, ends streams, waits for running posts and disconnects. `service.health` and `runningCalls` say
  where it stands.

The same features in TypeScript, and what other languages implement: hub-service's `docs/service-features.md`.
