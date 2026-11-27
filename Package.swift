// swift-tools-version:5.9
import PackageDescription

// macOS: WKWebView (WebKit is part of the system). Linux: WPE WebKit 2.54+ through a
// small C engine (Sources/CShojiWPE); see docs/linux.md.
let linux = TargetDependencyCondition.when(platforms: [.linux])

let package = Package(
  name: "shoji",
  platforms: [.macOS(.v13)],
  targets: [
    .systemLibrary(name: "CWPE", path: "Sources/CWPE", pkgConfig: "wpe-webkit-2.0"),
    .target(name: "CShojiWPE", dependencies: [.target(name: "CWPE", condition: linux)], path: "Sources/CShojiWPE",
            linkerSettings: [.linkedLibrary("png16", .when(platforms: [.linux]))]),
    .executableTarget(
      name: "shoji",
      dependencies: [.target(name: "CShojiWPE", condition: linux)],
      path: "Sources/shoji",
      swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
    )
  ]
)
