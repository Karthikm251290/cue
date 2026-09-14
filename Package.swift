// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SessionControl", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "SessionControl", targets: ["SessionApp"]),
    .executable(name: "SessionReporter", targets: ["SessionReporter"]),
  ],
  targets: [
    .target(
      name: "CPlatform",
      linkerSettings: [
        .linkedLibrary("sqlite3"), .linkedFramework("IOKit"), .linkedFramework("CoreFoundation"),
      ]),
    .target(name: "SessionCore", dependencies: ["CPlatform"]),
    .executableTarget(name: "SessionReporter", dependencies: ["SessionCore"]),
    .executableTarget(name: "SessionApp", dependencies: ["SessionCore", "CPlatform"]),
    .testTarget(name: "SessionCoreTests", dependencies: ["SessionCore"]),
    .testTarget(name: "SessionAppTests", dependencies: ["SessionApp"]),
  ], swiftLanguageModes: [.v5])
