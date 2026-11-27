// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "wkterm",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "wkterm",
      path: "Sources/wkterm",
      swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
    )
  ]
)
