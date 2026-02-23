// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "HubService",
  platforms: [.iOS(.v15), .macCatalyst(.v15), .tvOS(.v15), .macOS(.v12), .watchOS(.v8), .visionOS(.v1)],
  products: [.library(name: "HubService", targets: ["HubService"])],
  dependencies: [.package(url: "https://github.com/v57/ChannelSwift.git", branch: "main")],
  targets: [
    .target(name: "HubService", dependencies: [.product(name: "Channel", package: "ChannelSwift")]),
  ]
)
