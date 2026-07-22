// swift-tools-version: 6.1

import PackageDescription

// The native bridge for non-Swift hosts (P/Invoke, ctypes, JNI…):
// BoatToolsKit compiled into one dynamic library exposing a C ABI — NMEA
// parsing, streaming connections, the device-sensor feed, AIS details and
// GMDSS forecasts. A nested package so the main library product and its
// consumers are untouched; build it with `swift build -c release` from this
// directory (on Windows, pass the CCurl include/lib flags — see BoatTools'
// own README).
let package = Package(
	name: "BoatToolsBridge",
	// macOS 15 for `Mutex` (Synchronization); Linux, Android and Windows get
	// it from the Swift 6 runtime.
	platforms: [.macOS(.v15)],
	products: [
		.library(name: "BoatToolsBridge", type: .dynamic, targets: ["BoatToolsBridge"])
	],
	dependencies: [
		.package(path: "..")
	],
	targets: [
		.target(
			name: "BoatToolsBridge",
			dependencies: [.product(name: "BoatToolsKit", package: "BoatTools")],
			swiftSettings: [
				.enableUpcomingFeature("InternalImportsByDefault"),
				.enableUpcomingFeature("ExistentialAny"),
				.swiftLanguageMode(.v6),
			]
		),
		.testTarget(
			name: "BoatToolsBridgeTests",
			dependencies: ["BoatToolsBridge"],
			swiftSettings: [
				.enableUpcomingFeature("InternalImportsByDefault"),
				.enableUpcomingFeature("ExistentialAny"),
				.swiftLanguageMode(.v6),
			]
		),
	]
)
