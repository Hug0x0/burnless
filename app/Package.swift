// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Burnless",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "Burnless", targets: ["Burnless"])],
  targets: [
    // Report decoding, aggregation, caching and the engine process client.
    // Kept free of SwiftUI so it can be tested headlessly.
    .target(name: "BurnlessCore"),
    .executableTarget(
      name: "Burnless", dependencies: ["BurnlessCore"],
      resources: [.copy("Resources/AppIcon.icns"), .copy("Resources/Brands")]),
    .testTarget(name: "BurnlessCoreTests", dependencies: ["BurnlessCore"]),
  ]
)
