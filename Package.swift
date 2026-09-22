// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacTower",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacTower", targets: ["MacTowerApp"]),
        .executable(name: "mac-tower-daemon", targets: ["MacTowerDaemon"]),
        .executable(name: "mac-tower-claude-bridge", targets: ["MacTowerClaudeBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.90.0"),
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", exact: "2.13.0"),
    ],
    targets: [
        .target(name: "MacTowerCore", path: "src/MacTowerCore"),
        .target(
            name: "MacTowerTransport",
            dependencies: [
                "MacTowerCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "MQTTNIO", package: "mqtt-nio"),
            ],
            path: "src/MacTowerTransport"
        ),
        .executableTarget(
            name: "MacTowerApp",
            dependencies: ["MacTowerCore"],
            path: "src/MacTowerApp"
        ),
        .executableTarget(
            name: "MacTowerDaemon",
            dependencies: ["MacTowerCore", "MacTowerTransport"],
            path: "src/MacTowerDaemon"
        ),
        .executableTarget(
            name: "MacTowerClaudeBridge",
            dependencies: ["MacTowerCore"],
            path: "src/MacTowerClaudeBridge"
        ),
        .testTarget(
            name: "MacTowerCoreTests",
            dependencies: ["MacTowerCore"],
            path: "tests/MacTowerCoreTests"
        ),
    ]
)
