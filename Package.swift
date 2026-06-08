import Foundation
// swift-tools-version:6.1
import PackageDescription

let sharedSwiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault"),
]

var boatToolsKitDeps: [Target.Dependency] = [
  .product(name: "Stheno", package: "Stheno")
]

// Executable target dependencies are assembled here (mirroring `boatToolsKitDeps`)
// so the NIO products can be appended only on non-Windows platforms.
var boatToolsDeps: [Target.Dependency] = [
  "BoatToolsKit",
  .product(name: "Stheno", package: "Stheno"),
  .product(name: "ArgumentParser", package: "swift-argument-parser"),
]

var deps: [Package.Dependency] = [
  .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
]

// swift-nio (TCP/UDP networking via NIOPosix) plus the HTTP + WebSocket stack do
// not build on Windows: NIOPosix fails against the Windows SDK, and
// AsyncHTTPClient/WebSocketKit are not supported there either. The web-facing
// code paths (Signal K REST/WebSocket and Victron VRM) and all NIO-based
// transports are compiled out on Windows via `#if !os(Windows)` guards in the
// sources. The Signal K / NMEA decoders, the simulator and the metric store
// stay available on Windows.
#if !os(Windows)
  deps.append(.package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"))
  deps.append(.package(url: "https://github.com/swift-server/async-http-client", from: "1.20.0"))
  deps.append(.package(url: "https://github.com/vapor/websocket-kit.git", from: "2.14.0"))
  boatToolsKitDeps.append(.product(name: "NIOCore", package: "swift-nio"))
  boatToolsKitDeps.append(.product(name: "NIOPosix", package: "swift-nio"))
  boatToolsKitDeps.append(.product(name: "AsyncHTTPClient", package: "async-http-client"))
  boatToolsKitDeps.append(.product(name: "WebSocketKit", package: "websocket-kit"))
  boatToolsDeps.append(.product(name: "NIOCore", package: "swift-nio"))
  boatToolsDeps.append(.product(name: "NIOPosix", package: "swift-nio"))
#endif

// Stheno: use the sibling working copy only during local development — never
// when BoatTools is itself a checked-out dependency (its parent directory is
// SwiftPM's `checkouts/`). In that case a sibling `Stheno` checkout would
// otherwise be referenced by path and clash with a URL-based `Stheno` declared
// by the consuming package ("conflicting identity for stheno").
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let siblingsRoot = packageDirectory.deletingLastPathComponent()
let localSthenoPath = siblingsRoot.appendingPathComponent("Stheno").path
if siblingsRoot.lastPathComponent != "checkouts",
  FileManager.default.fileExists(atPath: localSthenoPath)
{
  // Local development: use the sibling working copy of Stheno.
  deps.append(.package(path: localSthenoPath))
} else {
  // CI / fresh clone: resolve from GitHub.
  deps.append(.package(url: "https://github.com/auvents-brave/Stheno", branch: "main"))
}

let extraTargets: [Target] = [
  .testTarget(
    name: "BoatToolsKitTests",
    dependencies: ["BoatToolsKit"],
    path: "Tests/BoatToolsKitTests",
    resources: [.process("Resources")],
    swiftSettings: sharedSwiftSettings
  )
]

let package = Package(
  name: "BoatTools",
  platforms: [
    .macOS(.v14),
    .macCatalyst(.v17),
    .iOS(.v17),
    .tvOS(.v17),
    .watchOS(.v11),
    .visionOS(.v1),
  ],
  products: [
    .library(name: "BoatToolsKit", targets: ["BoatToolsKit"]),
    .executable(name: "boattools", targets: ["BoatTools"]),
  ],
  dependencies: deps,
  targets: [
    .target(
      name: "BoatToolsKit",
      dependencies: boatToolsKitDeps,
      path: "Sources/BoatToolsKit",
      swiftSettings: sharedSwiftSettings
    ),
    .executableTarget(
      name: "BoatTools",
      dependencies: boatToolsDeps,
      path: "Sources/BoatTools",
      swiftSettings: sharedSwiftSettings
    ),
  ] + extraTargets
)
