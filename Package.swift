// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "shoji",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "shoji",
      path: "Sources/shoji",
      swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
    )
  ]
)
