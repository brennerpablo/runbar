// swift-tools-version:6.0
import PackageDescription

let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Runbar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "RunbarApp", targets: ["RunbarApp"]),
        .executable(name: "runbar", targets: ["runbar"]),
    ],
    targets: [
        .target(name: "RunbarCore", swiftSettings: settings),
        .executableTarget(name: "RunbarApp", dependencies: ["RunbarCore"], swiftSettings: settings),
        .executableTarget(name: "runbar", dependencies: ["RunbarCore"], path: "Sources/runbar-cli", swiftSettings: settings),
    ]
)
