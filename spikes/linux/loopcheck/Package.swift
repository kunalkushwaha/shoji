// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "loopcheck", targets: [
  .systemLibrary(name: "CGLib", path: "Sources/CGLib", pkgConfig: "glib-2.0"),
  .target(name: "CLoop", dependencies: ["CGLib"], path: "Sources/CLoop"),
  .executableTarget(name: "loopcheck", dependencies: ["CLoop"], path: "Sources/loopcheck"),
])
