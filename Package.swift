// swift-tools-version: 6.3
import PackageDescription

#if canImport(CryptoKit)
let package = Package(
  name: "HubService",
  platforms: [.macOS(.v10_15), .iOS(.v13), .visionOS(.v1), .tvOS(.v13), .watchOS(.v6), .macCatalyst(.v13)],
  products: [
    .library(name: "HubService", targets: ["HubService"]),
    .library(name: "HubUI", targets: ["HubUI"])
  ],
  dependencies: [.package(url: "https://github.com/v57/ChannelSwift.git", branch: "main")],
  targets: [
    .target(name: "HubService", dependencies: [.product(name: "Channel", package: "ChannelSwift")]),
    .target(name: "HubUI", dependencies: ["HubService", .product(name: "Channel", package: "ChannelSwift")]),
    .testTarget(
      name: "HubServiceTests",
      dependencies: ["HubService"],
      exclude: ["HubNetworkWireCompatibility.md"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
#else // Linux/Windows/Android
let package = Package(
  name: "HubService",
  platforms: [.macOS(.v10_15), .iOS(.v13), .visionOS(.v1), .tvOS(.v13), .watchOS(.v6), .macCatalyst(.v13)],
  products: [
    .library(name: "HubService", targets: ["HubService"]),
    .library(name: "HubUI", targets: ["HubUI"])
  ],
  dependencies: [
    .package(url: "https://github.com/v57/ChannelSwift.git", branch: "main"),
    .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "5.0.0"),
  ],
  targets: [
    .target(name: "HubService", dependencies: [
      .product(name: "Channel", package: "ChannelSwift"),
      .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows, .android])),
    ]),
    .target(name: "HubUI", dependencies: [
      "HubService", .product(name: "Channel", package: "ChannelSwift"), .product(name: "SwiftUI", package: "SwiftUI"),
    ]),
    .testTarget(
      name: "HubServiceTests",
      dependencies: [
        "HubService",
        .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows, .android])),
      ],
      exclude: ["HubNetworkWireCompatibility.md"],
      resources: [.copy("Fixtures")]
    ),
  ]
)

// Off Apple platforms SwiftUI is v57/SwiftUI, as for ComponentKit: GitHub's main branch, or the checkout at
// ~/Developer/v57/SwiftUI with `V57_LOCAL=1`.
package.dependencies.append(Context.environment["V57_LOCAL"] == nil
  ? .package(url: "https://github.com/v57/SwiftUI.git", branch: "main") : .package(path: "../../../v57/SwiftUI"))
#endif
