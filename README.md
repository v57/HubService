<h1>
  <img alt="Containerization logo" src="./icon.png" width="70" valign="middle">
  &nbsp;Hub Service
</h1>

> Made for [Hub](https://hub.v57.dev)

Hub Service allows you to connect to Hub, use it's api or share your own. 

### Features
- Connect to hub-server and pair as its first owner
- Call api, stream updates
- Add your own `async` and `AsyncIterator` api to Hub
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
