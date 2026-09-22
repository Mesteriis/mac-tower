// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacTower",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacTower", targets: ["MacTowerApp"]),
        .executable(name: "mac-tower-daemon", targets: ["MacTowerDaemon"]),
    ],
    targets: [
        .target(name: "MacTowerCore", path: "src/MacTowerCore"),
        .executableTarget(
            name: "MacTowerApp",
            dependencies: ["MacTowerCore"],
            path: "src/MacTowerApp"
        ),
        .executableTarget(
            name: "MacTowerDaemon",
            dependencies: ["MacTowerCore"],
            path: "src/MacTowerDaemon"
        ),
        .testTarget(
            name: "MacTowerCoreTests",
            dependencies: ["MacTowerCore"],
            path: "tests/MacTowerCoreTests"
        ),
    ]
)
