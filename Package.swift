// swift-tools-version: 6.1
import PackageDescription

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
  ]
)
