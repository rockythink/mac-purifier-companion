// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MacFanLink",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacFanLink", targets: ["MacFanLink"]),
        .executable(name: "FanHelper", targets: ["FanHelper"])
    ],
    targets: [
        .executableTarget(
            name: "MacFanLink",
            dependencies: ["FanControlProtocol"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .target(name: "FanControlProtocol"),
        .executableTarget(name: "FanHelper", dependencies: ["FanControlProtocol"]),
        .testTarget(name: "FanHelperTests", dependencies: ["FanHelper"], path: "tests/FanHelperTests")
    ]
)
