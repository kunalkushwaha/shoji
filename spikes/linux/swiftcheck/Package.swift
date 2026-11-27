// swift-tools-version:5.9
// Proves the Linux structure: Swift on top, WPE behind a small C shim.
import PackageDescription

let package = Package(
  name: "swiftcheck",
  targets: [
    .systemLibrary(name: "CWPE", path: "Sources/CWPE", pkgConfig: "wpe-webkit-2.0"),
    .target(name: "CShim", dependencies: ["CWPE"], path: "Sources/CShim"),
    .executableTarget(name: "swiftcheck", dependencies: ["CShim"], path: "Sources/swiftcheck"),
  ]
)
