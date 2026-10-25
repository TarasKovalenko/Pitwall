// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pitwall",
    platforms: [.macOS(.v14)],
    products: [
        // Linked by App/Pitwall.xcodeproj.
        .library(name: "PitwallCore", targets: ["PitwallCore"]),
        // Used by scripts/build-app.sh for command-line builds.
        .executable(name: "pitwall-app", targets: ["PitwallApp"]),
    ],
    targets: [
        .target(name: "PitwallCore"),
        .executableTarget(name: "PitwallApp", dependencies: ["PitwallCore"], path: "Sources/Pitwall"),
        .testTarget(name: "PitwallCoreTests", dependencies: ["PitwallCore"]),
    ]
)
